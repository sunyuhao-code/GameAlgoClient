local cjson = require("cjson")
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local files, sequence = {}, 0
FILE_READ, FILE_WRITE = 1, 2
fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
function File(name, mode)
    return { IsOpen = function() return mode == FILE_WRITE or files[name] ~= nil end,
        ReadString = function() return files[name] end,
        WriteString = function(_, value) files[name] = value end,
        Flush = function() end, Close = function() end }
end
lobby = { GetMyUserId = function() return "routing-maker-account" end }

local function decode(call)
    local parts = {}
    for index = 0, tonumber(call.properties.gamealgo_part_count) - 1 do
        table.insert(parts, call.properties["gamealgo_part_" .. tostring(index)])
    end
    return cjson.decode(table.concat(parts))
end
local function fixture(flags, options)
    sequence = sequence + 1
    options = options or {}
    local h = { calls = {}, requests = {}, flags = flags or {}, now = 1000, pending = {} }
    h.client = dofile("lua/GameAlgo.lua")
    h.host = { LogEvent = function(self, name, properties, ...)
        assert(self == h.host and select("#", ...) == 0)
        for _, value in pairs(properties) do
            assert(type(value) == "boolean" or (type(value) == "string" and #value <= 240), "flat, bounded native properties required")
        end
        table.insert(h.calls, { name = name, properties = properties })
        if h.throwTapdb then error("native failure") end
        return not h.rejectTapdb
    end }
    sdk = h.host
    h.transport = { Request = function(request, callback)
        local path, body = request.url:match("(/v1/.*)$")
        body = cjson.decode(request.body)
        table.insert(h.requests, { path = path, body = body })
        if path == "/v1/config" then
            local config = { contextId = "ctx-routing-" .. tostring(sequence), gameId = "fixture", configVersion = "1", experiments = {}, configFiles = {} }
            for key, value in pairs(h.flags) do config[key] = value end
            callback(nil, { status = 200, body = cjson.encode(config) })
        elseif path == "/v1/events/batch" and h.holdBatch then
            table.insert(h.pending, callback)
        elseif path == "/v1/events/batch" and h.failBatch then
            callback("offline", { status = 0 })
        else
            callback(nil, { status = 200, body = cjson.encode({ ok = true, accepted = body.events and #body.events or 1 }) })
        end
    end, Cancel = function() end }
    h.client.Init({ gameKey = options.gameKey or ("ga_live_maker_routing_fixture_" .. tostring(sequence)),
        transport = h.transport, preloadConfigFiles = false, autoFetch = options.autoFetch,
        maxBatchSize = options.maxBatchSize or 100,
        nowMs = function() return h.now end, logger = function() end })
    function h.events()
        local events = {}
        for _, request in ipairs(h.requests) do for _, event in ipairs(request.body.events or {}) do table.insert(events, event) end end
        return events
    end
    function h.refresh(nextFlags)
        h.flags = nextFlags
        h.client.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
    end
    function h.flush()
        local receipt, failure
        h.client.Flush(function(error, result) failure, receipt = error, result end)
        return receipt, failure
    end
    return h
end

for _, gamealgo in ipairs({ false, true }) do
    for _, tapdb in ipairs({ false, true }) do
        local h = fixture({ gamealgoReportingEnabled = gamealgo, tapdbReportingEnabled = tapdb })
        local types = { "level_start", "level_end", "session_end", "ad_view", "purchase", "milestone", "_custom", "experiment_exposure" }
        local text = string.rep("中🙂a", 200)
        for _, eventType in ipairs(types) do assert(h.client.Track(eventType, { text = text, value = 0, flag = false })) end
        local result, error = h.flush()
        assert(error == nil, tostring(error))
        assert(#h.events() == (gamealgo and #types or 0))
        assert(#h.calls == (tapdb and #types or 0))
        if not gamealgo then assert(result.accepted == 0 and result.skipped == #types) end
        if tapdb then
            for index, call in ipairs(h.calls) do
                local envelope = decode(call)
                assert(call.name == "gamealgo_event" and envelope.schemaVersion == 1 and envelope.path == "/v1/events/batch")
                assert(envelope.event.eventType == types[index] and envelope.event.payload.text == text)
                assert(envelope.event.payload.value == 0 and envelope.event.payload.flag == false)
                assert(envelope.event.eventId and envelope.event.timestamp and envelope.event.contextId)
                if gamealgo then assert(envelope.event.eventId == h.events()[index].eventId) end
                assert(not cjson.encode(call):find("ga_live_maker_routing_fixture", 1, true))
            end
        end
        h.flush()
        assert(#h.calls == (tapdb and #types or 0), "acknowledged/skipped queues must drain")
    end
end

-- Missing/malformed values keep compatibility, and the new off switch vetoes old identity linking.
for _, flags in ipairs({ {}, { gamealgoReportingEnabled = "false", tapdbReportingEnabled = "true" },
    { tapdbContextLinkEnabled = true, tapdbReportingEnabled = false } }) do
    local h = fixture(flags)
    assert(h.client.TrackLevelStart({}))
    h.flush()
    assert(#h.events() == 1 and #h.calls == 0)
end

-- TapDB calls never repeat on the direct channel's retry, even when the bridge throws.
do
    local h = fixture({ gamealgoReportingEnabled = true, tapdbReportingEnabled = true })
    h.throwTapdb, h.failBatch = true, true
    assert(h.client.TrackLevelStart({}))
    local _, failure = h.flush()
    assert(failure and #h.calls == 1)
    h.failBatch = false
    local _, error = h.flush()
    assert(error == nil and #h.calls == 1 and #h.events() == 2)
end

-- Runtime controls affect diagnostic requests as well as queued gameplay events.
do
    local h = fixture({ gamealgoReportingEnabled = false, tapdbReportingEnabled = true })
    h.rejectTapdb = true
    assert(h.client.TrackLevelStart({}))
    local _, failure = h.flush()
    assert(failure and #h.events() == 0 and #h.calls == 1)
    local original = decode(h.calls[1]).event
    h.rejectTapdb = false
    local receipt, error = h.flush()
    assert(error == nil and receipt.accepted == 0 and receipt.skipped == 1)
    assert(#h.calls == 2 and decode(h.calls[2]).event.eventId == original.eventId)
    h.flush(); assert(#h.calls == 2)
end

-- Runtime controls affect diagnostic requests as well as queued gameplay events.
do
    local h = fixture({ gamealgoReportingEnabled = false, tapdbReportingEnabled = true,
        eventQuota = { mode = "enforce", policyVersion = 1, ordinaryEventLimit = 0, quotaDate = "2026-11-16", resetAt = "2026-11-17T00:00:00Z", exemptEventTypes = {} } })
    assert(h.client.TrackLevelStart({}) == false)
    assert(#h.calls == 1 and h.calls[1].name == "gamealgo_request")
    assert(decode(h.calls[1]).path == "/v1/diagnostics/sdk")
    for _, request in ipairs(h.requests) do assert(request.path == "/v1/config") end
    h.refresh({ gamealgoReportingEnabled = false, tapdbReportingEnabled = false })
    assert(h.client.TrackLevelStart({}))
    h.flush()
    assert(#h.calls == 1 and #h.events() == 0)
    h.refresh({ gamealgoReportingEnabled = true, tapdbReportingEnabled = false })
    assert(h.client.TrackLevelStart({})); h.flush()
    assert(#h.events() == 1)
end

-- Recover the original failed direct batch through TapDB only, preserving its identity.
do
    local key = "ga_live_maker_routing_recovery"
    local first = fixture({}, { gameKey = key })
    first.failBatch = true
    assert(first.client.TrackLevelEnd({ result = "complete" })); first.flush()
    local original = first.events()[1]
    local second = fixture({ gamealgoReportingEnabled = false, tapdbReportingEnabled = true }, { gameKey = key })
    second.flush()
    assert(#second.events() == 0 and #second.calls == 1)
    local restored = decode(second.calls[1]).event
    assert(restored.eventId == original.eventId and restored.contextId == original.contextId)
    assert(restored.sessionId == original.sessionId and restored.timestamp == original.timestamp)
    local third = fixture({}, { gameKey = key }); third.flush()
    assert(#third.events() == 0, "completed local routing must remove the recovered durable batch")
end

-- Buffered events get the first fresh policy before any post-config flush.
do
    local h = fixture({}, { autoFetch = false })
    assert(h.client.TrackLevelStart({}))
    h.refresh({ gamealgoReportingEnabled = false, tapdbReportingEnabled = true })
    assert(#h.events() == 0 and #h.calls == 1)
end

-- No per-frame host polling or repeated failed attempts while completely idle.
do
    local h = fixture({ gamealgoReportingEnabled = false, tapdbReportingEnabled = true })
    local lookups = 0
    sdk = setmetatable({}, { __index = function() lookups = lookups + 1; return nil end })
    for _ = 1, 10000 do h.client.Update() end
    assert(lookups == 0)
    assert(h.client.TrackLevelStart({})); h.flush()
    local once = lookups
    for _ = 1, 10000 do h.client.Update() end
    assert(lookups == once)
end

print("PASS telemetry routing: four channel modes, complete UTF-8 envelopes, diagnostics, retries, persisted recovery, and idle CPU guards")
