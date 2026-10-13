local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local Multiplayer = require("Multiplayer")
local Protocol = require("MultiplayerProtocol")
local Wire = require("MultiplayerWire")

local function equal(actual, expected, message)
    assert(actual == expected, (message or "values differ")
        .. ": expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
end

local currentTime = 0
local tasks = {}
local nextTaskId = 0
local scheduler = {}

function scheduler:Schedule(delay, callback)
    nextTaskId = nextTaskId + 1
    local handle = { id = nextTaskId }
    tasks[handle.id] = { at = currentTime + delay, callback = callback }
    return handle
end

function scheduler:Cancel(handle)
    if handle then tasks[handle.id] = nil end
end

local function advance(milliseconds)
    currentTime = currentTime + milliseconds
    while true do
        local dueId, due = nil, nil
        for id, task in pairs(tasks) do
            if task.at <= currentTime and (not due or task.at < due.at or (task.at == due.at and id < dueId)) then
                dueId, due = id, task
            end
        end
        if not due then return end
        tasks[dueId] = nil
        due.callback()
    end
end

local sockets = {}
local function socketFactory(url, handlers)
    local socket = { url = url, handlers = handlers, sentText = {}, sentBinary = {}, closed = false }
    function socket:SendText(value) self.sentText[#self.sentText + 1] = value end
    function socket:SendBinary(value) self.sentBinary[#self.sentBinary + 1] = value end
    function socket:Close(code, reason) self.closed = true self.closeCode = code self.closeReason = reason end
    function socket:Open() self.handlers.open() end
    function socket:Text(value) self.handlers.text(value) end
    function socket:Binary(value) self.handlers.binary(value) end
    function socket:Fail(reason) self.handlers.error(reason) end
    function socket:Closed(code, reason) self.handlers.close(code, reason) end
    sockets[#sockets + 1] = socket
    return socket
end

local requests = {}
local function request(options, callback)
    requests[#requests + 1] = options
    if options.url:match("/v1/multiplayer/access%-token$") then
        callback(nil, {
            status = 200,
            body = cjson.encode({ accessToken = "access-a", controllerUrl = "ws://controller.test/match" }),
        })
    else
        callback(nil, { status = 200, body = cjson.encode({ items = {} }) })
    end
end

Multiplayer.Configure({
    baseUrl = "https://api.test",
    gameKey = "ga_live_test",
    userId = function() return "user-a" end,
    sessionId = function() return "session-a" end,
    nowMs = function() return currentTime end,
    scheduler = scheduler,
    request = request,
    socketFactory = socketFactory,
})

local protocol = Protocol.Define({
    id = "demo",
    version = 1,
    roomInit = { { "seed", "u32" }, { "map", { type = "string", maxBytes = 16 } } },
    sharedState = { { "tick", "u32" }, { "x", "i16" }, { "alive", "bool" } },
    seatState = { { "score", "u16" } },
    hostState = { { "tick", "u32" }, { "scores", { type = "array", items = "u16", maxLength = 4 } } },
    input = { { "direction", { type = "enum", values = { "left", "right" } } }, { "pressed", "bool" } },
    events = { { "winner", { { "seat", "u8" } } } },
})

equal(protocol.hash, "ga1_5108590b8da4fbfe", "Maker protocol hash matches the Web SDK")
local encodedInit = protocol.EncodeRoomInit({ seed = 42, map = "island" })
equal(protocol.DecodeRoomInit(encodedInit).map, "island", "protocol values round-trip")
local frame = Wire.Decode(Wire.Encode({
    type = Wire.MessageType.roomInit,
    flags = 0,
    targetSeat = 255,
    hostEpoch = 3,
    sequence = 4,
    stateRevision = 5,
    payload = encodedInit,
}))
equal(frame.hostEpoch, 3, "wire host epoch round-trips")
equal(frame.payload, encodedInit, "wire payload round-trips")
equal((encodedInit:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)),
    "2a000000060069736c616e64", "Maker payload bytes match the Web SDK")

-- Matching obtains a short-lived access token, opens the controller socket,
-- and exposes active cancellation without reporting it as a network error.
do
    local matched, failed = nil, nil
    local handle = Multiplayer.Matchmaking.Join({ queueId = "casual_1v1", protocolHash = protocol.hash })
    handle:OnMatched(function(value) matched = value end)
    handle:OnError(function(value) failed = value end)
    equal(#requests, 1, "match requests an access token")
    equal(#sockets, 1, "match opens a controller socket")
    local socket = sockets[#sockets]
    socket:Open()
    local join = cjson.decode(socket.sentText[1])
    equal(join.type, "join", "match sends a join command")
    equal(join.protocolHash, protocol.hash, "match sends the static protocol hash")
    socket:Text(cjson.encode({
        type = "matched",
        roomId = "room-a",
        relayId = "relay-a",
        relayUrl = "ws://relay.test/room",
        seat = 0,
        hostSeat = 0,
        ticket = "ticket-a",
    }))
    equal(matched.roomId, "room-a", "match callback receives the room")
    equal(failed, nil, "successful matching does not emit an error")

    local cancelError, cancelOnError = nil, nil
    local cancelled = Multiplayer.Matchmaking.Join({
        accessToken = "access-a",
        controllerUrl = "ws://controller.test/match",
        queueId = "casual_1v1",
        protocolHash = protocol.hash,
    })
    cancelled:WaitForMatched(function(error) cancelError = error end)
    cancelled:OnError(function(error) cancelOnError = error end)
    local cancelSocket = sockets[#sockets]
    cancelSocket:Open()
    cancelled:Cancel()
    equal(cancelError.code, "match_cancelled", "active cancellation settles the waiter")
    equal(cancelOnError, nil, "active cancellation is not a network error")
    equal(cjson.decode(cancelSocket.sentText[#cancelSocket.sentText]).type, "cancel", "controller receives cancel")
end

-- Room state uses the same binary envelopes, host-only operations, pacing,
-- reliable input acknowledgement, and recovery handshake as the Web SDK.
do
    local room, connectError = nil, nil
    Multiplayer.ConnectRoom("ws://relay.test/room", "ticket-a", protocol, function(error, value)
        connectError, room = error, value
    end)
    local socket = sockets[#sockets]
    socket:Open()
    equal(cjson.decode(socket.sentText[1]).type, "join", "room authenticates with the ticket")
    socket:Text(cjson.encode({
        type = "welcome",
        roomId = "room-a",
        seat = 0,
        hostSeat = 0,
        hostEpoch = 1,
        phase = "active",
        sessionToken = "session-token",
        roster = {
            { seat = 0, connected = true, canHost = true },
            { seat = 1, connected = true, canHost = true },
        },
    }))
    equal(connectError, nil, "room connects")
    equal(room.isHost, true, "welcome establishes host ownership")

    room:Initialize({ seed = 7, map = "island" })
    local initFrame = Wire.Decode(socket.sentBinary[#socket.sentBinary])
    equal(initFrame.type, Wire.MessageType.roomInit, "host publishes room init")
    equal(protocol.DecodeRoomInit(initFrame.payload).seed, 7, "room init uses the protocol codec")

    room:PublishState({ sharedState = { tick = 1, x = -2, alive = true }, seatStates = { [1] = { score = 9 } } })
    local sharedFrame = Wire.Decode(socket.sentBinary[#socket.sentBinary - 1])
    local seatFrame = Wire.Decode(socket.sentBinary[#socket.sentBinary])
    equal(sharedFrame.type, Wire.MessageType.sharedState, "shared state is broadcast")
    equal(seatFrame.targetSeat, 1, "seat state targets one seat")

    room:PublishState({ sharedState = { tick = 2, x = 3, alive = true } })
    room:PublishState({ sharedState = { tick = 3, x = 4, alive = true } })
    advance(99)
    equal(Wire.Decode(socket.sentBinary[#socket.sentBinary]).stateRevision, 1, "state updates are paced")
    advance(1)
    local latest = Wire.Decode(socket.sentBinary[#socket.sentBinary])
    equal(protocol.DecodeSharedState(latest.payload).tick, 3, "pacing keeps only the latest pending state")

    local received = nil
    room:OnInput(function(value) received = value end)
    socket:Binary(Wire.Encode({
        type = Wire.MessageType.inputBatch,
        flags = Wire.RELIABLE_INPUT_FLAG,
        targetSeat = 1,
        hostEpoch = 1,
        sequence = 8,
        stateRevision = 0,
        payload = protocol.EncodeInput({ direction = "left", pressed = true }),
    }))
    equal(received.seat, 1, "host receives player input")
    local ack = Wire.Decode(socket.sentBinary[#socket.sentBinary])
    equal(ack.type, Wire.MessageType.inputAck, "reliable input is acknowledged")
    equal(ack.sequence, 8, "acknowledgement carries the input sequence")

    local recovered = nil
    room:OnBecomeHost(function(value) recovered = value end)
    socket:Text(cjson.encode({ type = "become_host", hostEpoch = 2, recovery = true }))
    socket:Binary(Wire.Encode({
        type = Wire.MessageType.hostRecovery,
        flags = 0,
        targetSeat = 0,
        hostEpoch = 2,
        sequence = 9,
        stateRevision = 2,
        payload = protocol.EncodeHostState({ tick = 3, scores = { 1, 2 } }),
    }))
    equal(recovered.tick, 3, "new host receives the complete recovery state")
    equal(cjson.decode(socket.sentText[#socket.sentText]).type, "host_ready", "recovery completion is acknowledged")
    room:Disconnect({ reconnect = false })
end

print("Maker multiplayer tests passed")
