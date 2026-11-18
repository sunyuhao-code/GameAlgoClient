-- Controlled Android adapter for the unmodified SDK. This is not Maker itself.
local cjson = { encode = HostJsonEncode, decode = HostJsonDecode, null = HOST_JSON_NULL }
package.preload.cjson = function() return cjson end
table.insert(package.searchers, 2, function(name)
    local module = name:gsub("^sdk%.", "")
    if not module:match("^[%w_]+$") then return "unsupported probe module" end
    local ok, source = pcall(HostReadAsset, PROBE_VARIANT .. "/sdk/" .. module .. ".lua")
    if not ok then return "missing probe asset: " .. module end
    return assert(load(source, "@" .. module .. ".lua"))
end)
print = function(...) local v = {...}; for i = 1, #v do v[i] = tostring(v[i]) end; HostLog(table.concat(v, " ")) end

FILE_READ, FILE_WRITE = 1, 2
fileSystem = { FileExists = function(_, name)
    local h = io.open(PROBE_FILES .. "/" .. name, "rb")
    if h then h:close(); return true end
    return false
end }
function File(name, mode)
    local h = io.open(PROBE_FILES .. "/" .. name, mode == FILE_WRITE and "wb" or "rb")
    return {
        IsOpen = function() return h ~= nil end,
        ReadString = function() return assert(h):read("*a") end,
        WriteString = function(_, value) assert(assert(h):write(value)); return #value end,
        Flush = function() return assert(h):flush() end,
        Close = function() if h then h:close(); h = nil end end,
    }
end

local handlers = {}
function Node()
    return { CreateScriptObject = function()
        return { SubscribeToEvent = function(_, name, fn)
            handlers[name] = handlers[name] or {}
            table.insert(handlers[name], fn)
        end }
    end }
end
function ProbeLifecycle(name)
    print("LIFECYCLE " .. name)
    for _, fn in ipairs(handlers[name] or {}) do fn(nil, nil, nil) end
end
function ProbeFrame(delta)
    local data = { GetFloat = function() return delta end }
    for _, fn in ipairs(handlers.Update or {}) do fn(nil, nil, data) end
end

HTTP_GET, HTTP_POST, HTTP_PUT, HTTP_DELETE, HTTP_PATCH = "GET", "POST", "PUT", "DELETE", "PATCH"
local clients, nextRequest = {}, 0
http = { Create = function()
    local client = { headers = {}, method = "GET", url = "", body = "" }
    function client:SetUrl(v) self.url = v; return self end
    function client:SetMethod(v) self.method = v; return self end
    function client:SetTimeout(_) return self end
    function client:AddHeader(k, v) self.headers[k] = v; return self end
    function client:SetContentType(v) self.headers["Content-Type"] = v; return self end
    function client:SetBody(v) self.body = v; return self end
    function client:OnSuccess(fn) self.success = fn; return self end
    function client:OnError(fn) self.failure = fn; return self end
    function client:Cancel() if self.id then clients[self.id] = nil end end
    function client:Send()
        nextRequest = nextRequest + 1; self.id = nextRequest; clients[self.id] = self
        HostSend(self.id, self.url, self.method, self.body, cjson.encode(self.headers))
        return self
    end
    return client
end }
function ProbeHttpComplete(id, status, body, error)
    local client = clients[id]; clients[id] = nil
    if not client then return end
    if error == "" and status >= 200 and status < 300 then
        client.success(client, { statusCode = status, success = true, dataAsString = body })
    else client.failure(client, status, error ~= "" and error or ("HTTP " .. status)) end
end

lobby = { GetMyUserId = function() return "android-probe-account" end }
function GetNativePlatform() return "Android" end
function GetPlatform() return "Android" end

local GameAlgo = require("sdk.GameAlgo")
GameAlgo.Init({ gameKey = "ga_live_isolated_android_" .. PROBE_VARIANT .. "_" .. PROBE_CASE,
    userId = "android-probe-user", baseUrl = PROBE_URL, isDebug = true,
    appVersion = PROBE_VARIANT .. ":" .. PROBE_CASE, preloadConfigFiles = false,
    nowMs = HostNowMs, logger = HostLog })

function ProbeCommand(command, holdMs)
    assert(GameAlgo.Snapshot().contextId, "config not ready")
    if command == "busy" then
        assert(GameAlgo.Track("beads_leave", { reason = "background", probeCase = PROBE_CASE,
            holdResponseMs = holdMs }))
        GameAlgo.Flush(nil)
    elseif command == "manual_end" then
        assert(GameAlgo.TrackSessionEnd({ reason = "business_exit" }))
        GameAlgo.Flush(nil)
    elseif command == "ad" then
        assert(GameAlgo.TrackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0,
            { trackId = "isolated-ad-probe", holdResponseMs = holdMs }))
    elseif command == "will" then ProbeLifecycle("AppWillEnterBackground")
    elseif command == "did" then ProbeLifecycle("AppDidEnterBackground")
    elseif command == "exit" then ProbeLifecycle("ExitRequested")
    elseif command == "snapshot" then print("SNAPSHOT " .. cjson.encode(GameAlgo.Snapshot()))
    else error("unknown probe command: " .. tostring(command)) end
    print("COMMAND_OK " .. command)
end
