---@meta
--- TapTap Maker multiplayer client. The wire protocol is identical to
--- @gamealgo/web; only the asynchronous API follows Lua callback conventions.

local cjson = require("cjson")

local function requireSdkModule(name)
    local ok, value = pcall(require, "sdk." .. name)
    if ok then return value end
    return require(name)
end

local Wire = requireSdkModule("MultiplayerWire")

local Multiplayer = {}
local MessageType = Wire.MessageType
local unpackArgs = table.unpack or unpack

local config_ = {}
local resources_ = setmetatable({}, { __mode = "k" })

local Error = {}
Error.__index = Error

function Error:__tostring()
    return self.code
end

local function multiplayerError(code, phase, retryable, cause)
    return setmetatable({
        code = tostring(code),
        message = tostring(code),
        phase = phase,
        retryable = retryable == true,
        cause = cause,
    }, Error)
end

local function asError(value, phase, fallback, retryable)
    if getmetatable(value) == Error then return value end
    local code = type(value) == "string" and value:match("^[a-z][a-z0-9_]+$") and value or fallback
    return multiplayerError(code, phase, retryable, value)
end

local function retryableCode(code)
    return code == "match_connection_failed"
        or code == "match_connection_closed"
        or code == "match_connection_timeout"
        or code == "lobby_connection_failed"
        or code == "lobby_connection_closed"
        or code == "lobby_connection_timeout"
        or code == "relay_unavailable"
        or code == "room_connection_failed"
        or code == "room_connection_closed"
        or code == "room_connection_timeout"
        or code == "host_unavailable"
        or code == "heartbeat_timeout"
end

local function safeCallback(callback, ...)
    if type(callback) ~= "function" then return true end
    local ok, reason = pcall(callback, ...)
    if not ok and type(config_.logger) == "function" then
        pcall(config_.logger, "multiplayer callback failed: " .. tostring(reason))
    end
    return ok, reason
end

local function nowMs()
    if type(config_.nowMs) == "function" then return math.floor(tonumber(config_.nowMs()) or 0) end
    local ok, systemTime = pcall(function()
        return Time and tonumber(Time.systemTime)
    end)
    if ok and systemTime then return math.floor(systemTime * 1000) end
    return math.floor(os.time() * 1000)
end

local function boundedInteger(value, fallback, minimum, maximum)
    value = tonumber(value)
    if not value then value = fallback end
    return math.min(maximum, math.max(minimum, math.floor(value)))
end

local function schedule(delayMs, callback)
    if not config_.scheduler or type(config_.scheduler.Schedule) ~= "function" then
        return nil
    end
    return config_.scheduler:Schedule(math.max(0, tonumber(delayMs) or 0), callback)
end

local function cancelTimer(handle)
    if handle and config_.scheduler and type(config_.scheduler.Cancel) == "function" then
        config_.scheduler:Cancel(handle)
    end
end

local function addListener(target, name, callback)
    if type(callback) ~= "function" then error("listener must be a function", 3) end
    local listeners = target.listeners[name]
    if not listeners then
        listeners = {}
        target.listeners[name] = listeners
    end
    listeners[#listeners + 1] = callback
    local active = true
    return function()
        if not active then return end
        active = false
        for index, listener in ipairs(listeners) do
            if listener == callback then table.remove(listeners, index) break end
        end
    end
end

local function emit(target, name, ...)
    local listeners = target.listeners[name] or {}
    local arguments = { ... }
    local allOk = true
    for _, callback in ipairs(listeners) do
        local ok, reason = safeCallback(callback, unpackArgs(arguments))
        if not ok then
            allOk = false
            if name ~= "error" then
                local failure = multiplayerError("multiplayer_callback_failed", "room_active", false, reason)
                for _, errorCallback in ipairs(target.listeners.error or {}) do safeCallback(errorCallback, failure) end
            end
        end
    end
    return allOk
end

local function socketMethod(socket, names)
    if type(socket) ~= "table" and type(socket) ~= "userdata" then return nil end
    for _, name in ipairs(names) do
        local ok, method = pcall(function() return socket[name] end)
        if ok and type(method) == "function" then return method end
    end
    return nil
end

local function socketSendText(socket, value)
    local method = socketMethod(socket, { "SendText", "sendText", "Send", "send" })
    if not method then error("multiplayer socket does not implement SendText", 3) end
    return method(socket, value)
end

local function socketSendBinary(socket, value)
    local method = socketMethod(socket, { "SendBinary", "sendBinary" })
    if method then return method(socket, value) end
    method = socketMethod(socket, { "Send", "send" })
    if not method then error("multiplayer socket does not implement SendBinary", 3) end
    return method(socket, value, true)
end

local function socketClose(socket, code, reason)
    local method = socketMethod(socket, { "Close", "close" })
    if method then pcall(method, socket, code or 1000, reason or "closed") end
end

local function connectSocket(url, handlers, override, phase)
    phase = phase or "token"
    local factory = override or config_.socketFactory
    if factory == nil then
        error(multiplayerError("multiplayer_socket_unavailable", phase, false), 0)
    end
    local ready = false
    local pending = {}
    local proxyHandlers = {}
    for name, callback in pairs(handlers) do
        proxyHandlers[name] = function(...)
            local arguments = { ... }
            if not ready then
                pending[#pending + 1] = { callback = callback, arguments = arguments }
                return
            end
            safeCallback(callback, unpackArgs(arguments))
        end
    end
    local ok, socketOrError
    if type(factory) == "function" then
        ok, socketOrError = pcall(factory, url, proxyHandlers)
    elseif type(factory) == "table" and type(factory.Connect) == "function" then
        ok, socketOrError = pcall(factory.Connect, factory, url, proxyHandlers)
    else
        error(multiplayerError("invalid_multiplayer_socket_factory", phase, false), 0)
    end
    if not ok then error(asError(socketOrError, phase, "multiplayer_socket_unavailable", false), 0) end
    if socketOrError == nil then error(multiplayerError("multiplayer_socket_unavailable", phase, false), 0) end
    resources_[socketOrError] = true
    ready = true
    for _, event in ipairs(pending) do
        schedule(0, function() safeCallback(event.callback, unpackArgs(event.arguments)) end)
    end
    return socketOrError
end

local function trimSlash(value)
    return tostring(value or ""):gsub("/+$", "")
end

local function urlEncode(value)
    return tostring(value):gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function controllerHttpUrl(controllerUrl)
    local value = tostring(controllerUrl or "")
    if value:match("^wss://") then value = "https://" .. value:sub(7)
    elseif value:match("^ws://") then value = "http://" .. value:sub(6)
    elseif not value:match("^https?://") then error("invalid multiplayer controller URL", 3) end
    value = value:gsub("[?#].*$", "")
    return trimSlash(value) .. "/lobbies"
end

local function jsonDecode(value, fallbackCode, phase)
    local ok, decoded = pcall(cjson.decode, value or "")
    if not ok or type(decoded) ~= "table" then
        return nil, multiplayerError(fallbackCode, phase, false, decoded)
    end
    return decoded, nil
end

local function request(request, callback)
    if type(config_.request) ~= "function" then
        safeCallback(callback, multiplayerError("multiplayer_http_unavailable", "token", false), nil, nil)
        return nil
    end
    local ok, handleOrError = pcall(config_.request, request, function(error, response)
        local body = response and response.body or ""
        local decoded, decodeError = nil, nil
        if body ~= "" then decoded, decodeError = jsonDecode(body, "invalid_multiplayer_response", "token") end
        if error then return safeCallback(callback, error, decoded, response) end
        safeCallback(callback, decodeError, decoded, response)
    end)
    if not ok then safeCallback(callback, tostring(handleOrError), nil, nil) return nil end
    return handleOrError
end

local function credentials(options, phase, cancelled, callback, attempt, identityWaitStartedAt)
    local explicitUrl = options.controllerUrl or config_.controllerUrl
    if options.accessToken and explicitUrl then
        safeCallback(callback, nil, { accessToken = options.accessToken, controllerUrl = explicitUrl })
        return
    end
    local userId = options.userId or (type(config_.userId) == "function" and config_.userId() or nil)
    local sessionId = options.sessionId or (type(config_.sessionId) == "function" and config_.sessionId() or nil)
    if not userId or userId == "" or not sessionId or sessionId == "" then
        local pending = type(config_.identityPending) == "function" and config_.identityPending() == true
        identityWaitStartedAt = identityWaitStartedAt or nowMs()
        if pending and nowMs() - identityWaitStartedAt < boundedInteger(options.connectionTimeoutMs, 8000, 1000, 30000) then
            schedule(50, function()
                credentials(options, phase, cancelled, callback, attempt, identityWaitStartedAt)
            end)
            return
        end
        safeCallback(callback, multiplayerError("multiplayer_identity_unavailable", "token", true), nil)
        return
    end
    attempt = attempt or 0
    request({
        method = "POST",
        url = trimSlash(config_.baseUrl) .. "/v1/multiplayer/access-token",
        headers = {
            ["Content-Type"] = "application/json",
            ["X-GameAlgo-Key"] = config_.gameKey,
        },
        body = cjson.encode({ userId = userId, sessionId = sessionId, region = options.region }),
    }, function(error, payload, response)
        if cancelled() then return end
        local status = tonumber(response and response.status) or 0
        local retryable = status == 0 or status == 408 or status == 429 or status >= 500
        if error or status < 200 or status >= 300 then
            local retries = boundedInteger(options.connectionRetries, 2, 0, 5)
            if retryable and attempt < retries then
                local delay = math.min(5000, boundedInteger(options.retryDelayMs, 250, 50, 5000) * (2 ^ attempt))
                schedule(delay, function()
                    credentials(options, phase, cancelled, callback, attempt + 1, identityWaitStartedAt)
                end)
                return
            end
            safeCallback(callback, multiplayerError("multiplayer_access_token_failed_" .. tostring(status), "token", retryable, error), nil)
            return
        end
        if type(payload) ~= "table" or type(payload.accessToken) ~= "string" then
            safeCallback(callback, multiplayerError("multiplayer_access_token_missing", "token", false), nil)
            return
        end
        local controllerUrl = type(payload.controllerUrl) == "string" and payload.controllerUrl or explicitUrl
        if not controllerUrl then
            safeCallback(callback, multiplayerError("multiplayer_controller_url_missing", "token", false), nil)
            return
        end
        safeCallback(callback, nil, { accessToken = payload.accessToken, controllerUrl = controllerUrl })
    end)
end

local MatchHandle = {}
MatchHandle.__index = MatchHandle

function MatchHandle:OnMatched(callback)
    if self.result then safeCallback(callback, self.result) end
    return addListener(self, "matched", callback)
end

function MatchHandle:OnError(callback)
    if self.failure and self.failure.code ~= "match_cancelled" then safeCallback(callback, self.failure) end
    return addListener(self, "error", callback)
end

function MatchHandle:WaitForMatched(callback)
    if type(callback) ~= "function" then error("WaitForMatched requires a callback", 2) end
    if self.result then safeCallback(callback, nil, self.result)
    elseif self.failure then safeCallback(callback, self.failure, nil)
    else self.waiters[#self.waiters + 1] = callback end
    return self
end

function MatchHandle:_settle(error, result, notifyError)
    if self.finished then return end
    self.finished = true
    cancelTimer(self.connectionTimer)
    cancelTimer(self.retryTimer)
    self.connectionTimer, self.retryTimer = nil, nil
    if self.socket then socketClose(self.socket, 1000, error and "match_failed" or "matched") end
    self.failure, self.result = error, result
    local waiters = self.waiters
    self.waiters = {}
    for _, callback in ipairs(waiters) do safeCallback(callback, error, result) end
    if result then emit(self, "matched", result)
    elseif notifyError then emit(self, "error", error) end
end

function MatchHandle:Cancel()
    if self.cancelled or self.finished then return end
    self.cancelled = true
    if self.socketOpen and self.socket then pcall(socketSendText, self.socket, cjson.encode({ type = "cancel" })) end
    self:_settle(multiplayerError("match_cancelled", "match", false), nil, false)
end

function MatchHandle:_onMessage(raw)
    local message, decodeError = jsonDecode(raw, "invalid_match_message", "match")
    if decodeError then return self:_settle(decodeError, nil, true) end
    if message.type == "matched" then
        if type(message.ticket) ~= "string" or type(message.relayUrl) ~= "string" then
            return self:_settle(multiplayerError("invalid_matched_message", "match", false), nil, true)
        end
        return self:_settle(nil, message, false)
    end
    if message.type == "error" then
        local code = tostring(message.code or "match_failed")
        self:_settle(multiplayerError(code, "match", retryableCode(code)), nil, true)
    end
end

function MatchHandle:_open()
    if self.cancelled or self.finished or not self.credentials then return end
    local generation = self.connectionAttempt + 1
    self.generation = generation
    local attemptFinished = false
    local socket
    local function failAttempt(error)
        if attemptFinished or self.cancelled or self.finished or self.generation ~= generation then return end
        attemptFinished = true
        cancelTimer(self.connectionTimer)
        if socket then socketClose(socket, 1000, "match_retry") end
        local retries = boundedInteger(self.options.connectionRetries, 2, 0, 5)
        if error.retryable and self.connectionAttempt < retries then
            local delay = math.min(5000, boundedInteger(self.options.retryDelayMs, 250, 50, 5000) * (2 ^ self.connectionAttempt))
            self.connectionAttempt = self.connectionAttempt + 1
            self.retryTimer = schedule(delay, function() self:_open() end)
            return
        end
        self:_settle(error, nil, true)
    end
    local handlers = {
        open = function()
            if self.generation ~= generation or self.finished then return end
            self.socketOpen = true
            cancelTimer(self.connectionTimer)
            local ok, reason = pcall(socketSendText, socket or self.socket, cjson.encode({
                type = "join",
                accessToken = self.credentials.accessToken,
                queueId = self.options.queueId,
                protocolHash = self.options.protocolHash,
                rating = self.options.rating,
                canHost = self.options.canHost ~= false,
                foreground = self.options.foreground ~= false,
                rttMs = self.options.rttMs,
                deviceScore = self.options.deviceScore,
            }))
            if not ok then failAttempt(multiplayerError("match_connection_failed", "match", true, reason)) end
        end,
        text = function(value) if self.generation == generation then self:_onMessage(value) end end,
        error = function(reason) failAttempt(multiplayerError("match_connection_failed", "match", true, reason)) end,
        close = function(code, reason)
            self.socketOpen = false
            if not self.cancelled and not self.finished and tonumber(code) ~= 1000 then
                failAttempt(multiplayerError(reason or "match_connection_closed", "match", true))
            end
        end,
    }
    self.connectionTimer = schedule(boundedInteger(self.options.connectionTimeoutMs, 8000, 1000, 30000), function()
        failAttempt(multiplayerError("match_connection_timeout", "match", true))
    end)
    local ok, socketOrError = pcall(connectSocket, self.credentials.controllerUrl, handlers, self.options.socketFactory, "match")
    if not ok then return failAttempt(asError(socketOrError, "match", "match_connection_failed", true)) end
    socket = socketOrError
    self.socket = socket
end

local function newMatchHandle(options)
    local handle = setmetatable({
        options = options,
        listeners = {},
        waiters = {},
        connectionAttempt = 0,
        cancelled = false,
        finished = false,
    }, MatchHandle)
    resources_[handle] = true
    credentials(options, "match", function() return handle.cancelled end, function(error, result)
        if handle.cancelled or handle.finished then return end
        if error then return handle:_settle(asError(error, "token", "multiplayer_access_token_failed", true), nil, true) end
        handle.credentials = result
        handle:_open()
    end)
    return handle
end

local LobbyHandle = {}
LobbyHandle.__index = LobbyHandle

function LobbyHandle:OnChanged(callback)
    if self.snapshot then safeCallback(callback, self.snapshot) end
    return addListener(self, "changed", callback)
end

function LobbyHandle:OnMatched(callback)
    if self.result then safeCallback(callback, self.result) end
    return addListener(self, "matched", callback)
end

function LobbyHandle:OnError(callback)
    if self.failure then safeCallback(callback, self.failure) end
    return addListener(self, "error", callback)
end

function LobbyHandle:WaitForLobby(callback)
    if type(callback) ~= "function" then error("WaitForLobby requires a callback", 2) end
    if self.snapshot then safeCallback(callback, nil, self.snapshot)
    elseif self.failure then safeCallback(callback, self.failure, nil)
    else self.lobbyWaiters[#self.lobbyWaiters + 1] = callback end
    return self
end

function LobbyHandle:WaitForMatched(callback)
    if type(callback) ~= "function" then error("WaitForMatched requires a callback", 2) end
    if self.result then safeCallback(callback, nil, self.result)
    elseif self.failure then safeCallback(callback, self.failure, nil)
    else self.matchWaiters[#self.matchWaiters + 1] = callback end
    return self
end

function LobbyHandle:_fail(error)
    if self.finished then return end
    self.finished = true
    self.failure = error
    cancelTimer(self.connectionTimer)
    if self.socket then socketClose(self.socket, 1000, "lobby_failed") end
    for _, callback in ipairs(self.lobbyWaiters) do safeCallback(callback, error, nil) end
    for _, callback in ipairs(self.matchWaiters) do safeCallback(callback, error, nil) end
    self.lobbyWaiters, self.matchWaiters = {}, {}
    emit(self, "error", error)
end

function LobbyHandle:_send(value)
    if not self.socketOpen or not self.socket then error(multiplayerError("lobby_connection_unavailable", "lobby", true), 2) end
    socketSendText(self.socket, cjson.encode(value))
end

function LobbyHandle:Start() self:_send({ type = "lobby_start" }) end
function LobbyHandle:CancelMatchmaking() self:_send({ type = "lobby_cancel_matchmaking" }) end
function LobbyHandle:CloseLobby() self:_send({ type = "lobby_close" }) end

function LobbyHandle:Kick(memberId)
    memberId = tostring(memberId or "")
    if not memberId:match("^[A-Za-z0-9%._:%-]+$") or #memberId > 128 then
        error(multiplayerError("invalid_lobby_member_id", "lobby", false), 2)
    end
    self:_send({ type = "lobby_kick", memberId = memberId })
end

function LobbyHandle:Leave()
    if self.cancelled or self.finished then return end
    self.cancelled = true
    if self.socketOpen and self.socket then pcall(socketSendText, self.socket, cjson.encode({ type = "cancel" })) end
    self.finished = true
    self.failure = multiplayerError("lobby_left", "lobby", false)
    cancelTimer(self.connectionTimer)
    if self.socket then socketClose(self.socket, 1000, "lobby_left") end
    for _, callback in ipairs(self.lobbyWaiters) do safeCallback(callback, self.failure, nil) end
    for _, callback in ipairs(self.matchWaiters) do safeCallback(callback, self.failure, nil) end
    self.lobbyWaiters, self.matchWaiters = {}, {}
end

function LobbyHandle:_onMessage(raw)
    local message, decodeError = jsonDecode(raw, "invalid_lobby_message", "lobby")
    if decodeError then return self:_fail(decodeError) end
    if message.type == "lobby_snapshot" then
        if type(message.lobby) ~= "table" or type(message.lobby.lobbyId) ~= "string" then
            return self:_fail(multiplayerError("invalid_lobby_snapshot", "lobby", false))
        end
        self.snapshot = message.lobby
        local waiters = self.lobbyWaiters
        self.lobbyWaiters = {}
        for _, callback in ipairs(waiters) do safeCallback(callback, nil, self.snapshot) end
        emit(self, "changed", self.snapshot)
        return
    end
    if message.type == "matched" then
        if type(message.ticket) ~= "string" or type(message.relayUrl) ~= "string" then
            return self:_fail(multiplayerError("invalid_matched_message", "lobby", false))
        end
        self.finished = true
        self.result = message
        local waiters = self.matchWaiters
        self.matchWaiters = {}
        for _, callback in ipairs(waiters) do safeCallback(callback, nil, message) end
        emit(self, "matched", message)
        if self.socket then socketClose(self.socket, 1000, "matched") end
        return
    end
    if message.type == "lobby_error" or message.type == "lobby_start_retrying" then
        local code = tostring(message.code or "lobby_failed")
        emit(self, "error", multiplayerError(code, "lobby", retryableCode(code)))
        return
    end
    if message.type == "lobby_closed" then
        return self:_fail(multiplayerError(tostring(message.reason or "lobby_closed"), "lobby", false))
    end
    if message.type == "error" then
        local code = tostring(message.code or "lobby_failed")
        self:_fail(multiplayerError(code, "lobby", retryableCode(code)))
    end
end

local function newLobbyHandle(requestType, options)
    local handle = setmetatable({
        requestType = requestType,
        options = options,
        listeners = {},
        lobbyWaiters = {},
        matchWaiters = {},
        cancelled = false,
        finished = false,
    }, LobbyHandle)
    resources_[handle] = true
    credentials(options, "lobby", function() return handle.cancelled end, function(error, auth)
        if error then return handle:_fail(asError(error, "lobby", "lobby_connection_failed", true)) end
        local socket
        local handlers = {
            open = function()
                handle.socketOpen = true
                cancelTimer(handle.connectionTimer)
                local payload = {
                    type = requestType,
                    accessToken = auth.accessToken,
                    queueId = options.queueId,
                    lobbyId = options.lobbyId,
                    roomCode = options.roomCode,
                    protocolHash = options.protocolHash,
                    visibility = options.visibility,
                    metadata = options.metadata,
                    rating = options.rating,
                    canHost = options.canHost ~= false,
                    foreground = options.foreground ~= false,
                    rttMs = options.rttMs,
                    deviceScore = options.deviceScore,
                }
                local ok, reason = pcall(socketSendText, socket or handle.socket, cjson.encode(payload))
                if not ok then handle:_fail(multiplayerError("lobby_connection_failed", "lobby", true, reason)) end
            end,
            text = function(value) if not handle.finished then handle:_onMessage(value) end end,
            error = function(reason) handle:_fail(multiplayerError("lobby_connection_failed", "lobby", true, reason)) end,
            close = function(code, reason)
                handle.socketOpen = false
                if not handle.cancelled and not handle.finished and tonumber(code) ~= 1000 then
                    handle:_fail(multiplayerError(reason or "lobby_connection_closed", "lobby", true))
                end
            end,
        }
        handle.connectionTimer = schedule(boundedInteger(options.connectionTimeoutMs, 8000, 1000, 30000), function()
            handle:_fail(multiplayerError("lobby_connection_timeout", "lobby", true))
        end)
        local ok, socketOrError = pcall(connectSocket, auth.controllerUrl, handlers, options.socketFactory, "lobby")
        if not ok then return handle:_fail(asError(socketOrError, "lobby", "lobby_connection_failed", true)) end
        socket = socketOrError
        handle.socket = socket
    end)
    return handle
end

local Room = {}
Room.__index = Room

local function roomOn(name)
    return function(self, callback) return addListener(self, name, callback) end
end

Room.OnInitialized = roomOn("initialized")
Room.OnInput = roomOn("input")
Room.OnInputAcknowledged = roomOn("inputAcknowledged")
Room.OnState = roomOn("state")
Room.OnEvent = roomOn("event")
Room.OnPeerChanged = roomOn("peerChanged")
Room.OnPhase = roomOn("phase")
Room.OnPaused = roomOn("paused")
Room.OnResumed = roomOn("resumed")
Room.OnBecomeHost = roomOn("becomeHost")
Room.OnClosed = roomOn("closed")
Room.OnError = roomOn("error")

function Room:_requireHost()
    if not self.isHost then error(multiplayerError("not_host", "room_active", false), 3) end
end

function Room:_sendControl(value)
    if not self.socketOpen or not self.socket then error(multiplayerError("room_connection_unavailable", "room_active", true), 3) end
    socketSendText(self.socket, cjson.encode(value))
end

function Room:_sendFrame(messageType, payload, targetSeat, limit, sequence, flags)
    if #payload > limit then error(multiplayerError("payload_too_large", "room_active", false), 3) end
    if not self.socketOpen or not self.socket then error(multiplayerError("room_connection_unavailable", "room_active", true), 3) end
    if sequence == nil then
        self.sequence = self.sequence + 1
        sequence = self.sequence
    end
    socketSendBinary(self.socket, Wire.Encode({
        type = messageType,
        flags = flags or 0,
        targetSeat = targetSeat,
        hostEpoch = self.hostEpoch,
        sequence = sequence,
        stateRevision = self.stateRevision,
        payload = payload,
    }))
end

function Room:Initialize(value)
    self:_requireHost()
    self:_sendFrame(MessageType.roomInit, self.protocol.EncodeRoomInit(value), Wire.NO_TARGET_SEAT, 4 * 1024)
end

function Room:Ready()
    self:_sendControl({ type = "ready" })
end

function Room:PublishState(value)
    self:_requireHost()
    if type(value) ~= "table" or type(value.sharedState) ~= "table" then error("sharedState is required", 2) end
    self.pendingState = value
    local wait = math.max(0, 100 - (nowMs() - self.lastStateSentAt))
    if wait == 0 then self:_flushState()
    elseif not self.stateTimer then self.stateTimer = schedule(wait, function() self:_flushState() end) end
end

function Room:CommitHostState(value)
    self:_requireHost()
    self.pendingHostState = value
    local wait = math.max(0, 1000 - (nowMs() - self.lastHostStateSentAt))
    if wait == 0 then self:_flushHostState()
    elseif not self.hostStateTimer then self.hostStateTimer = schedule(wait, function() self:_flushHostState() end) end
end

function Room:SendEvent(eventType, payload, options)
    self:_requireHost()
    options = options or {}
    local target = Wire.NO_TARGET_SEAT
    if type(options.to) == "table" then target = tonumber(options.to.seat) or Wire.NO_TARGET_SEAT end
    self:_sendFrame(MessageType.gameEvent, self.protocol.EncodeEvent(eventType, payload), target, 512)
end

function Room:YieldHost()
    self:_requireHost()
    self:_sendControl({ type = "host_yield", hostEpoch = self.hostEpoch })
end

function Room:SetForeground(foreground)
    self.foreground = foreground ~= false
    if not self.foreground and self.isHost and self.phase == "active" and self.socketOpen then
        self:YieldHost()
    end
end

function Room:Close(reason)
    reason = reason or "host_closed"
    if self.isHost and self.socketOpen then
        pcall(function() self:_sendControl({ type = "close_room", hostEpoch = self.hostEpoch, reason = reason }) end)
    end
    self:Disconnect({ reconnect = false, reason = reason })
end

function Room:Disconnect(options)
    options = options or {}
    self.reconnectEnabled = options.reconnect == true
    if not self.reconnectEnabled then self.closed = true end
    cancelTimer(self.heartbeatTimer)
    self.heartbeatTimer = nil
    if self.socket then socketClose(self.socket, 1000, options.reason or "client_disconnect") end
end

function Room:_flushState()
    cancelTimer(self.stateTimer)
    self.stateTimer = nil
    if not self.pendingState or not self.isHost or self.closed then return end
    local value = self.pendingState
    self.pendingState = nil
    self.lastStateSentAt = nowMs()
    self.stateRevision = self.stateRevision + 1
    self:_sendFrame(MessageType.sharedState, self.protocol.EncodeSharedState(value.sharedState), Wire.NO_TARGET_SEAT, 1024)
    for seat, seatState in pairs(value.seatStates or {}) do
        self:_sendFrame(MessageType.seatState, self.protocol.EncodeSeatState(seatState), tonumber(seat), 512)
    end
end

function Room:_flushHostState()
    cancelTimer(self.hostStateTimer)
    self.hostStateTimer = nil
    if not self.pendingHostState or not self.isHost or self.closed then return end
    local value = self.pendingHostState
    self.pendingHostState = nil
    self.lastHostStateSentAt = nowMs()
    self:_sendFrame(MessageType.hostState, self.protocol.EncodeHostState(value), Wire.NO_TARGET_SEAT, 8 * 1024)
end

function Room:_heartbeat()
    cancelTimer(self.heartbeatTimer)
    self.heartbeatTimer = nil
    if self.closed or not self.socketOpen then return end
    local ok, reason = pcall(function()
        self:_sendControl({ type = "heartbeat", sentAt = nowMs(), foreground = self.foreground ~= false })
    end)
    if not ok then emit(self, "error", asError(reason, "room_active", "room_connection_failed", true)) end
    self.heartbeatTimer = schedule(self.isHost and 2000 or 5000, function() self:_heartbeat() end)
end

function Room:_applyWelcome(message)
    self.id = tostring(message.roomId or "")
    self.seat = tonumber(message.seat) or -1
    self.hostSeat = tonumber(message.hostSeat) or -1
    self.hostEpoch = tonumber(message.hostEpoch) or 0
    self.phase = tostring(message.phase or "joining")
    self.teamIndex = tonumber(message.teamIndex)
    self.roster = {}
    if type(message.roster) == "table" then
        for _, member in ipairs(message.roster) do
            if type(member) == "table" and tonumber(member.seat) then
                self.roster[#self.roster + 1] = {
                    seat = tonumber(member.seat),
                    connected = member.connected == true,
                    canHost = member.canHost == true,
                    teamIndex = tonumber(member.teamIndex),
                }
            end
        end
    end
    self.isHost = self.seat == self.hostSeat
    self.sessionToken = tostring(message.sessionToken or "")
    self.reconnectStartedAt = nil
    self.reconnectAttempt = 0
end

function Room:_onControl(message)
    if message.type == "error" then
        local code = tostring(message.code or "multiplayer_error")
        return emit(self, "error", multiplayerError(code, "room_active", retryableCode(code)))
    end
    if message.type == "peer_joined" or message.type == "peer_disconnected"
        or message.type == "peer_reconnected" or message.type == "peer_ready" then
        local seat = tonumber(message.seat) or -1
        if message.type ~= "peer_ready" then
            for _, member in ipairs(self.roster) do
                if member.seat == seat then member.connected = message.type ~= "peer_disconnected" end
            end
        end
        return emit(self, "peerChanged", { type = tostring(message.type), seat = seat })
    end
    if message.type == "room_phase" then
        self.phase = tostring(message.phase)
        return emit(self, "phase", { phase = self.phase })
    end
    if message.type == "room_paused" then return emit(self, "paused", { reason = message.reason }) end
    if message.type == "room_resumed" then return emit(self, "resumed") end
    if message.type == "host_changed" or message.type == "host_migrating" then
        self.hostSeat = tonumber(message.hostSeat) or -1
        self.hostEpoch = tonumber(message.hostEpoch) or self.hostEpoch
        self.isHost = self.seat == self.hostSeat
        return self:_heartbeat()
    end
    if message.type == "become_host" then
        self.isHost = true
        self.hostSeat = self.seat
        self.hostEpoch = tonumber(message.hostEpoch) or self.hostEpoch
        self.pendingHostRecovery = message.recovery == true
        self:_heartbeat()
        if not self.pendingHostRecovery then emit(self, "becomeHost", nil) end
        return
    end
    if message.type == "room_closed" then
        self.closed = true
        self.reconnectEnabled = false
        return emit(self, "closed", { reason = tostring(message.reason or "room_closed") })
    end
end

function Room:_onBinary(value)
    local ok, frameOrError = pcall(Wire.Decode, value)
    if not ok then return emit(self, "error", asError(frameOrError, "room_active", "invalid_room_message", false)) end
    local frame = frameOrError
    local decodeOk, reason = pcall(function()
        if frame.type == MessageType.roomInit then
            emit(self, "initialized", self.protocol.DecodeRoomInit(frame.payload))
        elseif frame.type == MessageType.sharedState then
            self.sharedState = self.protocol.DecodeSharedState(frame.payload)
            self.stateRevision = math.max(self.stateRevision, frame.stateRevision)
            emit(self, "state", { sharedState = self.sharedState, seatState = self.seatState, stateRevision = self.stateRevision })
        elseif frame.type == MessageType.seatState then
            self.seatState = self.protocol.DecodeSeatState(frame.payload)
            self.stateRevision = math.max(self.stateRevision, frame.stateRevision)
            emit(self, "state", { sharedState = self.sharedState, seatState = self.seatState, stateRevision = self.stateRevision })
        elseif frame.type == MessageType.inputBatch then
            if not self.isHost or frame.hostEpoch ~= self.hostEpoch then return end
            local reliable = (frame.flags & Wire.RELIABLE_INPUT_FLAG) ~= 0
            local previous = self.lastReliableInputSequenceBySeat[frame.targetSeat] or 0
            if not reliable or frame.sequence > previous then
                if reliable then self.lastReliableInputSequenceBySeat[frame.targetSeat] = frame.sequence end
                emit(self, "input", {
                    seat = frame.targetSeat,
                    input = self.protocol.DecodeInput(frame.payload),
                    sequence = frame.sequence,
                })
            end
            if reliable then
                self:_sendFrame(MessageType.inputAck, "", frame.targetSeat, 0, frame.sequence)
            end
        elseif frame.type == MessageType.inputAck then
            emit(self, "inputAcknowledged", { sequence = frame.sequence })
        elseif frame.type == MessageType.gameEvent then
            emit(self, "event", self.protocol.DecodeEvent(frame.payload))
        elseif frame.type == MessageType.hostRecovery then
            self.pendingHostRecovery = false
            local state = self.protocol.DecodeHostState(frame.payload)
            if emit(self, "becomeHost", state) then
                self:_sendControl({ type = "host_ready", hostEpoch = self.hostEpoch })
            end
        end
    end)
    if not decodeOk then emit(self, "error", asError(reason, "room_active", "invalid_room_message", false)) end
end

function Room:_scheduleReconnect()
    local startedAt = self.reconnectStartedAt or nowMs()
    self.reconnectStartedAt = startedAt
    if nowMs() - startedAt >= boundedInteger(self.options.reconnectWindowMs, 30000, 1000, 120000) then
        self.closed = true
        return emit(self, "closed", { reason = "reconnect_expired" })
    end
    local delay = math.min(2000, 250 * (2 ^ self.reconnectAttempt))
    self.reconnectAttempt = self.reconnectAttempt + 1
    self.reconnectTimer = schedule(delay, function()
        if self.closed or not self.sessionToken then return end
        self:_open({ type = "resume", sessionToken = self.sessionToken }, true, function(error)
            if error then self:_scheduleReconnect() end
        end)
    end)
end

function Room:_open(authentication, reconnecting, callback)
    self.socketGeneration = self.socketGeneration + 1
    local generation = self.socketGeneration
    local socket
    local welcomed = false
    local settled = false
    local function finish(error)
        if settled then return end
        settled = true
        cancelTimer(self.connectionTimer)
        safeCallback(callback, error, error and nil or self)
    end
    local handlers = {
        open = function()
            if self.socketGeneration ~= generation or self.closed then return end
            self.socketOpen = true
            local ok, reason = pcall(socketSendText, socket or self.socket, cjson.encode(authentication))
            if not ok then finish(multiplayerError("room_connection_failed", reconnecting and "room_active" or "room_join", true, reason)) end
        end,
        text = function(raw)
            if self.socketGeneration ~= generation then return end
            local message, decodeError = jsonDecode(raw, "invalid_room_message", welcomed and "room_active" or "room_join")
            if decodeError then
                if not welcomed then finish(decodeError) else emit(self, "error", decodeError) end
                return
            end
            if message.type == "welcome" and not welcomed then
                welcomed = true
                self:_applyWelcome(message)
                self:_heartbeat()
                finish(nil)
            elseif not welcomed and message.type == "error" then
                local code = tostring(message.code or "room_connection_failed")
                finish(multiplayerError(code, "room_join", retryableCode(code)))
            else
                self:_onControl(message)
            end
        end,
        binary = function(value) if self.socketGeneration == generation and welcomed then self:_onBinary(value) end end,
        error = function(reason)
            local failure = multiplayerError("room_connection_failed", welcomed and "room_active" or "room_join", true, reason)
            if not welcomed then finish(failure) else emit(self, "error", failure) end
        end,
        close = function(code, reason)
            if self.socketGeneration ~= generation then return end
            self.socketOpen = false
            cancelTimer(self.heartbeatTimer)
            self.heartbeatTimer = nil
            if not welcomed then
                finish(multiplayerError(reason or "room_connection_closed", "room_join", true))
            elseif not self.closed and self.reconnectEnabled and self.sessionToken then
                self:_scheduleReconnect()
            elseif not self.closed then
                emit(self, "closed", { reason = reason or "connection_closed" })
            end
        end,
    }
    self.connectionTimer = schedule(boundedInteger(self.options.connectTimeoutMs, 8000, 1000, 30000), function()
        finish(multiplayerError("room_connection_timeout", reconnecting and "room_active" or "room_join", true))
        socketClose(socket, 1000, "room_join_timeout")
    end)
    local ok, socketOrError = pcall(connectSocket, self.relayUrl, handlers, self.options.socketFactory,
        reconnecting and "room_active" or "room_join")
    if not ok then return finish(asError(socketOrError, "room_join", "room_connection_failed", true)) end
    socket = socketOrError
    self.socket = socket
end

function Room:SendAggregatedInput(value, firstSequence, lastSequence, options)
    options = options or {}
    self:_sendFrame(
        MessageType.inputBatch,
        self.protocol.EncodeInput(value),
        Wire.NO_TARGET_SEAT,
        512,
        tonumber(lastSequence) ~= 0 and tonumber(lastSequence) or tonumber(firstSequence),
        options.reliable == true and Wire.RELIABLE_INPUT_FLAG or 0
    )
end

local InputQueue = {}
InputQueue.__index = InputQueue

function InputQueue:_schedule()
    cancelTimer(self.timer)
    if self.closed then return end
    self.timer = schedule(self.intervalMs, function()
        self:Flush()
        self:_schedule()
    end)
end

function InputQueue:Push(value)
    if self.closed then error(multiplayerError("input_queue_closed", "input", false), 2) end
    local queued = #self.values + (self.inFlight and #self.inFlight.values or 0)
    if queued >= self.maxQueuedInputs then
        if self.delivery == "reliable" then
            local failure = multiplayerError("input_queue_full", "input", true)
            safeCallback(self.onError, failure)
            return false, failure
        end
        table.remove(self.values, 1)
    end
    self.nextSequence = self.nextSequence + 1
    self.values[#self.values + 1] = { sequence = self.nextSequence, value = value }
    return true
end

function InputQueue:_transmit(batch)
    batch.nextAttemptAt = nowMs() + self.ackTimeoutMs
    local ok, reason = pcall(self.room.SendAggregatedInput, self.room, batch.aggregate,
        batch.firstSequence, batch.lastSequence, { reliable = true })
    if not ok then safeCallback(self.onError, asError(reason, "input", "input_send_failed", true)) end
end

function InputQueue:Flush()
    if self.closed or self.room.phase ~= "active" then return end
    if self.inFlight then
        if nowMs() >= self.inFlight.nextAttemptAt then self:_transmit(self.inFlight) end
        return
    end
    if #self.values == 0 then return end
    local pending = self.values
    self.values = {}
    local plain = {}
    for index, item in ipairs(pending) do plain[index] = item.value end
    local ok, result = pcall(self.aggregate, plain)
    if not ok then safeCallback(self.onError, asError(result, "input", "input_aggregate_failed", false)) return end
    if result == nil then return end
    local batch = {
        values = pending,
        aggregate = result,
        firstSequence = pending[1].sequence,
        lastSequence = pending[#pending].sequence,
        nextAttemptAt = 0,
    }
    if self.delivery == "reliable" then
        self.inFlight = batch
        self:_transmit(batch)
        return
    end
    local sent, reason = pcall(self.room.SendAggregatedInput, self.room, result,
        batch.firstSequence, batch.lastSequence)
    if not sent then
        for index = #pending, 1, -1 do table.insert(self.values, 1, pending[index]) end
        safeCallback(self.onError, asError(reason, "input", "input_send_failed", true))
    end
end

function InputQueue:Close()
    if self.closed then return end
    self.closed = true
    cancelTimer(self.timer)
    if self.unsubscribeAck then self.unsubscribeAck() end
    if self.unsubscribePhase then self.unsubscribePhase() end
    if self.room.reliableInputQueue == self then self.room.reliableInputQueue = nil end
    self.inFlight = nil
end

function Room:CreateInputQueue(options)
    options = options or {}
    if type(options.aggregate) ~= "function" then error("input aggregate callback is required", 2) end
    local delivery = options.delivery or "latest"
    if delivery ~= "latest" and delivery ~= "reliable" then error("delivery must be latest or reliable", 2) end
    if delivery == "reliable" and self.reliableInputQueue then
        error(multiplayerError("reliable_input_queue_exists", "input", false), 2)
    end
    local queue = setmetatable({
        room = self,
        aggregate = options.aggregate,
        onError = options.onError,
        delivery = delivery,
        intervalMs = boundedInteger(options.intervalMs, 50, 50, 60000),
        maxQueuedInputs = boundedInteger(options.maxQueuedInputs, 128, 1, 10000),
        ackTimeoutMs = boundedInteger(options.ackTimeoutMs, 3000, 250, 10000),
        values = {},
        nextSequence = 0,
        closed = false,
    }, InputQueue)
    queue.unsubscribeAck = self:OnInputAcknowledged(function(value)
        if queue.inFlight and tonumber(value.sequence) >= queue.inFlight.lastSequence then
            queue.inFlight = nil
            queue:Flush()
        end
    end)
    queue.unsubscribePhase = self:OnPhase(function(value)
        if value.phase == "active" and queue.delivery == "reliable" and queue.inFlight then
            queue.inFlight.nextAttemptAt = 0
            queue:Flush()
        end
    end)
    if delivery == "reliable" then self.reliableInputQueue = queue end
    resources_[queue] = true
    queue:_schedule()
    return queue
end

local function newRoom(relayUrl, ticket, protocol, options, callback)
    options = options or {}
    local room = setmetatable({
        id = "",
        seat = -1,
        isHost = false,
        hostEpoch = 0,
        phase = "connecting",
        roster = {},
        protocolId = protocol.id,
        protocolVersion = protocol.version,
        relayUrl = relayUrl,
        ticket = ticket,
        protocol = protocol,
        options = options,
        listeners = {},
        sequence = 0,
        stateRevision = 0,
        socketGeneration = 0,
        reconnectEnabled = options.reconnect ~= false,
        reconnectAttempt = 0,
        lastReliableInputSequenceBySeat = {},
        lastStateSentAt = nowMs() - 100,
        lastHostStateSentAt = nowMs() - 1000,
        foreground = options.foreground ~= false,
        closed = false,
    }, Room)
    resources_[room] = true
    local attempts = 0
    local retries = boundedInteger(options.connectRetries, 1, 0, 3)
    local function connect()
        room:_open({ type = "join", ticket = ticket }, false, function(error)
            if error and error.retryable and attempts < retries then
                local delay = boundedInteger(options.retryDelayMs, 250, 50, 5000) * (2 ^ attempts)
                attempts = attempts + 1
                schedule(delay, connect)
                return
            end
            safeCallback(callback, error, error and nil or room)
        end)
    end
    connect()
    return room
end

Multiplayer.Matchmaking = {}

function Multiplayer.Matchmaking.Join(options)
    options = options or {}
    if type(options.queueId) ~= "string" or type(options.protocolHash) ~= "string" then
        error("queueId and protocolHash are required", 2)
    end
    return newMatchHandle(options)
end

function Multiplayer.Matchmaking.CreateLobby(options)
    options = options or {}
    if type(options.queueId) ~= "string" or type(options.protocolHash) ~= "string" then
        error("queueId and protocolHash are required", 2)
    end
    return newLobbyHandle("create_lobby", options)
end

function Multiplayer.Matchmaking.JoinLobby(options)
    options = options or {}
    if type(options.protocolHash) ~= "string" or (not options.lobbyId and not options.roomCode) then
        error("protocolHash and lobbyId or roomCode are required", 2)
    end
    return newLobbyHandle("join_lobby", options)
end

function Multiplayer.Matchmaking.ListLobbies(options, callback)
    options = options or {}
    if type(callback) ~= "function" then error("ListLobbies requires a callback", 2) end
    credentials(options, "lobby", function() return false end, function(error, auth)
        if error then return safeCallback(callback, error, nil) end
        local query = "?queueId=" .. urlEncode(options.queueId or "")
            .. "&protocolHash=" .. urlEncode(options.protocolHash or "")
        if options.limit ~= nil then query = query .. "&limit=" .. urlEncode(options.limit) end
        if options.cursor then query = query .. "&cursor=" .. urlEncode(options.cursor) end
        request({
            method = "GET",
            url = controllerHttpUrl(auth.controllerUrl) .. query,
            headers = { Authorization = "Bearer " .. auth.accessToken },
            body = "",
        }, function(requestError, payload, response)
            local status = tonumber(response and response.status) or 0
            if requestError or status < 200 or status >= 300 then
                local code = type(payload) == "table" and payload.error or ("lobby_list_failed_" .. tostring(status))
                return safeCallback(callback, multiplayerError(code, "lobby", false, requestError), nil)
            end
            if type(payload) ~= "table" or type(payload.items) ~= "table" then
                return safeCallback(callback, multiplayerError("invalid_lobby_list", "lobby", false), nil)
            end
            safeCallback(callback, nil, { items = payload.items, nextCursor = payload.nextCursor })
        end)
    end)
end

function Multiplayer.ConnectRoom(relayUrl, ticket, protocol, options, callback)
    if type(options) == "function" and callback == nil then callback, options = options, {} end
    if type(callback) ~= "function" then error("ConnectRoom requires a callback", 2) end
    if type(protocol) ~= "table" or type(protocol.EncodeInput) ~= "function" then
        error("a protocol from DefineMultiplayerProtocol is required", 2)
    end
    return newRoom(relayUrl, ticket, protocol, options, callback)
end

function Multiplayer.Configure(options)
    config_ = options or {}
end

function Multiplayer.Reset()
    for resource in pairs(resources_) do
        if getmetatable(resource) == Room then pcall(resource.Disconnect, resource, { reconnect = false, reason = "sdk_reinitialized" })
        elseif getmetatable(resource) == InputQueue then pcall(resource.Close, resource)
        elseif getmetatable(resource) == MatchHandle then pcall(resource.Cancel, resource)
        elseif getmetatable(resource) == LobbyHandle then pcall(resource.Leave, resource)
        else socketClose(resource, 1000, "sdk_reinitialized") end
    end
    resources_ = setmetatable({}, { __mode = "k" })
end

Multiplayer.Error = Error

return Multiplayer
