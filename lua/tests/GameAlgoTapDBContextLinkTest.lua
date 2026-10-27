local cjson = require("cjson")
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

-- Keep test persistence in memory, including SDK reinitialization.
local files = {}
FILE_READ, FILE_WRITE = 1, 2
fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
function File(name, mode)
    return {
        IsOpen = function() return mode == FILE_WRITE or files[name] ~= nil end,
        ReadString = function() return files[name] end,
        WriteString = function(_, value) files[name] = value end,
        Flush = function() end,
        Close = function() end,
    }
end
lobby = { GetMyUserId = function() return "maker-account-not-device-id" end }

local function harness()
    local h = { pending = {}, calls = {}, batches = {}, logs = {}, scheduled = {} }
    h.client = dofile("lua/GameAlgo.lua")
    h.host = {
        LogEvent = function(self, name, properties, ...)
            assert(self == h.host, "native bridge must receive its receiver")
            assert(select("#", ...) == 0, "older hosts reject a callback argument")
            local count = 0
            for _, value in pairs(properties) do
                assert(type(value) == "string" or type(value) == "boolean", "properties must be flat")
                count = count + 1
            end
            assert(count == 3, "only the documented identity properties should be sent")
            table.insert(h.calls, { name = name, properties = properties })
            return true
        end,
    }
    h.scheduler = {
        Schedule = function(_, delay, callback)
            local task = { delay = delay, callback = callback }
            table.insert(h.scheduled, task)
            return task
        end,
        Cancel = function(_, task) task.cancelled = true end,
        IsAutomatic = function() return true end,
        Update = function() end,
        Shutdown = function() end,
    }
    h.transport = {
        Request = function(request, callback)
            local body = cjson.decode(request.body)
            if request.url:match("/v1/config$") then
                table.insert(h.pending, { body = body, callback = callback })
            elseif request.url:match("/v1/events/batch$") then
                table.insert(h.batches, body.events)
                callback(nil, { status = 200, body = cjson.encode({ ok = true, accepted = #body.events }) })
            else
                error("unexpected HTTP request: " .. request.url)
            end
        end,
        Cancel = function() end,
    }
    function h.init(options)
        options = options or {}
        options.gameKey = "ga_live_tapdb_context_link_fixture"
        options.transport = h.transport
        options._scheduler = h.scheduler
        options.preloadConfigFiles = false
        options.logger = function(line) table.insert(h.logs, line) end
        h.client.Init(options)
    end
    function h.reply(index, contextId)
        h.pending[index].callback(nil, { status = 200, body = cjson.encode({
            contextId = contextId,
            gameId = "game-context-link-test",
            configVersion = "1",
            configFiles = {},
            experiments = {},
        }) })
    end
    sdk = h.host
    return h
end

-- Initialization waits for a real context and uses the same anonymous identity
-- as config/events, rather than the Maker account identity.
local h = harness()
h.init({ sessionId = "session-one" })
assert(#h.pending == 1 and #h.calls == 0)
assert(h.client.TrackEvent("before_config", {}))
h.reply(1, "ctx-one")
assert(#h.calls == 1)
assert(h.calls[1].name == "gamealgo_context_link")
assert(h.calls[1].properties.gamealgo_context_id == "ctx-one")
assert(h.calls[1].properties.gamealgo_device_id == h.pending[1].body.userId)
assert(h.calls[1].properties.gamealgo_device_id == h.client.Snapshot().userId)
assert(h.calls[1].properties.gamealgo_device_id ~= h.pending[1].body.accountUserId)
assert(h.calls[1].properties.gamealgo_is_debug == false)
assert(#h.batches == 1 and #h.batches[1] == 1)
assert(h.batches[1][1].eventType == "_before_config", "TapDB link must not enter the GameAlgo event queue")
h.reply(1, "ctx-duplicate")
h.client.FetchConfig(function(err) assert(err == nil) end)
h.reply(2, "ctx-refreshed")
assert(h.client.NewSession("session-two"))
h.reply(3, "ctx-session-two")
assert(#h.calls == 1, "refresh and session rotation must not repeat the Init link")

local firstDeviceId = h.calls[1].properties.gamealgo_device_id
h.init({ sessionId = "session-reinit", isDebug = true })
h.reply(4, "ctx-reinit")
assert(#h.calls == 2)
assert(h.calls[2].properties.gamealgo_context_id == "ctx-reinit")
assert(h.calls[2].properties.gamealgo_device_id == firstDeviceId)
assert(h.calls[2].properties.gamealgo_is_debug == true)

-- Failed and invalid config responses must not consume the single report.
local recovering = harness()
recovering.init({ autoFetch = false, userId = "explicit-device-id" })
assert(#recovering.pending == 0 and #recovering.calls == 0)
local completed = false
recovering.client.FetchConfig(function(err)
    assert(err == nil)
    assert(#recovering.calls == 1, "link must be emitted before invoking the config callback")
    completed = true
end)
recovering.pending[1].callback("HTTP 503", { status = 503, body = "" })
assert(#recovering.calls == 0 and not completed)
recovering.scheduled[#recovering.scheduled].callback()
recovering.reply(2, "")
assert(#recovering.calls == 0 and not completed)
recovering.scheduled[#recovering.scheduled].callback()
recovering.reply(3, "ctx-recovered")
assert(completed and #recovering.calls == 1)
assert(recovering.calls[1].properties.gamealgo_device_id == "explicit-device-id")

-- A response belonging to an old Init must not be linked to the new identity.
local overlapping = harness()
overlapping.init({ userId = "old-device", sessionId = "old-session" })
overlapping.init({ userId = "new-device", sessionId = "new-session" })
overlapping.reply(1, "ctx-old-init")
assert(#overlapping.calls == 0)
overlapping.reply(2, "ctx-new-init")
assert(#overlapping.calls == 1)
assert(overlapping.calls[1].properties.gamealgo_device_id == "new-device")
assert(overlapping.calls[1].properties.gamealgo_context_id == "ctx-new-init")

-- A late bridge must retain the first config's identity across session changes,
-- and report automatically on Update rather than requiring another HTTP call.
for _, mode in ipairs({ "absent", "missing_method", "lookup_error" }) do
    local delayed = harness()
    local now = 1000
    if mode == "absent" then sdk = nil
    elseif mode == "missing_method" then sdk = {}
    else sdk = setmetatable({}, { __index = function() error("bridge loading") end }) end
    delayed.init({ userId = "first-user", sessionId = "first-session", isDebug = true,
        nowMs = function() return now end })
    delayed.reply(1, "ctx-first-pending")
    assert(delayed.client.NewSession("later-session"))
    delayed.reply(2, "ctx-later-pending")
    assert(#delayed.calls == 0)
    sdk = delayed.host
    now = now + 500
    delayed.client.Update()
    assert(#delayed.calls == 1, mode)
    assert(delayed.calls[1].properties.gamealgo_context_id == "ctx-first-pending", mode)
    assert(delayed.calls[1].properties.gamealgo_device_id == "first-user", mode)
    assert(delayed.calls[1].properties.gamealgo_is_debug == true, mode)
    now = now + 30000
    delayed.client.Update()
    assert(#delayed.calls == 1 and #delayed.pending == 2, mode)
end

-- Reinitialization discards a pending link from the previous Init.
local pendingReinit = harness()
sdk = nil
pendingReinit.init({ userId = "old-pending-user" })
pendingReinit.reply(1, "ctx-old-pending")
sdk = pendingReinit.host
pendingReinit.init({ userId = "new-pending-user" })
pendingReinit.reply(2, "ctx-new-pending")
pendingReinit.client.Update()
assert(#pendingReinit.calls == 1)
assert(pendingReinit.calls[1].properties.gamealgo_device_id == "new-pending-user")
assert(pendingReinit.calls[1].properties.gamealgo_context_id == "ctx-new-pending")

-- Stop automatic discovery after ten seconds. A later config still checks the
-- host and sends the retained first link, without replacing its identity.
local bounded = harness()
local now, lookups = 1000, 0
sdk = setmetatable({}, { __index = function() lookups = lookups + 1; return nil end })
bounded.init({ nowMs = function() return now end })
bounded.reply(1, "ctx-bounded-first")
for _ = 1, 20 do now = now + 500; bounded.client.Update() end
local stoppedAt = lookups
assert(stoppedAt > 1)
now = now + 60000
bounded.client.Update()
assert(lookups == stoppedAt, "optional bridge discovery must stop")
sdk = bounded.host
bounded.client.FetchConfig()
bounded.reply(2, "ctx-bounded-later")
assert(#bounded.calls == 1)
assert(bounded.calls[1].properties.gamealgo_context_id == "ctx-bounded-first")

-- Optional hosts cannot prevent normal config callbacks or event delivery.
for _, mode in ipairs({ "absent", "missing_method", "lookup_error", "throws", "rejected", "nil_return" }) do
    local optional = harness()
    local calls = 0
    if mode == "absent" then
        sdk = nil
    elseif mode == "missing_method" then
        sdk = {}
    elseif mode == "lookup_error" then
        sdk = setmetatable({}, { __index = function() error("bridge lookup unavailable") end })
    else
        sdk = { LogEvent = function()
            calls = calls + 1
            if mode == "throws" then error("native bridge unavailable") end
            if mode == "rejected" then return false end
            return nil
        end }
    end
    optional.init({ autoFetch = false, userId = "optional-host-device" })
    local completedCount = 0
    local function onConfig(err)
        assert(err == nil, mode)
        completedCount = completedCount + 1
    end
    optional.client.FetchConfig(onConfig)
    optional.reply(1, "ctx-optional")
    optional.client.FetchConfig(onConfig)
    optional.reply(2, "ctx-optional-refresh")
    assert(completedCount == 2 and calls <= 1, mode)
    assert(optional.client.Snapshot().contextId == "ctx-optional-refresh", mode)
    assert(optional.client.TrackEvent("normal_event", {}))
    optional.client.Flush(function(err) assert(err == nil, mode) end)
    assert(#optional.batches == 1 and #optional.batches[1] == 1, mode)
end

-- Maker may supply sdk through an environment metatable, not a raw global.
local inherited = harness()
local oldMetatable = getmetatable(_G)
sdk = nil
setmetatable(_G, { __index = function(_, key)
    if key == "sdk" then return inherited.host end
end })
inherited.init()
inherited.reply(1, "ctx-environment-host")
setmetatable(_G, oldMetatable)
assert(#inherited.calls == 1)
sdk = nil

print("PASS TapDB context link: identity, once per Init, recovery, stale callbacks, optional hosts, environment lookup")
