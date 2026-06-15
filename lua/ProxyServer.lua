---@meta
--- ============================================================
--- ProxyServer.lua — 通用 HTTP 代理转发服务端
--- ============================================================
--- 职责：监听客户端 RemoteEvent，用 HttpClient 发出真实 HTTP 请求，
---       结果回传客户端。
---
--- 【复用性】：此文件与具体 SDK 无关，任何需要"客户端通过服务端
---            转发 HTTP"的场景都可以直接复用，无需修改。
---
--- 【安全性】：通过 allowedHosts 白名单限制可转发的域名。
--- ============================================================

local cjson = require("cjson")

local ProxyServer = {}

--- 配置项
---@class ProxyServerConfig
---@field allowedHosts string[]         白名单域名列表（精确匹配 host 部分）
---@field allowedPathPrefixes? string[] 允许转发的 path 前缀；不传则不限制 path
---@field defaultHeaders? table<string,string>  所有转发请求附加的公共 header
---@field timeout? integer              HTTP 超时毫秒数，默认 10000
---@field maxBodySize? integer          最大请求 body 字节数，默认 65536
---@field eventPrefix? string           RemoteEvent 前缀，默认 "HttpProxy"
---@field allowHttp? boolean            是否允许 http URL，默认 false

local EVENT_REQUEST  = "HttpProxy_Request"
local EVENT_RESPONSE = "HttpProxy_Response"

local config_ = {
    allowedHosts        = {},
    allowedPathPrefixes = nil,
    defaultHeaders      = {},
    timeout             = 10000,
    maxBodySize         = 65536,
    eventPrefix         = "HttpProxy",
    allowHttp           = false,
}

local HOP_BY_HOP_HEADERS = {
    ["connection"] = true,
    ["host"] = true,
    ["content-length"] = true,
    ["transfer-encoding"] = true,
}

--- 从 URL 中提取 scheme / host / path
---@param url string
---@return string,string,string
local function parseUrl(url)
    local scheme, rest = tostring(url or ""):match("^(https?)://(.+)$")
    if not scheme or not rest then return "", "", "" end
    local host = rest:match("^([^/:?#]+)") or ""
    local path = rest:match("^[^/?#]*(/[^?#]*)") or "/"
    return scheme, host, path
end

--- 检查 host 是否在白名单
---@param host string
---@return boolean
local function isHostAllowed(host)
    for _, h in ipairs(config_.allowedHosts) do
        if h == host then return true end
    end
    return false
end

--- 检查 path 是否允许
---@param path string
---@return boolean
local function isPathAllowed(path)
    if not config_.allowedPathPrefixes or #config_.allowedPathPrefixes == 0 then
        return true
    end
    for _, prefix in ipairs(config_.allowedPathPrefixes) do
        if path:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function normalizedHeaderName(name)
    return tostring(name or ""):lower()
end

local function isProtectedHeader(name)
    local key = normalizedHeaderName(name)
    if HOP_BY_HOP_HEADERS[key] then return true end
    for defaultName, _ in pairs(config_.defaultHeaders) do
        if normalizedHeaderName(defaultName) == key then return true end
    end
    return false
end

--- HTTP Method 字符串转枚举
local METHOD_MAP = {
    GET    = HTTP_GET,
    POST   = HTTP_POST,
    PUT    = HTTP_PUT,
    DELETE = HTTP_DELETE,
    PATCH  = HTTP_PATCH,
}

--- 处理客户端转发请求
---@param eventType string
---@param eventData table
function ProxyServer.HandleRequest(eventType, eventData)
    local connectionValue = eventData and eventData["Connection"]
    local connection = connectionValue and connectionValue:GetPtr("Connection")
    if not connection then
        print("[ProxyServer] ERROR: no connection in event")
        return
    end

    local payloadValue = eventData["Payload"]
    local payload = payloadValue and payloadValue:GetString()
    if not payload or #payload == 0 then
        ProxyServer.SendError(connection, "empty_request", "Empty payload", "")
        return
    end

    local ok, req = pcall(cjson.decode, payload)
    if not ok or type(req) ~= "table" then
        ProxyServer.SendError(connection, "parse_error", "Invalid JSON", "")
        return
    end

    local requestId = req.id or ""
    local url       = req.url or ""
    local method    = tostring(req.method or "GET")
    local headers   = type(req.headers) == "table" and req.headers or {}
    local body      = tostring(req.body or "")

    -- 安全检查：白名单
    local scheme, host, path = parseUrl(url)
    if scheme == "" then
        ProxyServer.SendError(connection, requestId, "Invalid URL", url)
        return
    end
    if scheme ~= "https" and not config_.allowHttp then
        ProxyServer.SendError(connection, requestId, "Only HTTPS is allowed", url)
        return
    end
    if not isHostAllowed(host) then
        print("[ProxyServer] BLOCKED host: " .. host .. " url: " .. url)
        ProxyServer.SendError(connection, requestId, "Host not allowed: " .. host, url)
        return
    end
    if not isPathAllowed(path) then
        print("[ProxyServer] BLOCKED path: " .. path .. " url: " .. url)
        ProxyServer.SendError(connection, requestId, "Path not allowed: " .. path, url)
        return
    end

    -- body 大小限制
    if #body > config_.maxBodySize then
        ProxyServer.SendError(connection, requestId, "Body too large", url)
        return
    end

    -- 构建 HttpClient 请求
    local httpMethod = METHOD_MAP[method:upper()] or HTTP_GET
    local client = http:Create()
        :SetUrl(url)
        :SetMethod(httpMethod)
        :SetTimeout(config_.timeout)

    -- 请求自带 headers。服务端 defaultHeaders 里的敏感 header 不允许客户端覆盖。
    for k, v in pairs(headers) do
        if not isProtectedHeader(k) then
            client:AddHeader(tostring(k), tostring(v))
        end
    end

    -- 公共 headers 最后添加，保证游戏 key 等服务端配置优先。
    for k, v in pairs(config_.defaultHeaders) do
        client:AddHeader(tostring(k), tostring(v))
    end

    -- body
    if body ~= "" and (httpMethod == HTTP_POST or httpMethod == HTTP_PUT or httpMethod == HTTP_PATCH) then
        client:SetContentType(headers["Content-Type"] or "application/json")
        client:SetBody(body)
    end

    -- 发送
    client
        :OnSuccess(function(_, response)
            local respData = VariantMap()
            respData["Payload"] = Variant(cjson.encode({
                id         = requestId,
                status     = response.statusCode,
                success    = response.success,
                body       = response.dataAsString,
            }))
            connection:SendRemoteEvent(EVENT_RESPONSE, true, respData)
        end)
        :OnError(function(_, statusCode, error)
            local respData = VariantMap()
            respData["Payload"] = Variant(cjson.encode({
                id         = requestId,
                status     = statusCode,
                success    = false,
                body       = "",
                error      = error,
            }))
            connection:SendRemoteEvent(EVENT_RESPONSE, true, respData)
        end)
        :Send()
end

--- 发送错误响应给客户端
function ProxyServer.SendError(connection, requestId, errorMsg, url)
    local respData = VariantMap()
    respData["Payload"] = Variant(cjson.encode({
        id      = requestId,
        status  = 0,
        success = false,
        body    = "",
        error   = errorMsg,
    }))
    connection:SendRemoteEvent(EVENT_RESPONSE, true, respData)
end

--- 初始化代理服务器
---@param cfg ProxyServerConfig
function ProxyServer.Start(cfg)
    assert(cfg and cfg.allowedHosts and #cfg.allowedHosts > 0,
        "[ProxyServer] allowedHosts is required and must not be empty")

    config_.allowedHosts        = cfg.allowedHosts
    config_.allowedPathPrefixes = cfg.allowedPathPrefixes
    config_.defaultHeaders      = cfg.defaultHeaders or {}
    config_.timeout             = cfg.timeout or 10000
    config_.maxBodySize         = cfg.maxBodySize or 65536
    config_.allowHttp           = cfg.allowHttp == true

    if cfg.eventPrefix then
        EVENT_REQUEST  = cfg.eventPrefix .. "_Request"
        EVENT_RESPONSE = cfg.eventPrefix .. "_Response"
    end

    -- 注册事件
    network:RegisterRemoteEvent(EVENT_REQUEST)
    network:RegisterRemoteEvent(EVENT_RESPONSE)
    SubscribeToEvent(EVENT_REQUEST, "HandleProxyRequest")

    print("[ProxyServer] Started. Allowed hosts: " .. table.concat(config_.allowedHosts, ", "))
end

return ProxyServer
