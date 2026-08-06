---@meta
--- ============================================================
--- GameAlgo.lua — TapTap 小游戏 Lua SDK 业务层
--- ============================================================
--- 职责：实验/配置读取、事件排队和上报。网络请求由客户端直接
---       调用 GameAlgo HTTP API。
---
--- 设计约束：
--- - Client Game Key 通过 X-GameAlgo-Key 随请求发送。
--- - 初始化不阻塞游戏主流程；远端失败时本地默认值继续生效。
--- - Lua 实验脚本按不可变 versionId 下载、校验后在受限环境执行。
--- ============================================================

local cjson = require("cjson")

local function requireSdkModule(name)
    local ok, value = pcall(require, "sdk." .. name)
    if ok then return value end
    return require(name)
end

local HttpTransport = requireSdkModule("HttpTransport")
local LuaScriptRuntime = requireSdkModule("LuaScriptRuntime")
local Sha256 = requireSdkModule("Sha256")
local DDA = requireSdkModule("DDA")

local GameAlgo = {}

local SDK_VERSION = "1.3.2-lua"
local DEFAULT_BASE_URL = "https://game-algo-sdk.dictapis.cn"

local state_ = {
    baseUrl = DEFAULT_BASE_URL,
    gameKey = nil,
    appVersion = nil,
    experimentIntegrationVersion = 0,
    platform = "rest",
    timezone = nil,
    device = {},
    isDebug = false,
    userId = nil,
    userCreatedAt = nil,
    userCreatedLocalAt = nil,
    sessionId = nil,
    sessionStartMs = nil,
    contextId = nil,
    config = nil,
    configFiles = {},
    scripts = {},
    ddaControllers = {},
    queue = {},
    flushing = false,
    flushRequested = false,
    pendingFlushCallbacks = {},
    maxBatchSize = 100,
    preloadConfigFiles = true,
    storage = nil,
    logger = nil,
    transport = HttpTransport,
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

local function localIsoNow(timestamp)
    timestamp = timestamp or os.time()
    local offset = os.date("%z", timestamp)
    if type(offset) == "string" and offset:match("^[+-]%d%d%d%d$") then
        offset = offset:sub(1, 3) .. ":" .. offset:sub(4, 5)
    else
        local localTime = os.date("*t", timestamp)
        local utcTime = os.date("!*t", timestamp)
        utcTime.isdst = localTime.isdst
        local offsetSeconds = os.difftime(os.time(localTime), os.time(utcTime))
        local sign = offsetSeconds >= 0 and "+" or "-"
        local absoluteMinutes = math.floor(math.abs(offsetSeconds) / 60)
        offset = string.format("%s%02d:%02d", sign, math.floor(absoluteMinutes / 60), absoluteMinutes % 60)
    end
    return os.date("%Y-%m-%dT%H:%M:%S", timestamp) .. offset
end

local function localIsoFromUtc(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not year then return nil end
    local interpretedAsLocal = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second),
        isdst = false,
    })
    if not interpretedAsLocal then return nil end
    local utcParts = os.date("!*t", interpretedAsLocal)
    local localParts = os.date("*t", interpretedAsLocal)
    utcParts.isdst = localParts.isdst
    local utcAsLocal = os.time(utcParts)
    if not utcAsLocal then return nil end
    local utcTimestamp = interpretedAsLocal + os.difftime(interpretedAsLocal, utcAsLocal)
    return localIsoNow(utcTimestamp)
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

local function hasStorageMethod(storage, name)
    local ok, method = pcall(function() return storage[name] end)
    return ok and type(method) == "function"
end

local function validateStorage(storage)
    if storage == nil then
        error(
            "options.storage is required; bind getItem(key) and setItem(key, value) "
                .. "to the game's persistent local or online save storage"
        )
    end

    local hasCamelCase = hasStorageMethod(storage, "getItem")
        and hasStorageMethod(storage, "setItem")
    local hasPascalCase = hasStorageMethod(storage, "GetItem")
        and hasStorageMethod(storage, "SetItem")
    if not hasCamelCase and not hasPascalCase then
        error(
            "options.storage must implement getItem(key)/setItem(key, value) "
                .. "or GetItem(key)/SetItem(key, value)"
        )
    end
end

local function ensureIdentity(explicitUserId)
    if explicitUserId and explicitUserId ~= "" then
        state_.userId = explicitUserId
        if not state_.userCreatedAt then
            state_.userCreatedAt = storageGet("gamealgo_user_created_at") or isoNow()
        end
        if not state_.userCreatedLocalAt then
            state_.userCreatedLocalAt = storageGet("gamealgo_user_created_local_at")
                or localIsoFromUtc(state_.userCreatedAt)
                or localIsoNow()
        end
    end

    if not state_.userId or state_.userId == "" then
        state_.userId = storageGet("gamealgo_user_id") or randomId("ga_user")
    end
    if not state_.userCreatedAt or state_.userCreatedAt == "" then
        state_.userCreatedAt = storageGet("gamealgo_user_created_at") or isoNow()
    end
    if not state_.userCreatedLocalAt or state_.userCreatedLocalAt == "" then
        state_.userCreatedLocalAt = storageGet("gamealgo_user_created_local_at")
            or localIsoFromUtc(state_.userCreatedAt)
            or localIsoNow()
    end
    storageSet("gamealgo_user_id", state_.userId)
    storageSet("gamealgo_user_created_at", state_.userCreatedAt)
    storageSet("gamealgo_user_created_local_at", state_.userCreatedLocalAt)
end

local function httpRequest(method, path, bodyTable, callback)
    callback = callback or function() end
    local headers = {
        ["Content-Type"] = "application/json",
    }
    if state_.gameKey and state_.gameKey ~= "" then
        headers["X-GameAlgo-Key"] = state_.gameKey
    end

    state_.transport.Request({
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

local function rawHttpRequest(method, url, callback)
    callback = callback or function() end
    local headers = {}
    if state_.gameKey and state_.gameKey ~= "" then headers["X-GameAlgo-Key"] = state_.gameKey end
    state_.transport.Request({
        method = method,
        url = tostring(url or ""),
        headers = headers,
        body = "",
    }, callback)
end

local function normalizePayload(payload)
    if type(payload) == "table" then return payload end
    return {}
end

local function decodeJsonObject(value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" then return nil end
    if not tostring(value):find("{", 1, true) then return nil end
    local ok, decoded = pcall(cjson.decode, value)
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function nonEmptyString(value)
    if value == nil or value == "" then return nil end
    return tostring(value)
end

local function currentAssignment(key)
    local config = state_.config
    local experiments = config and config.experiments or {}
    for _, item in ipairs(experiments) do
        if item.key == key then return item end
    end
    return nil
end

local function scriptCacheKey(script)
    if not script then return nil end
    if script.versionId and script.versionId ~= "" then return "version:" .. tostring(script.versionId) end
    if script.name and script.name ~= "" then return "name:" .. tostring(script.name) end
    return nil
end

local function scriptStorageKey(script)
    local key = scriptCacheKey(script)
    return key and ("gamealgo_lua_script_" .. key) or nil
end

local function isLuaScript(script)
    if not script then return false end
    local name = tostring(script.name or ""):lower()
    local contentType = tostring(script.contentType or ""):lower()
    return name:sub(-4) == ".lua" or contentType:find("lua", 1, true) ~= nil
end

local function verifyScript(script, content)
    if not script or not script.hash or script.hash == "" then return false, "script hash is required" end
    local actual = Sha256.hash(content)
    if tostring(script.hash):lower() ~= actual then
        return false, "script hash mismatch: expected " .. tostring(script.hash) .. ", got " .. actual
    end
    return true, nil
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
    validateStorage(options.storage)
    math.randomseed(os.time())
    state_.baseUrl = options.baseUrl or DEFAULT_BASE_URL
    state_.gameKey = options.gameKey
    state_.appVersion = options.appVersion
    state_.experimentIntegrationVersion = tonumber(options.experimentIntegrationVersion) or 0
    if state_.experimentIntegrationVersion < 0 or state_.experimentIntegrationVersion % 1 ~= 0 then
        error("experimentIntegrationVersion must be a non-negative integer")
    end
    state_.platform = options.platform or "rest"
    state_.timezone = options.timezone
    state_.device = options.device or {}
    state_.isDebug = options.isDebug == true
    state_.storage = options.storage
    state_.logger = options.logger
    state_.transport = options.transport or HttpTransport
    state_.maxBatchSize = options.maxBatchSize or 100
    state_.preloadConfigFiles = options.preloadConfigFiles ~= false
    state_.sessionId = options.sessionId or randomId("ga_session")
    state_.sessionStartMs = nowMs()
    ensureIdentity(options.userId)
    if type(state_.transport.Start) == "function" then state_.transport.Start(options.transportOptions) end
    if not state_.gameKey or state_.gameKey == "" then
        log("missing gameKey; config and event requests will be rejected")
    end
    log("initialized: userId=" .. state_.userId .. ", sessionId=" .. state_.sessionId)
    if options.autoFetch ~= false then
        GameAlgo.FetchConfig(nil)
    end
    return GameAlgo
end

function GameAlgo.Update()
    if type(state_.transport.Update) == "function" then state_.transport.Update() end
end

function GameAlgo.FetchConfig(callback)
    ensureIdentity()
    local request = {
        userId = state_.userId,
        userCreatedAt = state_.userCreatedAt,
        userCreatedLocalAt = state_.userCreatedLocalAt,
        createdLocalAt = localIsoNow(),
        sessionId = state_.sessionId,
        platform = state_.platform,
        sdkVersion = SDK_VERSION,
        appVersion = state_.appVersion,
        experimentIntegrationVersion = state_.experimentIntegrationVersion,
        timezone = state_.timezone,
        device = state_.device,
        isDebug = state_.isDebug,
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
                if experiment.script then GameAlgo.FetchScript(experiment.script, nil) end
            end
        end
        GameAlgo.Flush(nil)
    end)
end


function GameAlgo.FetchScript(script, callback)
    callback = callback or function() end
    if type(script) ~= "table" then callback("invalid script reference", nil) return end
    if not isLuaScript(script) then callback("unsupported Lua SDK script type: " .. tostring(script.name), nil) return end
    local cacheKey = scriptCacheKey(script)
    if not cacheKey then callback("script versionId or name is required", nil) return end

    local cached = state_.scripts[cacheKey]
    if cached then callback(nil, cached) return end

    local persisted = storageGet(scriptStorageKey(script))
    if persisted and persisted ~= "" then
        local valid = verifyScript(script, persisted)
        if valid then
            local file = { name = script.name, versionId = script.versionId, content = persisted, contentType = script.contentType, hash = script.hash }
            state_.scripts[cacheKey] = file
            log("script cache ready: " .. tostring(script.name) .. "@" .. tostring(script.versionId or "name"))
            callback(nil, file)
            return
        end
    end

    local url = script.url
    if not url or url == "" then callback("script url is required", nil) return end
    if tostring(url):sub(1, 1) == "/" then url = trimSlash(state_.baseUrl) .. tostring(url) end
    rawHttpRequest("GET", url, function(error, response)
        if error then
            log("script fetch failed: " .. tostring(script.name) .. " " .. tostring(error))
            callback(error, nil)
            return
        end
        local content = response and response.body or ""
        local valid, verifyError = verifyScript(script, content)
        if not valid then
            log("script verify failed: " .. tostring(script.name) .. " " .. tostring(verifyError))
            callback(verifyError, nil)
            return
        end
        local file = { name = script.name, versionId = script.versionId, content = content, contentType = script.contentType, hash = script.hash }
        state_.scripts[cacheKey] = file
        storageSet(scriptStorageKey(script), content)
        log("script ready: " .. tostring(script.name) .. "@" .. tostring(script.versionId or "name"))
        callback(nil, file)
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
        createdLocalAt = localIsoNow(),
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

function GameAlgo.ExtractAdTrackId(result)
    if type(result) ~= "table" then return nil end
    local direct = nonEmptyString(result.trackId or result.track_id)
    if direct then return direct end

    local extra = decodeJsonObject(result.extra)
    if extra then
        local trackId = nonEmptyString(extra.trackId or extra.track_id)
        if trackId then return trackId end
    end

    local message = decodeJsonObject(result.msg or result.message)
    if message then
        local trackId = nonEmptyString(message.trackId or message.track_id)
        if trackId then return trackId end
    end
    return nil
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
    local tracked = GameAlgo.Track("ad_view", merged)
    if tracked then GameAlgo.Flush(nil) end
    return tracked
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
    if state_.flushing then
        state_.flushRequested = true
        if callback then table.insert(state_.pendingFlushCallbacks, callback) end
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
    state_.flushing = true
    httpRequest("POST", "/v1/events/batch", { events = batch }, function(error, result)
        state_.flushing = false
        local flushRequested = state_.flushRequested
        local pendingCallbacks = state_.pendingFlushCallbacks
        state_.flushRequested = false
        state_.pendingFlushCallbacks = {}

        if error then
            for i = #batch, 1, -1 do
                table.insert(state_.queue, 1, batch[i])
            end
            log("flush failed: " .. tostring(error))
            if callback then callback(error, nil) end
            for _, pendingCallback in ipairs(pendingCallbacks) do
                pendingCallback(error, nil)
            end
            return
        end
        log("flush ok: accepted=" .. tostring(result and result.accepted or #batch))
        if callback then callback(nil, result) end
        if flushRequested then
            GameAlgo.Flush(function(nextError, nextResult)
                for _, pendingCallback in ipairs(pendingCallbacks) do
                    pendingCallback(nextError, nextResult)
                end
            end)
        else
            for _, pendingCallback in ipairs(pendingCallbacks) do
                pendingCallback(nil, { ok = true, accepted = 0 })
            end
        end
    end)
end

function GameAlgo.Executor(key)
    local executor = {}

    function executor.IsReady()
        local item = currentAssignment(key)
        if not item then return false end
        if not item.script then return true end
        local cacheKey = scriptCacheKey(item.script)
        return cacheKey ~= nil and state_.scripts[cacheKey] ~= nil
    end

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
        if item.script then
            if not isLuaScript(item.script) then
                log("execute skipped: unsupported script type: " .. tostring(item.script.name))
                return nil
            end
            local cacheKey = scriptCacheKey(item.script)
            local file = cacheKey and state_.scripts[cacheKey] or nil
            if not file then
                log("execute skipped: script not loaded: " .. tostring(item.key) .. " -> " .. tostring(item.script.name))
                return nil
            end
            local scriptInput = {
                state = normalizePayload(input),
                config = normalizePayload(item.config),
                meta = {
                    gameId = state_.config and state_.config.gameId or "",
                    userId = state_.userId or "",
                    environment = state_.config and state_.config.environment or "live",
                    strategy = item.key,
                    experimentId = item.experimentId,
                    variant = item.variant,
                },
            }
            local result, executeError = LuaScriptRuntime.Execute(file.content, scriptInput, {
                chunkName = "@gamealgo:" .. tostring(item.script.versionId or item.script.name),
            })
            if not result then
                log("execute failed: " .. tostring(item.key) .. " " .. tostring(executeError))
                return nil
            end
            local serializable = pcall(cjson.encode, result)
            if not serializable then
                log("execute failed: result is not JSON serializable: " .. tostring(item.key))
                return nil
            end
            return {
                variant = item.variant,
                payload = result.payload,
                diagnostics = result.diagnostics or {},
                assignment = item,
            }
        end
        return {
            variant = item.variant,
            payload = item.config or {},
            diagnostics = {
                luaSdk = "config_only",
            },
            input = input,
        }
    end

    return executor
end

function GameAlgo.DDA(key, options)
    key = tostring(key or "")
    if key == "" then error("DDA strategy key is required") end
    if state_.ddaControllers[key] then return state_.ddaControllers[key] end
    options = options or {}
    local gameKeyPrefix = tostring(state_.gameKey or "anonymous"):sub(1, 16)
    local controller = DDA.New({
        executor = GameAlgo.Executor(key),
        storageKey = options.storageKey or ("gamealgo:v1:dda:" .. gameKeyPrefix .. ":" .. key),
        recentWindowSize = options.recentWindowSize,
        storageGet = storageGet,
        storageSet = storageSet,
    })
    state_.ddaControllers[key] = controller
    return controller
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
        userCreatedLocalAt = state_.userCreatedLocalAt,
        sessionId = state_.sessionId,
        contextId = state_.contextId,
        config = state_.config,
        configFiles = state_.configFiles,
        scripts = state_.scripts,
        queuedEvents = #state_.queue,
    }
end

return GameAlgo
