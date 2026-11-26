-- GameAlgo storage and transport lifecycle regressions, using the real modules.
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local lu = require("tests.support.TestCase")

local json = require("cjson")
HTTP_GET, HTTP_POST, HTTP_PUT, HTTP_DELETE, HTTP_PATCH = 1, 2, 3, 4, 5
local Storage = require("MakerAutoStorage")
local Transport = require("HttpTransport")
local Sha256 = require("Sha256")
local gameModule = "GameAlgo"
local queueKey = "review:events:jsonl"
local chunkKey = "gaq_" .. Sha256.hex(queueKey):sub(1, 24) .. "_1"
local files, writes, failWriteName, missingReads, writeHook, closeFault
local scheduler

local function seedFile(name, value)
    files[name] = json.encode(value) .. "\0"
end

local function decodeFile(name)
    return json.decode(assert(files[name]):sub(1, -2))
end

TestGameAlgoStorage = {}
function TestGameAlgoStorage:setUp()
    files, writes, missingReads = {}, {}, 0
    failWriteName, writeHook, closeFault = nil, nil, nil
    clientCloud, http, lobby, sdk = nil, nil, nil, nil
    package.loaded[gameModule] = nil
    FILE_READ, FILE_WRITE = 1, 2
    fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
    File = function(name, mode)
        if mode == FILE_READ and files[name] == nil then missingReads = missingReads + 1 end
        local buffer = mode == FILE_READ and files[name] or nil
        local opened = mode == FILE_WRITE or buffer ~= nil
        local position = 0
        return {
            IsOpen = function() return opened end,
            GetSize = function() return opened and #(buffer or "") or 0 end,
            GetPosition = function() return position end,
            ReadString = function()
                assert(opened and mode == FILE_READ)
                local value = buffer:sub(position + 1):match("^[^%z]*")
                position = math.min(#buffer, position + #value + 1)
                return value
            end,
            Read = function(_, size)
                assert(opened and mode == FILE_READ)
                local bytes = buffer:sub(position + 1, position + size)
                position = position + #bytes
                return { ReadString = function() return bytes:match("^[^%z]*") end }
            end,
            WriteString = function(_, value)
                assert(opened and mode == FILE_WRITE)
                if writeHook then writeHook(name, value) end
                if name == failWriteName then files[name] = "torn write"; return false end
                buffer = value .. "\0"
                table.insert(writes, name)
                return true
            end,
            -- Native WriteString can accept the buffer before the commit.
            -- Both Flush and Close return no values in the deployed binding.
            Flush = function() end,
            Close = function()
                if opened and mode == FILE_WRITE and buffer then
                    if closeFault then buffer = closeFault(name, buffer) end
                    files[name] = buffer
                end
                opened = false
            end,
        }
    end
    scheduler = { Schedule = function(_, _, callback) return { callback = callback } end,
        Cancel = function() end, IsAutomatic = function() return true end }
end

local function event(id)
    return { eventId = id, sessionId = "old-session", payload = { original = true } }
end

function TestGameAlgoStorage:test_local_start_and_restart_never_touch_cloud()
    local calls = 0
    clientCloud = { Get = function() calls = calls + 1 end, Set = function() calls = calls + 1 end }
    local first = assert(Storage.New({ scheduler = { Schedule = function() error("storage must be synchronous") end } }))
    lu.assertTrue(first:IsReady())
    lu.assertEquals(missingReads, 0)
    lu.assertTrue(first:SetItem("identity", "local-user"))
    lu.assertTrue(first:SetItem("script", "cached script"))
    local queue = first:EventQueue(queueKey)
    queue:Upsert(event("offline"))
    first:Flush(function(error) lu.assertNil(error) end)
    first:Shutdown()
    local second = assert(Storage.New())
    local ready = false
    second:OnReady(function() ready = true end)
    lu.assertTrue(ready)
    lu.assertEquals(second:GetItem("identity"), "local-user")
    lu.assertEquals(second:GetItem("script"), "cached script")
    lu.assertEquals(second:EventQueue(queueKey):Events(), { event("offline") })
    lu.assertEquals(calls, 0)
end

function TestGameAlgoStorage:test_old_cloud_metadata_is_ignored()
    seedFile("gamealgo_sdk_storage_v1.json", { schemaVersion = 1, revision = 5,
        cloudDirectoryBlocked = true, cloudDirectoryConfirmed = false,
        legacyCloudBaseline = "obsolete", data = { identity = "original" } })
    clientCloud = { Get = function() error("must not read cloud") end, Set = function() error("must not write cloud") end }
    local storage = assert(Storage.New())
    lu.assertTrue(storage:IsReady())
    lu.assertEquals(storage:GetItem("identity"), "original")
    lu.assertTrue(storage:SetItem("config", "cached"))
    local checkpoint = decodeFile("gamealgo_sdk_storage_v1.backup.json")
    lu.assertNil(checkpoint.cloudDirectoryBlocked)
    lu.assertNil(checkpoint.legacyCloudBaseline)
    lu.assertEquals(assert(Storage.New()):GetItem("config"), "cached")
end

function TestGameAlgoStorage:test_torn_snapshot_keeps_previous_committed_bank()
    local storage = assert(Storage.New())
    lu.assertTrue(storage:SetItem("identity", "stable"))
    local committedWrites = #writes
    for _ = 1, 3 do lu.assertTrue(storage:SetItem("identity", "stable")) end
    lu.assertEquals(#writes, committedWrites)
    failWriteName = writes[#writes] == "gamealgo_sdk_storage_v1.json"
        and "gamealgo_sdk_storage_v1.backup.json" or "gamealgo_sdk_storage_v1.json"
    lu.assertFalse(storage:SetItem("identity", "unsaved"))
    lu.assertEquals(storage:GetItem("identity"), "unsaved")
    lu.assertEquals(assert(Storage.New()):GetItem("identity"), "stable")
    failWriteName = nil
    storage:Flush(function(error) lu.assertNil(error) end)
    lu.assertEquals(assert(Storage.New()):GetItem("identity"), "unsaved")
end

local function flushStorage(storage)
    local calls, reason = 0, nil
    storage:Flush(function(err) calls, reason = calls + 1, err end)
    lu.assertEquals(calls, 1)
    return reason
end

function TestGameAlgoStorage:test_buffered_snapshot_requires_complete_contents_after_close()
    local storage = assert(Storage.New())
    lu.assertTrue(storage:SetItem("identity", "stable"))
    -- ReadString also returns the full payload at EOF if only the NUL was lost.
    closeFault = function(_, bytes) return bytes:sub(1, -2) end
    lu.assertFalse(storage:SetItem("identity", "new"))
    lu.assertNotNil(flushStorage(storage))
    lu.assertEquals(storage:GetItem("identity"), "new")
    lu.assertEquals(assert(Storage.New()):GetItem("identity"), "stable")

    closeFault = nil
    lu.assertNil(flushStorage(storage))
    lu.assertEquals(assert(Storage.New()):GetItem("identity"), "new")
end

function TestGameAlgoStorage:test_buffered_ack_retries_same_size_corrupt_chunk()
    local storage = assert(Storage.New())
    local queue = storage:EventQueue(queueKey)
    local acked, pending = event("acked"), event("pending")
    queue:Upsert(acked)
    queue:Upsert(pending)
    lu.assertTrue(queue:Persist())
    closeFault = function(_, bytes) return "!" .. bytes:sub(2) end
    queue:Remove({ acked })
    lu.assertNotNil(flushStorage(storage))
    lu.assertEquals(queue:Events(), { pending })
    lu.assertEquals(assert(Storage.New()):EventQueue(queueKey):Events(), { acked, pending })

    closeFault = nil
    lu.assertNil(flushStorage(storage))
    lu.assertEquals(assert(Storage.New()):EventQueue(queueKey):Events(), { pending })
end

function TestGameAlgoStorage:test_file_only_hosts_verify_writes_and_restore_after_ack()
    for _, withSystem in ipairs({ false, true }) do
        self:setUp()
        fileSystem = withSystem and {} or nil
        local open = File
        File = function(name, mode)
            local file = open(name, mode)
            file.GetSize, file.Read, file.GetPosition = nil, nil, nil
            return file
        end
        local storage = assert(Storage.New())
        lu.assertTrue(missingReads > 0)
        lu.assertTrue(storage:SetItem("identity", "file-only"))
        local queue = storage:EventQueue(queueKey)
        queue:Upsert(event("file-only"))
        lu.assertNil(flushStorage(storage))

        local reopened = assert(Storage.New())
        lu.assertEquals(reopened:GetItem("identity"), "file-only")
        local pending = reopened:EventQueue(queueKey)
        lu.assertEquals(pending:Events(), { event("file-only") })
        pending:Remove(pending:Events())
        lu.assertNil(flushStorage(reopened))
        lu.assertEquals(assert(Storage.New()):EventQueue(queueKey):Events(), {})
        closeFault = function() return "torn" end
        lu.assertFalse(reopened:SetItem("identity", "new"))
        lu.assertEquals(assert(Storage.New()):GetItem("identity"), "file-only")
        closeFault = nil
        lu.assertNil(flushStorage(reopened))
        lu.assertEquals(assert(Storage.New()):GetItem("identity"), "new")
    end
end

function TestGameAlgoStorage:test_chunk_append_ack_and_slot_reuse_touch_only_changed_chunk()
    local storage = assert(Storage.New())
    local queue, events = storage:EventQueue(queueKey), {}
    for index = 1, 250 do events[index] = event("event-" .. index); queue:Upsert(events[index]) end
    lu.assertTrue(queue:Persist())
    lu.assertEquals(storage:GetItem(queueKey).blocks, 3)
    lu.assertEquals(#assert(Storage.New()):EventQueue(queueKey):Events(), 250)
    local before = #writes
    queue:Upsert(event("tail")); lu.assertTrue(queue:Persist())
    lu.assertEquals(#writes, before + 1)
    local removed = {}
    for index = 1, 100 do removed[index] = events[index] end
    queue:Remove(removed); lu.assertTrue(queue:Persist())
    local reopened = assert(Storage.New()):EventQueue(queueKey)
    lu.assertEquals(#reopened:Events(), 151)
    lu.assertEquals(reopened:Events()[1].eventId, "event-101")
    before = #writes
    reopened:Upsert(event("reused-slot")); lu.assertTrue(reopened:Persist())
    lu.assertEquals(#writes, before + 1)
    local all = assert(Storage.New()):EventQueue(queueKey):Events()
    lu.assertEquals(all[#all].eventId, "reused-slot")
end

function TestGameAlgoStorage:test_chunk_context_and_torn_write_recovery()
    local storage = assert(Storage.New())
    local queue, first = storage:EventQueue(queueKey), event("first")
    queue:Upsert(first); lu.assertTrue(queue:Persist())
    first.contextId = "bound"; queue:Upsert(first); lu.assertTrue(queue:Persist())
    local best = decodeFile(chunkKey .. "_1.json").revision
        > decodeFile(chunkKey .. "_2.json").revision and 1 or 2
    failWriteName = chunkKey .. "_" .. (best == 1 and 2 or 1) .. ".json"
    queue:Upsert(event("new")); lu.assertFalse(queue:Persist())
    local all = assert(Storage.New()):EventQueue(queueKey):Events()
    lu.assertEquals(#all, 1)
    lu.assertEquals(all[1].contextId, "bound")
    failWriteName = nil; lu.assertTrue(queue:Persist())
    lu.assertEquals(#assert(Storage.New()):EventQueue(queueKey):Events(), 2)
end

function TestGameAlgoStorage:test_new_directory_is_written_after_chunks_and_orphan_slots_are_reused_safely()
    local storage = assert(Storage.New())
    local queue = storage:EventQueue(queueKey)
    queue:Upsert(event("uncommitted"))
    local directoryFile = writes[#writes] == "gamealgo_sdk_storage_v1.json"
        and "gamealgo_sdk_storage_v1.backup.json" or "gamealgo_sdk_storage_v1.json"
    failWriteName = directoryFile
    lu.assertFalse(queue:Persist())
    lu.assertEquals(writes[#writes], chunkKey .. "_1.json")
    lu.assertNil(assert(Storage.New()):GetItem(queueKey))
    failWriteName = nil
    -- Simulate retained high-revision files from an interrupted old migration.
    seedFile(chunkKey .. "_1.json", { format = "event_chunks_v1", revision = 900,
        entries = { { sequence = 1, event = json.encode(event("orphan")) } } })
    local fresh = assert(Storage.New()):EventQueue(queueKey)
    lu.assertEquals(fresh:Events(), {})
    fresh:Upsert(event("committed"))
    lu.assertTrue(fresh:Persist())
    lu.assertEquals(decodeFile(chunkKey .. "_2.json").revision, 901)
    lu.assertEquals(assert(Storage.New()):EventQueue(queueKey):Events(), { event("committed") })
end

function TestGameAlgoStorage:test_local_jsonl_migration_survives_chunk_and_directory_failures()
    for _, failure in ipairs({ "chunk", "checkpoint", "directory" }) do
        self:setUp()
        local events = {}
        for index = 1, 101 do events[index] = event("legacy-" .. index) end
        local lines = {}
        for _, row in ipairs(events) do table.insert(lines, json.encode(row)) end
        seedFile("gamealgo_sdk_storage_v1.json", { schemaVersion = 1, revision = 4,
            data = { [queueKey] = table.concat(lines, "\n") } })
        seedFile(chunkKey .. "_1.json", { format = "event_chunks_v1", revision = 900,
            entries = { { sequence = 1, event = json.encode(event("stale-orphan")) } } })
        local storage = assert(Storage.New())
        local queue = storage:EventQueue(queueKey)
        queue:Remove({ queue:Events()[1] }); queue:Upsert(event("new"))
        if failure == "chunk" then failWriteName = chunkKey .. "_2.json"
        elseif failure == "checkpoint" then failWriteName = "gamealgo_sdk_storage_v1.backup.json"
        else
            -- Fail after the complete JSONL checkpoint and all chunks are safe.
            writeHook = function(name, value)
                if name == "gamealgo_sdk_storage_v1.json"
                    and type(json.decode(value).data[queueKey]) == "table" then failWriteName = name end
            end
        end
        lu.assertFalse(queue:Persist())
        failWriteName, writeHook = nil, nil
        local reopened = assert(Storage.New()):EventQueue(queueKey)
        local all = reopened:Events()
        lu.assertEquals(#all, 101)
        if failure ~= "checkpoint" then
            lu.assertEquals(all[1].eventId, "legacy-2")
            lu.assertEquals(all[#all].eventId, "new")
        else
            lu.assertEquals(all[1].eventId, "legacy-1")
        end
        lu.assertTrue(reopened:Persist())
        all = assert(Storage.New()):EventQueue(queueKey):Events()
        lu.assertEquals(#all, 101)
        for _, row in ipairs(all) do lu.assertNotEquals(row.eventId, "stale-orphan") end
    end
end

function TestGameAlgoStorage:test_missing_file_uses_memory_without_claiming_durability()
    File = nil
    lobby = { GetMyUserId = function() return "maker-account" end }
    clientCloud = { Get = function() error("cloud access") end, Set = function() error("cloud access") end }
    local storage = assert(Storage.New())
    lu.assertTrue(storage:IsReady())
    lu.assertFalse(storage:SetItem("identity", "memory"))
    lu.assertEquals(storage:GetItem("identity"), "memory")
    local queue = storage:EventQueue(queueKey); queue:Upsert(event("memory-event"))
    lu.assertFalse(queue:Persist())
    lu.assertEquals(#queue:Events(), 1)
    local callbackError
    storage:Flush(function(error) callbackError = error end)
    lu.assertNotNil(callbackError)
    lu.assertFalse(storage:Diagnostics().persistentStorageAvailable)
    lu.assertNil(assert(Storage.New()):GetItem("identity"))
end

function TestGameAlgoStorage:test_missing_or_corrupt_chunks_do_not_block_local_start()
    seedFile("gamealgo_sdk_storage_v1.json", { schemaVersion = 1, revision = 3,
        data = { [queueKey] = { format = "event_chunks_v1", blocks = 2 } } })
    files[chunkKey .. "_1.json"] = "invalid"
    local storage = assert(Storage.New())
    lu.assertTrue(storage:IsReady())
    local queue = storage:EventQueue(queueKey)
    lu.assertEquals(queue:Events(), {})
    queue:Upsert(event("fresh")); lu.assertTrue(queue:Persist())
    lu.assertEquals(assert(Storage.New()):EventQueue(queueKey):Events(), { event("fresh") })
end

function TestGameAlgoStorage:test_shutdown_stops_retained_queue_writes()
    local old = assert(Storage.New())
    lu.assertTrue(old:SetItem("identity", "old"))
    local queue = old:EventQueue(queueKey); queue:Upsert(event("old")); lu.assertTrue(queue:Persist())
    old:Shutdown()
    local current = assert(Storage.New()); lu.assertTrue(current:SetItem("identity", "current"))
    local before = #writes
    queue:Upsert(event("stale"))
    lu.assertFalse(queue:Persist())
    lu.assertFalse(old:SetItem("identity", "stale"))
    lu.assertFalse(old:IsReady())
    old:OnReady(function() error("stopped callback") end)
    lu.assertEquals(#writes, before)
    lu.assertEquals(assert(Storage.New()):GetItem("identity"), "current")
    lu.assertEquals(#assert(Storage.New()):EventQueue(queueKey):Events(), 1)
    -- Shutdown also prevents a legacy migration from writing its first chunk.
    local legacyKey = "stale:events:jsonl"
    lu.assertTrue(current:SetItem(legacyKey, json.encode(event("legacy"))))
    local legacy = current:EventQueue(legacyKey)
    current:Shutdown()
    before = #writes
    lu.assertFalse(legacy:Persist())
    lu.assertEquals(#writes, before)
end

local function savedGameEvents(gameKey, userId)
    local key = "gamealgo:v2:game:" .. Sha256.hex(gameKey) .. ":user:" .. Sha256.hex(userId) .. ":events:jsonl"
    return assert(Storage.New()):EventQueue(key):Events()
end

function TestGameAlgoStorage:test_http_replays_offline_backlog_and_ack_is_durable()
    local GameAlgo = require("GameAlgo")
    local requests, held, sent, offline = 0, nil, nil, true
    local transport = { Request = function(request, callback)
        if request.url:match("/v1/config$") then
            callback(nil, { status = 200, body = json.encode({ contextId = "online-context",
                gameId = "local-storage-test", experiments = {}, configFiles = {} }) })
        elseif request.url:match("/v1/events/batch$") then
            requests = requests + 1
            sent = json.decode(request.body).events
            lu.assertEquals(#savedGameEvents("http-local-storage", GameAlgo.Snapshot().userId), #sent)
            if offline then callback("offline", nil) else held = callback end
        end
    end }
    local options = { gameKey = "http-local-storage", sessionId = "offline-session",
        experimentIntegrationVersion = 1,
        autoFetch = false, preloadConfigFiles = false, transport = transport,
        _scheduler = scheduler, logger = function() end, nowMs = function() return 1000 end }
    GameAlgo.Init(options)
    local userId = GameAlgo.Snapshot().userId
    lu.assertTrue(GameAlgo.TrackEvent("offline", { marker = "kept" }))
    GameAlgo.FetchConfig()
    lu.assertEquals(requests, 1)
    local originalEvent = sent[1]
    options.sessionId = "online-session"; offline = false
    GameAlgo.Init(options)
    lu.assertEquals(GameAlgo.Snapshot().userId, userId)
    lu.assertEquals(GameAlgo.Snapshot().queuedEvents, 1)
    GameAlgo.Flush()
    lu.assertEquals(sent[1], originalEvent)
    lu.assertNotNil(held)
    held(nil, { status = 200, body = json.encode({ ok = true, accepted = #sent }) })
    lu.assertEquals(GameAlgo.Snapshot().queuedEvents, 0)
    GameAlgo.Init(options)
    lu.assertEquals(GameAlgo.Snapshot().queuedEvents, 0)
end

local function replyConfig(request, context)
    request.callback(nil, { status = 200, body = json.encode({ contextId = context,
        experiments = {}, configFiles = {} }) })
end

local function acknowledge(request)
    request.callback(nil, { status = 200, body = json.encode({ ok = true, accepted = #request.body.events }) })
end

local function newHost(options)
    local host = { options = options or {}, configs = {}, batches = {}, now = 1000 }
    local opts = host.options
    opts.gameKey, opts.userId, opts.sessionId = "test-game", "user-a", "session-a"
    if opts.experimentIntegrationVersion == nil then opts.experimentIntegrationVersion = 1 end
    opts.autoFetch, opts.preloadConfigFiles, opts._scheduler = false, false, scheduler
    opts.logger, opts.nowMs = function() end, function() return host.now end
    opts.transport = {
        Request = function(request, callback)
            local recorded = { body = json.decode(request.body), headers = request.headers, callback = callback }
            if request.url:match("/v1/config$") then table.insert(host.configs, recorded)
            elseif request.url:match("/v1/events/batch$") then table.insert(host.batches, recorded) end
            return recorded
        end,
        Cancel = function(request) request.cancelled = true end,
    }
    function host:restart()
        -- A cold start drops the old SDK without giving Init a chance to checkpoint its tail.
        package.loaded[gameModule] = nil
        self.game = require(gameModule)
        self.game.Init(self.options)
    end
    function host:connect(context)
        local before = #self.configs
        self.game.FetchConfig()
        lu.assertEquals(#self.configs, before + 1)
        replyConfig(self.configs[before + 1], context)
        lu.assertEquals(self.game.Snapshot().contextId, context)
    end
    host:restart()
    return host
end

function TestGameAlgoStorage:test_first_offline_event_survives_update_and_cold_start()
    local host = newHost()
    host.game.FetchConfig()
    host.configs[1].callback("offline", nil)
    lu.assertTrue(host.game.TrackEvent("offline", { score = 17 }))
    host.now = host.now + 60000
    host.game.Update()
    lu.assertEquals(#host.batches, 0)
    local saved = savedGameEvents(host.options.gameKey, host.options.userId)
    lu.assertEquals(#saved, 1)

    host.options.sessionId = "next-launch"
    host:restart()
    lu.assertEquals(host.game.Snapshot().queuedEvents, 1)
    host:connect("connected")
    host.game.Flush()
    lu.assertEquals(#host.batches, 1)
    local rows = host.batches[1].body.events
    lu.assertEquals(#rows, 1)
    lu.assertEquals(rows[1].eventId, saved[1].eventId)
    lu.assertEquals(rows[1].eventType, "_offline")
    lu.assertEquals(rows[1].payload.score, 17)
    lu.assertEquals(rows[1].sessionId, "session-a")
    lu.assertEquals(rows[1].contextId, "connected")
    acknowledge(host.batches[1])
    host:restart()
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_bound_milestone_is_recoverable_when_track_returns()
    local host = newHost()
    host:connect("first-context")
    lu.assertTrue(host.game.TrackMilestone("level", "10", { score = 20 }))
    local saved = savedGameEvents(host.options.gameKey, host.options.userId)
    lu.assertEquals(#saved, 1)
    local before = #host.batches
    host.options.sessionId = "next-launch"
    host:restart()
    lu.assertEquals(host.game.Snapshot().queuedEvents, 1)
    host.game.Flush()
    lu.assertEquals(#host.batches, before + 1)
    local batch = host.batches[#host.batches]
    lu.assertEquals(#batch.body.events, 1)
    local row = batch.body.events[1]
    lu.assertEquals(row.eventType, "milestone")
    lu.assertEquals({ row.sessionId, row.contextId }, { "session-a", "first-context" })
    lu.assertEquals({ row.payload.milestoneType, row.payload.milestonePoint, row.payload.score }, { "level", "10", 20 })
    lu.assertEquals(row, saved[1])
    acknowledge(batch)
    host:connect("second-context")
    lu.assertFalse(host.game.TrackMilestone("level", "10"))
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_failed_milestone_chunk_does_not_commit_a_dedup_marker()
    local host = newHost()
    host:connect("first-context")
    closeFault = function(name, bytes) return name:match("^gaq_") and "torn chunk" or bytes end
    host.game.TrackMilestone("level", "10")
    closeFault = nil
    host:restart()
    host:connect("new-context")
    lu.assertTrue(host.game.TrackMilestone("level", "10"))
    host.game.Flush()
    local batch = host.batches[#host.batches]
    lu.assertEquals(#batch.body.events, 1)
    lu.assertEquals(batch.body.events[1].payload.milestonePoint, "10")
    acknowledge(batch)
    lu.assertFalse(host.game.TrackMilestone("level", "10"))
end

function TestGameAlgoStorage:test_acknowledged_milestone_stays_duplicate_while_config_is_pending()
    local host = newHost()
    host:connect("first-context")
    lu.assertTrue(host.game.TrackMilestone("level", "10"))
    host.game.Flush()
    local first = host.batches[1].body.events[1]
    acknowledge(host.batches[1])

    host.options.sessionId = "next-launch"
    host:restart()
    host.game.FetchConfig()
    lu.assertNil(host.game.Snapshot().contextId)
    local tracked, reason = host.game.TrackMilestone("level", "10")
    lu.assertFalse(tracked)
    lu.assertEquals(reason, "duplicate milestone")
    lu.assertTrue(host.game.TrackMilestone("level", "11"))
    replyConfig(host.configs[2], "second-context")
    host.game.Flush()
    lu.assertEquals(#host.batches, 2)
    local second = host.batches[2].body.events
    lu.assertEquals(#second, 1)
    lu.assertEquals(second[1].payload.milestonePoint, "11")
    lu.assertNotEquals(second[1].eventId, first.eventId)
    acknowledge(host.batches[2])
end

function TestGameAlgoStorage:test_ack_before_milestone_marker_commit_never_creates_a_new_event_id()
    local host = newHost()
    host:connect("first-context")
    local failedMarkers = 0
    closeFault = function(name, bytes)
        if name:match("^gamealgo_sdk_storage") then
            for key in pairs(json.decode(bytes:sub(1, -2)).data) do
                if key:match(":milestones$") then
                    failedMarkers = failedMarkers + 1
                    return "torn marker snapshot"
                end
            end
        end
        return bytes
    end
    lu.assertTrue(host.game.TrackMilestone("level", "10"))
    host.game.Flush()
    local original = host.batches[1].body.events[1]
    acknowledge(host.batches[1])
    lu.assertTrue(failedMarkers > 0)

    closeFault = nil
    host:restart()
    lu.assertFalse(host.game.TrackMilestone("level", "10"))
    host:connect("next-context")
    host.game.Flush()
    for i = 2, #host.batches do
        lu.assertEquals(host.batches[i].body.events, { original })
        acknowledge(host.batches[i])
    end
    host:restart()
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
    lu.assertFalse(host.game.TrackMilestone("level", "10"))
end

local function queueBehindRequest(host)
    host:connect("first-context")
    lu.assertTrue(host.game.TrackEvent("first"))
    host.game.Flush()
    lu.assertEquals(#host.batches, 1)
    lu.assertTrue(host.game.TrackEvent("tail"))
    lu.assertEquals(host.game.Snapshot().queuedEvents, 2)
    return host.batches[1]
end

function TestGameAlgoStorage:test_inflight_tail_saves_at_previous_checkpoint_deadline()
    local host = newHost()
    host:connect("first-context")
    lu.assertTrue(host.game.TrackEvent("inflight"))
    host.game.Flush()
    local lastSave, initialWrites = host.now, #writes
    host.now = lastSave + 100
    lu.assertTrue(host.game.TrackEvent("tail"))
    host.now = lastSave + 4999
    host.game.Update()
    lu.assertEquals(#writes, initialWrites)
    host.now = lastSave + 5000
    host.game.Update()
    lu.assertEquals(#writes, initialWrites + 1)
    lu.assertEquals(#host.batches, 1)
    host:restart()
    lu.assertEquals(host.game.Snapshot().queuedEvents, 2)
end

function TestGameAlgoStorage:test_reinit_checkpoints_tail_behind_inflight_request()
    local host = newHost()
    local first = queueBehindRequest(host)
    host.options.sessionId = "next-launch"
    host.game.Init(host.options)
    acknowledge(first) -- A late callback from the cancelled generation.
    lu.assertEquals(host.game.Snapshot().queuedEvents, 2)
    host.game.Flush()
    lu.assertEquals(#host.batches, 2)
    local rows = host.batches[2].body.events
    lu.assertEquals(#rows, 2)
    lu.assertEquals(rows[1], first.body.events[1])
    lu.assertEquals({ rows[2].eventType, rows[2].sessionId, rows[2].contextId },
        { "_tail", "session-a", "first-context" })
    acknowledge(host.batches[2])
    host:restart()
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_failed_reinit_preserves_old_request_and_retryable_tail()
    local host = newHost()
    local first = queueBehindRequest(host)
    closeFault = function(name, bytes) return name:match("^gaq_") and "torn chunk" or bytes end
    host.options.sessionId = "next-launch"
    local ok, reason = pcall(host.game.Init, host.options)
    lu.assertFalse(ok)
    lu.assertStrContains(tostring(reason):lower(), "local")
    lu.assertNil(first.cancelled)
    local state = host.game.Snapshot()
    lu.assertEquals({ state.sessionId, state.contextId, state.inflightEvents, state.queuedEvents },
        { "session-a", "first-context", 1, 2 })

    closeFault = nil
    acknowledge(first)
    host.game.Flush()
    lu.assertEquals(#host.batches, 2)
    local rows = host.batches[2].body.events
    lu.assertEquals(#rows, 1)
    lu.assertEquals({ rows[1].eventType, rows[1].sessionId }, { "_tail", "session-a" })
    acknowledge(host.batches[2])
    host.game.Init(host.options)
    lu.assertEquals(host.game.Snapshot().sessionId, "next-launch")
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_memory_only_reinit_keeps_each_users_pending_events()
    File, lobby = nil, { GetMyUserId = function() return "maker-account" end }
    local host = newHost()
    lu.assertFalse(host.game.Snapshot().storage.persistentStorageAvailable)
    lu.assertTrue(host.game.TrackEvent("offline-a"))
    host.options.userId, host.options.sessionId = "user-b", "session-b"
    host.game.Init(host.options)
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
    lu.assertTrue(host.game.TrackEvent("offline-b"))
    for index, name in ipairs({ "a", "b" }) do
        host.options.userId, host.options.sessionId = "user-" .. name, "return-" .. name
        host.game.Init(host.options)
        lu.assertEquals(host.game.Snapshot().queuedEvents, 1)
        host:connect("context-" .. name)
        host.game.Flush()
        local rows = host.batches[index].body.events
        lu.assertEquals(#rows, 1)
        lu.assertEquals({ rows[1].eventType, rows[1].sessionId, rows[1].userId },
            { "_offline-" .. name, "session-" .. name, "user-" .. name })
        acknowledge(host.batches[index])
    end
end

function TestGameAlgoStorage:test_invalid_reinit_keeps_active_requests_and_game_key()
    local host = newHost()
    host:connect("first-context")
    lu.assertTrue(host.game.TrackEvent("inflight"))
    host.game.Flush()
    host.game.FetchConfig()
    local inflight, refresh = host.batches[1], host.configs[2]
    local ok, reason = pcall(host.game.Init, { gameKey = "new-game", userId = "user-b",
        sessionId = "new-session", experimentIntegrationVersion = -1 })
    lu.assertFalse(ok)
    lu.assertStrContains(tostring(reason), "experimentIntegrationVersion")
    lu.assertNil(inflight.cancelled)
    lu.assertNil(refresh.cancelled)
    local state = host.game.Snapshot()
    lu.assertEquals({ state.userId, state.sessionId, state.contextId, state.inflightEvents },
        { "user-a", "session-a", "first-context", 1 })
    acknowledge(inflight)
    replyConfig(refresh, "refreshed")
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
    lu.assertTrue(host.game.TrackEvent("after-invalid-init"))
    host.game.Flush()
    local batch = host.batches[2]
    lu.assertEquals(batch.headers["X-GameAlgo-Key"], "test-game")
    local row = batch.body.events[1]
    lu.assertEquals({ row.userId, row.sessionId, row.contextId, row.eventType },
        { "user-a", "session-a", "refreshed", "_after-invalid-init" })
    acknowledge(batch)
end

local placementId = "gap_" .. string.rep("a", 32)

local function startAd(host)
    local onResult, delivered = nil, {}
    sdk = { ShowRewardVideoAd = function(_, callback) onResult = callback; return true end }
    lu.assertTrue(host.game.ShowRewardVideoAd(placementId, function(result) table.insert(delivered, result) end))
    lu.assertNotNil(onResult)
    lu.assertEquals(#delivered, 0)
    return function()
        local result = { code = 1, trackId = "host-track" }
        onResult(result)
        onResult({ code = 0, trackId = "duplicate" })
        lu.assertEquals(#delivered, 1)
        lu.assertTrue(rawequal(delivered[1], result))
    end
end

local function assertOriginalAd(batch, expectedContext)
    lu.assertEquals(batch.headers["X-GameAlgo-Key"], "test-game")
    lu.assertEquals(#batch.body.events, 1)
    local row = batch.body.events[1]
    lu.assertEquals({ row.eventType, row.userId, row.accountUserId, row.sessionId, row.contextId, row.isDebug },
        { "ad_view", "user-a", "account-a", "session-a", expectedContext or "context-a", false })
    lu.assertEquals({ row.payload.adPlacementId, row.payload.trackId }, { placementId, "host-track" })
end

function TestGameAlgoStorage:test_late_ad_returns_to_original_user_and_game_queue()
    for _, change in ipairs({ "userId", "gameKey" }) do
        self:setUp()
        local host = newHost({ accountUserId = "account-a" })
        host:connect("context-a")
        local deliver = startAd(host)
        local original = host.options[change]
        host.options[change] = "different-" .. change
        host.options.sessionId, host.options.accountUserId = "session-b", "account-b"
        host.game.Init(host.options)
        host:connect("context-b")
        deliver()
        lu.assertEquals(#host.batches, 0, change)
        lu.assertTrue(host.game.TrackEvent("b-only"))
        host.game.Flush()
        local current = host.batches[1].body.events
        lu.assertEquals(#current, 1)
        lu.assertEquals({ current[1].eventType, current[1].contextId }, { "_b-only", "context-b" })
        acknowledge(host.batches[1])

        host.options[change] = original
        host.options.sessionId, host.options.accountUserId = "return-a", "account-a"
        host:restart()
        host:connect("return-context-a")
        host.game.Flush()
        lu.assertEquals(#host.batches, 2, change)
        assertOriginalAd(host.batches[2])
        acknowledge(host.batches[2])
        host:restart()
        lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
    end
end

function TestGameAlgoStorage:test_late_ad_within_user_keeps_requesting_session_and_context()
    local host = newHost({ accountUserId = "account-a" })
    host:connect("context-a")
    local deliver = startAd(host)
    lu.assertEquals(host.game.NewSession("session-b"), "session-b")
    replyConfig(host.configs[2], "context-b")
    for _, batch in ipairs(host.batches) do acknowledge(batch) end
    lu.assertEquals(host.game.Snapshot().contextId, "context-b")
    local before = #host.batches
    deliver()
    lu.assertEquals(#host.batches, before + 1)
    assertOriginalAd(host.batches[#host.batches])
    acknowledge(host.batches[#host.batches])
end

function TestGameAlgoStorage:test_late_ad_without_context_uses_ready_config_after_reinit()
    local host = newHost({ accountUserId = "account-a" })
    host.game.FetchConfig()
    local deliver = startAd(host)
    host.options.sessionId, host.options.accountUserId = "session-b", "account-b"
    host.game.Init(host.options)
    host:connect("new-context")

    deliver()
    lu.assertEquals(#host.batches, 1)
    assertOriginalAd(host.batches[1], "new-context")
    acknowledge(host.batches[1])
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_late_ad_without_context_waits_for_its_debug_mode()
    local host = newHost({ accountUserId = "account-a" })
    local deliver = startAd(host)
    host.options.sessionId, host.options.isDebug = "debug-session", true
    host.game.Init(host.options)
    host:connect("debug-context")
    deliver()
    lu.assertEquals(#host.batches, 0)

    host.options.sessionId, host.options.isDebug = "next-session", false
    host.game.Init(host.options)
    host:connect("production-context")
    host.game.Flush()
    lu.assertEquals(#host.batches, 1)
    assertOriginalAd(host.batches[1], "production-context")
    acknowledge(host.batches[1])
end

function TestGameAlgoStorage:test_batch_size_is_capped_at_server_limit()
    local host = newHost({ maxBatchSize = 101 })
    for index = 1, 101 do lu.assertTrue(host.game.TrackLevelStart({ index = index })) end
    host:connect("batch-context")
    host.game.Flush()
    lu.assertEquals(#host.batches, 1)
    local rows = host.batches[1].body.events
    lu.assertEquals(#rows, 100)
    for index, row in ipairs(rows) do lu.assertEquals(row.payload.index, index) end
    acknowledge(host.batches[1])
    lu.assertEquals(#host.batches, 2)
    rows = host.batches[2].body.events
    lu.assertEquals(#rows, 1)
    lu.assertEquals(rows[1].payload.index, 101)
    acknowledge(host.batches[2])
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_offline_production_event_waits_for_production_context()
    local host = newHost()
    lu.assertTrue(host.game.TrackEvent("production"))
    host.game.Flush()
    host.options.sessionId, host.options.isDebug = "debug-session", true
    host:restart()
    host:connect("debug-context")
    lu.assertTrue(host.configs[1].body.isDebug)
    lu.assertTrue(host.game.TrackEvent("debug"))
    host.game.Flush()
    lu.assertEquals(#host.batches, 1)
    local debugRows = host.batches[1].body.events
    lu.assertEquals(#debugRows, 1)
    lu.assertEquals({ debugRows[1].eventType, debugRows[1].contextId, debugRows[1].isDebug },
        { "_debug", "debug-context", true })
    acknowledge(host.batches[1])

    host.options.sessionId, host.options.isDebug = "prod-return", false
    host:restart()
    host:connect("production-context")
    lu.assertFalse(host.configs[2].body.isDebug)
    host.game.Flush()
    lu.assertEquals(#host.batches, 2)
    local prodRows = host.batches[2].body.events
    lu.assertEquals(#prodRows, 1)
    lu.assertEquals({ prodRows[1].eventType, prodRows[1].sessionId, prodRows[1].contextId, prodRows[1].isDebug },
        { "_production", "session-a", "production-context", false })
    acknowledge(host.batches[2])
end

function TestGameAlgoStorage:test_automatic_flush_observes_backoff_but_explicit_flush_can_retry()
    local host = newHost({ maxBatchSize = 2 })
    host:connect("online")
    lu.assertTrue(host.game.TrackEvent("first"))
    lu.assertTrue(host.game.TrackEvent("second"))
    local first = host.batches[1]
    first.callback("offline", nil)
    local retryAt = host.game.Snapshot().retryFlushAtMs
    lu.assertTrue(retryAt > host.now)
    lu.assertTrue(host.game.TrackEvent("third"))
    lu.assertEquals(#host.batches, 1)
    host.now = retryAt - 1
    host.game.Update()
    lu.assertEquals(#host.batches, 1)
    host.now = retryAt
    host.game.Update()
    lu.assertEquals(#host.batches, 2)
    lu.assertEquals(host.batches[2].body.events, first.body.events)
    host.batches[2].callback("offline", nil)
    lu.assertTrue(host.game.Snapshot().retryFlushAtMs > host.now)
    host.game.Flush()
    lu.assertEquals(#host.batches, 3)
    lu.assertEquals(host.batches[3].body.events, first.body.events)
    acknowledge(host.batches[3])
    lu.assertEquals(#host.batches, 4)
    local tail = host.batches[4].body.events
    lu.assertEquals(#tail, 1)
    lu.assertEquals(tail[1].eventType, "_third")
    acknowledge(host.batches[4])
    lu.assertEquals(host.game.Snapshot().queuedEvents, 0)
end

function TestGameAlgoStorage:test_gamealgo_ids_do_not_consume_host_random()
    local GameAlgo = require("GameAlgo")
    local originalRandom = math.random
    math.randomseed(81725)
    local expected = { originalRandom(), originalRandom(), originalRandom() }
    math.randomseed(81725)
    local randomCalls = 0
    math.random = function(...)
        randomCalls = randomCalls + 1
        return originalRandom(...)
    end
    local ok, reason = pcall(function()
        GameAlgo.Init({ gameKey = "gamealgo-random-isolation", experimentIntegrationVersion = 1, autoFetch = false,
            _scheduler = scheduler, nowMs = function() return 1000 end })
        lu.assertTrue(GameAlgo.TrackEvent("random_probe", {}))
        lu.assertNotNil(GameAlgo.NewSession())
    end)
    math.random = originalRandom
    lu.assertTrue(ok, reason)
    lu.assertEquals(randomCalls, 0)
    lu.assertEquals({ originalRandom(), originalRandom(), originalRandom() }, expected)
end

function TestGameAlgoStorage:test_http_early_failures_complete_once()
    for _, case in ipairs({
        { request = false, expected = "invalid HTTP request" },
        { request = {}, expected = "http client unavailable in this runtime" },
        { request = { method = "TRACE" }, manager = {}, expected = "unsupported HTTP method: TRACE" },
        { request = {}, manager = { Create = function() return nil end },
            expected = "http client unavailable in this runtime" },
    }) do
        http = case.manager
        local count, result = 0, nil
        Transport.Request(case.request, function(error) count, result = count + 1, error end)
        lu.assertEquals(count, 1)
        lu.assertEquals(result, case.expected)
        lu.assertEquals(Transport.Diagnostics().activeRequests, 0)
    end
end

function TestGameAlgoStorage:test_rooted_http_callbacks_release_clients()
    local roots, weak = {}, setmetatable({}, { __mode = "v" })
    http = { Create = function()
        local client, callbacks = {}, {}
        table.insert(roots, callbacks)
        for _, name in ipairs({ "SetUrl", "SetMethod", "SetTimeout", "Send" }) do
            client[name] = function(self) return self end
        end
        function client:OnSuccess(callback) callbacks.ok = callback; return self end
        function client:OnError(callback) callbacks.error = callback; return self end
        return client
    end }
    for index = 1, 12 do
        local client = Transport.Request({ url = "https://example.invalid" }, function() end)
        weak[index] = client
        roots[index].ok(nil, { statusCode = 200, dataAsString = "{}" })
        roots[index].error(nil, 500, "duplicate")
    end
    collectgarbage("collect"); collectgarbage("collect")
    lu.assertNil(next(weak))
    lu.assertEquals(Transport.Diagnostics().activeRequests, 0)
end

lu.run({ TestGameAlgoStorage })
