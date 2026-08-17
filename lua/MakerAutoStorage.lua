---@meta
--- Internal persistent storage for TapTap Maker.
---
--- The SDK exposes synchronous reads to its identity, script cache, and DDA
--- layers while hiding Maker's asynchronous clientCloud API. A local File
--- snapshot is used as the fast path. When no local snapshot exists, the
--- first cloud read completes before the SDK starts.

local cjson = require("cjson")

local MakerAutoStorage = {}

local FILE_NAME = "gamealgo_sdk_storage_v1.json"
local CLOUD_KEY = "gamealgo_sdk_storage_v1"
local SCHEMA_VERSION = 1

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

function MakerAutoStorage.New(options)
    options = options or {}
    if not isMakerRuntime() then
        return nil, "GameAlgo Lua SDK automatic storage requires a TapTap Maker runtime"
    end

    local logger = type(options.logger) == "function" and options.logger or function() end
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

        local started = pcall(function()
            cloud:Get(CLOUD_KEY, {
                ok = function(values)
                    local remote = cloudValue(values)
                    if remote then snapshot = remote end
                    persistLocal()
                    markReady(remote and "cloud" or (localAvailable and "local" or "memory"))
                end,
                error = function(code, reason)
                    logger("automatic storage cloud read failed: " .. tostring(code) .. " " .. tostring(reason))
                    persistLocal()
                    markReady(localAvailable and "local" or "memory")
                end,
            })
        end)
        if not started then
            persistLocal()
            markReady(localAvailable and "local" or "memory")
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
