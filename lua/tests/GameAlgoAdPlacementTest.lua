local cjson = require("cjson")
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local files = {}
FILE_READ = 1
FILE_WRITE = 2
function File(name, mode)
    local buffer = files[name] or ""
    return {
        IsOpen = function() return mode == FILE_WRITE or files[name] ~= nil end,
        ReadString = function() return buffer end,
        WriteString = function(_, value) buffer = value; files[name] = value end,
        Flush = function() files[name] = buffer end,
        Close = function() end,
    }
end
local function readFile(path)
    local handle = assert(io.open(path, "rb"))
    local value = handle:read("*a")
    handle:close()
    return value
end
local eventRequests = {}
local transport = {}
function transport.Request(options, callback)
    if options.url:match("/v1/config$") then
        callback(nil, {status = 200, body = readFile("protocol/fixtures/config-response.json"), headers = {}})
    elseif options.url:match("/v1/events/batch$") then
        local body = cjson.decode(options.body)
        table.insert(eventRequests, body)
        callback(nil, {status = 200, body = cjson.encode({ok = true, accepted = #body.events}), headers = {}})
    elseif options.url:match("/v1/diagnostics/sdk$") then
        callback(nil, {status = 200, body = '{"ok":true,"accepted":1}', headers = {}})
    else error("unexpected request: " .. options.url) end
end
local GameAlgo = require("GameAlgo")
assert(GameAlgo.TrackAd == nil, "new SDK exposes only registered placement tracking")
local adPlacementFixture = cjson.decode(readFile("protocol/fixtures/ad-placement-event.json"))
GameAlgo.Init({ gameKey = "ga_live_fixture_key", userId = "registered-ad-user", sessionId = "registered-ad-session", transport = transport, autoFetch = false, preloadConfigFiles = false })
GameAlgo.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
local requestsBeforeRegisteredAd = #eventRequests
for _, id in ipairs(adPlacementFixture.invalidIds) do assert(GameAlgo.TrackAdPlacement(id, 0) == false) end
assert(GameAlgo.TrackAdPlacement(adPlacementFixture.adPlacementId, 0 / 0) == false)
assert(GameAlgo.TrackAdPlacement(adPlacementFixture.adPlacementId, math.huge) == false)
assert(#eventRequests == requestsBeforeRegisteredAd)
assert(GameAlgo.TrackAdPlacement(adPlacementFixture.adPlacementId, adPlacementFixture.revenue, adPlacementFixture.network, adPlacementFixture.payload))
local registeredAd = nil
for index = requestsBeforeRegisteredAd + 1, #eventRequests do
    for _, event in ipairs(eventRequests[index].events) do
        if event.eventType == "ad_view" and event.payload.adPlacementId == adPlacementFixture.adPlacementId then
            assert(registeredAd == nil, "registered ad must not upload twice")
            registeredAd = event
        end
    end
end
assert(registeredAd ~= nil)
assert(registeredAd.eventType == "ad_view")
for key, value in pairs(adPlacementFixture.expectedPayload) do assert(registeredAd.payload[key] == value, key) end
assert(registeredAd.payload.placement == nil and registeredAd.payload.adType == nil and registeredAd.payload.currency == nil)
assert(adPlacementFixture.payload.placement == "legacy-name" and adPlacementFixture.payload.revenue == 999)
assert(GameAlgo.TrackAdPlacement(adPlacementFixture.adPlacementId, 0, { trackId = "zero" }))
assert(eventRequests[#eventRequests].events[1].payload.trackId == "zero")
assert(GameAlgo.TrackAdPlacement(adPlacementFixture.adPlacementId, 0))
assert(eventRequests[#eventRequests].events[1].payload.revenue == 0)

local function adCount()
    local count = 0
    for _, request in ipairs(eventRequests) do
        for _, event in ipairs(request.events) do if event.eventType == "ad_view" then count = count + 1 end end
    end
    return count
end
local id = adPlacementFixture.adPlacementId
local callbacks, businessResults = {}, {}
sdk = { ShowRewardVideoAd = function(_, callback)
    callbacks[#callbacks + 1] = callback
    return true
end }
for _, result in ipairs({
    { success = true, extra = '{"trackId":"completed"}' },
    { success = false, msg = "embed manual close", trackId = "skipped" },
    { success = false, code = 500, msg = "non-success", track_id = "non-success" },
    { success = false },
}) do
    local before = adCount()
    local payload = { level_no = 7, trackId = "stale-caller-track", revenue = 999 }
    assert(GameAlgo.ShowRewardVideoAd(id, function(value)
        assert(value == result, "business result must be passed through unchanged")
        assert(adCount() == before + 1, "report before invoking business code")
        businessResults[#businessResults + 1] = value
    end, payload) == true)
    assert(adCount() == before, "request acceptance is not an exposure")
    payload.level_no = 999
    local callback = callbacks[#callbacks]
    local businessBefore = #businessResults
    callback(result); callback(result)
    assert(adCount() == before + 1 and #businessResults == businessBefore + 1)
    local event = eventRequests[#eventRequests].events[1]
    assert(event.payload.trackId == GameAlgo.ExtractAdTrackId(result))
    assert(event.payload.level_no == 7 and event.payload.revenue == 0 and event.payload.network == "taptap")
    assert(payload.trackId == "stale-caller-track", "caller payload is not mutated")
end

local before, called = adCount(), 0
local nativeReturned = false
local syncResult = { success = true, trackId = "synchronous" }
sdk.ShowRewardVideoAd = function(_, callback)
    callback(syncResult); callback(syncResult)
    nativeReturned = true
    return true
end
assert(GameAlgo.ShowRewardVideoAd(id, function(result)
    assert(nativeReturned and result == syncResult, "wait for the native acceptance result")
    called = called + 1
end))
assert(called == 1 and adCount() == before + 1)

before, called = adCount(), 0
local refusedResult = { success = false, msg = "request not accepted", trackId = "must-not-report" }
sdk.ShowRewardVideoAd = function(_, callback)
    callbacks[#callbacks + 1] = callback
    callback(refusedResult)
    return false
end
assert(GameAlgo.ShowRewardVideoAd(id, function(result)
    assert(result == refusedResult); called = called + 1
end) == false)
callbacks[#callbacks]({ success = true, trackId = "late-refused" })
assert(called == 1 and adCount() == before, "synchronous rejection is not a close/exposure")

local late
sdk.ShowRewardVideoAd = function(_, callback) late = callback; return false end
assert(GameAlgo.ShowRewardVideoAd(id, function(result)
    assert(result == refusedResult); called = called + 1
end) == false)
assert(called == 1, "do not invent a callback when the host does not issue one")
late(refusedResult); late(refusedResult)
assert(called == 2 and adCount() == before, "late callbacks from rejected requests never report")

sdk.ShowRewardVideoAd = function() error("native request threw") end
local accepted, requestError = GameAlgo.ShowRewardVideoAd(id, function() error("unexpected invented result") end)
assert(accepted == false and requestError:find("native request threw") and adCount() == before)
sdk = nil
assert(GameAlgo.ShowRewardVideoAd(id) == false and adCount() == before)

local nativeCalls = 0
sdk = { ShowRewardVideoAd = function(_, callback) nativeCalls = nativeCalls + 1; callback(syncResult); return true end }
assert(GameAlgo.ShowRewardVideoAd("invalid", function() end) == false)
assert(GameAlgo.ShowRewardVideoAd(id, "invalid") == false)
assert(GameAlgo.ShowRewardVideoAd(id, nil, { invalid = 0/0 }) == false)
assert(nativeCalls == 0)
assert(adCount() == before, "invalid arguments do not request or report an ad")
assert(GameAlgo.ShowRewardVideoAd(id, function() error("business failure") end))
assert(adCount() == before + 1, "business exceptions do not suppress tracking or change acceptance")

local originalTrack = GameAlgo.TrackAdPlacement
GameAlgo.TrackAdPlacement = function() error("tracking failure") end
called = 0
assert(GameAlgo.ShowRewardVideoAd(id, function(result) assert(result == syncResult); called = called + 1 end))
assert(called == 1, "tracking failures do not stop the game's callback")
GameAlgo.TrackAdPlacement = originalTrack

print("Lua registered ad placements and Maker reward ad wrapper contracts passed")
