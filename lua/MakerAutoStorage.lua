---@meta
--- Internal persistent storage for TapTap Maker.
---
--- The SDK exposes synchronous reads to its identity, script cache, and DDA
--- layers while hiding Maker's asynchronous clientCloud API. A local File
--- snapshot is used as the fast path after the cloud directory is confirmed.
--- Otherwise a bounded cloud read precedes SDK startup; missing cloud access
--- keeps local operation available without allowing destructive cloud writes.

local cjson = require("cjson")

local moduleName = ...

local function localSdkModuleName(name)
    if type(moduleName) == "string" then
        local prefix, separator = moduleName:match("^(.*)([./])[^./]+$")
        if prefix and prefix ~= "" then return prefix .. separator .. name end
    end
    return "sdk." .. name
end

local function requireSdkModule(name)
    local localName = localSdkModuleName(name)
    local ok, value = pcall(require, localName)
    if ok then return value end
    local makerName = "sdk." .. name
    if localName ~= makerName then
        ok, value = pcall(require, makerName)
        if ok then return value end
    end
    return require(name)
end

local Sha256 = requireSdkModule("Sha256")

local MakerAutoStorage = {}

local FILE_NAME = "gamealgo_sdk_storage_v1.json"
local BACKUP_FILE_NAME = "gamealgo_sdk_storage_v1.backup.json"
local CLOUD_KEY = "gamealgo_sdk_storage_v1"
local SCHEMA_VERSION = 1
local DEFAULT_CLOUD_READ_TIMEOUT_MS = 5000

local function makerGlobal(read)
    local ok, value = pcall(read)
    if ok then return value end
    return nil
end

local function makerFileApi()
    local factory = makerGlobal(function() return File end)
    local readMode = makerGlobal(function() return FILE_READ end)
    local writeMode = makerGlobal(function() return FILE_WRITE end)
    local makerFileSystem = makerGlobal(function() return fileSystem end)
    if factory == nil or readMode == nil or writeMode == nil then return nil end
    return {
        factory = factory,
        readMode = readMode,
        writeMode = writeMode,
        fileSystem = makerFileSystem,
    }
end

local function makerCloud()
    local cloud = makerGlobal(function() return clientCloud end)
    if cloud == nil then return nil end
    local get = makerGlobal(function() return cloud.Get end)
    local set = makerGlobal(function() return cloud.Set end)
    if type(get) ~= "function" or type(set) ~= "function" then return nil end
    return cloud
end

local function isMakerRuntime()
    if makerFileApi() or makerCloud() then return true end
    return makerGlobal(function() return lobby end) ~= nil
end

local function emptySnapshot()
    return {
        schemaVersion = SCHEMA_VERSION,
        revision = 0,
        data = {},
        cloudDirectoryBlocked = true,
        cloudDirectoryConfirmed = false,
    }
end

local function normalizeSnapshot(value)
    if type(value) == "string" then
        local ok, decoded = pcall(cjson.decode, value)
        if not ok then return nil end
        value = decoded
    end
    if type(value) ~= "table" or type(value.data) ~= "table" then return nil end
    if tonumber(value.schemaVersion) ~= SCHEMA_VERSION then return nil end
    return {
        schemaVersion = SCHEMA_VERSION,
        revision = math.max(0, math.floor(tonumber(value.revision) or 0)),
        data = value.data,
        cloudDirectoryBlocked = value.cloudDirectoryBlocked == true,
        -- Older snapshots did not record whether the remote directory had
        -- ever been observed. Treat them as unknown and hydrate once before
        -- publishing again.
        cloudDirectoryConfirmed = value.cloudDirectoryConfirmed == true,
    }
end

local function encodeSnapshot(snapshot)
    local ok, encoded = pcall(cjson.encode, snapshot)
    if ok then return encoded end
    return nil
end

local function closeFile(file)
    if file == nil then return end
    pcall(function() file:Close() end)
end

local function readLocalFile(fileApi, name)
    if not fileApi then return nil end
    -- Maker logs an engine-level ERROR when FILE_READ targets a missing file.
    -- That log is emitted before Lua's pcall can contain the failed open, so a
    -- missing first-run snapshot must be detected before constructing File.
    local existsOk, exists = pcall(function()
        return fileApi.fileSystem ~= nil
            and fileApi.fileSystem:FileExists(name) == true
    end)
    if not existsOk or not exists then return nil end
    local ok, file = pcall(function()
        return fileApi.factory(name, fileApi.readMode)
    end)
    if not ok or file == nil then return nil end
    local opened = false
    pcall(function() opened = file:IsOpen() == true end)
    if not opened then
        closeFile(file)
        return nil
    end
    local readOk, encoded = pcall(function() return file:ReadString() end)
    closeFile(file)
    if not readOk then return nil end
    return encoded
end

local function writeLocalFile(fileApi, name, encoded)
    if not fileApi or not encoded then return false end
    local ok, file = pcall(function()
        return fileApi.factory(name, fileApi.writeMode)
    end)
    if not ok or file == nil then return false end
    local opened = false
    pcall(function() opened = file:IsOpen() == true end)
    if not opened then
        closeFile(file)
        return false
    end
    local writeOk = pcall(function()
        if file:WriteString(encoded) == false then error("local write failed") end
        if file:Flush() == false then error("local flush failed") end
    end)
    closeFile(file)
    return writeOk
end

local function readLocalSnapshot(fileApi)
    local primary = normalizeSnapshot(readLocalFile(fileApi, FILE_NAME))
    local backup = normalizeSnapshot(readLocalFile(fileApi, BACKUP_FILE_NAME))
    if backup and (not primary or backup.revision > primary.revision) then return backup, 2 end
    return primary, primary and 1 or nil
end

local function writeLocalSnapshot(fileApi, snapshot, previousBank)
    if not fileApi then return false end
    -- Maker's FILE_WRITE can truncate in place. Always write the other bank;
    -- reopening selects the highest valid revision without an extra pointer.
    local bank = previousBank == 1 and 2 or 1
    local name = bank == 1 and FILE_NAME or BACKUP_FILE_NAME
    return writeLocalFile(fileApi, name, encodeSnapshot(snapshot)), bank
end

local function cloudValue(values)
    if type(values) ~= "table" then return nil, false end
    if values[CLOUD_KEY] == nil then return nil, true end
    local remote = normalizeSnapshot(values[CLOUD_KEY])
    return remote, remote ~= nil
end

local QUEUE_FORMAT = "event_chunks_v1"
local CHUNK_SIZE = 100

local function sameJsonValue(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not sameJsonValue(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

-- Keep remote order, append local-only events, and match identical records by
-- occurrence. Repeating an interrupted merge must not duplicate the backlog;
-- distinct events with colliding legacy IDs must still survive.
local function mergeLegacyEvents(remote, localEvents)
    local lines, unmatched = {}, {}
    for line in remote:gmatch("[^\r\n]+") do
        local ok, event = pcall(cjson.decode, line)
        if ok and type(event) == "table" and type(event.eventId) == "string"
            and type(event.sessionId) == "string" then
            table.insert(lines, line)
            local matches = unmatched[event.eventId] or {}
            unmatched[event.eventId] = matches
            table.insert(matches, event)
        end
    end
    for _, event in ipairs(localEvents) do
        local matched = false
        for index, remoteEvent in ipairs(unmatched[event.eventId] or {}) do
            if sameJsonValue(event, remoteEvent) then
                table.remove(unmatched[event.eventId], index)
                matched = true
                break
            end
        end
        if not matched then table.insert(lines, cjson.encode(event)) end
    end
    return table.concat(lines, "\n")
end

local function decodeChunk(value)
    if type(value) == "string" then
        local ok, decoded = pcall(cjson.decode, value)
        if not ok then return nil end
        value = decoded
    end
    if type(value) ~= "table" or value.format ~= QUEUE_FORMAT
        or type(value.entries) ~= "table" or #value.entries > CHUNK_SIZE
        or type(value.revision) ~= "number" or value.revision < 1
        or value.revision >= math.huge or value.revision % 1 ~= 0 then return nil end
    local records = {}
    for _, row in ipairs(value.entries) do
        if type(row) ~= "table" or type(row.event) ~= "string"
            or type(row.sequence) ~= "number" or row.sequence < 1
            or row.sequence >= math.huge or row.sequence % 1 ~= 0 then return nil end
        local ok, event = pcall(cjson.decode, row.event)
        if not ok or type(event) ~= "table" or type(event.eventId) ~= "string"
            or type(event.sessionId) ~= "string" then return nil end
        table.insert(records, { event = event, encoded = row.event, sequence = row.sequence })
    end
    return value, records
end

-- Queue chunks have stable names and reusable slots. ACKs and appends touch
-- only affected chunks; the main snapshot contains just a small directory.
local function newEventQueue(key, value, fileApi, publishManifest, remoteManifest)
    local prefix = "gaq_" .. Sha256.hex(key):sub(1, 24)
    -- Object identity also preserves legacy events whose short IDs collide.
    local chunks, records, dirtyLocal = {}, {}, {}
    local nextSequence = 0
    local migrating = type(value) == "string" and (value ~= "" or remoteManifest ~= nil)
    local unmatchedLocal = nil
    local queue = {}

    local function newChunk(index, unknown)
        local chunk = { index = index, entries = {}, count = 0, revision = 0,
            cloudRevision = 0, bank = 0, unknown = unknown }
        if remoteManifest or migrating then
            -- Relocated chunks can reuse filenames from an older local queue.
            -- Their next checkpoint must outrank both of those local banks.
            for bank = 1, 2 do
                local previous = decodeChunk(readLocalFile(fileApi, prefix .. "_" .. index .. "_" .. bank .. ".json"))
                if previous and previous.revision > chunk.revision then
                    chunk.revision, chunk.bank = previous.revision, bank
                end
            end
        end
        chunks[index] = chunk
        return chunk
    end

    local function changed(chunk)
        chunk.revision = chunk.revision + 1
        chunk.data = nil
        dirtyLocal[chunk.index] = chunk
    end

    local function dataFor(chunk)
        if chunk.data then return chunk.data end
        local entries = {}
        for _, record in pairs(chunk.entries) do
            table.insert(entries, { sequence = record.sequence, event = record.encoded })
        end
        table.sort(entries, function(a, b) return a.sequence < b.sequence end)
        chunk.data = { format = QUEUE_FORMAT, revision = chunk.revision, entries = entries }
        return chunk.data
    end

    function queue:Upsert(event)
        local record = records[event]
        if record and record.contextId == event.contextId then return end
        local encoded = cjson.encode(event)
        if record then
            record.event, record.encoded, record.contextId = event, encoded, event.contextId
            changed(record.chunk)
            return
        end
        local chunk
        for _, candidate in ipairs(chunks) do
            if not candidate.unknown and candidate.count < CHUNK_SIZE then chunk = candidate; break end
        end
        chunk = chunk or newChunk(#chunks + 1, false)
        nextSequence = nextSequence + 1
        record = { event = event, encoded = encoded, contextId = event.contextId,
            sequence = nextSequence, chunk = chunk }
        records[event], chunk.entries[event] = record, record
        chunk.count = chunk.count + 1
        changed(chunk)
    end

    function queue:Remove(events)
        for _, event in ipairs(events) do
            local record = records[event]
            if record then
                records[event], record.chunk.entries[event] = nil, nil
                record.chunk.count = record.chunk.count - 1
                changed(record.chunk)
            end
        end
    end

    function queue:Events()
        local ordered, events = {}, {}
        for _, record in pairs(records) do table.insert(ordered, record) end
        table.sort(ordered, function(a, b) return a.sequence < b.sequence end)
        for _, record in ipairs(ordered) do table.insert(events, record.event) end
        return events
    end

    --- Restores an unread chunk. Recovery matches cloud/local copies once by
    --- eventId and JSON content, preserving colliding IDs and multiplicity.
    ---@param index integer Reserved chunk slot to hydrate.
    ---@param data table|string Encoded or decoded chunk.
    ---@param source string "local" or "cloud".
    ---@return boolean imported Whether a valid unread chunk was accepted.
    function queue:Import(index, data, source)
        local decoded, imported = decodeChunk(data)
        if not decoded then return false end
        local chunk = chunks[index]
        if not chunk or not chunk.unknown then return false end
        chunk.unknown = false
        chunk.revision = remoteManifest and math.max(decoded.revision, chunk.revision + 1) or decoded.revision
        chunk.data = chunk.revision == decoded.revision and decoded or nil
        if source == "cloud" then
            chunk.cloudRevision = chunk.revision
            dirtyLocal[index] = chunk
        end
        if remoteManifest and source == "cloud" and not unmatchedLocal then
            unmatchedLocal = {}
            for _, existing in pairs(records) do
                local event = existing.event
                local matches = unmatchedLocal[event.eventId] or {}
                unmatchedLocal[event.eventId] = matches
                table.insert(matches, event)
            end
        end
        for _, record in ipairs(imported) do
            local event = record.event
            if source == "cloud" and remoteManifest ~= nil then
                for matchIndex, localEvent in ipairs(unmatchedLocal[event.eventId] or {}) do
                    if sameJsonValue(localEvent, event) then
                        table.remove(unmatchedLocal[event.eventId], matchIndex)
                        -- Keep the cloud copy in its existing slot. Removing
                        -- the local copy avoids deleting remote data before
                        -- a relocated local chunk has reached the cloud.
                        self:Remove({ localEvent })
                        break
                    end
                end
            end
            if not records[event] then
                record.contextId, record.chunk = event.contextId, chunk
                record.fromRemote = remoteManifest ~= nil and source == "cloud"
                records[event], chunk.entries[event] = record, record
                chunk.count = chunk.count + 1
                nextSequence = math.max(nextSequence, record.sequence)
            end
        end
        return true
    end

    function queue:MissingBlocks()
        local missing = {}
        for index, chunk in ipairs(chunks) do
            if chunk.unknown then table.insert(missing, { queue = self, index = index, key = prefix .. "_" .. index }) end
        end
        return missing
    end

    function queue:ConfirmEmpty(index)
        local chunk = chunks[index]
        if chunk and chunk.unknown then
            chunk.unknown = false
            if remoteManifest then
                changed(chunk)
                chunk.cloudRevision = chunk.revision
            end
        end
    end

    function queue:Persist()
        if remoteManifest then
            for _, chunk in ipairs(chunks) do
                if chunk.unknown then
                    local lines = {}
                    for _, event in ipairs(self:Events()) do
                        if not records[event].fromRemote then table.insert(lines, cjson.encode(event)) end
                    end
                    return publishManifest(nil, table.concat(lines, "\n"))
                end
            end
            unmatchedLocal = nil
        end
        if migrating and fileApi and not remoteManifest then
            -- A legacy merge may reuse existing local chunk slots. Commit its
            -- complete JSONL recovery source before changing either chunk bank.
            local lines = {}
            for _, event in ipairs(self:Events()) do table.insert(lines, cjson.encode(event)) end
            if not publishManifest(nil, table.concat(lines, "\n")) then return false end
        end
        -- Publish new slots first so a completed chunk write is discoverable.
        -- Legacy migration instead keeps the old JSONL until every chunk is safe.
        if (not migrating or not fileApi) and not publishManifest(#chunks) then return false end
        for index, chunk in pairs(dirtyLocal) do
            local bank = chunk.bank == 1 and 2 or 1
            if not writeLocalFile(fileApi, prefix .. "_" .. index .. "_" .. bank .. ".json",
                encodeSnapshot(dataFor(chunk))) then return false end
            chunk.bank = bank
            dirtyLocal[index] = nil
        end
        if migrating then
            if not publishManifest(#chunks) then return false end
            migrating = false
        end
        return true
    end

    function queue:CloudJobs()
        local jobs = {}
        for index, chunk in ipairs(chunks) do
            if not chunk.unknown and chunk.cloudRevision < chunk.revision then
                local revision = chunk.revision
                table.insert(jobs, { key = prefix .. "_" .. index, data = dataFor(chunk),
                    ack = function() chunk.cloudRevision = math.max(chunk.cloudRevision, revision) end })
            end
        end
        return jobs
    end

    if remoteManifest then
        -- Reserve remote slots before appending locally recovered events.
        -- Their local files may belong to the timed-out run, so read these
        -- slots from cloud rather than mistaking local chunks for remote ones.
        for index = 1, math.max(0, math.floor(tonumber(remoteManifest.blocks) or 0)) do
            newChunk(index, true)
        end
    elseif type(value) == "table" and value.format == QUEUE_FORMAT then
        for index = 1, math.max(0, math.floor(tonumber(value.blocks) or 0)) do
            local chunk = newChunk(index, true)
            local best, bestBank
            for bank = 1, 2 do
                local candidate = decodeChunk(readLocalFile(fileApi, prefix .. "_" .. index .. "_" .. bank .. ".json"))
                if candidate and (not best or candidate.revision > best.revision) then best, bestBank = candidate, bank end
            end
            if best and queue:Import(index, best, "local") then
                chunk.bank = bestBank
            end
        end
    end
    if migrating then
        for line in value:gmatch("[^\r\n]+") do
            local ok, event = pcall(cjson.decode, line)
            if ok and type(event) == "table" and type(event.eventId) == "string"
                and type(event.sessionId) == "string" then queue:Upsert(event) end
        end
    end
    return queue
end

--- Creates a small Maker-native scheduler without replacing the game's global
--- Update handler. The dedicated LuaScriptObject owns its own subscription.
function MakerAutoStorage.NewScheduler(options)
    options = options or {}
    local logger = type(options.logger) == "function" and options.logger or function() end
    local now = type(options.nowMs) == "function"
        and options.nowMs
        or function() return math.floor(os.time() * 1000) end
    local tasks = {}
    local nextTaskId = 0
    local eventNode = nil
    local eventObject = nil
    local automatic = options.externallyDriven == true
    local stopped = false
    local scheduler = {}

    function scheduler:Schedule(delayMs, callback)
        if stopped or type(callback) ~= "function" then return nil end
        nextTaskId = nextTaskId + 1
        local handle = { id = nextTaskId }
        tasks[handle.id] = {
            handle = handle,
            dueAt = now() + math.max(0, tonumber(delayMs) or 0),
            callback = callback,
        }
        return handle
    end

    function scheduler:Cancel(handle)
        if type(handle) ~= "table" then return end
        tasks[handle.id] = nil
    end

    function scheduler:Update()
        if stopped then return end
        local current = now()
        local due = {}
        for id, task in pairs(tasks) do
            if task.dueAt <= current then
                tasks[id] = nil
                table.insert(due, task)
            end
        end
        table.sort(due, function(left, right)
            if left.dueAt == right.dueAt then return left.handle.id < right.handle.id end
            return left.dueAt < right.dueAt
        end)
        for _, task in ipairs(due) do
            local ok, reason = pcall(task.callback)
            if not ok then logger("scheduler callback failed: " .. tostring(reason)) end
        end
    end

    function scheduler:IsAutomatic()
        return automatic
    end

    function scheduler:Shutdown()
        if stopped then return end
        stopped = true
        tasks = {}
        if eventObject ~= nil then
            pcall(function() eventObject:UnsubscribeFromAllEvents() end)
        end
        eventObject = nil
        eventNode = nil
    end

    local nodeFactory = makerGlobal(function() return Node end)
    if not automatic and nodeFactory ~= nil then
        local subscribed = pcall(function()
            eventNode = nodeFactory()
            eventObject = eventNode:CreateScriptObject("LuaScriptObject")
            eventObject:SubscribeToEvent("Update", function()
                scheduler:Update()
            end)
        end)
        automatic = subscribed and eventObject ~= nil
    end

    return scheduler
end

--- Creates Maker storage with bounded cloud hydration and synchronous local
--- checkpoints. Unconfirmed cloud access remains write-blocked across restarts,
--- including launches without clientCloud or an automatic timeout scheduler.
---@param options table|nil Scheduler, logger, and optional cloudReadTimeoutMs.
---@return table|nil storage
---@return string|nil error
function MakerAutoStorage.New(options)
    options = options or {}
    if not isMakerRuntime() then
        return nil, "GameAlgo Lua SDK automatic storage requires a TapTap Maker runtime"
    end

    local logger = type(options.logger) == "function" and options.logger or function() end
    local scheduler = options.scheduler
    local cloudReadTimeoutMs = math.max(0,
        tonumber(options.cloudReadTimeoutMs) or DEFAULT_CLOUD_READ_TIMEOUT_MS)
    local fileApi = makerFileApi()
    local localSnapshot, localBank = readLocalSnapshot(fileApi)
    local snapshot = localSnapshot or emptySnapshot()
    local localAvailable = localSnapshot ~= nil
    local localDirty = localSnapshot == nil
    local legacyLocalRevision = localSnapshot and localSnapshot.revision or nil
    local legacyCloudDirectory = localSnapshot ~= nil
        and not localSnapshot.cloudDirectoryBlocked
        and not localSnapshot.cloudDirectoryConfirmed
    local ready = false
    local readyCallbacks = {}
    local stopped = false
    local cloudWriteInFlight = false
    local cloudWritePending = false
    local cloudWriteCallbacks = {}
    local cloudDirty = false
    local cloudDirectoryConfirmed = snapshot.cloudDirectoryConfirmed == true
    local cloudDirectoryBlocked = not cloudDirectoryConfirmed or snapshot.cloudDirectoryBlocked == true
    local cloudDirectoryKnown = false
    local cloudRecoveryPending = false

    local storage = {}
    local eventQueues = {}
    local recoveryManifests = {}

    local function persistLocal()
        if snapshot.cloudDirectoryBlocked ~= cloudDirectoryBlocked
            or snapshot.cloudDirectoryConfirmed ~= cloudDirectoryConfirmed then
            snapshot.revision = snapshot.revision + 1
            localDirty = true
        end
        snapshot.cloudDirectoryBlocked = cloudDirectoryBlocked
        snapshot.cloudDirectoryConfirmed = cloudDirectoryConfirmed
        local saved, bank = writeLocalSnapshot(fileApi, snapshot, localBank)
        if saved then
            localBank = bank
            localAvailable = true
            localDirty = false
            return true
        end
        return false
    end

    local function markReady(source)
        if stopped or ready then return end
        ready = true
        logger("automatic storage ready: " .. tostring(source))
        local callbacks = readyCallbacks
        readyCallbacks = {}
        for _, callback in ipairs(callbacks) do
            pcall(callback)
        end
    end

    function storage:EventQueue(key)
        if not eventQueues[key] then
            eventQueues[key] = newEventQueue(key, snapshot.data[key], fileApi, function(count, pendingEvents)
                if stopped then return false end
                local manifest = snapshot.data[key]
                if pendingEvents ~= nil and manifest ~= pendingEvents then
                    snapshot.data[key] = pendingEvents
                    snapshot.revision = snapshot.revision + 1
                    localDirty, cloudDirty = true, true
                elseif pendingEvents == nil and (type(manifest) ~= "table"
                    or manifest.format ~= QUEUE_FORMAT or manifest.blocks ~= count) then
                    snapshot.data[key] = { format = QUEUE_FORMAT, blocks = count }
                    snapshot.revision = snapshot.revision + 1
                    localDirty, cloudDirty = true, true
                end
                return not localDirty or persistLocal()
            end, recoveryManifests[key])
        end
        return eventQueues[key]
    end

    local function completeCloudRecovery()
        if not cloudRecoveryPending then return end
        for _, queue in pairs(eventQueues) do
            if #queue:MissingBlocks() > 0 then return end
            if not queue:Persist() and fileApi then return end
        end
        cloudDirectoryBlocked = false
        if persistLocal() or not fileApi then
            cloudRecoveryPending = false
        else
            cloudDirectoryBlocked = true
        end
    end

    local function loadQueuesThenReady(source)
        local missing = {}
        for key, value in pairs(snapshot.data) do
            if recoveryManifests[key] or (type(value) == "table" and value.format == QUEUE_FORMAT)
                or (type(key) == "string" and key:match(":events:jsonl$") and type(value) == "string") then
                for _, block in ipairs(storage:EventQueue(key):MissingBlocks()) do table.insert(missing, block) end
            end
        end
        local remaining, settled, timeout = #missing, false, nil
        local function finish()
            if stopped or settled then return end
            settled = true
            if timeout and type(scheduler.Cancel) == "function" then scheduler:Cancel(timeout) end
            for _, queue in pairs(eventQueues) do queue:Persist() end
            completeCloudRecovery()
            markReady(source)
        end
        local cloud = makerCloud()
        if remaining == 0 or not cloud or scheduler == nil or type(scheduler.Schedule) ~= "function"
            or (type(scheduler.IsAutomatic) == "function" and not scheduler:IsAutomatic()) then finish(); return end
        timeout = scheduler:Schedule(cloudReadTimeoutMs, function()
            logger("automatic storage queue read timed out")
            finish()
        end)
        if timeout == nil then finish(); return end
        for _, block in ipairs(missing) do
            local completed = false
            local function complete(values)
                if stopped or settled or completed then return end
                completed = true
                if type(values) == "table" then
                    if values[block.key] == nil then block.queue:ConfirmEmpty(block.index)
                    else block.queue:Import(block.index, values[block.key], "cloud") end
                end
                remaining = remaining - 1
                if remaining == 0 then finish() end
            end
            local started = pcall(function()
                cloud:Get(block.key, { ok = complete, error = function() complete(nil) end })
            end)
            if not started then complete(nil) end
        end
    end

    local function loadCloudThenReady()
        local cloud = makerCloud()
        if not cloud then
            -- Keep this marker in the local snapshot. A later run may regain
            -- clientCloud; it must read the remote directory before publishing.
            persistLocal()
            loadQueuesThenReady(localAvailable and "local" or "memory")
            return
        end

        local canSchedule = scheduler ~= nil
            and type(scheduler.Schedule) == "function"
            and (type(scheduler.IsAutomatic) ~= "function" or scheduler:IsAutomatic())
        if not canSchedule then
            logger("automatic storage cloud read skipped: timeout scheduler unavailable")
            persistLocal()
            loadQueuesThenReady(localAvailable and "local" or "memory")
            return
        end

        local settled = false
        local timeoutHandle = nil
        local function finish(source, remote, readResolved)
            if stopped or settled then return end
            settled = true
            if timeoutHandle and type(scheduler.Cancel) == "function" then
                scheduler:Cancel(timeoutHandle)
            end
            -- Only a resolved read (merged snapshot or confirmed-empty) makes
            -- the cloud directory safe to publish. After a timeout or error
            -- the remote state is unknown, so publishing could overwrite an
            -- existing snapshot with the fresh empty one.
            if readResolved and next(snapshot.data) ~= nil then cloudDirty = true end
            cloudDirectoryKnown = readResolved == true
            cloudDirectoryConfirmed = readResolved == true
            cloudDirectoryBlocked = not cloudDirectoryKnown
            if remote then
                for key, value in pairs(remote.data) do
                    if type(key) == "string" and key:match(":events:jsonl$") and type(value) == "string" then
                        cloudDirectoryBlocked, cloudRecoveryPending = true, true
                        break
                    end
                end
            end
            local legacySnapshotIsCurrent = legacyCloudDirectory
                and legacyLocalRevision ~= nil
                and remote ~= nil
                and remote.revision <= legacyLocalRevision
            if legacySnapshotIsCurrent then
                -- Snapshots written before the confirmation marker were
                -- published directly by the SDK. If the remote revision is
                -- not newer, the local directory is already authoritative;
                -- upgrade the marker without replaying its chunks.
                cloudDirectoryKnown = true
                cloudDirectoryConfirmed = true
                cloudDirectoryBlocked = false
                cloudRecoveryPending = false
            elseif remote and next(snapshot.data) ~= nil then
                -- Keep local values created while offline and retain remote
                -- keys. Conflicting queues append local events after reserved
                -- remote slots; never upload them into unread remote slots.
                cloudDirectoryBlocked, cloudRecoveryPending = true, true
                -- A timeout-created identity is provisional. Recover the
                -- original identity and retain both users' pending events.
                for identityKey, remoteUserId in pairs(remote.data) do
                    local namespace = type(identityKey) == "string"
                        and identityKey:match("^(gamealgo:v2:game:[^:]+):identity:user_id$")
                    local localUserId = snapshot.data[identityKey]
                    if namespace and type(localUserId) == "string" and localUserId ~= ""
                        and type(remoteUserId) == "string" and remoteUserId ~= ""
                        and localUserId ~= remoteUserId then
                        local localQueueKey = namespace .. ":user:" .. Sha256.hex(localUserId) .. ":events:jsonl"
                        local remoteQueueKey = namespace .. ":user:" .. Sha256.hex(remoteUserId) .. ":events:jsonl"
                        if snapshot.data[localQueueKey] ~= nil then
                            local lines = {}
                            for _, queueKey in ipairs({ remoteQueueKey, localQueueKey }) do
                                if snapshot.data[queueKey] ~= nil then
                                    for _, event in ipairs(storage:EventQueue(queueKey):Events()) do
                                        table.insert(lines, cjson.encode(event))
                                    end
                                end
                            end
                            snapshot.data[remoteQueueKey] = table.concat(lines, "\n")
                            snapshot.data[localQueueKey] = nil
                            eventQueues[localQueueKey], eventQueues[remoteQueueKey] = nil, nil
                        end
                    end
                end
                for key, value in pairs(remote.data) do
                    local localValue = snapshot.data[key]
                    if type(value) == "table" and value.format == QUEUE_FORMAT then
                        if localValue ~= nil then
                            local lines = {}
                            for _, event in ipairs(storage:EventQueue(key):Events()) do
                                table.insert(lines, cjson.encode(event))
                            end
                            -- This JSONL checkpoint survives interruption while
                            -- the merged chunks are being moved to new slots.
                            snapshot.data[key] = table.concat(lines, "\n")
                        else
                            snapshot.data[key] = ""
                        end
                        recoveryManifests[key], eventQueues[key] = value, nil
                    elseif type(value) == "string" and value ~= "" and type(key) == "string"
                        and (key:match(":identity:user_id$")
                        or key:match(":identity:user_created_at$")
                        or key:match(":identity:user_created_local_at$")) then
                        snapshot.data[key] = value
                    elseif type(value) == "string" and type(key) == "string"
                        and key:match(":events:jsonl$") then
                        local localEvents = localValue ~= nil and storage:EventQueue(key):Events() or {}
                        -- Checkpoint the complete merged JSONL before touching
                        -- chunk banks, so an interrupted migration can restart.
                        snapshot.data[key] = mergeLegacyEvents(value, localEvents)
                        eventQueues[key] = nil
                    elseif localValue == nil then
                        snapshot.data[key] = value
                    end
                end
                snapshot.revision = math.max(snapshot.revision, remote.revision) + 1
                localDirty, cloudDirty = true, true
            elseif remote then
                remote.revision = math.max(snapshot.revision, remote.revision) + 1
                snapshot = remote
            end
            persistLocal()
            loadQueuesThenReady(source)
        end

        timeoutHandle = scheduler:Schedule(cloudReadTimeoutMs, function()
            logger("automatic storage cloud read timed out after "
                .. tostring(cloudReadTimeoutMs) .. "ms")
            finish(localAvailable and "local-timeout" or "memory-timeout", nil)
        end)
        if timeoutHandle == nil then
            logger("automatic storage cloud read skipped: timeout scheduling failed")
            persistLocal()
            loadQueuesThenReady(localAvailable and "local" or "memory")
            return
        end

        -- Persist before starting the asynchronous read. A restart at any
        -- point, even before its timeout callback, must retain the gate.
        cloudDirectoryBlocked = true
        persistLocal()
        local started = pcall(function()
            cloud:Get(CLOUD_KEY, {
                ok = function(values)
                    local remote, resolved = cloudValue(values)
                    finish(remote and "cloud" or (localAvailable and "local" or "memory"), remote, resolved)
                end,
                error = function(code, reason)
                    logger("automatic storage cloud read failed: " .. tostring(code) .. " " .. tostring(reason))
                    finish(localAvailable and "local" or "memory", nil)
                end,
            })
        end)
        if not started then
            finish(localAvailable and "local" or "memory", nil)
        end
    end

    function storage:IsReady()
        return ready
    end

    function storage:OnReady(callback)
        if stopped or type(callback) ~= "function" then return end
        if ready then
            callback()
        else
            table.insert(readyCallbacks, callback)
        end
    end

    --- Stops local writes and ignores pending reads and write continuations.
    --- A cloud write already submitted to the host cannot be recalled.
    function storage:Shutdown()
        if stopped then return end
        stopped = true
        readyCallbacks = {}
        cloudWritePending = false
        cloudWriteCallbacks = {}
    end

    function storage:GetItem(key)
        return snapshot.data[tostring(key)]
    end

    function storage:SetItem(key, value)
        if stopped then return false end
        key = tostring(key)
        -- SDK values are normally serialized strings. Tables may have been
        -- mutated in place, so only scalar equality can skip a new revision.
        if snapshot.data[key] ~= value or type(value) == "table" then
            snapshot.data[key] = value
            snapshot.revision = snapshot.revision + 1
            cloudDirty = true
            localDirty = true
        end
        if not localDirty then return true end
        return persistLocal()
    end

    function storage:Flush(callback)
        callback = type(callback) == "function" and callback or function() end
        if stopped then callback(nil); return end
        if not ready then storage:OnReady(function() storage:Flush(callback) end); return end
        completeCloudRecovery()
        if localDirty then persistLocal() end
        if cloudWriteInFlight then
            cloudWritePending = true
            table.insert(cloudWriteCallbacks, callback)
            return
        end
        local cloud = makerCloud()
        if not cloud then callback(nil); return end
        -- Chunks use stable cloud keys too, so an unresolved read must block
        -- every write, not only publication of the root directory.
        if cloudDirectoryBlocked then callback(nil); return end
        local jobs = {}
        for _, queue in pairs(eventQueues) do
            for _, job in ipairs(queue:CloudJobs()) do table.insert(jobs, job) end
        end
        -- Upload chunks before publishing a directory that references them.
        -- Publishing is gated on the cloud read: a read that timed out or
        -- failed leaves the remote state unknown, so overwriting it could
        -- destroy the previous device's snapshot. A run without cloud access
        -- or an automatic scheduler keeps its data local until a later launch
        -- can confirm and reconcile the remote directory.
        if cloudDirty or (#jobs > 0 and not cloudDirectoryKnown) then
            local revision = snapshot.revision
            table.insert(jobs, { key = CLOUD_KEY, data = normalizeSnapshot(encodeSnapshot(snapshot)),
                ack = function()
                    cloudDirectoryKnown = true
                    if snapshot.revision == revision then cloudDirty = false end
                end })
        end
        if #jobs == 0 then callback(nil); return end
        local callbacks = cloudWriteCallbacks
        cloudWriteCallbacks = {}
        table.insert(callbacks, callback)
        cloudWriteInFlight, cloudWritePending = true, false
        local finished, pumping, waiting, index = false, false, false, 0
        local function complete(error)
            if finished then return end
            finished, cloudWriteInFlight = true, false
            for _, pendingCallback in ipairs(callbacks) do pcall(pendingCallback, error) end
            local changed = not stopped and cloudDirty
            if not changed and not error and not stopped then
                for _, queue in pairs(eventQueues) do
                    if #queue:CloudJobs() > 0 then changed = true; break end
                end
            end
            if not stopped and (cloudWritePending or (not error and changed)) then storage:Flush(nil) end
        end
        local pump
        pump = function()
            if pumping then return end
            pumping = true
            while not waiting and not finished do
                index = index + 1
                local job = jobs[index]
                if stopped then complete("storage stopped"); break end
                if not job then complete(nil); break end
                waiting = true
                local settled = false
                local function done(error)
                    if settled or finished then return end
                    if stopped then
                        settled, waiting = true, false
                        complete("storage stopped")
                        return
                    end
                    settled, waiting = true, false
                    if error then complete(error)
                    else
                        job.ack()
                        if not pumping then pump() end
                    end
                end
                local started = pcall(function()
                    cloud:Set(job.key, job.data, {
                        ok = function() done(nil) end,
                        error = function(code, reason)
                            logger("automatic storage cloud write failed: " .. tostring(code) .. " " .. tostring(reason))
                            done(tostring(reason or code or "cloud write failed"))
                        end,
                        timeout = function()
                            logger("automatic storage cloud write timed out")
                            done("cloud write timed out")
                        end,
                    })
                end)
                if not started then done("cloud write unavailable") end
            end
            pumping = false
        end
        pump()
    end

    function storage:Diagnostics()
        return {
            ready = ready,
            localAvailable = localAvailable,
            cloudAvailable = makerCloud() ~= nil,
            revision = snapshot.revision,
            cloudDirty = cloudDirty,
        }
    end

    if localSnapshot and not cloudDirectoryBlocked then
        loadQueuesThenReady("local")
    else
        loadCloudThenReady()
    end

    return storage, nil
end

return MakerAutoStorage
