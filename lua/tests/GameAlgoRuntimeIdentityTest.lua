local cjson = require("cjson")
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local files = {}
FILE_READ, FILE_WRITE = 1, 2
fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
function File(name, mode)
    return {
        IsOpen = function() return mode == FILE_WRITE or files[name] ~= nil end,
        ReadString = function() return files[name] end,
        WriteString = function(_, value) files[name] = value end,
        Flush = function() end, Close = function() end,
    }
end
local GameAlgo = require("GameAlgo")
local requests = {}
local transport = {}
function transport.Request(request, callback)
    assert(request.url:match("/v1/config$"), "identity collection must not emit extra telemetry")
    table.insert(requests, cjson.decode(request.body))
    callback(nil, { status = 200, body = '{"contextId":"ctx-identity","configVersion":"1","configFiles":[],"experiments":[]}' })
end
local copied = { runtimeMiniappId = "tapmccopied", runtimeProjectId = "copied", runtimeAppId = "999", runtimeIdentitySource = "copied", custom = "kept" }
local function fetch()
    local called = false
    GameAlgo.FetchConfig(function(err) assert(err == nil, tostring(err)); called = true end)
    assert(called)
    return requests[#requests].device
end
local function init()
    GameAlgo.Init({ gameKey = "ga_live_fixture", userId = "runtime-identity-test", sessionId = "identity-" .. tostring(#requests),
        autoFetch = false, preloadConfigFiles = false, transport = transport, device = copied, logger = false })
    return fetch()
end
local function onlyMiniappIdentity(device, expected)
    assert(device.runtimeMiniappId == expected)
    assert(device.runtimeProjectId == nil and device.runtimeAppId == nil and device.runtimeIdentitySource == nil)
    assert(device.custom == "kept")
end
local args = { miniapp_id = "tapmcactualgame", project_id = "m_actual", app_id = "979826" }
local readArgs = {}
GetAppArgv = function(name) readArgs[#readArgs + 1] = name; return args[name] end
local lobbyProjectReads = 0
lobby = { GetMyUserId = function() return "fixture-account" end,
    GetProjectId = function() lobbyProjectReads = lobbyProjectReads + 1; return "lobby-project" end }
local first = init()
onlyMiniappIdentity(first, "tapmcactualgame")
assert(copied.runtimeMiniappId == "tapmccopied", "caller data is not mutated")
assert(copied.runtimeProjectId == "copied" and copied.runtimeAppId == "999" and copied.runtimeIdentitySource == "copied")

args = { miniapp_id = "  tapmcnextgame  " }
local current = fetch()
onlyMiniappIdentity(current, "tapmcnextgame")
assert(first.runtimeMiniappId == "tapmcactualgame", "prior request snapshots are unchanged")
for _, name in ipairs(readArgs) do assert(name == "miniapp_id", "do not collect project ID or App ID") end
assert(lobbyProjectReads == 0, "do not probe lobby project identity")

GetAppArgv = nil
onlyMiniappIdentity(init(), nil)

-- Even when other IDs are available, only a native miniapp ID may be reported.
args = { project_id = "m_other", app_id = "979826" }
GetAppArgv = function(name) return args[name] end
onlyMiniappIdentity(init(), nil)
for _, value in ipairs({ {}, "", "tapmc", "tapmc-unsafe", "tapmcUPPER", "https://example.com/game", "two ids", "tapmc" .. string.rep("x", 124), "979826", 979826, math.huge, false }) do
    args.miniapp_id = value
    onlyMiniappIdentity(init(), nil)
end
GetAppArgv = function() error("not supported") end
onlyMiniappIdentity(init(), nil)

print("Lua runtime miniapp identity contracts passed")
