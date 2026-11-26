---@meta
--- Local persistent storage used by the GameAlgo Lua SDK.
---
--- The SDK keeps its identity, configuration, and event backlog in Maker's
--- local File API. HTTP is responsible for delivery and acknowledgement;
--- this module never depends on a platform cloud-variable service.

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
local SCHEMA_VERSION = 1
local QUEUE_FORMAT = "event_chunks_v1"
local CHUNK_SIZE = 100

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
    return { factory = factory, readMode = readMode, writeMode = writeMode, fileSystem = makerFileSystem }
end

local function isMakerRuntime()
    if makerFileApi() then return true end
    return makerGlobal(function() return lobby end) ~= nil
end

local function emptySnapshot()
    return { schemaVersion = SCHEMA_VERSION, revision = 0, data = {} }
end

local function normalizeSnapshot(value)
    if type(value) == "string" then
        local ok, decoded = pcall(cjson.decode, value)
        if not ok then return nil end
        value = decoded
    end
    if type(value) ~= "table" or type(value.data) ~= "table"
        or tonumber(value.schemaVersion) ~= SCHEMA_VERSION then return nil end
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
    if file == nil then return false end
    local ok, result = pcall(function() return file:Close() end)
    return ok and result ~= false
end

local function readLocalFile(fileApi, name, expectedSize)
    if not fileApi then return nil end
    -- Native File logs missing reads. File-only hosts can still probe IsOpen.
    local existsOk, exists = pcall(function()
        local fs = fileApi.fileSystem
        if fs and type(fs.FileExists) == "function" then return fs:FileExists(name) end
    end)
    if existsOk and exists == false then return nil end
    local ok, file = pcall(function() return fileApi.factory(name, fileApi.readMode) end)
    if not ok or file == nil then return nil end
    local opened = false
    pcall(function() opened = file:IsOpen() == true end)
    if not opened then closeFile(file); return nil end
    local readOk, encoded = pcall(function()
        local size = type(file.GetSize) == "function" and file:GetSize() or nil
        local reader = file
        if expectedSize and size then
            if size ~= expectedSize then return nil end
            -- Read a known-size checkpoint in one native I/O operation.
            if type(file.Read) == "function" and type(file.GetPosition) == "function" then
                reader = file:Read(size)
                if file:GetPosition() ~= size then return nil end
            end
        end
        local value = reader:ReadString()
        -- WriteString includes a NUL. ReadString also accepts EOF without it.
        if size == nil or size == #value + 1 then return value end
    end)
    closeFile(file)
    if not readOk then return nil end
    return encoded
end

local function writeLocalFile(fileApi, name, encoded)
    if not fileApi or not encoded then return false end
    local ok, file = pcall(function() return fileApi.factory(name, fileApi.writeMode) end)
    if not ok or file == nil then return false end
    local opened = false
    pcall(function() opened = file:IsOpen() == true end)
    if not opened then closeFile(file); return false end
    local writeOk, written = pcall(function()
        return file:WriteString(encoded) ~= false and file:Flush() ~= false
    end)
    local closed = closeFile(file)
    -- Deployed Flush and Close bindings return void even on a buffered commit failure.
    return writeOk and written and closed and readLocalFile(fileApi, name, #encoded + 1) == encoded
end

local function readLocalSnapshot(fileApi)
    local primary = normalizeSnapshot(readLocalFile(fileApi, FILE_NAME))
    local backup = normalizeSnapshot(readLocalFile(fileApi, BACKUP_FILE_NAME))
    if backup and (not primary or backup.revision > primary.revision) then return backup, 2 end
    return primary, primary and 1 or nil
end

local function writeLocalSnapshot(fileApi, snapshot, previousBank)
    if not fileApi then return false end
    local bank = previousBank == 1 and 2 or 1
    local name = bank == 1 and FILE_NAME or BACKUP_FILE_NAME
    return writeLocalFile(fileApi, name, encodeSnapshot(snapshot)), bank
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

-- Event chunks use stable names and two local banks. HTTP acknowledgement
-- removes records through Remove; no cloud copy is kept by this queue.
local function newEventQueue(key, value, fileApi, publishManifest, isActive)
    local prefix = "gaq_" .. Sha256.hex(key):sub(1, 24)
    local chunks, records, dirtyLocal = {}, {}, {}
    local nextSequence = 0
    local migrating = type(value) == "string" and value ~= ""
    local queue = {}

    local function newChunk(index, restore)
        local chunk = { index = index, entries = {}, count = 0, revision = 0, bank = 0 }
        -- An interrupted directory write may leave newer files outside the
        -- committed directory. Reusing a slot must outrank both retained banks
        -- without importing events that never belonged to this checkpoint.
        local bestRecords
        for bank = 1, 2 do
            local previous, imported = decodeChunk(readLocalFile(
                fileApi, prefix .. "_" .. index .. "_" .. bank .. ".json"))
            if previous and previous.revision > chunk.revision then
                chunk.revision, chunk.bank, bestRecords = previous.revision, bank, imported
            end
        end
        if restore then
            for _, record in ipairs(bestRecords or {}) do
                record.contextId, record.chunk = record.event.contextId, chunk
                records[record.event], chunk.entries[record.event] = record, record
                chunk.count = chunk.count + 1
                nextSequence = math.max(nextSequence, record.sequence)
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
        chunk.data = { format = QUEUE_FORMAT, revision = math.max(1, chunk.revision), entries = entries }
        return chunk.data
    end

    --- Adds an event or checkpoints a changed context on the same event object.
    ---@param event table Event owned by the SDK until HTTP acknowledgement.
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
            if candidate.count < CHUNK_SIZE then chunk = candidate; break end
        end
        chunk = chunk or newChunk(#chunks + 1)
        nextSequence = nextSequence + 1
        record = { event = event, encoded = encoded, contextId = event.contextId,
            sequence = nextSequence, chunk = chunk }
        records[event], chunk.entries[event] = record, record
        chunk.count = chunk.count + 1
        changed(chunk)
    end

    --- Removes acknowledged event objects; Persist commits the removal locally.
    ---@param events table[] Events acknowledged by the HTTP reporting layer.
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

    --- Returns unacknowledged events in their original queue order.
    ---@return table[] events
    function queue:Events()
        local ordered, events = {}, {}
        for _, record in pairs(records) do table.insert(ordered, record) end
        table.sort(ordered, function(a, b) return a.sequence < b.sequence end)
        for _, record in ipairs(ordered) do table.insert(events, record.event) end
        return events
    end

    --- Writes changed local chunks and their directory, retaining dirty state
    --- on failure. Without File, the queue remains available only in memory.
    ---@return boolean persisted Whether the local checkpoint succeeded.
    function queue:Persist()
        if not isActive() then return false end
        -- Keep legacy JSONL as the recovery source while replacing old chunk
        -- slots. Publish a new directory only after all its chunks are safe.
        if migrating then
            -- Retain a complete recovery source until every new chunk is safe,
            -- including ACKs or appends made while a migration is retried.
            local lines = {}
            for _, event in ipairs(self:Events()) do table.insert(lines, cjson.encode(event)) end
            if not publishManifest(nil, table.concat(lines, "\n")) then return false end
        end
        for index, chunk in pairs(dirtyLocal) do
            local bank = chunk.bank == 1 and 2 or 1
            if not writeLocalFile(fileApi,
                prefix .. "_" .. index .. "_" .. bank .. ".json",
                encodeSnapshot(dataFor(chunk))) then return false end
            chunk.bank = bank
            dirtyLocal[index] = nil
        end
        if not publishManifest(#chunks) then return false end
        migrating = false
        return true
    end

    local manifest = type(value) == "table" and value.format == QUEUE_FORMAT and value or nil
    if manifest then
        local blocks = math.max(0, math.floor(tonumber(manifest.blocks) or 0))
        for index = 1, blocks do newChunk(index, true) end
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

--- Creates synchronous File storage in the Maker sandbox, using memory only
--- when File is unavailable. Old snapshots and local JSONL remain readable;
--- obsolete cloud metadata is ignored. No remote reads delay initialization.
---@param options table|nil Optional logger callback.
---@return table|nil storage
---@return string|nil error
function MakerAutoStorage.New(options)
    options = options or {}
    if not isMakerRuntime() then
        return nil, "GameAlgo Lua SDK automatic storage requires a TapTap Maker runtime"
    end
    local logger = type(options.logger) == "function" and options.logger or function() end
    local fileApi = makerFileApi()
    local localSnapshot, localBank = readLocalSnapshot(fileApi)
    local snapshot = localSnapshot or emptySnapshot()
    local localDirty, stopped = localSnapshot == nil, false
    local localAvailable = localSnapshot ~= nil
    local eventQueues, storage = {}, {}

    local function persistLocal()
        if not localDirty then return true end
        local saved, bank = writeLocalSnapshot(fileApi, snapshot, localBank)
        if not saved then return false end
        localBank, localDirty = bank, false
        localAvailable = true
        return true
    end
    local function markChanged()
        snapshot.revision = snapshot.revision + 1
        localDirty = true
    end
    --- Reports whether this instance accepts operations; local write failures
    --- do not block in-memory operation or HTTP delivery.
    ---@return boolean ready
    function storage:IsReady() return not stopped end
    --- Invokes the callback immediately after synchronous local initialization.
    ---@param callback function Called only while this instance is active.
    function storage:OnReady(callback)
        if not stopped and type(callback) == "function" then callback() end
    end
    --- Stops future local writes and ignores callbacks retained by old Init.
    function storage:Shutdown() stopped = true end
    --- Reads a value from the current local snapshot, including unsaved changes.
    ---@param key string SDK-namespaced storage key.
    ---@return any value
    function storage:GetItem(key) return snapshot.data[tostring(key)] end
    --- Updates a local value and attempts a checkpoint to the alternate bank.
    ---@param key string SDK-namespaced storage key.
    ---@param value any Nil removes the key.
    ---@return boolean persisted False leaves the in-memory change retryable.
    function storage:SetItem(key, value)
        if stopped then return false end
        key = tostring(key)
        if snapshot.data[key] ~= value or type(value) == "table" then
            snapshot.data[key] = value
            markChanged()
        end
        return persistLocal()
    end
    --- Opens a local chunk queue, migrating legacy JSONL when persisted.
    ---@param key string SDK queue key.
    ---@return table queue Upsert, Remove, Events, and Persist operations.
    function storage:EventQueue(key)
        key = tostring(key)
        if not eventQueues[key] then
            eventQueues[key] = newEventQueue(key, snapshot.data[key], fileApi, function(blocks, pendingEvents)
                if stopped then return false end
                local manifest = snapshot.data[key]
                if pendingEvents ~= nil and manifest ~= pendingEvents then
                    snapshot.data[key] = pendingEvents
                    markChanged()
                elseif pendingEvents == nil and (type(manifest) ~= "table"
                    or manifest.format ~= QUEUE_FORMAT or manifest.blocks ~= blocks) then
                    snapshot.data[key] = { format = QUEUE_FORMAT, blocks = blocks }
                    markChanged()
                end
                return persistLocal()
            end, function() return not stopped end)
        end
        return eventQueues[key]
    end
    --- Checkpoints local queues and SDK state; performs no network requests.
    ---@param callback function|nil Receives nil on success or a write error.
    function storage:Flush(callback)
        callback = type(callback) == "function" and callback or function() end
        if stopped then callback("storage stopped"); return end
        local errorMessage
        for _, queue in pairs(eventQueues) do
            if not queue:Persist() then errorMessage = "local event queue write failed"; break end
        end
        if not errorMessage and not persistLocal() then errorMessage = "local snapshot write failed" end
        callback(errorMessage)
    end
    --- Reports local checkpoint and File capability state for SDK diagnostics.
    ---@return table diagnostics
    function storage:Diagnostics()
        return { ready = self:IsReady(), localAvailable = localAvailable,
            persistentStorageAvailable = fileApi ~= nil, revision = snapshot.revision }
    end
    persistLocal()
    for key, value in pairs(snapshot.data) do
        if (type(value) == "table" and value.format == QUEUE_FORMAT)
            or (type(key) == "string" and key:match(":events:jsonl$") and type(value) == "string") then
            storage:EventQueue(key)
        end
    end
    logger("automatic storage ready: " .. (localAvailable and "local" or "memory"))
    return storage
end

return MakerAutoStorage
