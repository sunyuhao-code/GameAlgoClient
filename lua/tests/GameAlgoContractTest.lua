local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local files = {}

FILE_READ = 1
FILE_WRITE = 2

function File(name, mode)
    local readable = mode == FILE_READ and files[name] ~= nil
    local writable = mode == FILE_WRITE
    local buffer = files[name] or ""
    return {
        IsOpen = function() return readable or writable end,
        ReadString = function() return buffer end,
        WriteString = function(_, value)
            buffer = value
            files[name] = value
        end,
        Flush = function() files[name] = buffer end,
        Close = function() end,
    }
end

lobby = {
    GetMyUserId = function() return "maker-account-001" end,
}

local function readFile(path)
    local handle = assert(io.open(path, "rb"))
    local value = handle:read("*a")
    handle:close()
    return value
end

local configFixture = readFile("protocol/fixtures/config-response.json")
local configCount = 0
local eventFailuresRemaining = 0
local eventRequests = {}
local logs = {}

local transport = {}

function transport.Request(options, callback)
    if options.url:match("/v1/config$") then
        configCount = configCount + 1
        local config = cjson.decode(configFixture)
        config.contextId = configCount == 1 and "ctx-fixture-001" or "ctx-fixture-002"
        callback(nil, { status = 200, body = cjson.encode(config), headers = {} })
        return
    end
    if options.url:match("/v1/events/batch$") then
        table.insert(eventRequests, cjson.decode(options.body))
        if eventFailuresRemaining > 0 then
            eventFailuresRemaining = eventFailuresRemaining - 1
            callback("simulated network failure", nil)
        else
            callback(nil, { status = 200, body = '{"ok":true,"accepted":1}', headers = {} })
        end
        return
    end
    callback("unexpected request: " .. tostring(options.url), nil)
end

local GameAlgo = require("GameAlgo")

GameAlgo.Init({
    gameKey = "ga_live_fixture_key",
    sessionId = "session-fixture-001",
    transport = transport,
    autoFetch = false,
    preloadConfigFiles = false,
})

local configError = nil
local config = nil
GameAlgo.FetchConfig(function(error, value)
    configError = error
    config = value
end)

assert(configError == nil, tostring(configError))
assert(config.contextId == "ctx-fixture-001")
assert(config.experiments[1].script.versionId == "sv_fixture_001")
assert(config.experiments[1].script.url == "/v1/scripts/sv_fixture_001")

local payload = {
    level = 7,
    nested = { mode = "classic", success = true },
}
assert(GameAlgo.TrackEvent("fixture_action", payload))
payload.level = 99
payload.nested.mode = "mutated"

local cycle = {}
cycle.self = cycle
local cycleAccepted, cycleError = GameAlgo.TrackEvent("cyclic", cycle)
assert(cycleAccepted == false)
assert(tostring(cycleError):find("cycle", 1, true) ~= nil)

eventFailuresRemaining = 3
for _ = 1, 3 do
    local flushError = nil
    GameAlgo.Flush(function(error) flushError = error end)
    assert(flushError == "simulated network failure")
end

local snapshot = cjson.decode(assert(files["gamealgo_sdk_storage_v1.json"]))
local persistedJsonl = nil
for key, value in pairs(snapshot.data) do
    if key:match(":events:jsonl$") then persistedJsonl = value end
end
assert(type(persistedJsonl) == "string" and persistedJsonl ~= "")
local persistedEvent = cjson.decode(persistedJsonl)
assert(persistedEvent.contextId == "ctx-fixture-001")
assert(persistedEvent.accountUserId == "maker-account-001")
assert(persistedEvent.payload.level == 7)
assert(persistedEvent.payload.nested.mode == "classic")

local refreshError = nil
GameAlgo.FetchConfig(function(error) refreshError = error end)
assert(refreshError == nil)
assert(eventRequests[#eventRequests].events[1].contextId == "ctx-fixture-001")

local finalFlushError = "not-called"
GameAlgo.Flush(function(error) finalFlushError = error end)
assert(finalFlushError == nil)

snapshot = cjson.decode(assert(files["gamealgo_sdk_storage_v1.json"]))
for key, value in pairs(snapshot.data) do
    if key:match(":events:jsonl$") then assert(value == "") end
end

assert(GameAlgo.TrackEvent("bound_session_one", { sequence = 1 }))
local sessionTwo = GameAlgo.NewSession("session-fixture-002")
assert(sessionTwo == "session-fixture-002")
assert(GameAlgo.TrackEvent("new_session_unbound", { sequence = 2 }))
GameAlgo.Flush(function(error) finalFlushError = error end)
assert(finalFlushError == nil)
local previousSessionEvents = eventRequests[#eventRequests - 1].events
local currentSessionEvents = eventRequests[#eventRequests].events
assert(#previousSessionEvents == 1)
assert(#currentSessionEvents == 1)
assert(previousSessionEvents[1].eventType == "_bound_session_one")
assert(previousSessionEvents[1].contextId == "ctx-fixture-002")
assert(previousSessionEvents[1].sessionId == "session-fixture-001")
assert(currentSessionEvents[1].eventType == "_new_session_unbound")
assert(currentSessionEvents[1].contextId == "ctx-fixture-002")
assert(currentSessionEvents[1].sessionId == "session-fixture-002")

local preloadConfig = cjson.decode(configFixture)
preloadConfig.contextId = "ctx-preload"
preloadConfig.configFiles = {}
preloadConfig.experiments[1].script.name = "wrong.js"
preloadConfig.experiments[1].script.contentType = "text/plain; charset=utf-8"
local preloadTransport = {}
function preloadTransport.Request(options, callback)
    if options.url:match("/v1/config$") then
        callback(nil, { status = 200, body = cjson.encode(preloadConfig), headers = {} })
        return
    end
    if options.url:match("/v1/events/batch$") then
        callback(nil, { status = 200, body = '{"ok":true,"accepted":0}', headers = {} })
        return
    end
    callback("unexpected request: " .. tostring(options.url), nil)
end

GameAlgo.Init({
    gameKey = "ga_live_fixture_key",
    sessionId = "session-preload",
    transport = preloadTransport,
    autoFetch = false,
    logger = function(message) table.insert(logs, message) end,
})
GameAlgo.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
local preloadFailureLogged = false
for _, message in ipairs(logs) do
    if message:find("script preload failed:", 1, true)
        and message:find("sv_fixture_001", 1, true)
        and message:find("unsupported Lua SDK script type", 1, true) then
        preloadFailureLogged = true
    end
end
assert(preloadFailureLogged, "expected script preload failure log")

local retryTasks = {}
local retryScheduler = {}
function retryScheduler:Schedule(delayMs, callback)
    local handle = { delayMs = delayMs, callback = callback }
    table.insert(retryTasks, handle)
    return handle
end
function retryScheduler:Cancel(handle)
    handle.cancelled = true
end
function retryScheduler:IsAutomatic()
    return true
end
function retryScheduler:Update()
end
function retryScheduler:Shutdown()
end

local retryConfigRequests = 0
local retryTransport = {}
function retryTransport.Request(options, callback)
    if options.url:match("/v1/config$") then
        retryConfigRequests = retryConfigRequests + 1
        if retryConfigRequests <= 2 then
            callback("temporary unavailable", { status = 503, body = "" })
        else
            local retryConfig = cjson.decode(configFixture)
            retryConfig.contextId = "ctx-after-retry"
            callback(nil, { status = 200, body = cjson.encode(retryConfig), headers = {} })
        end
        return
    end
    if options.url:match("/v1/events/batch$") then
        callback(nil, { status = 200, body = '{"ok":true,"accepted":0}', headers = {} })
        return
    end
    callback("unexpected request: " .. tostring(options.url), nil)
end

GameAlgo.Init({
    gameKey = "ga_live_fixture_key",
    sessionId = "session-config-retry",
    transport = retryTransport,
    autoFetch = false,
    preloadConfigFiles = false,
    _scheduler = retryScheduler,
})
local retryCallbackCount = 0
local retryConfigError = "not-called"
local retryConfig = nil
GameAlgo.FetchConfig(function(error, value)
    retryCallbackCount = retryCallbackCount + 1
    retryConfigError = error
    retryConfig = value
end)
GameAlgo.FetchConfig(function(error, value)
    retryCallbackCount = retryCallbackCount + 1
    retryConfigError = error
    retryConfig = value
end)
assert(retryConfigRequests == 1)
assert(retryCallbackCount == 0)
assert(#retryTasks == 1)
assert(retryTasks[1].delayMs == 1000)
retryTasks[1].callback()
assert(retryConfigRequests == 2)
assert(retryCallbackCount == 0)
assert(#retryTasks == 2)
assert(retryTasks[2].delayMs == 2000)
retryTasks[2].callback()
assert(retryConfigRequests == 3)
assert(retryCallbackCount == 2)
assert(retryConfigError == nil)
assert(retryConfig.contextId == "ctx-after-retry")

File = nil
FILE_READ = nil
FILE_WRITE = nil

local initOrder = {}
local initCloudCallbacks = nil
lobby = {
    GetMyUserId = function()
        table.insert(initOrder, "maker_user_id")
        return "maker-account-before-cloud"
    end,
}
clientCloud = {
    Get = function(_, _, callbacks)
        table.insert(initOrder, "cloud_get")
        initCloudCallbacks = callbacks
    end,
    Set = function(_, _, _, callbacks)
        if callbacks and callbacks.ok then callbacks.ok() end
    end,
}

local initTasks = {}
local initScheduler = {}
function initScheduler:Schedule(delayMs, callback)
    local handle = { delayMs = delayMs, callback = callback }
    table.insert(initTasks, handle)
    return handle
end
function initScheduler:Cancel(handle)
    handle.cancelled = true
end
function initScheduler:IsAutomatic()
    return true
end
function initScheduler:Update()
end
function initScheduler:Shutdown()
end

local initDiagnostics = {}
local initConfigRequests = 0
local initConfigShouldFail = true
local initTransport = {}
function initTransport.Request(options, callback)
    if options.url:match("/v1/diagnostics/init$") then
        table.insert(initDiagnostics, cjson.decode(options.body))
        callback(nil, { status = 200, body = '{"ok":true,"accepted":1}', headers = {} })
        return
    end
    if options.url:match("/v1/config$") then
        initConfigRequests = initConfigRequests + 1
        if initConfigShouldFail then
            callback("HTTP 503", { status = 503, body = "" })
        else
            local recoveredConfig = cjson.decode(configFixture)
            recoveredConfig.contextId = "ctx-after-init-recovery"
            callback(nil, { status = 200, body = cjson.encode(recoveredConfig), headers = {} })
        end
        return
    end
    if options.url:match("/v1/events/batch$") then
        callback(nil, { status = 200, body = '{"ok":true,"accepted":0}', headers = {} })
        return
    end
    callback("unexpected request: " .. tostring(options.url), nil)
end

GameAlgo.Init({
    gameKey = "ga_live_fixture_key",
    sessionId = "session-init-diagnostics",
    transport = initTransport,
    preloadConfigFiles = false,
    _scheduler = initScheduler,
    _cloudReadTimeoutMs = 5000,
})
assert(initOrder[1] == "maker_user_id")
assert(initOrder[2] == "cloud_get")
assert(type(initCloudCallbacks) == "table")
assert(#initTasks == 2)
assert(initTasks[1].delayMs == 5000)
assert(initTasks[2].delayMs == 10000)

initTasks[1].callback()
assert(initConfigRequests == 1)
assert(#initDiagnostics == 0)
assert(#initTasks == 3 and initTasks[3].delayMs == 1000)
initTasks[3].callback()
assert(initConfigRequests == 2)
assert(#initTasks == 4 and initTasks[4].delayMs == 2000)
initTasks[4].callback()
assert(initConfigRequests == 3)
assert(#initDiagnostics == 0)

initTasks[2].callback()
assert(#initDiagnostics == 1)
assert(initDiagnostics[1].accountUserId == "maker-account-before-cloud")
assert(initDiagnostics[1].contextId == nil)
assert(initDiagnostics[1].stage == "config")
assert(initDiagnostics[1].status == "failed")
assert(initDiagnostics[1].reasonCode == "initialization_timeout")
initTasks[2].callback()
assert(#initDiagnostics == 1)

initConfigShouldFail = false
local recoveredError = "not-called"
GameAlgo.FetchConfig(function(error) recoveredError = error end)
assert(recoveredError == nil)
assert(#initDiagnostics == 1)

local cloudCallbacks = nil
clientCloud = {
    Get = function(_, _, callbacks)
        cloudCallbacks = callbacks
    end,
    Set = function(_, _, _, callbacks)
        if callbacks and callbacks.ok then callbacks.ok() end
    end,
}

local timeoutTasks = {}
local timeoutScheduler = {}
function timeoutScheduler:Schedule(delayMs, callback)
    local handle = { delayMs = delayMs, callback = callback }
    table.insert(timeoutTasks, handle)
    return handle
end
function timeoutScheduler:Cancel(handle)
    handle.cancelled = true
end
function timeoutScheduler:IsAutomatic()
    return true
end

local MakerAutoStorage = require("MakerAutoStorage")
local timeoutStorage = assert(MakerAutoStorage.New({ scheduler = timeoutScheduler }))
local timeoutReadyCount = 0
timeoutStorage:OnReady(function() timeoutReadyCount = timeoutReadyCount + 1 end)
assert(timeoutStorage:IsReady() == false)
assert(type(cloudCallbacks) == "table")
assert(#timeoutTasks == 1)
assert(timeoutTasks[1].delayMs == 5000)
timeoutTasks[1].callback()
assert(timeoutStorage:IsReady() == true)
assert(timeoutReadyCount == 1)

cloudCallbacks.ok({
    gamealgo_sdk_storage_v1 = {
        schemaVersion = 1,
        revision = 1,
        data = { late_cloud_value = "must-not-overwrite-live-state" },
    },
})
assert(timeoutStorage:GetItem("late_cloud_value") == nil)
assert(timeoutReadyCount == 1)

local schedulerNowMs = 1000
local schedulerUpdateHandler = nil
local schedulerUnsubscribed = false
Node = function()
    return {
        CreateScriptObject = function(_, className)
            assert(className == "LuaScriptObject")
            return {
                SubscribeToEvent = function(_, eventName, callback)
                    assert(eventName == "Update")
                    schedulerUpdateHandler = callback
                end,
                UnsubscribeFromAllEvents = function()
                    schedulerUnsubscribed = true
                end,
            }
        end,
    }
end

local makerScheduler = MakerAutoStorage.NewScheduler({
    nowMs = function() return schedulerNowMs end,
})
assert(makerScheduler:IsAutomatic() == true)
local scheduledCallbackCount = 0
makerScheduler:Schedule(1000, function()
    scheduledCallbackCount = scheduledCallbackCount + 1
end)
schedulerNowMs = 1999
schedulerUpdateHandler()
assert(scheduledCallbackCount == 0)
schedulerNowMs = 2000
schedulerUpdateHandler()
assert(scheduledCallbackCount == 1)
makerScheduler:Shutdown()
assert(schedulerUnsubscribed == true)

print("Lua SDK contract tests passed")
