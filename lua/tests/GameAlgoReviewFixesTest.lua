local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

-- Every transport failure path must notify its caller once, including failures
-- before an HttpClient can be registered in the active-request table.
do
    HTTP_GET, HTTP_POST, HTTP_PUT, HTTP_DELETE, HTTP_PATCH = 1, 2, 3, 4, 5
    local HttpTransport = require("HttpTransport")
    local previousHttp = http
    local calls, receivedError = 0, nil
    http = nil
    HttpTransport.Request({ method = "GET", url = "https://example.invalid" }, function(error)
        calls, receivedError = calls + 1, error
    end)
    assert(calls == 1 and receivedError == "http client unavailable in this runtime")

    calls, receivedError = 0, nil
    http = {}
    HttpTransport.Request({ method = "TRACE", url = "https://example.invalid" }, function(error)
        calls, receivedError = calls + 1, error
    end)
    assert(calls == 1 and receivedError == "unsupported HTTP method: TRACE")

    local function expectFailure(request, manager, expected)
        http = manager
        local count, reason = 0, nil
        local returned = HttpTransport.Request(request, function(error)
            count, reason = count + 1, error
        end)
        assert(returned == nil and count == 1, "each early failure must invoke its callback once")
        assert(tostring(reason):find(expected, 1, true), tostring(reason))
        assert(HttpTransport.Diagnostics().activeRequests == 0)
    end
    expectFailure(false, {}, "invalid HTTP request")
    expectFailure({ method = setmetatable({}, { __tostring = function() error("bad method") end }) },
        {}, "invalid HTTP method")
    expectFailure({ method = "GET" }, { Create = function() return nil end }, "http client unavailable")
    expectFailure({ method = "GET" }, { Create = function() error("Create failed") end }, "http client unavailable")
    expectFailure({ method = "GET" }, { Create = function()
        return { SetUrl = function() error("setup failed") end }
    end }, "request setup failed")

    -- Model native callbacks rooted outside the Lua collector. Both the client
    -- and the business callback's captured objects must become collectible.
    local roots, clients, captures = {}, setmetatable({}, { __mode = "v" }), setmetatable({}, { __mode = "v" })
    http = { Create = function()
        local client = {}
        local callbacks = {}
        table.insert(roots, callbacks)
        for _, name in ipairs({ "SetUrl", "SetMethod", "SetTimeout", "Send" }) do
            client[name] = function(self) return self end
        end
        function client:OnSuccess(callback) callbacks.ok = callback; return self end
        function client:OnError(callback) callbacks.error = callback; return self end
        return client
    end }
    for index, outcome in ipairs({ "success", "http-error", "error", "cancel", "callback-error" }) do
        local capture = {}
        captures[index] = capture
        local count = 0
        local client = HttpTransport.Request({ method = "GET", url = "https://example.invalid" },
            function()
                capture.used = true
                count = count + 1
                if outcome == "callback-error" then error("business callback failed") end
            end)
        clients[index] = client
        if outcome == "cancel" then assert(HttpTransport.Cancel(client))
        elseif outcome == "error" then roots[index].error(nil, 503, "unavailable")
        else roots[index].ok(nil, { statusCode = outcome == "http-error" and 503 or 200, dataAsString = "{}" }) end
        roots[index].error(nil, 500, "duplicate terminal event")
        assert(count == 1 and capture.used)
    end
    collectgarbage("collect"); collectgarbage("collect")
    assert(next(clients) == nil, "completed clients must be collectible despite rooted native callbacks")
    assert(next(captures) == nil, "completed business callbacks must release their captured objects")
    assert(HttpTransport.Diagnostics().activeRequests == 0)
    http = previousHttp
end

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

-- Init must not reseed the game's RNG, and identifiers must not collide across
-- same-second initializations in independent VMs.
do
    local reseedCalls = 0
    local previousSeed = math.randomseed
    math.randomseed = function() reseedCalls = reseedCalls + 1 end
    clientCloud = {
        Get = function(_, _, callbacks) callbacks.ok({}) end,
        Set = function(_, _, _, callbacks) if callbacks and callbacks.ok then callbacks.ok() end end,
    }
    local seen = {}
    for index = 1, 3 do
        GameAlgo.Init({ gameKey = "ga_live_review_ids", autoFetch = false,
            _scheduler = scheduler(), nowMs = function() return 8000 end })
        local snapshot = GameAlgo.Snapshot()
        assert(snapshot.userId ~= nil and snapshot.sessionId ~= nil)
        local pair = tostring(snapshot.userId) .. "/" .. tostring(snapshot.sessionId)
        assert(seen[pair] == nil, "identical ids across same-second Init: " .. pair)
        seen[pair] = true
    end
    math.randomseed = previousSeed
    assert(reseedCalls == 0, "Init must not reseed the game RNG")
end

-- Re-initializing while the previous storage's cloud read is pending must not
-- let the stale callback install the old identity or publish the old snapshot.
do
    local reads, writes = {}, {}
    clientCloud = {
        Get = function(_, _, callbacks) table.insert(reads, callbacks) end,
        Set = function(_, key, data, callbacks)
            table.insert(writes, { key = key, data = data })
            if callbacks and callbacks.ok then callbacks.ok() end
        end,
    }
    GameAlgo.Init({ gameKey = "ga_live_review_reinit", userId = "user-a", sessionId = "session-a",
        autoFetch = false, _scheduler = scheduler(), nowMs = function() return 9000 end })
    GameAlgo.Init({ gameKey = "ga_live_review_reinit", userId = "user-b", sessionId = "session-b",
        autoFetch = false, _scheduler = scheduler(), nowMs = function() return 9000 end })
    assert(#reads == 2)
    reads[1].ok({})
    local snapshot = GameAlgo.Snapshot()
    assert(snapshot.userId ~= "user-a", "stale cloud callback installed the old identity")
    assert(snapshot.storage and snapshot.storage.ready == false)
    assert(#writes == 0, "stale storage must not publish before the current one is ready")
    reads[2].ok({})
    snapshot = GameAlgo.Snapshot()
    assert(snapshot.userId == "user-b")
    assert(snapshot.storage and snapshot.storage.ready == true)
    GameAlgo.TrackEvent("reinit_probe", {})
    GameAlgo.Flush()
    local published = false
    for _, write in ipairs(writes) do
        if write.key == "gamealgo_sdk_storage_v1" then
            published = true
            local foundUserB = false
            for _, value in pairs(write.data and write.data.data or {}) do
                assert(value ~= "user-a", "stale identity published to cloud")
                if value == "user-b" then foundUserB = true end
            end
            assert(foundUserB, "current identity must be published")
        end
    end
    assert(published, "a resolved read must unlock the directory write")
end

-- A retrying config fetch from a previous session must hand the in-flight slot
-- to the queued session instead of starving it.
do
    local configRequests = {}
    local scheduled = {}
    local transport = {}
    function transport.Request(options, callback)
        if options.url:match("/v1/config$") then
            table.insert(configRequests, { callback = callback, body = cjson.decode(options.body) })
        elseif options.url:match("/v1/events/batch$") then
            callback(nil, { status = 200, body = '{"ok":true,"accepted":1}', headers = {} })
        else
            error("unexpected request: " .. tostring(options.url))
        end
    end
    local function taskScheduler()
        local value = {}
        function value:Schedule(delayMs, callback)
            local handle = { delayMs = delayMs, callback = callback, cancelled = false }
            table.insert(scheduled, handle)
            return handle
        end
        function value:Cancel(handle) if handle then handle.cancelled = true end end
        function value:IsAutomatic() return true end
        function value:Update() end
        return value
    end
    local function okConfig(contextId)
        return cjson.encode({ contextId = contextId, experiments = {}, configFiles = {} })
    end
    clientCloud = {
        Get = function(_, _, callbacks) callbacks.ok({}) end,
        Set = function(_, _, _, callbacks) if callbacks and callbacks.ok then callbacks.ok() end end,
    }

    -- A stale failure arrives after the session switch: it must yield the slot
    -- immediately instead of retrying the old session.
    GameAlgo.Init({ gameKey = "ga_live_review_retry", userId = "retry-user",
        sessionId = "retry-a", autoFetch = false, preloadConfigFiles = false,
        transport = transport, _scheduler = taskScheduler(), nowMs = function() return 10000 end })
    GameAlgo.FetchConfig()
    assert(#configRequests == 1)
    assert(GameAlgo.NewSession("retry-b"))
    configRequests[1].callback("HTTP 503", nil, { status = 503 })
    assert(#configRequests == 2, "stale fetch must yield to the queued session")
    assert(configRequests[2].body.sessionId == "retry-b")
    configRequests[2].callback(nil, { status = 200, body = okConfig("retry-context-b") })
    assert(GameAlgo.Snapshot().contextId == "retry-context-b")

    -- A retry scheduled while the old session was still current must stop once
    -- the session changes, handing the slot to the queue.
    GameAlgo.Init({ gameKey = "ga_live_review_retry", userId = "retry-user",
        sessionId = "retry-c", autoFetch = false, preloadConfigFiles = false,
        transport = transport, _scheduler = taskScheduler(), nowMs = function() return 11000 end })
    GameAlgo.FetchConfig()
    assert(#configRequests == 3)
    configRequests[3].callback("HTTP 503", nil, { status = 503 })
    assert(#configRequests == 3, "the current session may still retry")
    local retryTask = scheduled[#scheduled]
    assert(retryTask ~= nil and not retryTask.cancelled)
    assert(GameAlgo.NewSession("retry-d"))
    local previousMeta = getmetatable(_G)
    setmetatable(_G, { __index = function(_, name)
        if name == "requestTimeoutHandle" then error("unexpected global timeout lookup") end
        local lookup = previousMeta and previousMeta.__index
        if type(lookup) == "function" then return lookup(_G, name) end
        if type(lookup) == "table" then return lookup[name] end
    end })
    local retryOk, retryError = pcall(retryTask.callback)
    setmetatable(_G, previousMeta)
    assert(retryOk, tostring(retryError))
    assert(#configRequests == 4, "a pending retry must yield after the session switch")
    assert(configRequests[4].body.sessionId == "retry-d")
    configRequests[4].callback(nil, { status = 200, body = okConfig("retry-context-d") })
    assert(GameAlgo.Snapshot().contextId == "retry-context-d")
end

-- Scripted experiments must not report IsReady on hosts that cannot enforce an
-- instruction budget; config-only experiments stay ready either way.
do
    local scriptBody = "return function(input) return { payload = { adjustment = 'keep' } } end"
    local configBody = cjson.encode({
        contextId = "ready-context", configVersion = "v1",
        experiments = {
            { key = "scripted", variant = "a",
              script = { name = "exp.lua", versionId = "sv1",
                  url = "https://example.invalid/exp.lua", hash = Sha256.hash(scriptBody) } },
            { key = "plain", variant = "b", config = { difficulty = 1 } },
        },
        configFiles = {},
    })
    local transport = {}
    function transport.Request(options, callback)
        if options.url:match("/v1/config$") then
            callback(nil, { status = 200, body = configBody, headers = {} })
        elseif options.url:match("/exp%.lua$") then
            callback(nil, { status = 200, body = scriptBody, headers = {} })
        elseif options.url:match("/v1/events/batch$") then
            callback(nil, { status = 200, body = '{"ok":true,"accepted":1}', headers = {} })
        else
            error("unexpected request: " .. tostring(options.url))
        end
    end
    clientCloud = {
        Get = function(_, _, callbacks) callbacks.ok({}) end,
        Set = function(_, _, _, callbacks) if callbacks and callbacks.ok then callbacks.ok() end end,
    }
    local originalDebug = debug
    GameAlgo.Init({ gameKey = "ga_live_review_ready", userId = "ready-user",
        sessionId = "ready-session", autoFetch = false, transport = transport,
        _scheduler = scheduler(), nowMs = function() return 12000 end })
    GameAlgo.FetchConfig(function(error) assert(error == nil, tostring(error)) end)

    local scripted = GameAlgo.Executor("scripted")
    local plain = GameAlgo.Executor("plain")
    assert(scripted:IsReady() == true, "scripted executor must be ready on a hook-capable host")
    local executed = scripted:Execute({ turn = 1 })
    assert(executed ~= nil and executed.payload.adjustment == "keep")
    assert(plain:IsReady() == true)

    debug = { traceback = originalDebug.traceback, getinfo = originalDebug.getinfo }
    assert(scripted:IsReady() == false, "IsReady must reflect the missing instruction budget")
    assert(scripted:Execute({ turn = 1 }) == nil)
    assert(plain:IsReady() == true, "config-only experiments stay ready without a budget")
    debug = originalDebug
    assert(scripted:IsReady() == true)
end

print("GameAlgo review-fix tests passed")
