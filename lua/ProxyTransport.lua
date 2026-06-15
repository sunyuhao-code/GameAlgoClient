---@meta
--- ============================================================
--- ProxyTransport.lua — 客户端 RemoteEvent HTTP transport
--- ============================================================
--- 职责：把 SDK 的 HTTP 请求序列化为 RemoteEvent，交给服务端
---       ProxyServer.lua 做真实 HTTP，然后按 request id 分发响应。
---
--- 回调约定：callback(error, response)
---   error: string|nil
---   response: { id, status, success, body, error }
--- ============================================================

local cjson = require("cjson")

local ProxyTransport = {}

local EVENT_REQUEST = "HttpProxy_Request"
local EVENT_RESPONSE = "HttpProxy_Response"

local nextId_ = 1
local pending_ = {}
local started_ = false

local function nowMs()
    return math.floor(os.time() * 1000)
end

local function nextRequestId()
    local id = "ga_lua_" .. tostring(os.time()) .. "_" .. tostring(nextId_)
    nextId_ = nextId_ + 1
    return id
end

local function safeDecode(value)
    local ok, decoded = pcall(cjson.decode, value or "")
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function sendRemoteEvent(eventName, payload)
    local eventData = VariantMap()
    eventData["Payload"] = Variant(payload)
    network:SendRemoteEvent(eventName, true, eventData)
end

function ProxyTransport.HandleResponse(eventType, eventData)
    local payloadValue = eventData and eventData["Payload"]
    local payload = payloadValue and payloadValue:GetString()
    local response = safeDecode(payload)
    if not response then
        print("[GameAlgoSDK] proxy response parse failed")
        return
    end

    local id = response.id or ""
    local item = pending_[id]
    if not item then return end
    pending_[id] = nil

    if response.success then
        item.callback(nil, response)
    else
        item.callback(response.error or ("HTTP " .. tostring(response.status or 0)), response)
    end
end

---@param cfg? table
function ProxyTransport.Start(cfg)
    cfg = cfg or {}
    local prefix = cfg.eventPrefix or "HttpProxy"
    EVENT_REQUEST = prefix .. "_Request"
    EVENT_RESPONSE = prefix .. "_Response"

    if started_ then return end
    started_ = true

    network:RegisterRemoteEvent(EVENT_REQUEST)
    network:RegisterRemoteEvent(EVENT_RESPONSE)
    _G.HandleGameAlgoProxyResponse = function(eventType, eventData)
        ProxyTransport.HandleResponse(eventType, eventData)
    end
    SubscribeToEvent(EVENT_RESPONSE, "HandleGameAlgoProxyResponse")
end

---@param request table
---@param callback fun(error:string|nil,response:table|nil)
function ProxyTransport.Request(request, callback)
    if not started_ then ProxyTransport.Start() end
    callback = callback or function() end

    local id = request.id or nextRequestId()
    local timeoutMs = request.timeoutMs or 10000
    local payload = cjson.encode({
        id = id,
        method = request.method or "GET",
        url = request.url,
        headers = request.headers or {},
        body = request.body or "",
    })

    pending_[id] = {
        callback = callback,
        expiresAt = nowMs() + timeoutMs,
    }
    sendRemoteEvent(EVENT_REQUEST, payload)
    return id
end

--- 如果游戏有 tick/update，可以周期调用用于清理超时请求。
function ProxyTransport.Update()
    local now = nowMs()
    for id, item in pairs(pending_) do
        if item.expiresAt <= now then
            pending_[id] = nil
            item.callback("proxy timeout", nil)
        end
    end
end

function ProxyTransport.PendingCount()
    local count = 0
    for _, _ in pairs(pending_) do count = count + 1 end
    return count
end

return ProxyTransport
