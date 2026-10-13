---@meta
--- Binary envelope shared with @gamealgo/web multiplayer.

local MultiplayerWire = {}

MultiplayerWire.HEADER_BYTES = 20
MultiplayerWire.NO_TARGET_SEAT = 0xff
MultiplayerWire.RELIABLE_INPUT_FLAG = 1
MultiplayerWire.MessageType = {
    roomInit = 1,
    sharedState = 2,
    seatState = 3,
    hostState = 4,
    inputBatch = 5,
    gameEvent = 6,
    hostRecovery = 7,
    inputAck = 8,
}

local function unsigned32(value, label)
    value = tonumber(value)
    if not value or value % 1 ~= 0 or value < 0 or value > 0xffffffff then
        error((label or "value") .. " must be an unsigned 32-bit integer", 3)
    end
    return value
end

function MultiplayerWire.Encode(frame)
    if type(frame) ~= "table" then error("multiplayer frame is required", 2) end
    local payload = frame.payload or ""
    if type(payload) ~= "string" then error("multiplayer payload must be a Lua string", 2) end
    return string.pack(
        "<BBBBBBxxI4I4I4",
        0x47,
        0x41,
        1,
        tonumber(frame.type) or 0,
        tonumber(frame.flags) or 0,
        tonumber(frame.targetSeat) or MultiplayerWire.NO_TARGET_SEAT,
        unsigned32(frame.hostEpoch or 0, "hostEpoch"),
        unsigned32(frame.sequence or 0, "sequence"),
        unsigned32(frame.stateRevision or 0, "stateRevision")
    ) .. payload
end

function MultiplayerWire.Decode(value)
    if type(value) ~= "string" or #value < MultiplayerWire.HEADER_BYTES then
        error("invalid multiplayer frame", 2)
    end
    local magicG, magicA, version, messageType, flags, targetSeat,
        hostEpoch, sequence, stateRevision, payloadOffset = string.unpack("<BBBBBBxxI4I4I4", value)
    if magicG ~= 0x47 or magicA ~= 0x41 or version ~= 1 then
        error("invalid multiplayer frame", 2)
    end
    return {
        type = messageType,
        flags = flags,
        targetSeat = targetSeat,
        hostEpoch = hostEpoch,
        sequence = sequence,
        stateRevision = stateRevision,
        payload = value:sub(payloadOffset),
    }
end

return MultiplayerWire
