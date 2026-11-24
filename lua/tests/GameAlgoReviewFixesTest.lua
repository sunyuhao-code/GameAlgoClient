local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

-- Loading an SDK entry through a non-Maker namespace must keep all sibling
-- modules in that namespace instead of silently falling back to sdk/.
do
    local sentinels = {}
    for _, name in ipairs({ "HttpTransport", "LuaScriptRuntime", "Sha256", "DDA", "MakerAutoStorage" }) do
        sentinels[name] = {}
        package.preload["review." .. name] = function() return sentinels[name] end
        package.preload["sdk." .. name] = function() error("wrong SDK namespace: " .. name) end
    end
    package.preload["review.GameAlgo"] = function(name)
        return assert(loadfile("lua/GameAlgo.lua"))(name)
    end
    local loaded = assert(require("review.GameAlgo"))
    assert(type(loaded.Init) == "function")
    for _, name in ipairs({ "HttpTransport", "LuaScriptRuntime", "Sha256", "DDA", "MakerAutoStorage" }) do
        assert(package.loaded["review." .. name] == sentinels[name], name .. " escaped its namespace")
    end

    package.loaded["review.MakerAutoStorage"] = nil
    package.preload["review.Sha256"] = function() return sentinels.Sha256 end
    package.preload["review.MakerAutoStorage"] = function(name)
        return assert(loadfile("lua/MakerAutoStorage.lua"))(name)
    end
    assert(type(require("review.MakerAutoStorage").New) == "function")
    assert(package.loaded["review.Sha256"] == sentinels.Sha256)

    for _, name in ipairs({ "GameAlgo", "HttpTransport", "LuaScriptRuntime", "Sha256", "DDA", "MakerAutoStorage" }) do
        package.loaded["review." .. name] = nil
        package.preload["review." .. name] = nil
        package.preload["sdk." .. name] = nil
    end
end

-- The script runtime must fail closed without a budget hook, reject a non-Lua
-- hook, and remove its own hook after a bounded execution fails.
do
    local LuaScriptRuntime = require("LuaScriptRuntime")
    local originalDebug = debug
    local source = "return function(input) return { payload = { ok = true } } end"

    debug = { gethook = function() return nil end }
    local result, errorMessage = LuaScriptRuntime.Execute(source, {})
    assert(result == nil and tostring(errorMessage):find("debug.sethook", 1, true))

    local setHookCalls = 0
    debug = {
        gethook = function() return "external hook", "c", 1000 end,
        sethook = function() setHookCalls = setHookCalls + 1 end,
    }
    result, errorMessage = LuaScriptRuntime.Execute(source, {})
    assert(result == nil and tostring(errorMessage):find("not a Lua function", 1, true))
    assert(setHookCalls == 0, "a non-Lua hook must be rejected before replacement")

    debug = originalDebug
    result, errorMessage = LuaScriptRuntime.Execute(source, {})
    assert(result and result.payload.ok == true, tostring(errorMessage))
    result, errorMessage = LuaScriptRuntime.Execute(
        "return function() while true do end end", {}, { instructionLimit = 1000 })
    assert(result == nil and tostring(errorMessage):find("instruction limit exceeded", 1, true))
    assert(debug.gethook() == nil, "the SDK hook must be removed after execution failure")
end

local files = {}
FILE_READ = 1
FILE_WRITE = 2
fileSystem = {
    FileExists = function(_, name) return files[name] ~= nil end,
}
function File(name, mode)
    local readable = mode == FILE_READ and files[name] ~= nil
    local writable = mode == FILE_WRITE
    local buffer = files[name] or ""
    return {
        IsOpen = function() return readable or writable end,
        ReadString = function() return buffer end,
        WriteString = function(_, value) buffer = value; files[name] = value; return #value end,
        Flush = function() files[name] = buffer; return true end,
        Close = function() end,
    }
end

local function scheduler()
    local tasks = {}
    local value = {}
    function value:Schedule(delayMs, callback)
        local handle = { delayMs = delayMs, callback = callback, cancelled = false }
        table.insert(tasks, handle)
        return handle
    end
    function value:Cancel(handle) if handle then handle.cancelled = true end end
    function value:IsAutomatic() return true end
    function value:Update() end
    return value, tasks
end

local GameAlgo = require("GameAlgo")
local Sha256 = require("Sha256")
Node = nil
lobby = nil

-- Calling DDA before cloud identity hydration must not read the anonymous
-- namespace. The pending operation is replayed in the real user's namespace.
do
    File, FILE_READ, FILE_WRITE = nil, nil, nil
    local cloudRead
    clientCloud = {
        Get = function(_, _, callbacks) cloudRead = callbacks end,
        Set = function(_, _, _, callbacks) if callbacks and callbacks.ok then callbacks.ok() end end,
    }
    local clock = 1000
    local storageScheduler = scheduler()
    local gameKey = "ga_live_review_dda"
    local anonymousKey = "gamealgo:v2:game:" .. Sha256.hex(gameKey)
        .. ":user:" .. Sha256.hex("anonymous") .. ":dda:early"
    local anonymousState = cjson.encode({
        schemaVersion = 1, current = {}, lifetime = { old = 99 }, recentSteps = {}, completedSteps = 0,
    })
    GameAlgo.Init({ gameKey = gameKey, userId = "real-user", sessionId = "dda-session",
        autoFetch = false, nowMs = function() return clock end, _scheduler = storageScheduler })
    local dda = GameAlgo.DDA("early")
    dda.RecordBehavior("new")
    assert(dda.Snapshot().diagnostics.storageReady == false)
    cloudRead.ok({ gamealgo_sdk_storage_v1 = {
        schemaVersion = 1, revision = 1, data = { [anonymousKey] = anonymousState },
    } })
    local state = dda.Snapshot().behavior
    assert(state.lifetime.old == nil, "DDA loaded the pre-identity anonymous state")
    assert(state.lifetime.new == 1, "DDA did not replay the pre-ready operation")
end

-- A late config response from an older session may bind only that session's
-- events. The current response may adopt restored orphan events for itself.
do
    local previousCloud = clientCloud
    clientCloud = {
        Get = function(_, _, callbacks) callbacks.ok({}) end,
        Set = function(_, _, _, callbacks) if callbacks and callbacks.ok then callbacks.ok() end end,
    }
    local configRequests, eventBatches = {}, {}
    local transport = {}
    function transport.Request(options, callback)
        if options.url:match("/v1/config$") then
            table.insert(configRequests, { callback = callback, body = cjson.decode(options.body) })
        elseif options.url:match("/v1/events/batch$") then
            table.insert(eventBatches, cjson.decode(options.body).events)
            callback(nil, { status = 200, body = '{"ok":true,"accepted":1}', headers = {} })
        else
            error("unexpected request: " .. tostring(options.url))
        end
    end
    local config = function(contextId)
        return { contextId = contextId, experiments = {}, configFiles = {} }
    end
    local sessionScheduler = scheduler()
    GameAlgo.Init({ gameKey = "ga_live_review_sessions", userId = "session-user",
        sessionId = "old-session", autoFetch = false, preloadConfigFiles = false,
        transport = transport, _scheduler = sessionScheduler, nowMs = function() return 2000 end })
    assert(GameAlgo.TrackEvent("old-event", {}))
    GameAlgo.FetchConfig()
    assert(#configRequests == 1)
    assert(GameAlgo.NewSession("new-session"))
    assert(GameAlgo.TrackEvent("new-event", {}))
    configRequests[1].callback(nil, { status = 200, body = cjson.encode(config("old-context")), headers = {} })
    assert(#configRequests == 2)
    configRequests[2].callback(nil, { status = 200, body = cjson.encode(config("new-context")), headers = {} })
    assert(#eventBatches >= 2)
    local oldBatch, newBatch = eventBatches[#eventBatches - 1], eventBatches[#eventBatches]
    for _, event in ipairs(oldBatch) do
        assert(event.sessionId == "old-session")
        assert(event.contextId == "old-context")
    end
    for _, event in ipairs(newBatch) do
        assert(event.sessionId == "new-session")
        assert(event.contextId == "new-context")
    end
    clientCloud = previousCloud
end

-- A same-name config file response from before NewSession must not populate
-- the new lifecycle's cache; the new request remains usable.
do
    local previousCloud = clientCloud
    clientCloud = {
        Get = function(_, _, callbacks) callbacks.ok({}) end,
        Set = function(_, _, _, callbacks) if callbacks and callbacks.ok then callbacks.ok() end end,
    }
    local fileRequests, configCount = {}, 0
    local transport = {}
    function transport.Request(options, callback)
        if options.url:match("/v1/config$") then
            configCount = configCount + 1
            callback(nil, { status = 200, body = cjson.encode({
                contextId = "file-context-" .. configCount, experiments = {}, configFiles = {},
            }), headers = {} })
        elseif options.url:find("/v1/config-files/", 1, true) then
            table.insert(fileRequests, callback)
        elseif options.url:match("/v1/events/batch$") then
            callback(nil, { status = 200, body = '{"ok":true,"accepted":1}', headers = {} })
        else
            error("unexpected request: " .. tostring(options.url))
        end
    end
    GameAlgo.Init({ gameKey = "ga_live_review_files", userId = "file-user",
        sessionId = "file-session-old", autoFetch = false, preloadConfigFiles = false,
        transport = transport, _scheduler = scheduler(), nowMs = function() return 3000 end })
    GameAlgo.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
    local oldError
    GameAlgo.FetchConfigFile("balance", function(error) oldError = error end)
    assert(#fileRequests == 1)
    assert(GameAlgo.NewSession("file-session-new"))
    fileRequests[1](nil, { status = 200, body = '{"value":"old"}' })
    assert(oldError == "stale config file response")
    assert(GameAlgo.ConfigValue("value", "default", "balance") == "default")
    local newError
    GameAlgo.FetchConfigFile("balance", function(error) newError = error end)
    assert(#fileRequests == 2)
    fileRequests[2](nil, { status = 200, body = '{"value":"new"}' })
    assert(newError == nil)
    assert(GameAlgo.ConfigValue("value", "default", "balance") == "new")
    clientCloud = previousCloud
end

print("GameAlgo review-fix tests passed")
