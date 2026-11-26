---@meta
--- ============================================================
--- GameAlgo.lua — TapTap mini-game Lua SDK business layer
--- ============================================================
--- Responsibilities: read experiments/configuration and queue/report events.
--- Network requests go directly to the GameAlgo HTTP API.
---
--- Design constraints:
--- - Sends the Client Game Key in the X-GameAlgo-Key header.
--- - Initialization does not block gameplay; local defaults remain on remote failure.
--- - Downloads Lua experiments by immutable versionId, verifies them, and runs them in a restricted environment.
--- ============================================================

local cjson = require("cjson")

local moduleName = ...

local function localSdkModuleName(name)
    if type(moduleName) == "string" then
        local prefix, separator = moduleName:match("^(.*)([./])[^./]+$")
        if prefix and prefix ~= "" then return prefix .. separator .. name end
    end
    return "sdk." .. name
end

local function requireSdkModule(name)
    local localName = localSdkModuleName(name)
    local ok, value = pcall(require, localName)
    if ok then return value end
    local makerName = "sdk." .. name
    if localName ~= makerName then
        ok, value = pcall(require, makerName)
        if ok then return value end
    end
    return require(name)
end

local HttpTransport = requireSdkModule("HttpTransport")
local LuaScriptRuntime = requireSdkModule("LuaScriptRuntime")
local Sha256 = requireSdkModule("Sha256")
local DDA = requireSdkModule("DDA")
local MakerAutoStorage = requireSdkModule("MakerAutoStorage")

local GameAlgo = {}
local unpackArgs = table.unpack or unpack

local SDK_VERSION = "2.1.5-lua"
local DEFAULT_BASE_URL = "https://game-algo-sdk.dictapis.cn"
local DEFAULT_FLUSH_INTERVAL_MS = 5000
local DEFAULT_FLUSH_TIMEOUT_MS = 15000
local MAX_HTTP_BATCH_SIZE = 100
local DEFAULT_MAX_QUEUE_SIZE = 500
local MAX_CRITICAL_QUEUE_RESERVE = 8
local MAX_AD_PRIORITY_BATCH_SIZE = 20
local DEFAULT_MAX_PENDING_FLUSH_CALLBACKS = 1000
local QUEUE_PERSIST_INTERVAL_MS = DEFAULT_FLUSH_INTERVAL_MS
local QUEUE_PERSIST_EVENT_COUNT = 100
local CONFIG_FETCH_RETRY_BASE_MS = 1000
local CONFIG_FETCH_RETRY_MAX_MS = 30000
local CONFIG_FETCH_TIMEOUT_MS = 12000
local INIT_WATCHDOG_MS = 10000
local TAPDB_CONTEXT_LINK_EVENT = "gamealgo_context_link"
local TAPDB_CONTEXT_LINK_DISCOVERY_INTERVAL_MS = 500
local TAPDB_CONTEXT_LINK_DISCOVERY_WINDOW_MS = 10000
local STANDARD_EVENT_TYPES = {
    session_end = true, level_start = true, level_end = true,
    ad_view = true, purchase = true, milestone = true,
    experiment_exposure = true, experiment_execution = true,
}

local state_ = {
    baseUrl = DEFAULT_BASE_URL,
    gameKey = nil,
    appVersion = nil,
    experimentIntegrationVersion = 0,
    platform = "maker",
    timezone = nil,
    device = {},
    isDebug = false,
    userId = nil,
    userCreatedAt = nil,
    userCreatedLocalAt = nil,
    accountUserId = nil,
    accountUserCreatedAt = nil,
    prefetchedMakerUserId = nil,
    sessionId = nil,
    sessionStartMs = nil,
    foregroundTimeMs = 0,
    sessionForegroundStartMs = 0,
    sessionHasEnd = false,
    contextId = nil,
    config = nil,
    configFiles = {},
    configFileRequests = {},
    scripts = {},
    scriptRequests = {},
    ddaControllers = {},
    queue = {},
    flushableEvents = 0,
    eventQueueStorage = nil,
    flushing = false,
    activeFlush = nil,
    activeEndFlush = nil,
    activeAdFlush = nil,
    pendingEndSnapshot = nil,
    pendingAdFlush = false,
    adPriorityHandled = {},
    backgroundWillSnapshotPending = false,
    flushSequence = 0,
    lifecycleGeneration = 0,
    flushRequested = false,
    pendingFlushCallbacks = {},
    pendingFlushAccepted = 0,
    pendingFlushRejected = 0,
    maxBatchSize = MAX_HTTP_BATCH_SIZE,
    maxQueueSize = DEFAULT_MAX_QUEUE_SIZE,
    maxPendingFlushCallbacks = DEFAULT_MAX_PENDING_FLUSH_CALLBACKS,
    flushIntervalMs = DEFAULT_FLUSH_INTERVAL_MS,
    flushTimeoutMs = DEFAULT_FLUSH_TIMEOUT_MS,
    nextAutoFlushAtMs = nil,
    retryFlushAtMs = nil,
    clock = nil,
    internalUpdateSubscribed = false,
    internalUpdateNode = nil,
    internalUpdateObject = nil,
    lifecycleFlushPending = false,
    preloadConfigFiles = true,
    storage = nil,
    storageReady = false,
    initializationComplete = false,
    fetchConfigRequested = false,
    pendingFetchConfigCallbacks = {},
    configFetchCallbacks = {},
    configFetchBodies = {},
    configFetchBody = nil,
    configFetchInFlight = false,
    configFetchAttempt = 0,
    configFetchRetryHandle = nil,
    configFetchRequestHandle = nil,
    configFetchTimeoutHandle = nil,
    initWatchdogHandle = nil,
    initDiagnosticReported = false,
    tapDbContextLinkAttempted = false,
    tapDbContextLinkProperties = nil,
    tapDbContextLinkNextCheckAtMs = 0,
    tapDbContextLinkDiscoveryUntilMs = 0,
    gamealgoStandardReportingEnabled = true,
    gamealgoCustomReportingEnabled = true,
    tapdbStandardReportingEnabled = false,
    tapdbCustomReportingEnabled = false,
    directCompleted = {},
    directCompletedRing = {},
    directCompletedNext = 1,
    tapdbAttemptedKeys = {},
    tapdbAttemptedRing = {},
    tapdbAttemptedNext = 1,
    pendingFlushSkipped = 0,
    pendingFlushTapdbAttempted = 0,
    customEventCounts = {},
    ordinaryEventCounts = {},
    eventQuota = nil,
    eventGuardDiagnosticKeys = {},
    eventGuardDiagnosticCount = 0,
    reachedMilestoneKeys = {},
    pendingMilestoneKeys = {},
    pendingTracks = {},
    consecutiveFlushFailures = 0,
    queuePersistenceDirty = false,
    persistentStorageAvailable = false,
    milestoneMarkersDirty = false,
    deferredMilestoneAcks = {},
    queueEventsSincePersist = 0,
    lastQueuePersistAtMs = 0,
    logger = nil,
    transport = HttpTransport,
    scheduler = nil,
}

local function logTo(logger, message)
    local line = "[GameAlgoSDK] " .. tostring(message)
    if type(logger) == "function" then
        local ok, loggerError = pcall(logger, line)
        if not ok then
            print(line)
            print("[GameAlgoSDK] logger failed: " .. tostring(loggerError))
        end
    else
        print(line)
    end
end

local function log(message)
    logTo(state_.logger, message)
end

local function safeCallback(callback, ...)
    if type(callback) ~= "function" then return true end
    local ok, callbackError = pcall(callback, ...)
    if not ok then log("callback failed: " .. tostring(callbackError)) end
    return ok
end

local function cancelTransportRequest(transport, handle)
    if handle == nil or type(transport) ~= "table" then return end
    if type(transport.Cancel) == "function" then
        pcall(transport.Cancel, handle)
        return
    end
    local cancel = nil
    pcall(function() cancel = handle.Cancel or handle.Abort end)
    if type(cancel) == "function" then pcall(cancel, handle) end
end

local function isoNow()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Count Gregorian calendar days directly. os.time interprets its table in the
-- host timezone and cannot unambiguously represent both sides of a DST change.
local monthStarts = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 }
local function calendarSeconds(year, month, day, hour, minute, second)
    if month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then return nil end
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local daysInMonth = monthStarts[month + 1] - monthStarts[month] + (leap and month == 2 and 1 or 0)
    if day < 1 or day > daysInMonth then return nil end
    local y = year - 1
    local days = 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
        - 719162 + monthStarts[month] + (leap and month > 2 and 1 or 0) + day - 1
    return ((days * 24 + hour) * 60 + minute) * 60 + second
end

local function epochMsFromIso(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second, suffix = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return nil end
    local timestamp = calendarSeconds(tonumber(year), tonumber(month), tonumber(day),
        tonumber(hour), tonumber(minute), tonumber(second))
    if not timestamp then return nil end
    local fraction, zone = suffix:match("^%.(%d+)(.*)$")
    zone = zone or suffix
    if zone ~= "Z" then
        local sign, h, m = zone:match("^([+-])(%d%d):?(%d%d)$")
        if not sign or tonumber(h) > 23 or tonumber(m) > 59 then return nil end
        local offset = (tonumber(h) * 60 + tonumber(m)) * 60
        timestamp = timestamp - (sign == "+" and offset or -offset)
    end
    return timestamp * 1000 + tonumber(((fraction or "") .. "000"):sub(1, 3))
end

local function localIsoNow(timestamp)
    timestamp = timestamp or os.time()
    local t = os.date("*t", timestamp)
    local localSeconds = calendarSeconds(t.year, t.month, t.day, t.hour, t.min, t.sec)
    local minutes = math.floor(math.abs(localSeconds - timestamp) / 60)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d", t.year, t.month,
        t.day, t.hour, t.min, t.sec, localSeconds >= timestamp and "+" or "-", math.floor(minutes / 60), minutes % 60)
end

local function localIsoFromUtc(value)
    local milliseconds = epochMsFromIso(value)
    if milliseconds then return localIsoNow(math.floor(milliseconds / 1000)) end
end

local function nowMs()
    local ok, value = pcall(function()
        if Time and type(Time.GetTimeSinceEpochMs) == "function" then
            return Time:GetTimeSinceEpochMs()
        end
        if Time then
            local systemTime = tonumber(Time.systemTime)
            if systemTime then return systemTime * 1000 end
        end
        return nil
    end)
    local milliseconds = tonumber(value)
    if ok and milliseconds and milliseconds == milliseconds and milliseconds < math.huge then
        return math.floor(milliseconds)
    end
    return math.floor(os.time() * 1000)
end

local function clockMs()
    local clock = state_.clock
    if type(clock) == "function" then
        local ok, value = pcall(clock)
        value = ok and tonumber(value)
        if value and value == value and math.abs(value) < math.huge then return math.floor(value) end
    end
    return nowMs()
end

local randomIdCounter = 0
local randomIdEntropy = tostring({})

local function randomId(prefix)
    randomIdCounter = randomIdCounter + 1
    -- Do not reseed or touch the game's shared math.random state. Combine
    -- per-call and per-VM entropy instead.
    local address = tostring({}):match("0x(%x+)") or "0"
    randomIdEntropy = Sha256.hex(table.concat({
        randomIdEntropy,
        tostring(os.time()),
        tostring(os.clock()),
        tostring(randomIdCounter),
        address,
    }, ":"))
    return (prefix or "id") .. "_" .. randomIdEntropy:sub(1, 24)
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
    if not storage then return false end
    local ok, persisted = pcall(function() return storage:SetItem(key, value) end)
    return ok and persisted ~= false
end

local cachedGameKey, cachedGameNamespace, cachedUserId, cachedUserNamespace

local function gameStorageNamespace()
    local gameKey = tostring(state_.gameKey or "anonymous")
    if cachedGameKey ~= gameKey then
        cachedGameKey = gameKey
        cachedGameNamespace = "gamealgo:v2:game:" .. Sha256.hex(gameKey)
        cachedUserNamespace = nil
    end
    return cachedGameNamespace
end

local function identityStorageKey(name)
    return gameStorageNamespace() .. ":identity:" .. tostring(name)
end

local function userStorageNamespace()
    local gameNamespace = gameStorageNamespace()
    local userId = tostring(state_.userId or "anonymous")
    if not cachedUserNamespace or cachedUserId ~= userId then
        cachedUserId = userId
        cachedUserNamespace = gameNamespace .. ":user:" .. Sha256.hex(userId)
    end
    return cachedUserNamespace
end

local function queueStorageKey()
    return userStorageNamespace() .. ":events:jsonl"
end

local function milestoneStorageKey()
    return userStorageNamespace() .. ":milestones"
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

local function ensureIdentity(explicitUserId, explicitUserCreatedAt, explicitUserCreatedLocalAt)
    if state_.userId then return end
    local legacyUser = storageGet(identityStorageKey("user_id"))
    local globalUser = storageGet("gamealgo_user_id")
    state_.userId = explicitUserId and explicitUserId ~= "" and tostring(explicitUserId)
        or storageGet(identityStorageKey("last_user_id")) or legacyUser or globalUser or randomId("ga_user")
    local key = userStorageNamespace() .. ":registration"
    local saved = storageGet(key)
    if type(saved) ~= "table" then saved = {} end
    local utc, localTime = saved.utc, saved.localTime
    if state_.userId == legacyUser then
        utc = utc or storageGet(identityStorageKey("user_created_at"))
        localTime = localTime or storageGet(identityStorageKey("user_created_local_at"))
    end
    if state_.userId == globalUser then
        utc = utc or storageGet("gamealgo_user_created_at")
        localTime = localTime or storageGet("gamealgo_user_created_local_at")
    end
    if explicitUserCreatedAt and explicitUserCreatedAt ~= "" then
        utc, localTime = tostring(explicitUserCreatedAt), nil
    end
    state_.userCreatedAt = utc or isoNow()
    state_.userCreatedLocalAt = explicitUserCreatedLocalAt and explicitUserCreatedLocalAt ~= "" and tostring(explicitUserCreatedLocalAt)
        or localTime or localIsoFromUtc(state_.userCreatedAt) or localIsoNow()
    if saved.utc ~= state_.userCreatedAt or saved.localTime ~= state_.userCreatedLocalAt then
        storageSet(key, { utc = state_.userCreatedAt, localTime = state_.userCreatedLocalAt })
    end
    storageSet(identityStorageKey("last_user_id"), state_.userId)
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

local TELEMETRY_PATHS = {
    ["/v1/events/batch"] = true, ["/v1/attribution"] = true,
    ["/v1/context-identifiers"] = true, ["/v1/diagnostics/sdk"] = true,
    ["/v1/diagnostics/init"] = true,
}

-- Keep each native property below 256 bytes without splitting a UTF-8 codepoint.
local function tapdbParts(value)
    local parts, first = {}, 1
    while first <= #value do
        local last = math.min(#value, first + 239)
        while last < #value do
            local nextByte = value:byte(last + 1)
            if nextByte < 128 or nextByte >= 192 then break end
            last = last - 1
        end
        table.insert(parts, value:sub(first, last))
        first = last + 1
    end
    if #parts == 0 then parts[1] = "" end
    return parts
end

local function tapdbEnvelope(envelope, event)
    local parts = tapdbParts(cjson.encode(envelope))
    local properties = {
        gamealgo_envelope_version = "1", gamealgo_part_count = tostring(#parts),
        gamealgo_event_id = tapdbParts(tostring(event.eventId or ""))[1],
        gamealgo_event_type = tapdbParts(tostring(event.eventType or ""))[1],
        gamealgo_context_id = tapdbParts(tostring(event.contextId or ""))[1],
        gamealgo_device_id = tapdbParts(tostring(event.userId or ""))[1],
        gamealgo_session_id = tapdbParts(tostring(event.sessionId or ""))[1],
        gamealgo_is_debug = event.isDebug == true,
    }
    for index, part in ipairs(parts) do properties["gamealgo_part_" .. tostring(index - 1)] = part end
    return properties
end

local function telemetryEnabled(channel, event)
    local standard = not event or STANDARD_EVENT_TYPES[event.eventType]
    if channel == "gamealgo" then
        return (standard and state_.gamealgoStandardReportingEnabled
            or not standard and state_.gamealgoCustomReportingEnabled)
    end
    return (standard and state_.tapdbStandardReportingEnabled
        or not standard and state_.tapdbCustomReportingEnabled)
end

local function directEventKey(event)
    return tostring(event.isDebug == true) .. ":" .. tostring(event.eventId)
end

local function rememberDirectEvents(events)
    for _, event in ipairs(events) do
        local key, slot = directEventKey(event), state_.directCompletedNext
        local previous = state_.directCompletedRing[slot]
        if previous and state_.directCompleted[previous] == slot then state_.directCompleted[previous] = nil end
        state_.directCompletedRing[slot] = key
        state_.directCompleted[key] = slot
        state_.directCompletedNext = slot % math.max(1000, state_.maxQueueSize * 2) + 1
    end
end

local function forwardTapdbTelemetry(path, body)
    if not state_.tapdbStandardReportingEnabled and not state_.tapdbCustomReportingEnabled then return 0, true end
    local found, host, logEvent = pcall(function()
        local value = sdk
        if value == nil then return nil end
        return value, value.LogEvent
    end)
    local available = found and type(logEvent) == "function"
    local count, generation, allAccepted = 0, state_.lifecycleGeneration, true
    local function forward(name, key, envelope, event)
        local categoryEvent = path == "/v1/events/batch" and event or nil
        if not telemetryEnabled("tapdb", categoryEvent) then return end
        local required = not telemetryEnabled("gamealgo", categoryEvent)
        if generation ~= state_.lifecycleGeneration or not available then
            if required then allAccepted = false end
            return
        end
        local previousStatus = state_.tapdbAttemptedKeys[key]
        if previousStatus and (previousStatus.state ~= "failed" or not required) then
            if required and previousStatus.state ~= "accepted" then allAccepted = false end
            return
        end
        local encoded, properties = pcall(tapdbEnvelope, envelope, event)
        if not encoded then if required then allAccepted = false end; log("TapDB telemetry encode failed"); return end
        -- Bounded, in-memory retry guard. No per-frame scan or extra disk writes.
        local slot = state_.tapdbAttemptedNext
        local previous = state_.tapdbAttemptedRing[slot]
        if previous and state_.tapdbAttemptedKeys[previous] and state_.tapdbAttemptedKeys[previous].slot == slot then
            state_.tapdbAttemptedKeys[previous] = nil
        end
        state_.tapdbAttemptedRing[slot] = key
        local entry = { state = "pending", slot = slot }
        state_.tapdbAttemptedKeys[key] = entry
        state_.tapdbAttemptedNext = slot % math.max(1000, state_.maxQueueSize * 2) + 1
        count = count + 1
        -- Exactly the verified Maker signature, without an extra callback.
        local ok, accepted = pcall(logEvent, host, name, properties)
        if generation ~= state_.lifecycleGeneration then allAccepted = false; return end
        if ok and accepted == true then entry.state = "accepted"
        else entry.state = "failed"; if required then allAccepted = false end; log("TapDB telemetry handoff failed") end
    end
    if path == "/v1/events/batch" then
        for _, event in ipairs(body.events or {}) do
            forward("gamealgo_event", "event:" .. tostring(event.eventId),
                { schemaVersion = 1, path = path, event = event }, event)
        end
    else
        local requestId = Sha256.hex(cjson.encode({ path = path, body = body }))
        forward("gamealgo_request", "request:" .. requestId,
            { schemaVersion = 1, path = path, requestId = requestId, body = body },
            { eventId = body.diagnosticId or requestId, eventType = path, contextId = body.contextId,
                userId = body.userId, sessionId = body.sessionId, isDebug = body.isDebug })
    end
    return count, allAccepted
end

local function httpRequest(method, path, bodyTable, callback)
    callback = callback or function() end
    if method == "POST" and TELEMETRY_PATHS[path] then
        local generation = state_.lifecycleGeneration
        local originalBody, directEvents, directIndices = bodyTable or {}, nil, {}
        local direct = telemetryEnabled("gamealgo")
        if path == "/v1/events/batch" then
            directEvents = {}
            for index, event in ipairs(originalBody.events or {}) do
                if telemetryEnabled("gamealgo", event) and not state_.directCompleted[directEventKey(event)] then
                    table.insert(directEvents, event)
                    table.insert(directIndices, index - 1)
                end
            end
            direct = #directEvents > 0
        end
        local attempted, allAccepted = forwardTapdbTelemetry(path, originalBody)
        if generation ~= state_.lifecycleGeneration then
            safeCallback(callback, "SDK reinitialized during telemetry handoff", nil, { status = 0 })
            return nil
        end
        if not direct then
            if allAccepted == false then
                safeCallback(callback, "TapDB telemetry handoff failed", nil, { status = 0, localOnly = true })
                return nil
            end
            safeCallback(callback, nil, { ok = true, accepted = 0,
                skipped = path == "/v1/events/batch" and #(originalBody.events or {}) or 1,
                tapdbAttempted = attempted }, { status = 200, localOnly = true })
            return nil
        end
        if directEvents and #directEvents < #originalBody.events then
            bodyTable = {}
            for key, value in pairs(originalBody) do bodyTable[key] = value end
            bodyTable.events = directEvents
            local originalCallback = callback
            callback = function(error, result, response)
                if generation ~= state_.lifecycleGeneration then return end
                if error then safeCallback(originalCallback, error, nil, response); return end
                local accepted = type(result) == "table" and tonumber(result.accepted) or nil
                local rejected = type(result) == "table" and result.rejected or nil
                local valid = accepted and accepted >= 0 and accepted <= #directEvents and accepted % 1 == 0
                    and result.ok ~= false and response and tonumber(response.status) == 200
                if valid and accepted == 0 then
                    valid = type(rejected) == "table" and #rejected == #directEvents
                    if valid then for _, row in ipairs(rejected) do if type(row) ~= "table" then valid = false; break end end end
                end
                if not valid then safeCallback(originalCallback, "invalid telemetry batch acknowledgement", nil, response); return end
                rememberDirectEvents(directEvents)
                if not allAccepted then safeCallback(originalCallback, "TapDB telemetry handoff failed", nil, response); return end
                -- Native rejection indices refer to the filtered subset, so restore the caller's batch indices.
                if type(rejected) == "table" then
                    for _, row in ipairs(rejected) do
                        if type(row) == "table" and type(row.index) == "number" then row.index = directIndices[row.index + 1] end
                    end
                end
                result.skipped = #originalBody.events - #directEvents
                result.tapdbAttempted = attempted
                response.localOnly = true
                safeCallback(originalCallback, nil, result, response)
            end
        elseif directEvents then
            local originalCallback = callback
            callback = function(error, result, response)
                if type(result) == "table" then result.tapdbAttempted = attempted end
                safeCallback(originalCallback, error, result, response)
            end
        end
    end
    local headers = {
        ["Content-Type"] = "application/json",
    }
    if state_.gameKey and state_.gameKey ~= "" then
        headers["X-GameAlgo-Key"] = state_.gameKey
    end

    local body = ""
    if bodyTable ~= nil then
        local encodeOk, encoded = pcall(cjson.encode, bodyTable)
        if not encodeOk then
            safeCallback(callback, "request encode failed: " .. tostring(encoded), nil, nil)
            return nil
        end
        body = encoded
    end

    local settled = false
    local function complete(error, response)
        if settled then return end
        settled = true
        if error then
            safeCallback(callback, error, nil, response)
            return
        end
        local body = response and response.body or ""
        local decoded = nil
        if body ~= "" then
            local ok, value = pcall(cjson.decode, body)
            if ok then decoded = value end
        end
        safeCallback(callback, nil, decoded, response)
    end

    local requestOk, requestOrError = pcall(function()
        return state_.transport.Request({
            method = method,
            url = trimSlash(state_.baseUrl) .. path,
            headers = headers,
            body = body,
        }, complete)
    end)
    if not requestOk then
        complete("request failed: " .. tostring(requestOrError), nil)
        return nil
    end
    return requestOrError
end

local function reportInitTimeout()
    state_.initWatchdogHandle = nil
    if state_.contextId and state_.contextId ~= "" then return end
    if state_.initDiagnosticReported then return end
    state_.initDiagnosticReported = true
    httpRequest("POST", "/v1/diagnostics/init", {
        diagnosticId = randomId("ga_diag"),
        userId = state_.userId,
        accountUserId = state_.accountUserId or state_.prefetchedMakerUserId,
        sessionId = state_.sessionId,
        platform = state_.platform,
        sdkVersion = SDK_VERSION,
        appVersion = state_.appVersion,
        stage = "config",
        status = "failed",
        reasonCode = "initialization_timeout",
        reasonDetail = "context not ready after 10000ms",
        createdAt = isoNow(),
        createdLocalAt = localIsoNow(),
        isDebug = state_.isDebug,
    }, function(error)
        if error then log("init timeout diagnostic upload failed: " .. tostring(error)) end
    end)
end

local function tryTapDbContextLink()
    local properties = state_.tapDbContextLinkProperties
    if state_.tapDbContextLinkAttempted or properties == nil then return end
    state_.tapDbContextLinkNextCheckAtMs = clockMs() + TAPDB_CONTEXT_LINK_DISCOVERY_INTERVAL_MS
    local found, host, logEvent = pcall(function()
        -- Maker can expose sdk through the environment metatable.
        local value = sdk
        if value == nil then return nil end
        return value, value.LogEvent
    end)
    if not found or type(logEvent) ~= "function" then return end
    -- One best-effort native call per Init, even if the host rejects it.
    -- Set the guard before calling out so refreshes cannot duplicate the link.
    state_.tapDbContextLinkAttempted = true
    state_.tapDbContextLinkProperties = nil
    -- Keep the tested two-argument signature: older hosts reject callbacks.
    local ok, accepted = pcall(logEvent, host, TAPDB_CONTEXT_LINK_EVENT, properties)
    if not ok then
        log("TapDB context link failed: " .. tostring(accepted))
    elseif accepted == false then
        log("TapDB context link rejected")
    end
end

local function reportTapDbContextLink(config, requestBody)
    if config.tapdbContextLinkEnabled ~= true or not state_.tapdbStandardReportingEnabled then
        state_.tapDbContextLinkProperties = nil
        state_.tapDbContextLinkNextCheckAtMs = 0
        state_.tapDbContextLinkDiscoveryUntilMs = 0
        return
    end
    if state_.tapDbContextLinkAttempted then return end
    if state_.tapDbContextLinkProperties == nil then
        -- Preserve the first config request identity while the host is loading.
        state_.tapDbContextLinkProperties = {
            gamealgo_context_id = config.contextId,
            gamealgo_device_id = requestBody.userId,
            gamealgo_is_debug = requestBody.isDebug == true,
        }
    end
    state_.tapDbContextLinkDiscoveryUntilMs = clockMs() + TAPDB_CONTEXT_LINK_DISCOVERY_WINDOW_MS
    tryTapDbContextLink()
end

local function mergeCustomEventCountBucket(from, to)
    local pending = state_.customEventCounts[from]
    if not pending then return end
    local target = state_.customEventCounts[to] or { total = 0, byType = {}, distinct = 0 }
    target.total = target.total + pending.total
    for eventType, count in pairs(pending.byType) do
        if target.byType[eventType] == nil then target.distinct = target.distinct + 1 end
        target.byType[eventType] = (target.byType[eventType] or 0) + count
    end
    state_.customEventCounts[to] = target
    state_.customEventCounts[from] = nil
end

local function mergeOrdinaryEventCountBucket(from, to)
    local pending = state_.ordinaryEventCounts[from]
    if pending == nil then return end
    state_.ordinaryEventCounts[to] = (state_.ordinaryEventCounts[to] or 0) + pending
    state_.ordinaryEventCounts[from] = nil
end

local function reportEventGuardDiagnostic(eventType, scope, limit, observed, reasonCode, detailSuffix, diagnosticKey)
    local key = diagnosticKey or (tostring(state_.sessionId) .. "\0" .. tostring(eventType) .. "\0" .. tostring(scope))
    if state_.eventGuardDiagnosticKeys[key] or state_.eventGuardDiagnosticCount >= 10 then return end
    state_.eventGuardDiagnosticKeys[key] = true
    state_.eventGuardDiagnosticCount = state_.eventGuardDiagnosticCount + 1
    local safeEventType = tostring(eventType):gsub("[;\r\n]", "_"):sub(1, 96)
    httpRequest("POST", "/v1/diagnostics/sdk", {
        diagnosticId = randomId("ga_diag"),
        userId = state_.userId,
        accountUserId = state_.accountUserId or state_.prefetchedMakerUserId,
        sessionId = state_.sessionId,
        contextId = state_.contextId,
        platform = state_.platform,
        sdkVersion = SDK_VERSION,
        appVersion = state_.appVersion,
        stage = "event_guard",
        status = "degraded",
        reasonCode = reasonCode or "custom_event_quota_exceeded",
        reasonDetail = "eventType=" .. safeEventType .. ";scope=" .. scope .. ";limit=" .. tostring(limit)
            .. ";observed=" .. tostring(observed) .. (detailSuffix or "") .. ";dropped=1",
        createdAt = isoNow(),
        createdLocalAt = localIsoNow(),
        isDebug = state_.isDebug,
    }, function(error)
        if error then log("event guard diagnostic upload failed: " .. tostring(error)) end
    end)
end

local function consumeOrdinaryEventQuota(eventType, consume)
    local quota = state_.eventQuota
    if eventType == "purchase" or eventType == "ad_view"
        or (quota and quota.exemptEventTypes and quota.exemptEventTypes[eventType]) then
        return true, nil
    end
    local bucketKey = state_.contextId and state_.contextId ~= ""
        and ("context:" .. state_.contextId) or ("pending:" .. tostring(state_.sessionId))
    local current = state_.ordinaryEventCounts[bucketKey] or 0
    if quota and current >= quota.ordinaryEventLimit then
        reportEventGuardDiagnostic(
            eventType,
            "context_total",
            quota.ordinaryEventLimit,
            current + 1,
            "context_event_quota_exceeded",
            ";policyVersion=" .. tostring(quota.policyVersion) .. ";quotaDate=" .. tostring(quota.quotaDate),
            bucketKey .. "\0context_event_quota"
        )
        return false, "context event quota exceeded (limit=" .. tostring(quota.ordinaryEventLimit) .. ")"
    end
    if consume ~= false then state_.ordinaryEventCounts[bucketKey] = current + 1 end
    return true, nil
end

local function normalizeEventQuota(config)
    local quota = type(config) == "table" and config.eventQuota or nil
    if type(quota) ~= "table" or quota.mode ~= "enforce" then return nil end
    local limit = tonumber(quota.ordinaryEventLimit)
    if limit == nil or limit < 0 or limit % 1 ~= 0 then
        return nil
    end
    local exempt = { purchase = true, ad_view = true }
    if type(quota.exemptEventTypes) == "table" then
        for _, eventType in ipairs(quota.exemptEventTypes) do
            if type(eventType) == "string" and eventType ~= "" then exempt[eventType] = true end
        end
    end
    return {
        ordinaryEventLimit = math.floor(limit),
        policyVersion = math.floor(tonumber(quota.policyVersion) or 0),
        quotaDate = tostring(quota.quotaDate or ""),
        resetAt = tostring(quota.resetAt or ""),
        exemptEventTypes = exempt,
    }
end

local function consumeCustomEventQuota(eventType)
    if STANDARD_EVENT_TYPES[eventType] then return true, nil end
    local bucketKey = state_.contextId and state_.contextId ~= ""
        and ("context:" .. state_.contextId) or ("pending:" .. tostring(state_.sessionId))
    local bucket = state_.customEventCounts[bucketKey] or { total = 0, byType = {}, distinct = 0 }
    local current = bucket.byType[eventType] or 0
    local scope, limit, observed = nil, nil, nil
    if bucket.byType[eventType] == nil and bucket.distinct >= 100 then
        scope, limit, observed = "distinct_event_types", 100, bucket.distinct + 1
    elseif current >= 1000 then
        scope, limit, observed = "context_event_type", 1000, current + 1
    elseif bucket.total >= 5000 then
        scope, limit, observed = "context_total", 5000, bucket.total + 1
    end
    if scope then
        reportEventGuardDiagnostic(eventType, scope, limit, observed)
        return false, "custom event quota exceeded (scope=" .. scope .. ", limit=" .. tostring(limit) .. ")"
    end
    if bucket.byType[eventType] == nil then bucket.distinct = bucket.distinct + 1 end
    bucket.byType[eventType] = current + 1
    bucket.total = bucket.total + 1
    state_.customEventCounts[bucketKey] = bucket
    return true, nil
end

-- Only conventional HTTPS authorities can receive the API credential. The
-- transport still enforces its normal resource URL policy for every request.
local function httpsAuthority(url)
    if type(url) ~= "string" or url:find("[%s%c\\]") then return nil end
    local authority = url:lower():match("^https://([^/?#]+)")
    if not authority then return nil end
    local host, port = authority:match("^([%w%.%-]+):(%d+)$")
    if not host then host, port = authority:match("^(%[[%x:%.]+%]):(%d+)$") end
    host = host or authority:match("^([%w%.%-]+)$") or authority:match("^(%[[%x:%.]+%])$")
    if not host then return nil end
    return host .. ":" .. (port or "443")
end

local function rawHttpRequest(method, url, callback)
    callback = callback or function() end
    local headers = {}
    local trusted = httpsAuthority(state_.baseUrl)
    if trusted and trusted == httpsAuthority(url) and state_.gameKey and state_.gameKey ~= "" then
        headers["X-GameAlgo-Key"] = state_.gameKey
    end
    local settled = false
    local function complete(error, response)
        if settled then return end
        settled = true
        safeCallback(callback, error, response)
    end
    local requestOk, requestOrError = pcall(function()
        return state_.transport.Request({
            method = method,
            url = tostring(url or ""),
            headers = headers,
            body = "",
        }, complete)
    end)
    if not requestOk then
        complete("request failed: " .. tostring(requestOrError), nil)
        return nil
    end
    return requestOrError
end

local function snapshotJsonValue(value, seen, path)
    local valueType = type(value)
    if value == nil or valueType == "string" or valueType == "boolean" then return value, nil end
    if valueType == "userdata" and value == cjson.null then return value, nil end
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

local function preparePayload(payload)
    local snapshotOk, copy, snapshotError = pcall(normalizePayload, payload)
    if not snapshotOk then
        return nil, "payload snapshot failed: " .. tostring(copy)
    end
    if snapshotError then return nil, snapshotError end
    local encodeOk, encodeError = pcall(cjson.encode, copy)
    if not encodeOk then
        return nil, "payload is not JSON serializable: " .. tostring(encodeError)
    end
    return copy, nil
end

local function milestoneKey(isDebug, milestoneType, milestonePoint)
    local ok, encoded = pcall(cjson.encode, {
        isDebug and "debug" or "live",
        tostring(milestoneType),
        tostring(milestonePoint),
    })
    if ok then return encoded end
    return (isDebug and "debug" or "live") .. "\0"
        .. tostring(milestoneType) .. "\0" .. tostring(milestonePoint)
end

local function persistReachedMilestones()
    local keys = {}
    for key in pairs(state_.reachedMilestoneKeys) do table.insert(keys, key) end
    table.sort(keys)
    local ok, encoded = pcall(cjson.encode, keys)
    return ok and storageSet(milestoneStorageKey(), encoded)
end

local function restoreReachedMilestones()
    state_.reachedMilestoneKeys = {}
    local raw = storageGet(milestoneStorageKey())
    if type(raw) ~= "string" or raw == "" then return end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or type(decoded) ~= "table" then
        storageSet(milestoneStorageKey(), "")
        return
    end
    for _, key in pairs(decoded) do
        if type(key) == "string" and key ~= "" then state_.reachedMilestoneKeys[key] = true end
    end
end

local function eventMilestoneKey(eventType, payload, isDebug)
    if eventType == "milestone" and type(payload) == "table"
        and type(payload.milestoneType) == "string" and payload.milestoneType ~= ""
        and type(payload.milestonePoint) == "string" and payload.milestonePoint ~= "" then
        return milestoneKey(isDebug, payload.milestoneType, payload.milestonePoint)
    end
end

local function prepareMilestone(eventType, payload, occurredAtMs)
    if eventType ~= "milestone" then return payload end
    local registeredAtMs = epochMsFromIso(state_.userCreatedAt)
    payload.elapsedSinceRegistrationMs = registeredAtMs and math.max(0, math.floor(occurredAtMs - registeredAtMs)) or nil
    local key = eventMilestoneKey(eventType, payload, state_.isDebug)
    local bound = state_.contextId ~= nil and state_.contextId ~= ""
    return payload, key, bound, state_.reachedMilestoneKeys[key] or state_.pendingMilestoneKeys[key]
end

local function rememberMilestone(key, bound)
    if not key or state_.reachedMilestoneKeys[key] then return end
    if bound then
        state_.reachedMilestoneKeys[key] = true
        state_.pendingMilestoneKeys[key] = nil
        state_.milestoneMarkersDirty = true
    else
        state_.pendingMilestoneKeys[key] = true
    end
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
    if type(script) ~= "table" then return nil end
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
    if type(script) ~= "table" then return false end
    local name = tostring(script.name or ""):lower()
    local contentType = tostring(script.contentType or ""):lower()
    return name:sub(-4) == ".lua" or contentType:find("lua", 1, true) ~= nil
end

local function cachedScript(script)
    local key = scriptCacheKey(script)
    local file = key and state_.scripts[key]
    if file and type(script.hash) == "string" and file.hash:lower() == script.hash:lower() then return file end
end

local function copyScript(file)
    if file then
        return { name = file.name, versionId = file.versionId, content = file.content,
            contentType = file.contentType, hash = file.hash }
    end
end

local function tablePath(root, path)
    local value = root
    for part in tostring(path or ""):gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        if value[part] == nil and part:match("^%d+$") then
            value = value[tonumber(part) + 1]
        else
            value = value[part]
        end
        if value == nil then return nil end
    end
    return value
end

local function chunkEvents()
    local batch = {}
    local remaining = {}
    for _, event in ipairs(state_.queue) do
        local criticalInFlight = (state_.activeEndFlush and state_.activeEndFlush.event.eventId == event.eventId)
            or (state_.activeAdFlush and state_.activeAdFlush.ids[event.eventId])
        if not criticalInFlight and #batch < state_.maxBatchSize and event.contextId and event.contextId ~= "" then
            table.insert(batch, event)
        else
            table.insert(remaining, event)
        end
    end
    state_.queue = remaining
    state_.flushableEvents = state_.flushableEvents - #batch
    return batch
end

local function outstandingEventCount()
    local activeCount = state_.activeFlush and #state_.activeFlush.batch or 0
    return activeCount + #state_.queue
end

local function queueAdmissionError(eventType, count)
    local maximum = state_.maxQueueSize
    if count >= maximum then return "event queue is full (max=" .. tostring(maximum) .. ")" end
    -- Preserve a small exit slot even when ads fill the shared critical reserve.
    -- Tiny custom queues keep their existing capacity; default 500 reserves 8.
    local reserve = math.min(MAX_CRITICAL_QUEUE_RESERVE, math.floor(maximum / 10))
    local limit = maximum
    if eventType == "ad_view" and reserve > 0 then limit = maximum - 1
    elseif eventType ~= "session_end" then limit = maximum - reserve end
    if count >= limit then
        return "event queue is full for " .. tostring(eventType)
            .. " (limit=" .. tostring(limit) .. ", max=" .. tostring(maximum) .. ")"
    end
    return nil
end

local function armAutoFlush()
    if state_.flushIntervalMs > 0 and not state_.nextAutoFlushAtMs then
        state_.nextAutoFlushAtMs = clockMs() + state_.flushIntervalMs
    end
end

local function persistEventQueue()
    if not state_.eventQueueStorage then return true end
    if not state_.queuePersistenceDirty and not state_.milestoneMarkersDirty then return true end
    local queue = state_.eventQueueStorage
    local memoryOnly = not state_.persistentStorageAvailable
    local ok, persisted = pcall(function()
        -- The event ID must be recoverable before its permanent dedup key.
        if not memoryOnly and not queue:Persist() then return false end
        if state_.milestoneMarkersDirty then
            if not persistReachedMilestones() and not memoryOnly then return false end
            state_.milestoneMarkersDirty = false
        end
        if #state_.deferredMilestoneAcks > 0 then
            queue:Remove(state_.deferredMilestoneAcks)
            state_.deferredMilestoneAcks = {}
            if not memoryOnly then return queue:Persist() end
        end
        return true
    end)
    if not ok then log("event queue persistence failed: " .. tostring(persisted)) end
    state_.queuePersistenceDirty = not (ok and persisted)
    state_.queueEventsSincePersist = 0
    state_.lastQueuePersistAtMs = clockMs()
    return not state_.queuePersistenceDirty
end

local function scheduleEventQueuePersistence()
    local now = clockMs()
    if not state_.queuePersistenceDirty and now - state_.lastQueuePersistAtMs >= QUEUE_PERSIST_INTERVAL_MS then
        state_.lastQueuePersistAtMs = now
    end
    state_.queuePersistenceDirty = true
    state_.queueEventsSincePersist = state_.queueEventsSincePersist + 1
    if state_.queueEventsSincePersist >= QUEUE_PERSIST_EVENT_COUNT
        or now - state_.lastQueuePersistAtMs >= QUEUE_PERSIST_INTERVAL_MS then
        persistEventQueue()
    end
end

local function restoreEventQueue()
    state_.eventQueueStorage = state_.storage:EventQueue(queueStorageKey())
    local restored = 0
    for _, event in ipairs(state_.eventQueueStorage:Events()) do
        table.insert(state_.queue, event)
        if event.eventType == "ad_view" then state_.pendingAdFlush = true end
        local bound = event.contextId ~= nil and event.contextId ~= ""
        if bound then state_.flushableEvents = state_.flushableEvents + 1 end
        rememberMilestone(eventMilestoneKey(event.eventType, event.payload, event.isDebug), bound)
        restored = restored + 1
    end
    if restored > 0 then
        persistEventQueue()
        if state_.flushableEvents > 0 then armAutoFlush() end
        if #state_.queue >= state_.maxBatchSize and state_.flushableEvents > 0 then state_.flushRequested = true end
        log("restored persisted events: " .. tostring(restored))
    end
end

local function bindQueuedEvents(contextId, identity, adoptOrphans)
    if not contextId or contextId == "" then return end
    local changed = false
    for _, event in ipairs(state_.queue) do
        if (not event.contextId or event.contextId == "")
            and event.userId == identity.userId and (event.isDebug == true) == identity.isDebug
            and (event.sessionId == identity.sessionId or adoptOrphans) then
            event.contextId = contextId
            state_.flushableEvents = state_.flushableEvents + 1
            state_.eventQueueStorage:Upsert(event)
            rememberMilestone(eventMilestoneKey(event.eventType, event.payload, event.isDebug), true)
            if event.eventType == "ad_view" then state_.pendingAdFlush = true end
            changed = true
        end
    end
    if changed then armAutoFlush(); scheduleEventQueuePersistence() end
end

local function sessionAttribution()
    return { queueKey = queueStorageKey(), userId = state_.userId, accountUserId = state_.accountUserId,
        sessionId = state_.sessionId, contextId = state_.contextId, isDebug = state_.isDebug }
end

local function makeEvent(owner, eventType, payload, timestamp, createdLocalAt)
    return {
        eventId = randomId("ga_event"), contextId = owner.contextId or "", userId = owner.userId,
        accountUserId = owner.accountUserId, sessionId = owner.sessionId, isDebug = owner.isDebug,
        eventType = eventType, timestamp = timestamp or isoNow(), createdLocalAt = createdLocalAt or localIsoNow(),
        payload = payload,
    }
end

local function enqueueTrack(eventType, payload, timestamp, createdLocalAt, sessionEndSnapshot, owner)
    local admissionError = queueAdmissionError(eventType, outstandingEventCount())
    if admissionError then
        persistEventQueue()
        return false, admissionError
    end
    local payloadCopy, payloadError = preparePayload(payload)
    if payloadError then return false, payloadError end
    local event = makeEvent(owner or state_.sessionAttribution, eventType, payloadCopy, timestamp, createdLocalAt)
    table.insert(state_.queue, event)
    if event.contextId and event.contextId ~= "" then
        state_.flushableEvents = state_.flushableEvents + 1
        armAutoFlush()
    end
    if #state_.queue >= state_.maxBatchSize and state_.flushableEvents > 0 then state_.flushRequested = true end
    state_.eventQueueStorage:Upsert(event)
    if eventType == "session_end" and not sessionEndSnapshot then state_.sessionHasEnd = true end
    if eventType == "session_end" then state_.pendingEndSnapshot = event end
    if eventType == "ad_view" then state_.pendingAdFlush = true end
    scheduleEventQueuePersistence()
    return true, nil
end

local function flushAutomaticStorage()
    if not state_.storage or not state_.persistentStorageAvailable then return true end
    local failure
    local ok, reason = pcall(function()
        state_.storage:Flush(function(error) failure = error end)
    end)
    if not ok then failure = reason end
    if failure then
        state_.queuePersistenceDirty = true
        log("automatic storage flush failed: " .. tostring(failure))
    end
    return ok and failure == nil
end

local sendEndSnapshot
local sendAdBatch
local startFlush

local function handleLifecycleSessionEnd(eventName, reason)
    if not state_.sessionId or not state_.sessionStartMs then return end
    -- A normal Will/Did pair needs one snapshot. Update clears this marker so
    -- a later Did-only background still works without foreground notifications.
    if eventName == "AppDidEnterBackground" and state_.backgroundWillSnapshotPending then
        state_.backgroundWillSnapshotPending = false
        return
    end
    local occurredAt = clockMs()
    local payload = {
        reason = reason,
        lifecycleEvent = eventName,
        sessionDurationMs = GameAlgo.GetForegroundTimeMs() - state_.sessionForegroundStartMs,
    }
    if not state_.storageReady then
        if queueAdmissionError("session_end", #state_.pendingTracks) then
            log("lifecycle session_end not queued: pending event queue is full")
            return
        end
        table.insert(state_.pendingTracks, {
            eventType = "session_end",
            payload = payload,
            timestamp = isoNow(),
            createdLocalAt = localIsoNow(),
            occurredAtMs = occurredAt,
            sessionId = state_.sessionId,
            sessionEndSnapshot = true,
        })
        state_.backgroundWillSnapshotPending = eventName == "AppWillEnterBackground"
        state_.lifecycleFlushPending = true
        return
    end

    -- Backgrounding includes fullscreen ads in Maker. This is an end snapshot,
    -- not a session rotation or an explicit terminal end. Later backgrounds and
    -- NewSession must still be able to report a newer duration for this session.
    local tracked, error = enqueueTrack("session_end", payload, nil, nil, true)
    if not tracked then log("lifecycle session_end not queued: " .. tostring(error)) end
    if tracked then state_.backgroundWillSnapshotPending = eventName == "AppWillEnterBackground" end
    persistEventQueue()
    flushAutomaticStorage()
    GameAlgo.Flush(nil)
end

local function ensureAutomaticUpdateDriver()
    if state_.internalUpdateSubscribed and state_.internalUpdateObject ~= nil then return true end
    local nodeFactory = nil
    pcall(function() nodeFactory = Node end)
    if nodeFactory == nil then
        log("automatic update driver unavailable; timed flush will run on subsequent SDK calls")
        return false
    end
    local eventNode = nil
    local eventObject = nil
    local subscribed = pcall(function()
        eventNode = nodeFactory()
        eventObject = eventNode:CreateScriptObject("LuaScriptObject")
        eventObject:SubscribeToEvent("Update", function(_, _, eventData)
            if eventData ~= nil then
                local ok, delta = pcall(function() return eventData:GetFloat("TimeStep") end)
                if ok and type(delta) == "number" and delta == delta and delta > 0 and delta < math.huge then
                    state_.foregroundTimeMs = state_.foregroundTimeMs + delta * 1000
                end
            end
            local updateOk, updateError = pcall(GameAlgo.Update)
            if not updateOk then log("automatic update failed: " .. tostring(updateError)) end
        end)
    end)
    if subscribed and eventObject ~= nil then
        -- Retain both objects for the full SDK lifetime. Using a dedicated
        -- receiver avoids replacing the game's global Update subscription.
        state_.internalUpdateNode = eventNode
        state_.internalUpdateObject = eventObject
        state_.internalUpdateSubscribed = true
        for eventName, reason in pairs({
            AppWillEnterBackground = "app_background",
            AppDidEnterBackground = "app_background",
            AppTerminating = "app_terminating",
            ExitRequested = "exit_requested",
        }) do
            -- Each optional lifecycle subscription is isolated so a custom
            -- runtime that only supports Update keeps its automatic timer.
            local lifecycleOk, lifecycleError = pcall(function()
                eventObject:SubscribeToEvent(eventName, function()
                    local ok, error = pcall(handleLifecycleSessionEnd, eventName, reason)
                    if not ok then log("automatic session_end failed: " .. tostring(error)) end
                end)
            end)
            if not lifecycleOk then
                log("lifecycle listener unavailable: " .. eventName .. " " .. tostring(lifecycleError))
            end
        end
        log("automatic update driver ready")
        return true
    end
    state_.internalUpdateNode = nil
    state_.internalUpdateObject = nil
    state_.internalUpdateSubscribed = false
    log("automatic update driver unavailable; timed flush will run on subsequent SDK calls")
    return false
end

local function completeInitialization(options)
    if state_.initializationComplete then return end
    state_.storageReady = true
    state_.initializationComplete = true

    ensureIdentity(options.userId, options.userCreatedAt, options.userCreatedLocalAt)
    ensureAccountIdentity(options.accountUserId or state_.prefetchedMakerUserId, options.accountUserCreatedAt)
    state_.sessionAttribution = sessionAttribution()
    restoreReachedMilestones()
    restoreEventQueue()

    for _, controller in pairs(state_.ddaControllers) do
        if type(controller._Hydrate) == "function" then controller._Hydrate() end
    end
    for _, pending in ipairs(state_.pendingTracks) do
        local prepared, key, durable, duplicate = prepareMilestone(
            pending.eventType,
            pending.payload,
            pending.occurredAtMs
        )
        local tracked, trackError = false, "duplicate milestone"
        if not duplicate then
            tracked, trackError = enqueueTrack(pending.eventType, prepared, pending.timestamp,
                pending.createdLocalAt, pending.sessionEndSnapshot)
            if tracked and key then
                rememberMilestone(key, durable)
                persistEventQueue()
            end
        end
        if not tracked then log("pending event dropped: " .. tostring(trackError)) end
    end
    state_.pendingTracks = {}

    if not state_.gameKey or state_.gameKey == "" then
        log("missing gameKey; config and event requests will be rejected")
    end
    log("initialized: userId=" .. state_.userId
        .. ", accountUserId=" .. tostring(state_.accountUserId or "-")
        .. ", sessionId=" .. state_.sessionId)
    flushAutomaticStorage()

    if state_.lifecycleFlushPending then
        state_.lifecycleFlushPending = false
        persistEventQueue()
        flushAutomaticStorage()
        GameAlgo.Flush(nil)
    end

    if state_.fetchConfigRequested then
        local callbacks = state_.pendingFetchConfigCallbacks
        state_.pendingFetchConfigCallbacks = {}
        GameAlgo.FetchConfig(function(error, config)
            for _, callback in ipairs(callbacks) do safeCallback(callback, error, config) end
        end)
    end
end

local function numericOption(options, name, default)
    if options[name] == nil then return default end
    local value = tonumber(options[name])
    if not value or value ~= value or math.abs(value) == math.huge then
        error(name .. " must be a finite number")
    end
    return value
end

--- Initializes a game/user session after checkpointing the previous one. A failed
--- local checkpoint raises an error and leaves the previous instance available for retry.
---@param options table SDK identity, transport, timing and queue options.
---@return table sdk
function GameAlgo.Init(options)
    if options == nil then options = {} end
    if type(options) ~= "table" then error("Init options must be a table") end
    if options.storage ~= nil then
        error("options.storage is not supported; TapTap Maker storage is managed automatically by the Lua SDK")
    end
    local integrationVersion = numericOption(options, "experimentIntegrationVersion", 0)
    if integrationVersion < 0 or integrationVersion % 1 ~= 0 then
        error("experimentIntegrationVersion must be a non-negative integer")
    end
    local maxBatch = math.min(MAX_HTTP_BATCH_SIZE, math.max(1, math.floor(numericOption(options, "maxBatchSize", MAX_HTTP_BATCH_SIZE))))
    local maxQueue = math.max(maxBatch, math.floor(numericOption(options, "maxQueueSize", DEFAULT_MAX_QUEUE_SIZE)))
    local maxCallbacks = math.max(1, math.floor(numericOption(options, "maxPendingFlushCallbacks", DEFAULT_MAX_PENDING_FLUSH_CALLBACKS)))
    local interval = math.max(0, numericOption(options, "flushIntervalMs", DEFAULT_FLUSH_INTERVAL_MS))
    local timeout = math.max(1000, numericOption(options, "flushTimeoutMs", DEFAULT_FLUSH_TIMEOUT_MS))
    local transport = options.transport or HttpTransport
    if type(transport) ~= "table" or type(transport.Request) ~= "function" then error("transport.Request must be a function") end
    if options.device ~= nil and type(options.device) ~= "table" then error("device must be a table") end
    if options._scheduler ~= nil and type(options._scheduler) ~= "table" then error("invalid scheduler") end
    for _, name in ipairs({ "sessionId", "baseUrl", "gameKey", "appVersion", "timezone" }) do
        if options[name] ~= nil and type(options[name]) ~= "string" then error(name .. " must be a string") end
    end

    -- Chunks own both queued and in-flight events. Commit their complete index
    -- before retiring any HTTP handles or opening the next storage snapshot.
    if not persistEventQueue() or not flushAutomaticStorage() then
        error("cannot reinitialize GameAlgo: previous local checkpoint failed")
    end
    local storage = state_.storage
    if not storage or state_.persistentStorageAvailable then
        local storageError
        storage, storageError = MakerAutoStorage.New({ logger = function(message) logTo(options.logger, message) end })
        if not storage then error(storageError) end
    end
    if type(transport.Start) == "function" then transport.Start(options.transportOptions) end
    local previousScripts = state_.scriptRequests
    local previousActive = state_.activeFlush
    local previousEnd = state_.activeEndFlush
    local previousAd = state_.activeAdFlush
    local previousConfigRequestHandle = state_.configFetchRequestHandle
    local previousTransport = state_.transport
    state_.activeFlush = nil
    state_.activeEndFlush = nil
    state_.activeAdFlush = nil
    state_.flushing = false
    state_.lifecycleGeneration = state_.lifecycleGeneration + 1
    if previousActive then cancelTransportRequest(previousTransport, previousActive.handle) end
    if previousEnd then cancelTransportRequest(previousTransport, previousEnd.handle) end
    if previousAd then cancelTransportRequest(previousTransport, previousAd.handle) end
    if previousConfigRequestHandle then cancelTransportRequest(previousTransport, previousConfigRequestHandle) end
    if state_.scheduler and state_.scheduler ~= options._scheduler and type(state_.scheduler.Shutdown) == "function" then
        state_.scheduler:Shutdown()
    elseif state_.scheduler and type(state_.scheduler.Cancel) == "function" then
        for _, handle in pairs({ state_.configFetchTimeoutHandle, state_.configFetchRetryHandle, state_.initWatchdogHandle }) do
            state_.scheduler:Cancel(handle)
        end
    end
    if state_.storage and state_.storage ~= storage then
        state_.storage:Shutdown()
    end
    state_.baseUrl = options.baseUrl or DEFAULT_BASE_URL
    state_.gameKey = options.gameKey
    state_.appVersion = options.appVersion
    state_.experimentIntegrationVersion = integrationVersion
    -- Maker is a runtime property of this SDK, not an application option.
    -- Ignore legacy `platform` input so older integrations keep working while
    -- current clients always emit the canonical storage value.
    state_.platform = "maker"
    state_.timezone = options.timezone
    state_.device = options.device or {}
    state_.isDebug = options.isDebug == true
    state_.logger = options.logger
    state_.transport = transport
    state_.maxBatchSize = maxBatch
    state_.maxQueueSize = maxQueue
    state_.maxPendingFlushCallbacks = maxCallbacks
    state_.flushIntervalMs = interval
    state_.flushTimeoutMs = timeout
    state_.clock = type(options.nowMs) == "function" and options.nowMs or nowMs
    state_.preloadConfigFiles = options.preloadConfigFiles ~= false
    state_.sessionId = options.sessionId or randomId("ga_session")
    state_.sessionStartMs = clockMs()
    state_.foregroundTimeMs = 0
    state_.sessionForegroundStartMs = 0
    state_.sessionHasEnd = false
    state_.userId = nil
    state_.userCreatedAt = nil
    state_.userCreatedLocalAt = nil
    state_.accountUserId = nil
    state_.accountUserCreatedAt = nil
    state_.prefetchedMakerUserId = nil
    state_.contextId = nil
    state_.config = nil
    state_.configFiles = {}
    state_.configFileRequests = {}
    state_.scripts = {}
    state_.scriptRequests = {}
    state_.ddaControllers = {}
    state_.queue = {}
    state_.flushableEvents = 0
    state_.eventQueueStorage = nil
    state_.pendingTracks = {}
    state_.lifecycleFlushPending = false
    state_.pendingEndSnapshot = nil
    state_.pendingAdFlush = false
    state_.adPriorityHandled = {}
    state_.backgroundWillSnapshotPending = false
    state_.customEventCounts = {}
    state_.ordinaryEventCounts = {}
    state_.eventQuota = nil
    state_.eventGuardDiagnosticKeys = {}
    state_.eventGuardDiagnosticCount = 0
    state_.reachedMilestoneKeys = {}
    state_.pendingMilestoneKeys = {}
    state_.consecutiveFlushFailures = 0
    state_.queuePersistenceDirty = false
    state_.milestoneMarkersDirty = false
    state_.deferredMilestoneAcks = {}
    state_.queueEventsSincePersist = 0
    state_.lastQueuePersistAtMs = clockMs()
    state_.flushing = false
    state_.activeFlush = nil
    state_.flushSequence = 0
    state_.flushRequested = false
    state_.pendingFlushCallbacks = {}
    state_.pendingFlushAccepted = 0
    state_.pendingFlushRejected = 0
    state_.nextAutoFlushAtMs = nil
    state_.retryFlushAtMs = nil
    state_.storageReady = false
    state_.initializationComplete = false
    state_.fetchConfigRequested = options.autoFetch ~= false
    state_.pendingFetchConfigCallbacks = {}
    state_.configFetchCallbacks = {}
    state_.configFetchBodies = {}
    state_.configFetchBody = nil
    state_.configFetchInFlight = false
    state_.configFetchAttempt = 0
    state_.configFetchRetryHandle = nil
    state_.configFetchRequestHandle = nil
    state_.configFetchTimeoutHandle = nil
    state_.initWatchdogHandle = nil
    state_.initDiagnosticReported = false
    state_.tapDbContextLinkAttempted = false
    state_.tapDbContextLinkProperties = nil
    state_.tapDbContextLinkNextCheckAtMs = 0
    state_.tapDbContextLinkDiscoveryUntilMs = 0
    state_.gamealgoStandardReportingEnabled = true
    state_.gamealgoCustomReportingEnabled = true
    state_.tapdbStandardReportingEnabled = false
    state_.tapdbCustomReportingEnabled = false
    state_.directCompleted = {}
    state_.directCompletedRing = {}
    state_.directCompletedNext = 1
    state_.tapdbAttemptedKeys = {}
    state_.tapdbAttemptedRing = {}
    state_.tapdbAttemptedNext = 1
    state_.pendingFlushSkipped = 0
    state_.pendingFlushTapdbAttempted = 0
    -- Keep the Maker account separate from the locally persisted SDK identity.
    -- Config diagnostics can use it even when local storage is unavailable.
    state_.prefetchedMakerUserId = options.accountUserId or resolveMakerUserId()
    ensureAutomaticUpdateDriver()
    state_.scheduler = options._scheduler or MakerAutoStorage.NewScheduler({
        logger = log,
        nowMs = state_.clock,
        externallyDriven = state_.internalUpdateSubscribed,
    })
    state_.storage = storage
    state_.persistentStorageAvailable = storage:Diagnostics().persistentStorageAvailable == true
    local initGeneration = state_.lifecycleGeneration
    if state_.fetchConfigRequested and state_.scheduler and type(state_.scheduler.Schedule) == "function" then
        state_.initWatchdogHandle = state_.scheduler:Schedule(INIT_WATCHDOG_MS, function()
            if initGeneration == state_.lifecycleGeneration then reportInitTimeout() end
        end)
    end
    storage:OnReady(function()
        if initGeneration ~= state_.lifecycleGeneration or state_.storage ~= storage then
            log("stale storage ready callback ignored (SDK reinitialized)")
            return
        end
        completeInitialization(options)
    end)
    for _, request in pairs(previousScripts) do request.cancel() end
    return GameAlgo
end

local beginNextConfigFetch
local function finishConfigFetch(request, error, config)
    if state_.configFetchBody ~= request then return end
    local owner = request.owner
    local generation = state_.lifecycleGeneration
    state_.configFetchInFlight = false
    state_.configFetchBody = nil
    state_.configFetchAttempt = 0
    state_.configFetchRetryHandle = nil
    state_.configFetchRequestHandle = nil
    state_.configFetchTimeoutHandle = nil
    local completed, waiting = {}, {}
    for _, entry in ipairs(state_.configFetchCallbacks) do
        table.insert(entry.owner == owner and completed or waiting, entry)
    end
    state_.configFetchCallbacks = waiting
    for _, entry in ipairs(completed) do safeCallback(entry.callback, error, config) end
    if generation == state_.lifecycleGeneration then beginNextConfigFetch() end
end

local function isRetryableConfigFailure(response)
    local status = tonumber(response and response.status) or 0
    return status == 0 or status == 408 or status == 425 or status == 429 or status >= 500
end

local RUNTIME_IDENTITY_FIELDS = {
    runtimeMiniappId = true, runtimeProjectId = true,
    runtimeAppId = true, runtimeIdentitySource = true,
}

local function runtimeMiniappId(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if #value > 128 or not value:match("^tapmc[a-z0-9]+$") then return nil end
    return value
end

local function runtimeIdentity()
    local ok, value = pcall(function()
        if type(GetAppArgv) == "function" then return GetAppArgv("miniapp_id") end
    end)
    return { runtimeMiniappId = ok and runtimeMiniappId(value) or nil }
end

local function deviceContext()
    local device = {}
    local osNames = {
        ios = "ios", ipados = "ios", iphoneos = "ios", android = "android",
        mac = "macos", macos = "macos", macosx = "macos", darwin = "macos",
        windows = "windows", windowsnt = "windows", win32 = "windows", win64 = "windows",
        linux = "linux", harmonyos = "harmonyos", openharmony = "harmonyos", ohos = "harmonyos",
    }
    for _, name in ipairs({"GetNativePlatform", "GetPlatform"}) do
        local fn = _G[name]
        if type(fn) == "function" then
            local ok, value = pcall(fn)
            if ok and type(value) == "string" then
                local key = value:lower():gsub("[%s_-]+", "")
                if osNames[key] then device.os = osNames[key]; break end
            end
        end
    end
    -- GetOSVersion can report a macOS/Darwin description on an iPhone.
    -- Only use a version explicitly supplied by the game.
    for key, value in pairs(state_.device) do
        if not RUNTIME_IDENTITY_FIELDS[key] then device[key] = value end
    end
    for key, value in pairs(runtimeIdentity()) do device[key] = value end
    return device
end

local function configRequestBody()
    return {
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
        device = deviceContext(),
        isDebug = state_.isDebug,
    }
end

-- Optional collections may be missing or malformed on older backends. Only
-- publish references that their public lookup/preload paths can consume.
local function configReferences(items, field)
    local valid = {}
    if type(items) == "table" then
        for _, item in ipairs(items) do
            if type(item) == "table" and type(item[field]) == "string" then table.insert(valid, item) end
        end
    end
    return valid
end

local performConfigFetchAttempt
performConfigFetchAttempt = function()
    if not state_.configFetchInFlight then return end
    state_.configFetchRetryHandle = nil
    state_.configFetchAttempt = state_.configFetchAttempt + 1
    local attempt = state_.configFetchAttempt
    local generation = state_.lifecycleGeneration
    local request = state_.configFetchBody
    local requestBody, owner = request.body, request.owner
    local scheduler = state_.scheduler
    local settled = false

    local function scheduleRetry(error)
        local delayMs = math.min(CONFIG_FETCH_RETRY_MAX_MS,
            CONFIG_FETCH_RETRY_BASE_MS * (2 ^ math.min(attempt - 1, 5)))
        local handle = scheduler ~= nil and type(scheduler.Schedule) == "function"
            and scheduler:Schedule(delayMs, function()
                if generation ~= state_.lifecycleGeneration or not state_.configFetchInFlight then return end
                if owner ~= state_.sessionAttribution then
                    -- The session changed while this retry was pending. Hand the
                    -- in-flight slot back to the queue instead of retrying.
                    finishConfigFetch(request, error, nil)
                    return
                end
                performConfigFetchAttempt()
            end) or nil
        if handle then
            state_.configFetchRetryHandle = handle
            log("config fetch failed; retrying in " .. tostring(delayMs)
                .. "ms (next attempt " .. tostring(attempt + 1) .. "): " .. tostring(error))
            return true
        end
        return false
    end

    local function completeAttempt(error, config, response)
        if generation ~= state_.lifecycleGeneration or not state_.configFetchInFlight then return end
        state_.configFetchRequestHandle = nil
        state_.configFetchTimeoutHandle = nil

        if not error then
            local contextId = type(config) == "table" and config.contextId or nil
            if type(contextId) ~= "string" or contextId == "" then
                error = "invalid config response: contextId is required"
                response = { status = 0 }
            end
        end

        if error then
            if owner ~= state_.sessionAttribution then
                -- A newer session is waiting behind this request. Stop
                -- retrying the old session and release the in-flight slot so
                -- the queue advances; the current session's response adopts
                -- any orphaned events from the previous one.
                log("config fetch aborted for stale session: " .. tostring(error))
                finishConfigFetch(request, error, nil)
                return
            end
            if isRetryableConfigFailure(response) and scheduleRetry(error) then return end
            log("config fetch failed: " .. tostring(error))
            finishConfigFetch(request, error, nil)
            return
        end
        local contextId = config.contextId
        config.experiments = configReferences(config.experiments, "key")
        config.configFiles = configReferences(config.configFiles, "name")
        owner.contextId = contextId
        local current = owner == state_.sessionAttribution
        if current then
            local previous = state_.config
            if not previous or config.configVersion == nil or previous.configVersion ~= config.configVersion
                or previous.contextId ~= contextId then
                state_.configFileRequests = {}
                state_.configFiles = {}
            end
            state_.config = config
            state_.eventQuota = normalizeEventQuota(config)
            state_.contextId = contextId
            state_.gamealgoStandardReportingEnabled = config.gamealgoStandardReportingEnabled ~= false
            state_.gamealgoCustomReportingEnabled = config.gamealgoCustomReportingEnabled ~= false
            state_.tapdbStandardReportingEnabled = config.tapdbStandardReportingEnabled == true
            state_.tapdbCustomReportingEnabled = config.tapdbCustomReportingEnabled == true
        end
        mergeCustomEventCountBucket("pending:" .. tostring(requestBody.sessionId), "context:" .. contextId)
        mergeOrdinaryEventCountBucket("pending:" .. tostring(requestBody.sessionId), "context:" .. contextId)
        bindQueuedEvents(contextId, requestBody, current)
        if state_.milestoneMarkersDirty then persistEventQueue() end
        if state_.initWatchdogHandle and state_.scheduler and type(state_.scheduler.Cancel) == "function" then
            state_.scheduler:Cancel(state_.initWatchdogHandle)
            state_.initWatchdogHandle = nil
        end
        reportTapDbContextLink(config, requestBody)
        if generation ~= state_.lifecycleGeneration then return end
        log("config fetched: version=" .. tostring(config.configVersion or "unknown"))
        if generation ~= state_.lifecycleGeneration then return end
        finishConfigFetch(request, nil, config)
        if generation ~= state_.lifecycleGeneration then return end
        if current and state_.config == config and state_.preloadConfigFiles then
            for _, file in ipairs(config.configFiles or {}) do
                if state_.config ~= config then return end
                if not state_.configFiles[file.name] then GameAlgo.FetchConfigFile(file.name, nil) end
            end
            local canExecute = #config.experiments > 0 and LuaScriptRuntime.CanEnforceLimit()
            for _, experiment in ipairs(config.experiments) do
                if state_.config ~= config then return end
                if canExecute and type(experiment.script) == "table" then
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
        if generation == state_.lifecycleGeneration then
            startFlush(false)
            sendEndSnapshot()
            sendAdBatch()
        end
    end

    local requestTimeoutHandle = nil
    local requestHandle = httpRequest("POST", "/v1/config", requestBody, function(error, config, response)
        if settled or generation ~= state_.lifecycleGeneration then return end
        settled = true
        if requestTimeoutHandle and scheduler and type(scheduler.Cancel) == "function" then
            scheduler:Cancel(requestTimeoutHandle)
        end
        completeAttempt(error, config, response)
    end)

    -- Maker normally applies its own HTTP timeout, but this independent guard
    -- also recovers when the engine never invokes either request callback.
    if not settled and generation == state_.lifecycleGeneration and state_.configFetchInFlight then
        state_.configFetchRequestHandle = requestHandle
        if scheduler and type(scheduler.Schedule) == "function" then
            requestTimeoutHandle = scheduler:Schedule(CONFIG_FETCH_TIMEOUT_MS, function()
                if settled or generation ~= state_.lifecycleGeneration or not state_.configFetchInFlight then return end
                settled = true
                state_.configFetchRequestHandle = nil
                state_.configFetchTimeoutHandle = nil
                cancelTransportRequest(state_.transport, requestHandle)
                completeAttempt("config request timed out after " .. tostring(CONFIG_FETCH_TIMEOUT_MS) .. "ms", nil, {
                    status = 0,
                })
            end)
            if not settled then state_.configFetchTimeoutHandle = requestTimeoutHandle end
        end
    end
end

beginNextConfigFetch = function()
    if state_.configFetchInFlight or #state_.configFetchBodies == 0 then return end
    state_.configFetchBody = table.remove(state_.configFetchBodies, 1)
    state_.configFetchInFlight = true
    state_.configFetchAttempt = 0
    performConfigFetchAttempt()
end

--- Fetches the current session configuration and joins a request already in progress.
---@param callback function|nil Receives (error, config) for the requesting session.
function GameAlgo.FetchConfig(callback)
    if not state_.storageReady then
        state_.fetchConfigRequested = true
        if type(callback) == "function" then table.insert(state_.pendingFetchConfigCallbacks, callback) end
        return
    end
    ensureIdentity()
    if type(callback) == "function" then
        table.insert(state_.configFetchCallbacks, { owner = state_.sessionAttribution, callback = callback })
    end
    local owner = state_.sessionAttribution
    if state_.configFetchBody and state_.configFetchBody.owner == owner then return end
    for _, request in ipairs(state_.configFetchBodies) do
        if request.owner == owner then return end
    end
    table.insert(state_.configFetchBodies, { owner = owner, body = configRequestBody() })
    beginNextConfigFetch()
end


--- Fetches and verifies an immutable script. Callers waiting for the same
--- version and digest share one download and one verification.
---@param script table Script reference with name, versionId, hash and URL.
---@param callback function|nil Receives (error, file) on completion or supersession.
function GameAlgo.FetchScript(script, callback)
    if type(script) ~= "table" then safeCallback(callback, "invalid script reference", nil); return end
    if not isLuaScript(script) then
        safeCallback(callback, "unsupported Lua SDK script type: " .. tostring(script.name), nil)
        return
    end
    local key = scriptCacheKey(script)
    if not key then safeCallback(callback, "script versionId is required", nil); return end
    if type(script.hash) ~= "string" or script.hash == "" then safeCallback(callback, "script hash is required", nil); return end
    local cached = cachedScript(script)
    if cached then safeCallback(callback, nil, copyScript(cached)); return end
    local expected = script.hash:lower()
    local previous = state_.scriptRequests[key]
    if previous and previous.hash == expected then
        if callback then table.insert(previous.callbacks, callback) end
        return
    end

    local generation = state_.lifecycleGeneration
    local requests, transport = state_.scriptRequests, state_.transport
    local diskKey, legacyKey = scriptStorageKey(script), legacyScriptStorageKey(script)
    local url = script.url
    if type(url) == "string" and url:sub(1, 2) == "//" then
        url = (state_.baseUrl:match("^([%a]+):") or "https") .. ":" .. url
    elseif type(url) == "string" and url:sub(1, 1) == "/" then
        url = trimSlash(state_.baseUrl) .. url
    end
    local file = { name = script.name, versionId = script.versionId, contentType = script.contentType, hash = script.hash }
    local request = { hash = expected, callbacks = { callback } }
    requests[key] = request
    local function current() return state_.lifecycleGeneration == generation and requests[key] == request end
    local function finish(error, content)
        if not request.callbacks then return end
        if not current() then error = "stale script response" end
        if requests[key] == request then requests[key] = nil end
        local callbacks = request.callbacks
        request.callbacks = nil
        if not error then
            file.content = content
            state_.scripts[key] = file
            storageSet(diskKey, content)
        end
        for _, waiter in ipairs(callbacks) do safeCallback(waiter, error, not error and copyScript(file) or nil) end
    end
    function request.cancel()
        if request.hashTask then request.hashTask:Cancel() end
        cancelTransportRequest(transport, request.handle)
        finish("stale script response")
    end
    if previous then previous.cancel() end
    if not current() then return end

    local function verify(content, nextStep)
        if type(content) ~= "string" then finish("invalid script content"); return end
        local task = Sha256.hashAsync(content, state_.scheduler, function(error, digest)
            if not current() then finish("stale script response"); return end
            if error then finish(error); return end
            if digest == expected then finish(nil, content); return end
            if nextStep then nextStep() else finish("script hash mismatch: expected " .. expected .. ", got " .. digest) end
        end)
        if task then request.hashTask = task end
    end
    local function download()
        if type(url) ~= "string" or url == "" then finish("script url is required"); return end
        request.handle = rawHttpRequest("GET", url, function(error, response)
            if not current() then finish("stale script response"); return end
            if error then finish(error); return end
            verify(response and response.body or "")
        end)
    end
    local persisted = storageGet(diskKey) or storageGet(legacyKey)
    if type(persisted) == "string" and persisted ~= "" then verify(persisted, download) else download() end
end

--- Downloads a named file from the active config revision. Concurrent callers
--- share its result. A superseded revision or session completes with an error.
---@param name string Config file name.
---@param callback function|nil Receives (error, file).
function GameAlgo.FetchConfigFile(name, callback)
    if type(name) ~= "string" or name == "" or name:find("..", 1, true) then
        safeCallback(callback, "invalid config file name", nil)
        return
    end
    local requests = state_.configFileRequests
    local waiters = requests[name]
    if waiters then
        if callback then table.insert(waiters, callback) end
        return
    end
    waiters = { callback }
    requests[name] = waiters
    httpRequest("GET", "/v1/config-files/" .. urlEncode(name), nil, function(error, _, response)
        requests[name] = nil
        local file
        if state_.configFileRequests ~= requests then
            error = "stale config file response"
        elseif not error then
            file = { name = name, content = response and response.body or "" }
            state_.configFiles[name] = file
        end
        if error then log("config file fetch failed: " .. name .. " " .. tostring(error)) end
        for _, waiter in ipairs(waiters) do safeCallback(waiter, error, file) end
    end)
end

--- Enqueues an event for the current identity and schedules its local checkpoint.
---@param eventType string Wire event type.
---@param payload table|nil JSON-serializable event properties.
---@return boolean accepted
---@return string|nil error
function GameAlgo.Track(eventType, payload)
    if not eventType or eventType == "" then return false end
    local payloadCopy, payloadError = preparePayload(payload)
    if payloadError then
        log("event rejected: " .. tostring(eventType) .. " " .. tostring(payloadError))
        return false, payloadError
    end
    if not state_.storageReady then
        local queueError = queueAdmissionError(eventType, #state_.pendingTracks)
        if queueError then
            log("event rejected: " .. tostring(eventType) .. " " .. queueError)
            return false, queueError
        end
        if eventType == "milestone"
            and type(payloadCopy.milestoneType) == "string" and payloadCopy.milestoneType ~= ""
            and type(payloadCopy.milestonePoint) == "string" and payloadCopy.milestonePoint ~= "" then
            for _, pending in ipairs(state_.pendingTracks) do
                if pending.eventType == "milestone"
                    and pending.payload.milestoneType == payloadCopy.milestoneType
                    and pending.payload.milestonePoint == payloadCopy.milestonePoint then
                    return false, "duplicate milestone"
                end
            end
        end
        local ordinaryAccepted, ordinaryError = consumeOrdinaryEventQuota(eventType, false)
        if not ordinaryAccepted then
            log("event rejected: " .. tostring(eventType) .. " " .. tostring(ordinaryError))
            return false, ordinaryError
        end
        local quotaAccepted, quotaError = consumeCustomEventQuota(eventType)
        if not quotaAccepted then
            log("event rejected: " .. tostring(eventType) .. " " .. tostring(quotaError))
            return false, quotaError
        end
        consumeOrdinaryEventQuota(eventType, true)
        table.insert(state_.pendingTracks, {
            eventType = eventType,
            payload = payloadCopy,
            timestamp = isoNow(),
            createdLocalAt = localIsoNow(),
            occurredAtMs = clockMs(),
            sessionId = state_.sessionId,
        })
        if eventType == "session_end" then state_.sessionHasEnd = true end
        return true
    end
    ensureIdentity()
    local queueError = queueAdmissionError(eventType, outstandingEventCount())
    if queueError then
        log("event rejected: " .. tostring(eventType) .. " " .. queueError)
        return false, queueError
    end
    local prepared, key, durable, duplicate = prepareMilestone(
        eventType,
        payloadCopy,
        clockMs()
    )
    if duplicate then return false, "duplicate milestone" end
    local ordinaryAccepted, ordinaryError = consumeOrdinaryEventQuota(eventType, false)
    if not ordinaryAccepted then
        log("event rejected: " .. tostring(eventType) .. " " .. tostring(ordinaryError))
        return false, ordinaryError
    end
    local quotaAccepted, quotaError = consumeCustomEventQuota(eventType)
    if not quotaAccepted then
        log("event rejected: " .. tostring(eventType) .. " " .. tostring(quotaError))
        return false, quotaError
    end
    consumeOrdinaryEventQuota(eventType, true)
    local tracked, trackError = enqueueTrack(eventType, prepared, nil, nil)
    if not tracked then
        log("event rejected: " .. tostring(eventType) .. " " .. tostring(trackError))
        return false, trackError
    end
    if key then
        rememberMilestone(key, durable)
        persistEventQueue()
    end
    if eventType == "ad_view" then
        GameAlgo.Flush(nil)
    elseif state_.contextId and state_.contextId ~= ""
        and not state_.activeFlush
        and (#state_.queue >= state_.maxBatchSize
            or (state_.nextAutoFlushAtMs and clockMs() >= state_.nextAutoFlushAtMs)) then
        startFlush(false)
    end
    return true, nil
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

function GameAlgo.TrackMilestone(milestoneType, milestonePoint, payload)
    local merged, payloadError = preparePayload(payload)
    if payloadError then return false, payloadError end
    merged.milestoneType = milestoneType
    merged.milestonePoint = milestonePoint
    return GameAlgo.Track("milestone", merged)
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

local function validAdPlacementId(adPlacementId)
    return type(adPlacementId) == "string" and #adPlacementId == 36
        and adPlacementId:match("^gap_[a-f0-9]+$") ~= nil
end

local function setAdFields(payload, adPlacementId, revenue, network)
    payload.placement, payload.adType, payload.currency = nil, nil, nil
    payload.adPlacementId, payload.revenue = adPlacementId, revenue
    if network and network ~= "" then payload.network = network end
end

function GameAlgo.TrackAdPlacement(adPlacementId, revenue, network, payload)
    if not validAdPlacementId(adPlacementId) then
        return false, "adPlacementId must be gap_ followed by 32 lowercase hex characters"
    end
    if type(revenue) ~= "number" or revenue ~= revenue or revenue == math.huge or revenue == -math.huge then
        return false, "revenue must be a finite number"
    end
    if type(network) == "table" and payload == nil then
        payload = network
        network = nil
    end
    local merged, payloadError = preparePayload(payload)
    if payloadError then return false, payloadError end
    setAdFields(merged, adPlacementId, revenue, network)
    local tracked = GameAlgo.Track("ad_view", merged)
    return tracked
end

-- A result can arrive after the player or session changes. A different user's
-- queue is replayed on their next Init, using their own transport credentials.
local function queueRewardResult(owner, contextAtRequest, queueLimit, placement, payload)
    local current = state_.sessionAttribution
    if not owner or not current then return false end
    if current == owner and (not contextAtRequest or contextAtRequest == current.contextId) then
        return GameAlgo.TrackAdPlacement(placement, 0, "taptap", payload)
    end
    local attribution = { userId = owner.userId, accountUserId = owner.accountUserId, sessionId = owner.sessionId,
        isDebug = owner.isDebug, contextId = contextAtRequest or owner.contextId }
    setAdFields(payload, placement, 0, "taptap")
    if current.queueKey == owner.queueKey then
        if not attribution.contextId and current.isDebug == owner.isDebug then
            attribution.contextId = current.contextId
        end
        local queued = enqueueTrack("ad_view", payload, nil, nil, nil, attribution)
        if queued then GameAlgo.Flush(nil) end
        return queued
    end
    local queue = state_.storage:EventQueue(owner.queueKey)
    local limit = queueLimit - (queueLimit >= 10 and 1 or 0)
    if #queue:Events() >= limit then return false end
    queue:Upsert(makeEvent(attribution, "ad_view", payload))
    flushAutomaticStorage()
    return true
end

--- Asks Maker to show a rewarded ad and attributes its result to the initiating session.
--- A result without an original context can use a later one for the same game, user and debug mode.
--- Delivers the first native result to the business callback, including synchronous rejection.
---@param adPlacementId string Registered placement ID.
---@param callback function|nil Receives the original Maker result once.
---@param payload table|nil Additional event properties, captured at request time.
---@return boolean accepted
---@return string|nil error
function GameAlgo.ShowRewardVideoAd(adPlacementId, callback, payload)
    if not validAdPlacementId(adPlacementId) then
        return false, "adPlacementId must be gap_ followed by 32 lowercase hex characters"
    end
    if callback ~= nil and type(callback) ~= "function" then
        return false, "callback must be a function or nil"
    end
    local snapshot, payloadError = preparePayload(payload)
    if payloadError then return false, payloadError end
    snapshot.adElapsedMs, snapshot.adElapsedSource = nil, nil

    local owner = state_.sessionAttribution
    local contextAtRequest = owner and owner.contextId
    local queueLimit = state_.maxQueueSize
    local adClock = state_.clock or nowMs
    local function elapsedTime()
        local ok, value = pcall(adClock)
        value = ok and tonumber(value) or nil
        if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
            return math.floor(value)
        end
        return nil
    end

    local requestId = randomId("ga_ad")
    local returned, accepted, received, delivered = false, nil, false, false
    local firstResult
    local requestedAt, resultAt
    local function deliver()
        if delivered or not received then return end
        delivered = true
        if accepted == true then
            local trackId
            local ok, queued = pcall(function()
                trackId = GameAlgo.ExtractAdTrackId(firstResult)
                snapshot.trackId = trackId -- Never reuse a caller's stale Track ID.
                if requestedAt and resultAt then
                    local elapsed = resultAt - requestedAt
                    if elapsed >= 0 and elapsed <= 9007199254740991 then
                        snapshot.adElapsedMs = elapsed
                        snapshot.adElapsedSource = "request_to_result"
                    end
                end
                return queueRewardResult(owner, contextAtRequest, queueLimit, adPlacementId, snapshot)
            end)
            log("reward ad result: requestId=" .. requestId
                .. " queued=" .. tostring(ok and queued == true)
                .. " hasTrackId=" .. tostring(trackId ~= nil))
            if not ok then log("reward ad tracking failed: " .. tostring(queued)) end
            if not trackId then log("reward ad missing trackId: requestId=" .. requestId) end
        end
        safeCallback(callback, firstResult)
    end
    local function onResult(result)
        if received then
            log("reward ad duplicate callback ignored: requestId=" .. requestId)
            return
        end
        resultAt = elapsedTime()
        received, firstResult = true, result
        if returned then deliver() end
    end

    local ok, value = pcall(function()
        local host = sdk -- Maker globals may be exposed through a metatable.
        if not host or type(host.ShowRewardVideoAd) ~= "function" then
            error("Maker ShowRewardVideoAd is unavailable", 0)
        end
        requestedAt = elapsedTime()
        return host:ShowRewardVideoAd(onResult)
    end)
    accepted = ok and value or false
    returned = true
    log("reward ad request: requestId=" .. requestId .. " accepted=" .. tostring(accepted))
    deliver()
    if not ok then
        log("reward ad request failed: " .. tostring(value))
        return false, tostring(value)
    end
    return value
end

function GameAlgo.TrackPurchase(productId, revenue, currency, payload)
    local merged, payloadError = preparePayload(payload)
    if payloadError then return false, payloadError end
    if productId then merged.productId = productId end
    if revenue ~= nil then merged.revenue = revenue end
    if currency then merged.currency = currency end
    return GameAlgo.Track("purchase", merged)
end

--- Cumulative sampled foreground milliseconds since Init. Read-only; session
--- changes, tracking and config refresh never reset or advance this clock.
function GameAlgo.GetForegroundTimeMs()
    return math.floor(state_.foregroundTimeMs + 0.5)
end

function GameAlgo.TrackSessionEnd(payload)
    local merged, payloadError = preparePayload(payload)
    if payloadError then return false, payloadError end
    if merged.sessionDurationMs == nil and state_.sessionStartMs then
        merged.sessionDurationMs = GameAlgo.GetForegroundTimeMs() - state_.sessionForegroundStartMs
    end
    return GameAlgo.Track("session_end", merged)
end

local function hasFlushableEvents()
    local held = (state_.activeEndFlush and 1 or 0)
        + (state_.activeAdFlush and #state_.activeAdFlush.batch or 0)
    return state_.flushableEvents > held
end

local function prependBatch(batch)
    for index = #batch, 1, -1 do table.insert(state_.queue, 1, batch[index]) end
    state_.flushableEvents = state_.flushableEvents + #batch
    armAutoFlush()
end

local function retryDelayMs(failures)
    return math.min(30000, 1000 * (2 ^ math.min(5, math.max(0, failures - 1))))
end

local function completeFlushCallbacks(error, result)
    local callbacks = state_.pendingFlushCallbacks
    state_.pendingFlushCallbacks = {}
    for _, pendingCallback in ipairs(callbacks) do
        safeCallback(pendingCallback, error, result)
    end
end

local function queueFlushCallback(callback)
    if type(callback) ~= "function" then return true end
    if #state_.pendingFlushCallbacks >= state_.maxPendingFlushCallbacks then
        safeCallback(callback, "too many pending flush callbacks", nil)
        return false
    end
    table.insert(state_.pendingFlushCallbacks, callback)
    return true
end

local function cancelRequest(handle)
    cancelTransportRequest(state_.transport, handle)
end

local function failActiveFlush(active, error, cancel)
    if state_.activeFlush ~= active then return end
    state_.activeFlush = nil
    state_.flushing = false
    state_.flushRequested = true
    if cancel then cancelRequest(active.handle) end
    prependBatch(active.batch)
    state_.consecutiveFlushFailures = state_.consecutiveFlushFailures + 1
    state_.retryFlushAtMs = clockMs() + retryDelayMs(state_.consecutiveFlushFailures)
    state_.pendingFlushAccepted = 0
    state_.pendingFlushRejected = 0
    state_.pendingFlushSkipped = 0
    state_.pendingFlushTapdbAttempted = 0
    persistEventQueue()
    flushAutomaticStorage()
    log("flush failed: " .. tostring(error))
    completeFlushCallbacks(error, nil)
end

local function validateFlushResult(result, batchSize, localOnly)
    if type(result) ~= "table" then return nil, "invalid flush response" end
    if result.ok == false then return nil, tostring(result.error or "flush rejected") end
    local accepted = tonumber(result.accepted)
    if accepted == nil then return nil, "flush response missing accepted count" end
    if accepted < 0 or accepted > batchSize or accepted % 1 ~= 0 then
        return nil, "invalid flush accepted count: " .. tostring(result.accepted)
    end
    local skipped = localOnly and tonumber(result.skipped) or 0
    skipped = skipped or 0
    if skipped < 0 or skipped > batchSize or skipped % 1 ~= 0 then return nil, "invalid local routing receipt" end
    if localOnly and accepted == 0 and skipped == batchSize then
        return 0, nil, {}, skipped, tonumber(result.tapdbAttempted) or 0
    end
    local directBatchSize = batchSize - skipped
    if accepted > directBatchSize then return nil, "invalid routed accepted count" end

    -- A positive count proves the batch reached event processing. Prefer
    -- progress over replaying the whole batch; rejection details are advisory.
    if accepted > 0 then
        local rows = {}
        if type(result.rejected) == "table" then
            for _, row in ipairs(result.rejected) do
                if type(row) == "table" and #rows < directBatchSize - accepted then
                    table.insert(rows, row)
                end
            end
        end
        return accepted, nil, rows, skipped, tonumber(result.tapdbAttempted) or 0
    end

    local rejected = result.rejected
    if rejected == nil then rejected = {} end
    if type(rejected) ~= "table" then return nil, "invalid flush rejected rows" end
    for index, row in ipairs(rejected) do
        if type(row) ~= "table" then
            return nil, "invalid flush rejected row at position " .. tostring(index)
        end
    end

    if accepted + #rejected ~= directBatchSize then
        return nil, "partial flush acceptance: accepted=" .. tostring(accepted)
            .. ", rejected=" .. tostring(#rejected)
            .. ", sent=" .. tostring(batchSize)
    end
    return accepted, nil, rejected, skipped, tonumber(result.tapdbAttempted) or 0
end

local function resumeAfterCritical(error)
    if state_.activeFlush then return end
    if error then
        state_.flushRequested = true
        state_.retryFlushAtMs = state_.retryFlushAtMs or (clockMs() + retryDelayMs(1))
    else
        startFlush(false)
        sendEndSnapshot()
        sendAdBatch()
    end
end

local function finishEndFlush(active, error, result, localOnly)
    if state_.activeEndFlush ~= active or active.generation ~= state_.lifecycleGeneration then return end
    state_.activeEndFlush = nil
    if not error then
        local accepted, receiptError = validateFlushResult(result, 1, localOnly)
        error = receiptError
        if accepted and accepted > 0 then
            -- The durable queue still owns this event. Its normal flush can
            -- reuse the existing routing receipt instead of sending it again.
            rememberDirectEvents({ active.event })
        end
    end
    if error then log("session end immediate send failed; durable retry retained: " .. tostring(error))
    else log("session end immediate send acknowledged") end
    sendEndSnapshot()
    resumeAfterCritical(error)
end

local function recoverTimedOutEndFlush(currentTime)
    local active = state_.activeEndFlush
    if not active or currentTime - active.startedAtMs < state_.flushTimeoutMs then return end
    state_.activeEndFlush = nil
    cancelRequest(active.handle)
    log("session end immediate send timed out; durable retry retained")
    sendEndSnapshot()
    resumeAfterCritical("timeout")
end

sendEndSnapshot = function()
    local event = state_.pendingEndSnapshot
    if not event or not event.contextId or event.contextId == "" or not state_.storageReady then return end
    local ordinary = state_.activeFlush
    if not ordinary then return end
    for _, sent in ipairs(ordinary.batch) do
        if sent.eventId == event.eventId then
            state_.pendingEndSnapshot = nil
            return -- Already handed to HTTP; no extra request is needed.
        end
    end
    if state_.activeEndFlush then return end
    -- Only one additional request is allowed. Keep the event in the ordinary
    -- durable queue: failures, suspension and cold starts retain its original
    -- ID, Context, Session and timestamp without changing ordinary ACK handling.
    local active = { event = event, generation = state_.lifecycleGeneration,
        startedAtMs = clockMs(), handle = nil }
    state_.pendingEndSnapshot = nil
    state_.activeEndFlush = active
    local handle = httpRequest("POST", "/v1/events/batch", { events = { event } },
        function(error, result, response)
            finishEndFlush(active, error, result, response and response.localOnly == true)
        end)
    if state_.activeEndFlush == active then active.handle = handle end
end

local function finishAdFlush(active, error, result, localOnly)
    if state_.activeAdFlush ~= active or active.generation ~= state_.lifecycleGeneration then return end
    state_.activeAdFlush = nil
    if not error then
        local accepted, receiptError = validateFlushResult(result, #active.batch, localOnly)
        error = receiptError
        if accepted and accepted > 0 then rememberDirectEvents(active.batch) end
    end
    if error then
        log("ad immediate send failed; durable retry retained: " .. tostring(error))
    else
        for _, event in ipairs(active.batch) do state_.adPriorityHandled[event.eventId] = true end
        log("ad immediate send acknowledged")
        state_.pendingAdFlush = true
        sendAdBatch()
    end
    resumeAfterCritical(error)
end

local function recoverTimedOutAdFlush(currentTime)
    local active = state_.activeAdFlush
    if not active or currentTime - active.startedAtMs < state_.flushTimeoutMs then return end
    state_.activeAdFlush = nil
    cancelRequest(active.handle)
    log("ad immediate send timed out; durable retry retained")
    resumeAfterCritical("timeout")
end

sendAdBatch = function()
    if not state_.storageReady or not state_.activeFlush or state_.activeAdFlush
        or not state_.pendingAdFlush then return end
    state_.pendingAdFlush = false
    local batch, ids = {}, {}
    for _, event in ipairs(state_.queue) do
        if event.eventType == "ad_view" and event.contextId and event.contextId ~= ""
            and not state_.adPriorityHandled[event.eventId]
            and not state_.directCompleted[directEventKey(event)] then
            table.insert(batch, event)
            ids[event.eventId] = true
            if #batch >= math.min(MAX_AD_PRIORITY_BATCH_SIZE, state_.maxBatchSize) then break end
        end
    end
    if #batch == 0 then return end
    -- The queue and its durable chunks retain ownership until ordinary cleanup.
    local active = { batch = batch, ids = ids, generation = state_.lifecycleGeneration,
        startedAtMs = clockMs(), handle = nil }
    state_.activeAdFlush = active
    local handle = httpRequest("POST", "/v1/events/batch", { events = batch },
        function(error, result, response)
            finishAdFlush(active, error, result, response and response.localOnly == true)
        end)
    if state_.activeAdFlush == active then active.handle = handle end
end

local function finishActiveFlush(lifecycleGeneration, sequence, error, result, localOnly)
    local active = state_.activeFlush
    if not active
        or active.lifecycleGeneration ~= lifecycleGeneration
        or active.sequence ~= sequence then
        log("ignored stale flush callback: sequence=" .. tostring(sequence))
        return
    end
    if error then
        failActiveFlush(active, error, false)
        return
    end
    local accepted, resultError, rejected, skipped, tapdbAttempted = validateFlushResult(result, #active.batch, localOnly)
    if resultError then
        failActiveFlush(active, resultError, false)
        return
    end

    state_.activeFlush = nil
    state_.flushing = false
    state_.flushRequested = false
    state_.retryFlushAtMs = nil
    state_.consecutiveFlushFailures = 0
    state_.pendingFlushAccepted = state_.pendingFlushAccepted + accepted
    state_.pendingFlushRejected = state_.pendingFlushRejected + #rejected
    state_.pendingFlushSkipped = state_.pendingFlushSkipped + (skipped or 0)
    state_.pendingFlushTapdbAttempted = state_.pendingFlushTapdbAttempted + (tapdbAttempted or 0)
    for _, event in ipairs(active.batch) do state_.adPriorityHandled[event.eventId] = nil end
    if state_.pendingEndSnapshot then
        for _, event in ipairs(active.batch) do
            if event.eventId == state_.pendingEndSnapshot.eventId then
                state_.pendingEndSnapshot = nil
                break
            end
        end
    end
    if state_.milestoneMarkersDirty then
        -- Keep ACKed milestones recoverable while their marker write is retried.
        local removable = {}
        for _, event in ipairs(active.batch) do
            local target = event.eventType == "milestone" and state_.deferredMilestoneAcks or removable
            table.insert(target, event)
        end
        state_.eventQueueStorage:Remove(removable)
    else
        state_.eventQueueStorage:Remove(active.batch)
    end
    state_.queuePersistenceDirty = true
    persistEventQueue()
    flushAutomaticStorage()
    log("flush ok: accepted=" .. tostring(accepted) .. ", rejected=" .. tostring(#rejected)
        .. ", skipped=" .. tostring(skipped or 0) .. ", notAccepted=" .. tostring(#active.batch - accepted - (skipped or 0)))
    for _, row in ipairs(rejected) do
        log("flush event rejected: index=" .. tostring(row.index)
            .. ", eventId=" .. tostring(row.eventId)
            .. ", reason=" .. tostring(row.reason))
    end

    if hasFlushableEvents() then
        startFlush(false)
        sendEndSnapshot()
        sendAdBatch()
        return
    end
    if state_.activeEndFlush or state_.activeAdFlush then return end

    local totalAccepted = state_.pendingFlushAccepted
    local totalRejected = state_.pendingFlushRejected
    local totalSkipped = state_.pendingFlushSkipped
    local totalTapdbAttempted = state_.pendingFlushTapdbAttempted
    state_.pendingFlushAccepted = 0
    state_.pendingFlushRejected = 0
    state_.pendingFlushSkipped = 0
    state_.pendingFlushTapdbAttempted = 0
    state_.nextAutoFlushAtMs = nil
    completeFlushCallbacks(nil, {
        ok = true,
        accepted = totalAccepted,
        rejectedCount = totalRejected,
        skipped = totalSkipped,
        tapdbAttempted = totalTapdbAttempted,
    })
end

startFlush = function(force)
    if state_.activeFlush or not state_.storageReady then return false end
    local currentTime = clockMs()
    if not force and state_.retryFlushAtMs and currentTime < state_.retryFlushAtMs then
        return false
    end
    local batch = chunkEvents()
    if #batch == 0 then return false end

    state_.flushSequence = state_.flushSequence + 1
    local active = {
        lifecycleGeneration = state_.lifecycleGeneration,
        sequence = state_.flushSequence,
        batch = batch,
        startedAtMs = currentTime,
        handle = nil,
    }
    state_.activeFlush = active
    state_.flushing = true
    state_.flushRequested = false
    state_.nextAutoFlushAtMs = nil
    if state_.flushableEvents > 0 then armAutoFlush() end
    persistEventQueue()
    flushAutomaticStorage()

    local handle = httpRequest("POST", "/v1/events/batch", { events = batch },
        function(error, result, response)
            finishActiveFlush(active.lifecycleGeneration, active.sequence, error, result, response and response.localOnly == true)
        end)
    if state_.activeFlush == active then active.handle = handle end
    return true
end

local function recoverTimedOutFlush(currentTime)
    local active = state_.activeFlush
    if not active then return false end
    if currentTime - active.startedAtMs < state_.flushTimeoutMs then return false end
    failActiveFlush(active,
        "flush request timed out after " .. tostring(state_.flushTimeoutMs) .. "ms", true)
    return true
end

function GameAlgo.Update()
    state_.backgroundWillSnapshotPending = false
    if state_.scheduler and type(state_.scheduler.Update) == "function" then
        local schedulerOk, schedulerError = pcall(function() state_.scheduler:Update() end)
        if not schedulerOk then log("scheduler update failed: " .. tostring(schedulerError)) end
    end
    if type(state_.transport.Update) == "function" then
        local updateOk, updateError = pcall(state_.transport.Update)
        if not updateOk then log("transport update failed: " .. tostring(updateError)) end
    end
    if not state_.storageReady then return end
    local currentTime = clockMs()
    if state_.activeEndFlush then recoverTimedOutEndFlush(currentTime) end
    if state_.activeAdFlush then recoverTimedOutAdFlush(currentTime) end
    if state_.tapDbContextLinkProperties ~= nil
        and currentTime >= state_.tapDbContextLinkNextCheckAtMs
        and currentTime <= state_.tapDbContextLinkDiscoveryUntilMs then
        tryTapDbContextLink()
    end
    if state_.queuePersistenceDirty
        and currentTime - state_.lastQueuePersistAtMs >= QUEUE_PERSIST_INTERVAL_MS then
        persistEventQueue()
        flushAutomaticStorage()
    end
    recoverTimedOutFlush(currentTime)
    if state_.activeFlush then return end
    if state_.retryFlushAtMs then
        if currentTime < state_.retryFlushAtMs then return end
    elseif not state_.flushRequested
        and not (state_.nextAutoFlushAtMs and currentTime >= state_.nextAutoFlushAtMs) then
        return
    end
    -- Inspect queue availability only after a send has actually been requested
    -- or its timer/backoff is due. Empty queues have no automatic deadline.
    if not hasFlushableEvents() then
        state_.flushRequested = false
        state_.retryFlushAtMs = nil
        state_.nextAutoFlushAtMs = nil
        return
    end
    startFlush(false)
    sendEndSnapshot()
    sendAdBatch()
end

--- Checkpoints pending events and requests immediate delivery, including during backoff.
---@param callback function|nil Receives (error, receipt) with HTTP and TapDB delivery counts.
function GameAlgo.Flush(callback)
    if not state_.storageReady then
        safeCallback(callback, "storage not ready", nil)
        return
    end

    local currentTime = clockMs()
    recoverTimedOutFlush(currentTime)
    if state_.activeEndFlush then recoverTimedOutEndFlush(currentTime) end
    if state_.activeAdFlush then recoverTimedOutAdFlush(currentTime) end
    -- Flush is also a durability boundary. A busy request or missing context
    -- must not leave newly queued exit events waiting for Update/the HTTP ACK.
    -- The normal send path checkpoints in startFlush before starting HTTP.
    if state_.activeFlush or (not hasFlushableEvents() and #state_.queue > 0) then
        persistEventQueue()
        flushAutomaticStorage()
    end
    if not queueFlushCallback(callback) then return end
    if state_.activeFlush then
        state_.flushRequested = true
        sendEndSnapshot()
        sendAdBatch()
        return
    end
    if not hasFlushableEvents() then
        if state_.activeEndFlush or state_.activeAdFlush then return end
        if #state_.queue > 0 then
            completeFlushCallbacks("context not ready", nil)
        else
            completeFlushCallbacks(nil, { ok = true, accepted = 0, rejectedCount = 0 })
        end
        return
    end

    state_.retryFlushAtMs = nil
    startFlush(true)
    sendEndSnapshot()
    sendAdBatch()
end

function GameAlgo.NewSession(sessionId, callback)
    local previousSessionId = state_.sessionId
    local nextSessionId = nonEmptyString(sessionId) or randomId("ga_session")
    if nextSessionId == previousSessionId then
        safeCallback(callback, nil, state_.config)
        return nextSessionId
    end
    if not state_.storageReady then
        safeCallback(callback, "storage not ready", nil)
        return nil, "storage not ready"
    end
    local endedAt = clockMs()
    if not state_.sessionHasEnd then
        local accepted, error = enqueueTrack("session_end", {
            reason = "new_session",
            sessionDurationMs = GameAlgo.GetForegroundTimeMs() - state_.sessionForegroundStartMs,
        })
        if not accepted then
            safeCallback(callback, error, nil)
            return nil, error
        end
    end
    state_.ordinaryEventCounts["pending:" .. tostring(previousSessionId)] = nil
    state_.sessionId = nextSessionId
    state_.backgroundWillSnapshotPending = false
    state_.sessionHasEnd = false
    state_.eventGuardDiagnosticKeys = {}
    state_.eventGuardDiagnosticCount = 0
    state_.sessionStartMs = endedAt
    state_.sessionForegroundStartMs = GameAlgo.GetForegroundTimeMs()
    state_.contextId = nil
    state_.sessionAttribution = sessionAttribution()
    state_.config = nil
    state_.configFiles = {}
    state_.configFileRequests = {}
    state_.eventQuota = nil
    persistEventQueue()
    flushAutomaticStorage()
    GameAlgo.Flush(nil)
    GameAlgo.FetchConfig(callback)
    return nextSessionId
end

--- Looks up the current assignment for an experiment strategy.
---@param key string Strategy key.
---@return table executor
function GameAlgo.Executor(key)
    local executor = {}

    function executor.IsReady()
        local item = currentAssignment(key)
        if not item then return false end
        if not item.script then return true end
        -- Scripts also need a host that can enforce the instruction budget;
        -- otherwise Execute() refuses and IsReady() would lie to the game.
        return cachedScript(item.script) ~= nil
            and LuaScriptRuntime.CanEnforceLimit()
    end

    function executor.Variant(defaultValue)
        local item = currentAssignment(key)
        return item and item.variant or defaultValue
    end

    --- Reads a dotted JSON path. Array positions start at zero and object keys are literal strings.
    function executor.Value(path, defaultValue)
        local item = currentAssignment(key)
        local value = item and tablePath(item.config, path)
        if value == nil then return defaultValue end
        return (snapshotJsonValue(value, {}, "config"))
    end

    --- Returns the variant, payload, diagnostics and a copy of the assignment when ready.
    --- Config-only assignments preserve JSON scalar values and return independent table payloads.
    function executor.Execute(input)
        local item = currentAssignment(key)
        if not item then return nil end
        if item.script then
            if not isLuaScript(item.script) then
                log("execute skipped: unsupported script type: " .. tostring(item.script.name))
                return nil
            end
            local file = cachedScript(item.script)
            if not file then
                log("execute skipped: script not loaded: " .. tostring(item.key) .. " -> " .. tostring(item.script.name))
                return nil
            end
            local inputCopy = normalizePayload(input)
            local configCopy = snapshotJsonValue(item.config, {}, "config")
            if configCopy == nil then configCopy = {} end
            local scriptInput = {
                state = inputCopy or {},
                config = configCopy,
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
                assignment = snapshotJsonValue(item, {}, "assignment"),
            }
        end
        local payload = snapshotJsonValue(item.config, {}, "config")
        if payload == nil then payload = {} end
        return {
            variant = item.variant,
            payload = payload,
            assignment = snapshotJsonValue(item, {}, "assignment"),
            diagnostics = {
                luaSdk = "config_only",
            },
            input = input,
        }
    end

    return executor
end

--- Returns the strategy controller for this Init. After reinitialization an old
--- controller rejects mutations and Decide returns a neutral fallback.
---@param key string DDA strategy key.
---@param options table|nil Optional storage key and history window.
function GameAlgo.DDA(key, options)
    key = tostring(key or "")
    if key == "" then error("DDA strategy key is required") end
    if state_.ddaControllers[key] then return state_.ddaControllers[key] end
    options = options or {}
    local generation = state_.lifecycleGeneration
    local storageKey = options.storageKey
    local actual = nil
    local pending = {}
    local controller = {}

    local function queueOrRun(method, ...)
        if generation ~= state_.lifecycleGeneration then return nil, "stale DDA controller" end
        if actual then return actual[method](...) end
        table.insert(pending, { method = method, args = { ... } })
    end

    function controller._Hydrate()
        if generation ~= state_.lifecycleGeneration or actual or not state_.storageReady then return end
        storageKey = storageKey or (userStorageNamespace() .. ":dda:" .. key)
        local legacyStorageKey = "gamealgo:v1:dda:" .. tostring(state_.gameKey or "anonymous"):sub(1, 16) .. ":" .. key
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
        local stale = generation ~= state_.lifecycleGeneration
        if not stale and actual then return actual.Snapshot(context) end
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
            diagnostics = { storageReady = false, reason = stale and "stale_controller" or nil },
        }
    end

    function controller.Decide(context)
        local stale = generation ~= state_.lifecycleGeneration
        if not stale and actual then return actual.Decide(context) end
        return {
            adjustment = "keep",
            payload = { adjustment = "keep" },
            diagnostics = { fallback = true, reason = stale and "stale_controller" or "storage_not_ready" },
            isFallback = true,
        }
    end

    state_.ddaControllers[key] = controller
    controller._Hydrate()
    return controller
end

--- Reads a dotted JSON path from a downloaded config file, using zero-based array indices.
---@param path string Dotted path, or an empty string for the full document.
---@param defaultValue any Fallback for missing files, invalid JSON or absent keys.
---@param fileName string Downloaded config file name.
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
    local active = state_.activeFlush
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
        scripts = snapshotJsonValue(state_.scripts, {}, "scripts"),
        queuedEvents = outstandingEventCount(),
        inflightEvents = active and #active.batch or 0,
        flushing = active ~= nil,
        flushAgeMs = active and math.max(0, clockMs() - active.startedAtMs) or 0,
        flushIntervalMs = state_.flushIntervalMs,
        flushTimeoutMs = state_.flushTimeoutMs,
        consecutiveFlushFailures = state_.consecutiveFlushFailures,
        nextAutoFlushAtMs = state_.nextAutoFlushAtMs,
        retryFlushAtMs = state_.retryFlushAtMs,
        pendingEvents = #state_.pendingTracks,
        storage = state_.storage and state_.storage:Diagnostics() or nil,
    }
end

return GameAlgo
