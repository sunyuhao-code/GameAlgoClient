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
local outbox_ = {}
local started_ = false
local connected_ = false

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

local function canSendRemoteEvent()
    if not network then return false end
    local ok, method = pcall(function() return network.SendRemoteEvent end)
    return ok and type(method) == "function"
end

local function trySendRemoteEvent(eventName, payload)
    local eventData = VariantMap()
    eventData["Payload"] = Variant(payload)
    local ok, err = pcall(function()
        network:SendRemoteEvent(eventName, true, eventData)
    end)
    if ok then return true end
    return false, tostring(err)
end

local function drainOutbox()
    if #outbox_ == 0 or not canSendRemoteEvent() then return end

    connected_ = true
    local queue = outbox_
    outbox_ = {}

    for index, item in ipairs(queue) do
        local shouldSend = true
        if item.requestId then
            local pending = pending_[item.requestId]
            if not pending then
                shouldSend = false
            elseif pending.expiresAt <= nowMs() then
                pending_[item.requestId] = nil
                pending.callback("proxy timeout", nil)
                shouldSend = false
            end
        end

        if shouldSend then
            local sent, err = trySendRemoteEvent(item.eventName, item.payload)
            if not sent then
                connected_ = false
                table.insert(outbox_, item)
                for rest = index + 1, #queue do
                    table.insert(outbox_, queue[rest])
                end
                print("[GameAlgoSDK] proxy transport waiting for connection: " .. tostring(err))
                return
            end
        end
    end
end

local function sendRemoteEvent(eventName, payload, requestId)
    if canSendRemoteEvent() then
        connected_ = true
        local sent, err = trySendRemoteEvent(eventName, payload)
        if sent then return end
        connected_ = false
        print("[GameAlgoSDK] proxy send deferred: " .. tostring(err))
    end

    table.insert(outbox_, {
        eventName = eventName,
        payload = payload,
        requestId = requestId,
    })
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
    _G.HandleGameAlgoServerConnected = function()
        connected_ = true
        drainOutbox()
    end
    SubscribeToEvent(EVENT_RESPONSE, "HandleGameAlgoProxyResponse")
    SubscribeToEvent("ServerConnected", "HandleGameAlgoServerConnected")
    drainOutbox()
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
    sendRemoteEvent(EVENT_REQUEST, payload, id)
    drainOutbox()
    return id
end

--- 如果游戏有 tick/update，可以周期调用用于清理超时请求。
function ProxyTransport.Update()
    drainOutbox()
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

function ProxyTransport.OutboxCount()
    return #outbox_
end

return ProxyTransport
