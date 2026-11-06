---@meta
--- Internal persistent storage for TapTap Maker.
---
--- The SDK exposes synchronous reads to its identity, script cache, and DDA
--- layers while hiding Maker's asynchronous clientCloud API. A local File
--- snapshot is used as the fast path. When no local snapshot exists, the
--- first cloud read completes before the SDK starts, with a bounded timeout so
--- a missing clientCloud callback cannot block the whole session.

local cjson = require("cjson")

local shaOk, Sha256 = pcall(require, "sdk.Sha256")
if not shaOk then Sha256 = require("Sha256") end

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
    if type(values) ~= "table" then return nil end
    return normalizeSnapshot(values[CLOUD_KEY])
end

local QUEUE_FORMAT = "event_chunks_v1"
local CHUNK_SIZE = 100

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
local function newEventQueue(key, value, fileApi, publishManifest)
    local prefix = "gaq_" .. Sha256.hex(key):sub(1, 24)
    -- Object identity also preserves legacy events whose short IDs collide.
    local chunks, records, dirtyLocal = {}, {}, {}
    local nextSequence = 0
    local migrating = type(value) == "string" and value ~= ""
    local queue = {}

    local function newChunk(index, unknown)
        local chunk = { index = index, entries = {}, count = 0, revision = 0,
            cloudRevision = 0, bank = 0, unknown = unknown }
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

    function queue:Import(index, data, source)
        local decoded, imported = decodeChunk(data)
        if not decoded then return false end
        local chunk = chunks[index]
        if not chunk or not chunk.unknown then return false end
        chunk.unknown, chunk.revision = false, decoded.revision
        chunk.data = decoded
        if source == "cloud" then
            chunk.cloudRevision = decoded.revision
            dirtyLocal[index] = chunk
        end
        for _, record in ipairs(imported) do
            local event = record.event
            if not records[event] then
                record.contextId, record.chunk = event.contextId, chunk
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
        if chunk and chunk.unknown then chunk.unknown = false end
    end

    function queue:Persist()
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

    if type(value) == "table" and value.format == QUEUE_FORMAT then
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
    elseif migrating then
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
    local ready = false
    local readyCallbacks = {}
    local cloudWriteInFlight = false
    local cloudWritePending = false
    local cloudWriteCallbacks = {}
    local cloudDirty = false
    local cloudDirectoryKnown = false

    local storage = {}
    local eventQueues = {}

    local function persistLocal()
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
        if ready then return end
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
            eventQueues[key] = newEventQueue(key, snapshot.data[key], fileApi, function(count)
                local manifest = snapshot.data[key]
                if type(manifest) ~= "table" or manifest.format ~= QUEUE_FORMAT or manifest.blocks ~= count then
                    snapshot.data[key] = { format = QUEUE_FORMAT, blocks = count }
                    snapshot.revision = snapshot.revision + 1
                    localDirty, cloudDirty = true, true
                end
                return not localDirty or persistLocal()
            end)
        end
        return eventQueues[key]
    end

    local function loadQueuesThenReady(source)
        local missing = {}
        for key, value in pairs(snapshot.data) do
            if type(value) == "table" and value.format == QUEUE_FORMAT then
                for _, block in ipairs(storage:EventQueue(key):MissingBlocks()) do table.insert(missing, block) end
            end
        end
        local remaining, settled, timeout = #missing, false, nil
        local function finish()
            if settled then return end
            settled = true
            if timeout and type(scheduler.Cancel) == "function" then scheduler:Cancel(timeout) end
            for _, queue in pairs(eventQueues) do queue:Persist() end
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
                if settled or completed then return end
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
        local function finish(source, remote)
            if settled then return end
            settled = true
            if timeoutHandle and type(scheduler.Cancel) == "function" then
                scheduler:Cancel(timeoutHandle)
            end
            if remote then snapshot = remote; cloudDirectoryKnown = true end
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

        local started = pcall(function()
            cloud:Get(CLOUD_KEY, {
                ok = function(values)
                    local remote = cloudValue(values)
                    finish(remote and "cloud" or (localAvailable and "local" or "memory"), remote)
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
        if type(callback) ~= "function" then return end
        if ready then
            callback()
        else
            table.insert(readyCallbacks, callback)
        end
    end

    function storage:GetItem(key)
        return snapshot.data[tostring(key)]
    end

    function storage:SetItem(key, value)
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
        if not ready then storage:OnReady(function() storage:Flush(callback) end); return end
        if localDirty then persistLocal() end
        if cloudWriteInFlight then
            cloudWritePending = true
            table.insert(cloudWriteCallbacks, callback)
            return
        end
        local cloud = makerCloud()
        if not cloud then callback(nil); return end
        local jobs = {}
        for _, queue in pairs(eventQueues) do
            for _, job in ipairs(queue:CloudJobs()) do table.insert(jobs, job) end
        end
        -- Upload chunks before publishing a directory that references them.
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
            local changed = cloudDirty
            if not changed and not error then
                for _, queue in pairs(eventQueues) do
                    if #queue:CloudJobs() > 0 then changed = true; break end
                end
            end
            if cloudWritePending or (not error and changed) then storage:Flush(nil) end
        end
        local pump
        pump = function()
            if pumping then return end
            pumping = true
            while not waiting and not finished do
                index = index + 1
                local job = jobs[index]
                if not job then complete(nil); break end
                waiting = true
                local settled = false
                local function done(error)
                    if settled or finished then return end
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

    if localSnapshot then
        loadQueuesThenReady("local")
    else
        loadCloudThenReady()
    end

    return storage, nil
end

return MakerAutoStorage
