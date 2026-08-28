---@meta
--- TapTap Maker client-side HTTP transport.

local HttpTransport = {}

local METHOD_MAP = {
    GET = HTTP_GET,
    POST = HTTP_POST,
    PUT = HTTP_PUT,
    DELETE = HTTP_DELETE,
    PATCH = HTTP_PATCH,
}

local activeRequests = {}
local requestIdsByClient = setmetatable({}, { __mode = "k" })
local nextRequestId = 0

function HttpTransport.Start()
end

local function safeError(value)
    local ok, message = pcall(tostring, value)
    return ok and message or "unknown error"
end

local function safePrint(prefix, value)
    pcall(print, prefix .. safeError(value))
end

---@param request table
---@param callback fun(error:string|nil,response:table|nil)
function HttpTransport.Request(request, callback)
    local rawCallback = type(callback) == "function" and callback or function() end
    local settled = false
    local requestId = nil
    local client = nil

    local function complete(error, response)
        if settled then return false end
        settled = true
        if requestId then activeRequests[requestId] = nil end
        if client then requestIdsByClient[client] = nil end
        local callbackOk, callbackError = pcall(rawCallback, error, response)
        if not callbackOk then safePrint("[GameAlgoHttp] callback failed: ", callbackError) end
        return callbackOk
    end

    if type(request) ~= "table" then
        complete("invalid HTTP request", nil)
        return nil
    end

    -- Maker may expose `http` through the current environment's metatable.
    -- Keep a normal global lookup here instead of using rawget(_G, ...).
    local okHttp, httpManager = pcall(function()
        return http
    end)
    if not okHttp or httpManager == nil then
        complete("http client unavailable in this runtime", nil)
        return nil
    end

    local methodOk, method = pcall(function()
        return tostring(request.method or "GET"):upper()
    end)
    if not methodOk then
        complete("invalid HTTP method", nil)
        return nil
    end
    local httpMethod = METHOD_MAP[method]
    if not httpMethod then
        complete("unsupported HTTP method: " .. tostring(method), nil)
        return nil
    end

    local createOk = pcall(function() client = httpManager:Create() end)
    if not createOk or client == nil then
        complete("http client unavailable in this runtime", nil)
        return nil
    end

    nextRequestId = nextRequestId + 1
    requestId = nextRequestId
    activeRequests[requestId] = { client = client, complete = complete }
    requestIdsByClient[client] = requestId

    local setupOk, setupError = pcall(function()
        client:SetUrl(request.url)
            :SetMethod(httpMethod)
            :SetTimeout(request.timeoutMs or 10000)

        for name, value in pairs(request.headers or {}) do
            client:AddHeader(tostring(name), tostring(value))
        end

        local body = tostring(request.body or "")
        if body ~= "" and (method == "POST" or method == "PUT" or method == "PATCH") then
            client:SetContentType((request.headers or {})["Content-Type"] or "application/json")
            client:SetBody(body)
        end

        client
            :OnSuccess(function(_, response)
                local handlerOk, handlerError = pcall(function()
                    if response == nil then error("missing HTTP success response") end
                    local status = response.statusCode or 0
                    local result = {
                        status = status,
                        success = response.success ~= false and status >= 200 and status < 300,
                        body = response.dataAsString or "",
                    }
                    if result.success then
                        complete(nil, result)
                    else
                        complete("HTTP " .. tostring(status), result)
                    end
                end)
                if not handlerOk then
                    local message = "success handler failed: " .. safeError(handlerError)
                    safePrint("[GameAlgoHttp] ", message)
                    complete(message, { status = 0, success = false, body = "", error = message })
                end
            end)
            :OnError(function(_, statusCode, errorMessage)
                local handlerOk, handlerError = pcall(function()
                    local message = errorMessage or ("HTTP " .. tostring(statusCode or 0))
                    complete(tostring(message), {
                        status = statusCode or 0,
                        success = false,
                        body = "",
                        error = errorMessage,
                    })
                end)
                if not handlerOk then
                    local message = "error handler failed: " .. safeError(handlerError)
                    safePrint("[GameAlgoHttp] ", message)
                    complete(message, {
                        status = statusCode or 0,
                        success = false,
                        body = "",
                        error = message,
                    })
                end
            end)
            :Send()
    end)

    if not setupOk then
        local message = "request setup failed: " .. safeError(setupError)
        safePrint("[GameAlgoHttp] ", message)
        complete(message, nil)
        return nil
    end

    return client
end

function HttpTransport.Cancel(client)
    local requestId = client and requestIdsByClient[client] or nil
    local active = requestId and activeRequests[requestId] or nil
    if not active then return false end

    local cancel = nil
    pcall(function() cancel = client.Cancel or client.Abort end)
    if type(cancel) == "function" then pcall(cancel, client) end
    active.complete("request cancelled", nil)
    return true
end

function HttpTransport.Diagnostics()
    local activeCount = 0
    for _ in pairs(activeRequests) do activeCount = activeCount + 1 end
    return { activeRequests = activeCount }
end

function HttpTransport.Update()
end

return HttpTransport
