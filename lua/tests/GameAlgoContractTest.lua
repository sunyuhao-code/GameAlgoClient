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

print("Lua SDK contract tests passed")
