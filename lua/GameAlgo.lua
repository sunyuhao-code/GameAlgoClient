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
local MakerAutoStorage = requireSdkModule("MakerAutoStorage")

local GameAlgo = {}
local unpackArgs = table.unpack or unpack

local SDK_VERSION = "1.4.1-lua"
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
    accountUserId = nil,
    accountUserCreatedAt = nil,
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
    storageReady = false,
    initializationComplete = false,
    fetchConfigRequested = false,
    pendingFetchConfigCallbacks = {},
    pendingTracks = {},
    consecutiveFlushFailures = 0,
    queuePersistenceActive = false,
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
    local ok, value = pcall(function() return storage:GetItem(key) end)
    if ok then return value end
    return nil
end

local function storageSet(key, value)
    local storage = state_.storage
    if not storage then return end
    pcall(function() storage:SetItem(key, value) end)
end

local function gameStorageNamespace()
    return "gamealgo:v2:game:" .. Sha256.hex(tostring(state_.gameKey or "anonymous"))
end

local function identityStorageKey(name)
    return gameStorageNamespace() .. ":identity:" .. tostring(name)
end

local function userStorageNamespace()
    return gameStorageNamespace() .. ":user:" .. Sha256.hex(tostring(state_.userId or "anonymous"))
end

local function queueStorageKey()
    return userStorageNamespace() .. ":events:jsonl"
end

local function resolveMakerUserId()
    -- Maker exposes some globals through the Lua environment metatable, so the
    -- lookup must preserve the environment's normal index behavior.
    local okLobby, makerLobby = pcall(function() return lobby end)
    if not okLobby or makerLobby == nil then return nil end

    local okGetter, getter = pcall(function() return makerLobby.GetMyUserId end)
    if not okGetter or type(getter) ~= "function" then return nil end

    local okUserId, userId = pcall(function() return makerLobby:GetMyUserId() end)
    if not okUserId or userId == nil then return nil end

    local normalized = tostring(userId)
    if normalized == "" then return nil end
    return normalized
end

local function ensureIdentity(explicitUserId)
    if explicitUserId and explicitUserId ~= "" then
        state_.userId = tostring(explicitUserId)
        if not state_.userCreatedAt then
            state_.userCreatedAt = storageGet(identityStorageKey("user_created_at"))
                or storageGet("gamealgo_user_created_at")
                or isoNow()
        end
        if not state_.userCreatedLocalAt then
            state_.userCreatedLocalAt = storageGet(identityStorageKey("user_created_local_at"))
                or storageGet("gamealgo_user_created_local_at")
                or localIsoFromUtc(state_.userCreatedAt)
                or localIsoNow()
        end
    end

    if not state_.userId or state_.userId == "" then
        state_.userId = storageGet(identityStorageKey("user_id"))
            or storageGet("gamealgo_user_id")
            or randomId("ga_user")
    end
    if not state_.userCreatedAt or state_.userCreatedAt == "" then
        state_.userCreatedAt = storageGet(identityStorageKey("user_created_at"))
            or storageGet("gamealgo_user_created_at")
            or isoNow()
    end
    if not state_.userCreatedLocalAt or state_.userCreatedLocalAt == "" then
        state_.userCreatedLocalAt = storageGet(identityStorageKey("user_created_local_at"))
            or storageGet("gamealgo_user_created_local_at")
            or localIsoFromUtc(state_.userCreatedAt)
            or localIsoNow()
    end
    storageSet(identityStorageKey("user_id"), state_.userId)
    storageSet(identityStorageKey("user_created_at"), state_.userCreatedAt)
    storageSet(identityStorageKey("user_created_local_at"), state_.userCreatedLocalAt)
end

local function ensureAccountIdentity(explicitAccountUserId, explicitCreatedAt)
    local accountUserId = explicitAccountUserId
    if accountUserId == nil or accountUserId == "" then accountUserId = resolveMakerUserId() end
    if accountUserId == nil or accountUserId == "" then
        state_.accountUserId = nil
        state_.accountUserCreatedAt = nil
        return
    end

    state_.accountUserId = tostring(accountUserId)
    local accountKey = identityStorageKey("account_created_at:" .. Sha256.hex(state_.accountUserId))
    state_.accountUserCreatedAt = explicitCreatedAt
        or storageGet(accountKey)
    if state_.accountUserCreatedAt and state_.accountUserCreatedAt ~= "" then
        storageSet(accountKey, state_.accountUserCreatedAt)
    end
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

local function snapshotJsonValue(value, seen, path)
    local valueType = type(value)
    if value == nil or valueType == "string" or valueType == "boolean" then return value, nil end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil, tostring(path) .. " contains a non-finite number"
        end
        return value, nil
    end
    if valueType ~= "table" then
        return nil, tostring(path) .. " contains unsupported " .. valueType
    end
    if seen[value] then return nil, tostring(path) .. " contains a cycle" end

    seen[value] = true
    local copy = {}
    for key, item in pairs(value) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            seen[value] = nil
            return nil, tostring(path) .. " contains unsupported key type " .. keyType
        end
        if keyType == "number" and (key < 1 or key % 1 ~= 0) then
            seen[value] = nil
            return nil, tostring(path) .. " contains a non-positive or fractional array key"
        end
        local itemCopy, itemError = snapshotJsonValue(item, seen, tostring(path) .. "." .. tostring(key))
        if itemError then
            seen[value] = nil
            return nil, itemError
        end
        copy[key] = itemCopy
    end
    seen[value] = nil
    return copy, nil
end

local function normalizePayload(payload)
    if payload == nil then return {}, nil end
    if type(payload) ~= "table" then return nil, "payload must be a table" end
    return snapshotJsonValue(payload, {}, "payload")
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
    return nil
end

local function scriptStorageKey(script)
    local key = scriptCacheKey(script)
    return key and (gameStorageNamespace() .. ":script:" .. key) or nil
end

local function legacyScriptStorageKey(script)
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
    local remaining = {}
    for _, event in ipairs(state_.queue) do
        if #batch < state_.maxBatchSize and event.contextId and event.contextId ~= "" then
            table.insert(batch, event)
        else
            table.insert(remaining, event)
        end
    end
    state_.queue = remaining
    return batch
end

local function persistEventQueue()
    if not state_.storageReady or not state_.userId then return end
    if #state_.queue == 0 then
        storageSet(queueStorageKey(), "")
        return
    end
    local lines = {}
    for _, event in ipairs(state_.queue) do
        local ok, encoded = pcall(cjson.encode, event)
        if ok then table.insert(lines, encoded) end
    end
    storageSet(queueStorageKey(), table.concat(lines, "\n"))
end

local function restoreEventQueue()
    local encoded = storageGet(queueStorageKey())
    if type(encoded) ~= "string" or encoded == "" then return end
    local restored = 0
    for line in encoded:gmatch("[^\r\n]+") do
        local ok, event = pcall(cjson.decode, line)
        if ok and type(event) == "table" and event.eventId and event.contextId and event.contextId ~= "" then
            table.insert(state_.queue, event)
            restored = restored + 1
        end
    end
    if restored > 0 then
        state_.queuePersistenceActive = true
        log("restored persisted events: " .. tostring(restored))
    else
        storageSet(queueStorageKey(), "")
    end
end

local function bindQueuedEvents(contextId, sessionId)
    if not contextId or contextId == "" then return end
    for _, event in ipairs(state_.queue) do
        if (not event.contextId or event.contextId == "") and event.sessionId == sessionId then
            event.contextId = contextId
        end
    end
    if state_.queuePersistenceActive then persistEventQueue() end
end

local function enqueueTrack(eventType, payload, timestamp, createdLocalAt)
    local payloadCopy, payloadError = normalizePayload(payload)
    if payloadError then return false, payloadError end
    table.insert(state_.queue, {
        eventId = randomId("ga_event"),
        contextId = state_.contextId or "",
        userId = state_.userId,
        accountUserId = state_.accountUserId,
        sessionId = state_.sessionId,
        eventType = eventType,
        isDebug = state_.isDebug,
        timestamp = timestamp or isoNow(),
        createdLocalAt = createdLocalAt or localIsoNow(),
        payload = payloadCopy,
    })
    if state_.queuePersistenceActive then persistEventQueue() end
    return true, nil
end

local function flushAutomaticStorage()
    if not state_.storage or type(state_.storage.Flush) ~= "function" then return end
    state_.storage:Flush(function(error)
        if error then log("automatic storage flush failed: " .. tostring(error)) end
    end)
end

local function completeInitialization(options)
    if state_.initializationComplete then return end
    state_.storageReady = true
    state_.initializationComplete = true

    ensureIdentity(options.userId)
    ensureAccountIdentity(options.accountUserId, options.accountUserCreatedAt)
    restoreEventQueue()

    for _, controller in pairs(state_.ddaControllers) do
        if type(controller._Hydrate) == "function" then controller._Hydrate() end
    end
    for _, pending in ipairs(state_.pendingTracks) do
        local tracked, trackError = enqueueTrack(pending.eventType, pending.payload, pending.timestamp, pending.createdLocalAt)
        if not tracked then log("pending event dropped: " .. tostring(trackError)) end
    end
    state_.pendingTracks = {}

    if type(state_.transport.Start) == "function" then state_.transport.Start(options.transportOptions) end
    if not state_.gameKey or state_.gameKey == "" then
        log("missing gameKey; config and event requests will be rejected")
    end
    log("initialized: userId=" .. state_.userId
        .. ", accountUserId=" .. tostring(state_.accountUserId or "-")
        .. ", sessionId=" .. state_.sessionId)
    flushAutomaticStorage()

    if state_.fetchConfigRequested then
        local callbacks = state_.pendingFetchConfigCallbacks
        state_.pendingFetchConfigCallbacks = {}
        GameAlgo.FetchConfig(function(error, config)
            for _, callback in ipairs(callbacks) do callback(error, config) end
        end)
    end
end

---@param options table
function GameAlgo.Init(options)
    options = options or {}
    if options.storage ~= nil then
        error("options.storage is not supported; TapTap Maker storage is managed automatically by the Lua SDK")
    end
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
    state_.logger = options.logger
    state_.transport = options.transport or HttpTransport
    state_.maxBatchSize = options.maxBatchSize or 100
    state_.preloadConfigFiles = options.preloadConfigFiles ~= false
    state_.sessionId = options.sessionId or randomId("ga_session")
    state_.sessionStartMs = nowMs()
    state_.userId = nil
    state_.userCreatedAt = nil
    state_.userCreatedLocalAt = nil
    state_.accountUserId = nil
    state_.accountUserCreatedAt = nil
    state_.contextId = nil
    state_.config = nil
    state_.configFiles = {}
    state_.scripts = {}
    state_.ddaControllers = {}
    state_.queue = {}
    state_.pendingTracks = {}
    state_.consecutiveFlushFailures = 0
    state_.queuePersistenceActive = false
    state_.flushing = false
    state_.flushRequested = false
    state_.pendingFlushCallbacks = {}
    state_.storageReady = false
    state_.initializationComplete = false
    state_.fetchConfigRequested = options.autoFetch ~= false
    state_.pendingFetchConfigCallbacks = {}

    local storage, storageError = MakerAutoStorage.New({
        logger = log,
    })
    if not storage then error(storageError) end
    state_.storage = storage
    storage:OnReady(function() completeInitialization(options) end)
    return GameAlgo
end

function GameAlgo.Update()
    if type(state_.transport.Update) == "function" then state_.transport.Update() end
end

function GameAlgo.FetchConfig(callback)
    if not state_.storageReady then
        state_.fetchConfigRequested = true
        if type(callback) == "function" then table.insert(state_.pendingFetchConfigCallbacks, callback) end
        return
    end
    ensureIdentity()
    local request = {
        userId = state_.userId,
        userCreatedAt = state_.userCreatedAt,
        userCreatedLocalAt = state_.userCreatedLocalAt,
        accountUserId = state_.accountUserId,
        accountUserCreatedAt = state_.accountUserCreatedAt,
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
        bindQueuedEvents(state_.contextId, state_.sessionId)
        log("config fetched: version=" .. tostring(config and config.configVersion or "unknown"))
        if callback then callback(nil, config) end
        if state_.preloadConfigFiles and config then
            for _, file in ipairs(config.configFiles or {}) do
                if file.name then GameAlgo.FetchConfigFile(file.name, nil) end
            end
            for _, experiment in ipairs(config.experiments or {}) do
                if experiment.script then
                    GameAlgo.FetchScript(experiment.script, function(scriptError)
                        if scriptError then
                            log("script preload failed: name=" .. tostring(experiment.script.name)
                                .. ", versionId=" .. tostring(experiment.script.versionId)
                                .. ", error=" .. tostring(scriptError))
                        end
                    end)
                end
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
    if not cacheKey then callback("script versionId is required", nil) return end

    local cached = state_.scripts[cacheKey]
    if cached then callback(nil, cached) return end

    local persisted = storageGet(scriptStorageKey(script))
        or storageGet(legacyScriptStorageKey(script))
    if persisted and persisted ~= "" then
        local valid = verifyScript(script, persisted)
        if valid then
            local file = { name = script.name, versionId = script.versionId, content = persisted, contentType = script.contentType, hash = script.hash }
            state_.scripts[cacheKey] = file
            storageSet(scriptStorageKey(script), persisted)
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
    local payloadCopy, payloadError = normalizePayload(payload)
    if payloadError then
        log("event rejected: " .. tostring(eventType) .. " " .. tostring(payloadError))
        return false, payloadError
    end
    if not state_.storageReady then
        table.insert(state_.pendingTracks, {
            eventType = eventType,
            payload = payloadCopy,
            timestamp = isoNow(),
            createdLocalAt = localIsoNow(),
        })
        return true
    end
    ensureIdentity()
    return enqueueTrack(eventType, payloadCopy, nil, nil)
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
    local merged, payloadError = normalizePayload(payload)
    if payloadError then return false, payloadError end
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
    local merged, payloadError = normalizePayload(payload)
    if payloadError then return false, payloadError end
    if productId then merged.productId = productId end
    if revenue ~= nil then merged.revenue = revenue end
    if currency then merged.currency = currency end
    return GameAlgo.Track("purchase", merged)
end

function GameAlgo.TrackSessionEnd(payload)
    local merged, payloadError = normalizePayload(payload)
    if payloadError then return false, payloadError end
    if merged.sessionDurationMs == nil and state_.sessionStartMs then
        merged.sessionDurationMs = nowMs() - state_.sessionStartMs
    end
    return GameAlgo.Track("session_end", merged)
end

function GameAlgo.Flush(callback)
    flushAutomaticStorage()
    if not state_.storageReady then
        if callback then callback("storage not ready", nil) end
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
    if #batch == 0 then
        if callback then callback("context not ready", nil) end
        return
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
            state_.consecutiveFlushFailures = state_.consecutiveFlushFailures + 1
            if state_.consecutiveFlushFailures >= 3 then
                state_.queuePersistenceActive = true
                persistEventQueue()
                flushAutomaticStorage()
            end
            log("flush failed: " .. tostring(error))
            if callback then callback(error, nil) end
            for _, pendingCallback in ipairs(pendingCallbacks) do
                pendingCallback(error, nil)
            end
            return
        end
        state_.consecutiveFlushFailures = 0
        if state_.queuePersistenceActive then
            persistEventQueue()
            flushAutomaticStorage()
            if #state_.queue == 0 then state_.queuePersistenceActive = false end
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

function GameAlgo.NewSession(sessionId, callback)
    local nextSessionId = sessionId or randomId("ga_session")
    local retained = {}
    for _, event in ipairs(state_.queue) do
        if event.contextId and event.contextId ~= "" then table.insert(retained, event) end
    end
    state_.queue = retained
    state_.sessionId = nextSessionId
    state_.sessionStartMs = nowMs()
    state_.contextId = nil
    state_.config = nil
    if state_.queuePersistenceActive then persistEventQueue() end
    GameAlgo.FetchConfig(callback)
    return nextSessionId
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
            local inputCopy = normalizePayload(input)
            local configCopy = normalizePayload(item.config)
            local scriptInput = {
                state = inputCopy or {},
                config = configCopy or {},
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
    local storageKey = options.storageKey or (userStorageNamespace() .. ":dda:" .. key)
    local legacyStorageKey = "gamealgo:v1:dda:" .. tostring(state_.gameKey or "anonymous"):sub(1, 16) .. ":" .. key
    local actual = nil
    local pending = {}
    local controller = {}

    local function queueOrRun(method, ...)
        if actual then return actual[method](...) end
        table.insert(pending, { method = method, args = { ... } })
    end

    function controller._Hydrate()
        if actual or not state_.storageReady then return end
        if storageGet(storageKey) == nil then
            local legacyValue = storageGet(legacyStorageKey)
            if legacyValue ~= nil then storageSet(storageKey, legacyValue) end
        end
        actual = DDA.New({
            executor = GameAlgo.Executor(key),
            storageKey = storageKey,
            recentWindowSize = options.recentWindowSize,
            storageGet = storageGet,
            storageSet = storageSet,
        })
        local operations = pending
        pending = {}
        for _, operation in ipairs(operations) do
            local ok, operationError = pcall(function()
                actual[operation.method](unpackArgs(operation.args))
            end)
            if not ok then log("deferred DDA operation failed: " .. tostring(operationError)) end
        end
    end

    function controller.RecordBehavior(behaviorType, amount)
        return queueOrRun("RecordBehavior", behaviorType, amount)
    end

    function controller.CompleteStep(stepId)
        return queueOrRun("CompleteStep", stepId)
    end

    function controller.Reset(scope)
        return queueOrRun("Reset", scope)
    end

    function controller.Snapshot(context)
        if actual then return actual.Snapshot(context) end
        return {
            context = type(context) == "table" and context or {},
            behavior = {
                current = {},
                recent = {},
                lifetime = {},
                recentSteps = {},
                completedSteps = 0,
                windowSize = tonumber(options.recentWindowSize) or 10,
            },
            diagnostics = { storageReady = false },
        }
    end

    function controller.Decide(context)
        if actual then return actual.Decide(context) end
        return {
            adjustment = "keep",
            payload = { adjustment = "keep" },
            diagnostics = { fallback = true, reason = "storage_not_ready" },
            isFallback = true,
        }
    end

    state_.ddaControllers[key] = controller
    controller._Hydrate()
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
        accountUserId = state_.accountUserId,
        accountUserCreatedAt = state_.accountUserCreatedAt,
        sessionId = state_.sessionId,
        contextId = state_.contextId,
        config = state_.config,
        configFiles = state_.configFiles,
        scripts = state_.scripts,
        queuedEvents = #state_.queue,
        pendingEvents = #state_.pendingTracks,
        storage = state_.storage and state_.storage:Diagnostics() or nil,
    }
end

return GameAlgo
