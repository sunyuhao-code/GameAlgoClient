---@meta
--- ============================================================
--- GameAlgo.lua — TapTap 小游戏 Lua SDK 业务层
--- ============================================================
--- 职责：实验/配置读取、事件排队和上报。网络请求通过
---       ProxyTransport.lua 发给游戏服务端，再由 ProxyServer.lua
---       转发到 GameAlgo HTTP API。
---
--- 设计约束：
--- - 客户端不需要携带 X-GameAlgo-Key；推荐在 ProxyServer defaultHeaders
---   中由服务端注入。
--- - 初始化不阻塞游戏主流程；远端失败时本地默认值继续生效。
--- - Lua 版先不执行 JS 实验脚本，execute 返回 config-only 结果。
--- ============================================================

local cjson = require("cjson")

local okTransport, ProxyTransport = pcall(require, "sdk.ProxyTransport")
if not okTransport then
    ProxyTransport = require("ProxyTransport")
end

local GameAlgo = {}

local SDK_VERSION = "1.0.0-lua"
local DEFAULT_BASE_URL = "https://game-algo-sdk.dictapis.cn"

local state_ = {
    baseUrl = DEFAULT_BASE_URL,
    gameKey = nil,
    appVersion = nil,
    platform = "rest",
    timezone = nil,
    device = {},
    isDebug = false,
    userId = nil,
    userCreatedAt = nil,
    sessionId = nil,
    sessionStartMs = nil,
    contextId = nil,
    config = nil,
    configFiles = {},
    queue = {},
    maxBatchSize = 100,
    preloadConfigFiles = true,
    storage = nil,
    logger = nil,
}

local function log(message)
    local line = "[GameAlgoSDK] " .. tostring(message)
    if type(state_.logger) == "function" then
        state_.logger(line)
    else
        print(line)
    end
end

local function isoNow()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function nowMs()
    return math.floor(os.time() * 1000)
end

local function randomId(prefix)
    return (prefix or "id") .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
end

local function trimSlash(value)
    return tostring(value or ""):gsub("/+$", "")
end

local function urlEncode(value)
    return tostring(value):gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function storageGet(key)
    local storage = state_.storage
    if not storage then return nil end
    if type(storage.getItem) == "function" then
        local ok, value = pcall(storage.getItem, key)
        if ok then return value end
        ok, value = pcall(function() return storage:getItem(key) end)
        if ok then return value end
    end
    if type(storage.GetItem) == "function" then
        local ok, value = pcall(function() return storage:GetItem(key) end)
        if ok then return value end
    end
    return storage[key]
end

local function storageSet(key, value)
    local storage = state_.storage
    if not storage then return end
    if type(storage.setItem) == "function" then
        local ok = pcall(storage.setItem, key, value)
        if ok then return end
        ok = pcall(function() storage:setItem(key, value) end)
        if ok then return end
    end
    if type(storage.SetItem) == "function" then
        local ok = pcall(function() storage:SetItem(key, value) end)
        if ok then return end
    end
    storage[key] = value
end

local function ensureIdentity(explicitUserId)
    if explicitUserId and explicitUserId ~= "" then
        state_.userId = explicitUserId
        if not state_.userCreatedAt then
            state_.userCreatedAt = storageGet("gamealgo_user_created_at") or isoNow()
        end
    end

    if not state_.userId or state_.userId == "" then
        state_.userId = storageGet("gamealgo_user_id") or randomId("ga_user")
    end
    if not state_.userCreatedAt or state_.userCreatedAt == "" then
        state_.userCreatedAt = storageGet("gamealgo_user_created_at") or isoNow()
    end
    storageSet("gamealgo_user_id", state_.userId)
    storageSet("gamealgo_user_created_at", state_.userCreatedAt)
end

local function httpRequest(method, path, bodyTable, callback)
    callback = callback or function() end
    local headers = {
        ["Content-Type"] = "application/json",
    }
    if state_.gameKey and state_.gameKey ~= "" then
        headers["X-GameAlgo-Key"] = state_.gameKey
    end

    ProxyTransport.Request({
        method = method,
        url = trimSlash(state_.baseUrl) .. path,
        headers = headers,
        body = bodyTable and cjson.encode(bodyTable) or "",
    }, function(error, response)
        if error then
            callback(error, nil, response)
            return
        end
        local body = response and response.body or ""
        local decoded = nil
        if body ~= "" then
            local ok, value = pcall(cjson.decode, body)
            if ok then decoded = value end
        end
        callback(nil, decoded, response)
    end)
end

local function normalizePayload(payload)
    if type(payload) == "table" then return payload end
    return {}
end

local function currentAssignment(key)
    local config = state_.config
    local experiments = config and config.experiments or {}
    for _, item in ipairs(experiments) do
        if item.key == key then return item end
    end
    return nil
end

local function tablePath(root, path)
    local value = root
    for part in tostring(path or ""):gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
        if value == nil then return nil end
    end
    return value
end

local function chunkEvents()
    local batch = {}
    while #state_.queue > 0 and #batch < state_.maxBatchSize do
        table.insert(batch, table.remove(state_.queue, 1))
    end
    return batch
end

---@param options table
function GameAlgo.Init(options)
    options = options or {}
    math.randomseed(os.time())
    state_.baseUrl = options.baseUrl or DEFAULT_BASE_URL
    state_.gameKey = options.gameKey
    state_.appVersion = options.appVersion
    state_.platform = options.platform or "rest"
    state_.timezone = options.timezone
    state_.device = options.device or {}
    state_.isDebug = options.isDebug == true
    state_.storage = options.storage
    state_.logger = options.logger
    state_.maxBatchSize = options.maxBatchSize or 100
    state_.preloadConfigFiles = options.preloadConfigFiles ~= false
    state_.sessionId = options.sessionId or randomId("ga_session")
    state_.sessionStartMs = nowMs()
    ensureIdentity(options.userId)
    ProxyTransport.Start({
        eventPrefix = options.eventPrefix or "HttpProxy",
        waitForServerReady = options.waitForServerReady,
    })
    log("initialized: userId=" .. state_.userId .. ", sessionId=" .. state_.sessionId)
    if options.autoFetch ~= false then
        GameAlgo.FetchConfig(nil)
    end
    return GameAlgo
end

function GameAlgo.Update()
    ProxyTransport.Update()
end

function GameAlgo.FetchConfig(callback)
    ensureIdentity()
    local request = {
        userId = state_.userId,
        userCreatedAt = state_.userCreatedAt,
        sessionId = state_.sessionId,
        platform = state_.platform,
        sdkVersion = SDK_VERSION,
        appVersion = state_.appVersion,
        timezone = state_.timezone,
        device = state_.device,
    }
    httpRequest("POST", "/v1/config", request, function(error, config)
        if error then
            log("config fetch failed: " .. tostring(error))
            if callback then callback(error, nil) end
            return
        end
        state_.config = config
        state_.contextId = config and config.contextId or nil
        log("config fetched: version=" .. tostring(config and config.configVersion or "unknown"))
        if callback then callback(nil, config) end
        if state_.preloadConfigFiles and config then
            for _, file in ipairs(config.configFiles or {}) do
                if file.name then GameAlgo.FetchConfigFile(file.name, nil) end
            end
            for _, experiment in ipairs(config.experiments or {}) do
                if experiment.script and experiment.script.name then
                    GameAlgo.FetchConfigFile(experiment.script.name, nil)
                end
            end
        end
        GameAlgo.Flush(nil)
    end)
end

function GameAlgo.FetchConfigFile(name, callback)
    if not name or name == "" or tostring(name):find("..", 1, true) then
        if callback then callback("invalid config file name", nil) end
        return
    end
    httpRequest("GET", "/v1/config-files/" .. urlEncode(name), nil, function(error, decoded, response)
        if error then
            log("config file fetch failed: " .. tostring(name) .. " " .. tostring(error))
            if callback then callback(error, nil) end
            return
        end
        local file = {
            name = name,
            content = response and response.body or "",
        }
        state_.configFiles[name] = file
        log("config file loaded: " .. tostring(name))
        if callback then callback(nil, file) end
    end)
end

function GameAlgo.Track(eventType, payload)
    if not eventType or eventType == "" then return false end
    ensureIdentity()
    table.insert(state_.queue, {
        eventId = randomId("ga_event"),
        contextId = state_.contextId or "",
        userId = state_.userId,
        sessionId = state_.sessionId,
        eventType = eventType,
        isDebug = state_.isDebug,
        timestamp = isoNow(),
        payload = normalizePayload(payload),
    })
    return true
end

function GameAlgo.TrackEvent(name, payload)
    local eventType = tostring(name or "")
    if eventType ~= "" and eventType:sub(1, 1) ~= "_" then
        eventType = "_" .. eventType
    end
    return GameAlgo.Track(eventType, payload)
end

function GameAlgo.TrackLevelStart(payload)
    return GameAlgo.Track("level_start", payload)
end

function GameAlgo.TrackLevelEnd(payload)
    return GameAlgo.Track("level_end", payload)
end

function GameAlgo.TrackAd(placement, adType, revenue, currency, network, payload)
    if type(network) == "table" and payload == nil then
        payload = network
        network = nil
    end
    local merged = normalizePayload(payload)
    merged.placement = placement
    merged.adType = adType
    merged.revenue = revenue
    merged.currency = currency
    if network and network ~= "" then merged.network = network end
    return GameAlgo.Track("ad_view", merged)
end

function GameAlgo.TrackPurchase(productId, revenue, currency, payload)
    local merged = normalizePayload(payload)
    if productId then merged.productId = productId end
    if revenue ~= nil then merged.revenue = revenue end
    if currency then merged.currency = currency end
    return GameAlgo.Track("purchase", merged)
end

function GameAlgo.TrackSessionEnd(payload)
    local merged = normalizePayload(payload)
    if merged.sessionDurationMs == nil and state_.sessionStartMs then
        merged.sessionDurationMs = nowMs() - state_.sessionStartMs
    end
    return GameAlgo.Track("session_end", merged)
end

function GameAlgo.Flush(callback)
    if not state_.contextId or state_.contextId == "" then
        if callback then callback("context not ready", nil) end
        return
    end
    if #state_.queue == 0 then
        if callback then callback(nil, { ok = true, accepted = 0 }) end
        return
    end

    local batch = chunkEvents()
    for _, event in ipairs(batch) do
        event.contextId = state_.contextId
    end
    httpRequest("POST", "/v1/events/batch", { events = batch }, function(error, result)
        if error then
            for i = #batch, 1, -1 do
                table.insert(state_.queue, 1, batch[i])
            end
            log("flush failed: " .. tostring(error))
            if callback then callback(error, nil) end
            return
        end
        log("flush ok: accepted=" .. tostring(result and result.accepted or #batch))
        if callback then callback(nil, result) end
    end)
end

function GameAlgo.Executor(key)
    local executor = {}

    function executor.Variant(defaultValue)
        local item = currentAssignment(key)
        return item and item.variant or defaultValue
    end

    function executor.Value(path, defaultValue)
        local item = currentAssignment(key)
        local value = item and tablePath(item.config, path)
        if value == nil then return defaultValue end
        return value
    end

    function executor.Execute(input)
        local item = currentAssignment(key)
        if not item then return nil end
        return {
            variant = item.variant,
            payload = item.config or {},
            diagnostics = {
                luaSdk = "config_only",
                script = item.script and item.script.name or nil,
            },
            input = input,
        }
    end

    return executor
end

function GameAlgo.ConfigValue(path, defaultValue, fileName)
    if not fileName then return defaultValue end
    local file = state_.configFiles[fileName]
    if not file or not file.content or file.content == "" then return defaultValue end
    local ok, decoded = pcall(cjson.decode, file.content)
    if not ok then return defaultValue end
    local value = tablePath(decoded, path)
    if value == nil then return defaultValue end
    return value
end

function GameAlgo.Snapshot()
    return {
        userId = state_.userId,
        userCreatedAt = state_.userCreatedAt,
        sessionId = state_.sessionId,
        contextId = state_.contextId,
        config = state_.config,
        configFiles = state_.configFiles,
        queuedEvents = #state_.queue,
    }
end

return GameAlgo
