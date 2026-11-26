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
            callback(nil, { status = 200, body = cjson.encode(h.batchReply or { ok = true, accepted = body.events and #body.events or 1 }) })
        end
    end, Cancel = function() end }
    h.client.Init({ gameKey = options.gameKey or ("ga_live_maker_routing_fixture_" .. tostring(sequence)),
        experimentIntegrationVersion = 1,
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
        local h = fixture({ gamealgoStandardReportingEnabled = gamealgo, gamealgoCustomReportingEnabled = gamealgo, tapdbStandardReportingEnabled = tapdb, tapdbCustomReportingEnabled = tapdb })
        local types = { "level_start", "level_end", "session_end", "ad_view", "purchase", "milestone", "_custom", "experiment_exposure" }
        local text = string.rep("中🙂a", 200)
        for _, eventType in ipairs(types) do assert(h.client.Track(eventType, { text = text, value = 0, flag = false })) end
        local pending = h.client.Snapshot().queuedEvents
        local result, error = h.flush()
        assert(error == nil, tostring(error))
        assert(#h.events() == (gamealgo and #types or 0))
        assert(#h.calls == (tapdb and #types or 0))
        if not gamealgo then assert(result.accepted == 0 and result.skipped == pending) end
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

-- Both critical paths use the same independent category switches and
-- receipts while an unrelated native custom-event request is still in flight.
for _, criticalType in ipairs({ "session_end", "ad_view" }) do
for _, gamealgo in ipairs({ false, true }) do
    for _, tapdb in ipairs({ false, true }) do
        local h = fixture({ gamealgoStandardReportingEnabled = gamealgo,
            gamealgoCustomReportingEnabled = true, tapdbStandardReportingEnabled = tapdb,
            tapdbCustomReportingEnabled = false })
        h.holdBatch = true
        assert(h.client.Track("_busy_ordinary", {}))
        h.flush()
        assert(#h.events() == 1)
        assert(h.client.Track(criticalType, { reason = "business_exit" }))
        h.flush()
        assert(#h.events() == (gamealgo and 2 or 1), "only the native-enabled end bypasses the held ACK")
        assert(#h.calls == (tapdb and 1 or 0), "only the TapDB-enabled end is handed to the bridge")
        if gamealgo then
            h.pending[2](nil, { status = 200, body = cjson.encode({ ok = true, accepted = 1 }) })
        end
        h.pending[1](nil, { status = 200, body = cjson.encode({ ok = true, accepted = 1 }) })
        assert(h.client.Snapshot().queuedEvents == 0)
        assert(#h.events() == (gamealgo and 2 or 1), "ordinary drain must reuse the end receipt")
        assert(#h.calls == (tapdb and 1 or 0), "ordinary drain must not repeat TapDB delivery")
    end
end
end

-- Missing/malformed values keep compatibility, and the new off switch vetoes old identity linking.
for _, flags in ipairs({ {}, { gamealgoStandardReportingEnabled = "false", gamealgoCustomReportingEnabled = "false", tapdbStandardReportingEnabled = "true", tapdbCustomReportingEnabled = "true" },
    { tapdbContextLinkEnabled = true, tapdbStandardReportingEnabled = false, tapdbCustomReportingEnabled = false } }) do
    local h = fixture(flags)
    assert(h.client.TrackLevelStart({}))
    h.flush()
    assert(#h.events() == 1 and #h.calls == 0)
end

-- TapDB calls never repeat on the direct channel's retry, even when the bridge throws.
do
    local h = fixture({ gamealgoStandardReportingEnabled = true, gamealgoCustomReportingEnabled = true, tapdbStandardReportingEnabled = true, tapdbCustomReportingEnabled = true })
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
    local h = fixture({ gamealgoStandardReportingEnabled = false, gamealgoCustomReportingEnabled = false, tapdbStandardReportingEnabled = true, tapdbCustomReportingEnabled = true })
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
    local h = fixture({ gamealgoStandardReportingEnabled = false, gamealgoCustomReportingEnabled = false, tapdbStandardReportingEnabled = true, tapdbCustomReportingEnabled = true,
        eventQuota = { mode = "enforce", policyVersion = 1, ordinaryEventLimit = 0, quotaDate = "2026-11-16", resetAt = "2026-11-17T00:00:00Z", exemptEventTypes = {} } })
    assert(h.client.TrackLevelStart({}) == false)
    assert(#h.calls == 1 and h.calls[1].name == "gamealgo_request")
    assert(decode(h.calls[1]).path == "/v1/diagnostics/sdk")
    for _, request in ipairs(h.requests) do assert(request.path == "/v1/config") end
    h.refresh({ gamealgoStandardReportingEnabled = false, gamealgoCustomReportingEnabled = false, tapdbStandardReportingEnabled = false, tapdbCustomReportingEnabled = false })
    assert(h.client.TrackLevelStart({}))
    h.flush()
    assert(#h.calls == 1 and #h.events() == 0)
    h.refresh({ gamealgoStandardReportingEnabled = true, gamealgoCustomReportingEnabled = true, tapdbStandardReportingEnabled = false, tapdbCustomReportingEnabled = false })
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
    local second = fixture({ gamealgoStandardReportingEnabled = false, gamealgoCustomReportingEnabled = false, tapdbStandardReportingEnabled = true, tapdbCustomReportingEnabled = true }, { gameKey = key })
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
    h.refresh({ gamealgoStandardReportingEnabled = false, gamealgoCustomReportingEnabled = false, tapdbStandardReportingEnabled = true, tapdbCustomReportingEnabled = true })
    assert(#h.events() == 0 and #h.calls == 1)
end

-- No per-frame host polling or repeated failed attempts while completely idle.
do
    local h = fixture({ gamealgoStandardReportingEnabled = false, gamealgoCustomReportingEnabled = false, tapdbStandardReportingEnabled = true, tapdbCustomReportingEnabled = true })
    local lookups = 0
    sdk = setmetatable({}, { __index = function() lookups = lookups + 1; return nil end })
    for _ = 1, 10000 do h.client.Update() end
    assert(lookups == 0)
    assert(h.client.TrackLevelStart({})); h.flush()
    local once = lookups
    for _ = 1, 10000 do h.client.Update() end
    assert(lookups == once)
end

-- Each category has an independent route, including reserved SDK experiment events.
for mask = 0, 15 do
    local flags = {
        gamealgoStandardReportingEnabled = mask % 2 == 1,
        gamealgoCustomReportingEnabled = math.floor(mask / 2) % 2 == 1,
        tapdbStandardReportingEnabled = math.floor(mask / 4) % 2 == 1,
        tapdbCustomReportingEnabled = math.floor(mask / 8) % 2 == 1,
    }
    local h = fixture(flags)
    local types = { "level_end", "experiment_exposure", "experiment_execution", "_business", "raw_business" }
    local directTypes, tapTypes = {}, {}
    for index, eventType in ipairs(types) do
        assert(h.client.Track(eventType, { value = index }))
        local direct, tapdb = flags.gamealgoCustomReportingEnabled, flags.tapdbCustomReportingEnabled
        if index <= 3 then direct, tapdb = flags.gamealgoStandardReportingEnabled, flags.tapdbStandardReportingEnabled end
        if direct then table.insert(directTypes, eventType) end
        if tapdb then table.insert(tapTypes, eventType) end
    end
    local result, failure = h.flush()
    assert(failure == nil, tostring(failure))
    assert(result.accepted == #directTypes and (result.skipped or 0) == #types - #directTypes)
    assert(#h.events() == #directTypes and #h.calls == #tapTypes)
    for index, eventType in ipairs(directTypes) do assert(h.events()[index].eventType == eventType) end
    for index, eventType in ipairs(tapTypes) do assert(decode(h.calls[index]).event.eventType == eventType) end
end

-- A failed TapDB-only subset cannot cause repeated HTTP delivery of an acknowledged subset.
do
    local h = fixture({ gamealgoCustomReportingEnabled = false, tapdbCustomReportingEnabled = true })
    h.rejectTapdb = true
    assert(h.client.TrackLevelStart({})); assert(h.client.TrackEvent("business", { value = 42 }))
    local _, failure = h.flush()
    assert(failure and #h.events() == 1 and h.events()[1].eventType == "level_start")
    local original = decode(h.calls[1]).event
    h.rejectTapdb = false
    local result, error = h.flush()
    assert(error == nil and result.accepted == 0 and result.skipped == 2)
    assert(#h.events() == 1 and #h.calls == 2)
    local retried = decode(h.calls[2]).event
    assert(retried.eventId == original.eventId and retried.timestamp == original.timestamp)
    h.flush(); assert(#h.calls == 2)
end

-- Conversely, HTTP retries must not repeat an already accepted TapDB-only subset.
do
    local h = fixture({ gamealgoCustomReportingEnabled = false, tapdbCustomReportingEnabled = true })
    h.failBatch = true
    assert(h.client.TrackLevelStart({})); assert(h.client.TrackEvent("business", {}))
    local _, failure = h.flush(); assert(failure and #h.calls == 1)
    h.failBatch = false
    local _, error = h.flush(); assert(error == nil and #h.calls == 1 and #h.events() == 2)
end

-- Custom routing permission cannot enable SDK diagnostics or the legacy identity link.
do
    local h = fixture({ gamealgoStandardReportingEnabled = false, tapdbCustomReportingEnabled = true,
        tapdbContextLinkEnabled = true,
        eventQuota = { mode = "enforce", policyVersion = 1, ordinaryEventLimit = 0, quotaDate = "2026-11-16", resetAt = "2026-11-17T00:00:00Z", exemptEventTypes = {} } })
    assert(h.client.TrackLevelStart({}) == false)
    assert(#h.calls == 0)
    for _, request in ipairs(h.requests) do assert(request.path == "/v1/config") end
end

-- Invalid HTTP responses cannot mark a native subset completed. All-rejected subsets are terminal too.
do
    local h = fixture({ gamealgoCustomReportingEnabled = false, tapdbCustomReportingEnabled = true })
    assert(h.client.TrackEvent("business", {})); assert(h.client.TrackLevelStart({}))
    for _, reply in ipairs({ {}, { accepted = 0, rejected = {} }, { accepted = 0, rejected = { false } }, { ok = false, accepted = 1 } }) do
        h.batchReply = reply
        local _, failure = h.flush(); assert(failure and #h.events() >= 1)
    end
    h.batchReply = { ok = true, accepted = 0, rejected = { { index = 0, reason = "fixture rejection" } } }
    local result, failure = h.flush()
    assert(failure == nil and result.accepted == 0 and result.skipped == 1 and result.rejectedCount == 1)
    assert(#h.calls == 1)
end

print("PASS telemetry routing: 16 independent category combinations, mixed-batch retry isolation, diagnostics, persisted recovery, and idle CPU guards")
