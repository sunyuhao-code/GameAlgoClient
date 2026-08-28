---@meta
--- Internal persistent storage for TapTap Maker.
---
--- The SDK exposes synchronous reads to its identity, script cache, and DDA
--- layers while hiding Maker's asynchronous clientCloud API. A local File
--- snapshot is used as the fast path. When no local snapshot exists, the
--- first cloud read completes before the SDK starts, with a bounded timeout so
--- a missing clientCloud callback cannot block the whole session.

local cjson = require("cjson")

local MakerAutoStorage = {}

local FILE_NAME = "gamealgo_sdk_storage_v1.json"
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
    if factory == nil or readMode == nil or writeMode == nil then return nil end
    return {
        factory = factory,
        readMode = readMode,
        writeMode = writeMode,
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

local function readLocalSnapshot(fileApi)
    if not fileApi then return nil end
    local ok, file = pcall(function()
        return fileApi.factory(FILE_NAME, fileApi.readMode)
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
    return normalizeSnapshot(encoded)
end

local function writeLocalSnapshot(fileApi, snapshot)
    if not fileApi then return false end
    local encoded = encodeSnapshot(snapshot)
    if not encoded then return false end
    local ok, file = pcall(function()
        return fileApi.factory(FILE_NAME, fileApi.writeMode)
    end)
    if not ok or file == nil then return false end
    local opened = false
    pcall(function() opened = file:IsOpen() == true end)
    if not opened then
        closeFile(file)
        return false
    end
    local writeOk = pcall(function()
        file:WriteString(encoded)
        file:Flush()
    end)
    closeFile(file)
    return writeOk
end

local function cloudValue(values)
    if type(values) ~= "table" then return nil end
    return normalizeSnapshot(values[CLOUD_KEY])
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
    local localSnapshot = readLocalSnapshot(fileApi)
    local snapshot = localSnapshot or emptySnapshot()
    local localAvailable = localSnapshot ~= nil
    local ready = false
    local readyCallbacks = {}
    local cloudWriteInFlight = false
    local cloudWritePending = false
    local cloudWriteCallbacks = {}
    local cloudDirty = false

    local storage = {}

    local function persistLocal()
        if writeLocalSnapshot(fileApi, snapshot) then
            localAvailable = true
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

    local function loadCloudThenReady()
        local cloud = makerCloud()
        if not cloud then
            persistLocal()
            markReady(localAvailable and "local" or "memory")
            return
        end

        local canSchedule = scheduler ~= nil
            and type(scheduler.Schedule) == "function"
            and (type(scheduler.IsAutomatic) ~= "function" or scheduler:IsAutomatic())
        if not canSchedule then
            logger("automatic storage cloud read skipped: timeout scheduler unavailable")
            persistLocal()
            markReady(localAvailable and "local" or "memory")
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
            if remote then snapshot = remote end
            persistLocal()
            markReady(source)
        end

        timeoutHandle = scheduler:Schedule(cloudReadTimeoutMs, function()
            logger("automatic storage cloud read timed out after "
                .. tostring(cloudReadTimeoutMs) .. "ms")
            finish(localAvailable and "local-timeout" or "memory-timeout", nil)
        end)
        if timeoutHandle == nil then
            logger("automatic storage cloud read skipped: timeout scheduling failed")
            persistLocal()
            markReady(localAvailable and "local" or "memory")
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
        snapshot.data[tostring(key)] = value
        snapshot.revision = snapshot.revision + 1
        cloudDirty = true
        persistLocal()
    end

    function storage:Flush(callback)
        callback = type(callback) == "function" and callback or function() end
        if not ready then
            storage:OnReady(function() storage:Flush(callback) end)
            return
        end
        if not cloudDirty then
            callback(nil)
            return
        end
        if cloudWriteInFlight then
            cloudWritePending = true
            table.insert(cloudWriteCallbacks, callback)
            return
        end

        local cloud = makerCloud()
        if not cloud then
            callback(nil)
            return
        end

        local writingRevision = snapshot.revision
        local writingSnapshot = normalizeSnapshot(encodeSnapshot(snapshot)) or snapshot
        local callbacks = cloudWriteCallbacks
        cloudWriteCallbacks = {}
        table.insert(callbacks, callback)
        cloudWriteInFlight = true
        cloudWritePending = false
        local function complete(error)
            cloudWriteInFlight = false
            if not error and snapshot.revision == writingRevision then cloudDirty = false end
            for _, pendingCallback in ipairs(callbacks) do pcall(pendingCallback, error) end
            if cloudWritePending or (not error and cloudDirty) then storage:Flush(nil) end
        end
        local started = pcall(function()
            cloud:Set(CLOUD_KEY, writingSnapshot, {
                ok = function() complete(nil) end,
                error = function(code, reason)
                    logger("automatic storage cloud write failed: " .. tostring(code) .. " " .. tostring(reason))
                    complete(tostring(reason or code or "cloud write failed"))
                end,
            })
        end)
        if not started then complete("cloud write unavailable") end
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
        markReady("local")
    else
        loadCloudThenReady()
    end

    return storage, nil
end

return MakerAutoStorage
