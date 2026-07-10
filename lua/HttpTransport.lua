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

function HttpTransport.Start()
end

---@param request table
---@param callback fun(error:string|nil,response:table|nil)
function HttpTransport.Request(request, callback)
    callback = callback or function() end
    local method = tostring(request.method or "GET"):upper()
    local httpMethod = METHOD_MAP[method]
    if not httpMethod then
        callback("unsupported HTTP method: " .. method, nil)
        return nil
    end

    local client = http:Create()
        :SetUrl(request.url)
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
            local status = response.statusCode or 0
            local result = {
                status = status,
                success = response.success ~= false and status >= 200 and status < 300,
                body = response.dataAsString or "",
            }
            if result.success then
                callback(nil, result)
            else
                callback("HTTP " .. tostring(status), result)
            end
        end)
        :OnError(function(_, statusCode, error)
            callback(tostring(error or ("HTTP " .. tostring(statusCode or 0))), {
                status = statusCode or 0,
                success = false,
                body = "",
                error = error,
            })
        end)
        :Send()

    return client
end

function HttpTransport.Update()
end

return HttpTransport
