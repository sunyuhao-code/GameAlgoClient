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

print("Lua registered ad placement contracts passed")
