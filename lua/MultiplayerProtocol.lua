---@meta
--- Static binary protocol shared by the Maker and Web multiplayer SDKs.

local MultiplayerProtocol = {}

local PRIMITIVES = {
    bool = true,
    u8 = true,
    i8 = true,
    u16 = true,
    i16 = true,
    u32 = true,
    i32 = true,
    f32 = true,
}

local function integer(value, minimum, maximum)
    if type(value) ~= "number" or value % 1 ~= 0 or value < minimum or value > maximum then
        error("integer must be between " .. tostring(minimum) .. " and " .. tostring(maximum), 3)
    end
    return value
end

local function orderedEntries(value, label)
    if type(value) ~= "table" then error(label .. " must be an ordered field list", 3) end
    local result = {}
    for index, entry in ipairs(value) do
        if type(entry) ~= "table" or type(entry[1]) ~= "string" or entry[2] == nil then
            error(label .. " entry " .. tostring(index) .. " must be { name, schema }", 3)
        end
        if not entry[1]:match("^[A-Za-z_][A-Za-z0-9_]*$") or #entry[1] > 64 then
            error("invalid field name: " .. tostring(entry[1]), 3)
        end
        result[#result + 1] = { entry[1], entry[2] }
    end
    return result
end

local function validateSchema(schema, ancestors)
    if type(schema) == "string" then
        if not PRIMITIVES[schema] then error("unsupported multiplayer primitive: " .. schema, 3) end
        return
    end
    if type(schema) ~= "table" then error("multiplayer field schema must be a string or table", 3) end
    if ancestors[schema] then error("recursive multiplayer schemas are not supported", 3) end
    ancestors[schema] = true
    if schema.type == "string" or schema.type == "bytes" then
        integer(schema.maxBytes, 0, 65535)
    elseif schema.type == "enum" then
        if type(schema.values) ~= "table" or #schema.values < 1 or #schema.values > 256 then
            error("enum values must contain 1 to 256 unique values", 3)
        end
        local seen = {}
        for _, item in ipairs(schema.values) do
            if type(item) ~= "string" or seen[item] then
                error("enum values must contain 1 to 256 unique strings", 3)
            end
            seen[item] = true
        end
    elseif schema.type == "array" then
        integer(schema.maxLength, 0, 65535)
        validateSchema(schema.items, ancestors)
    elseif schema.type == "struct" then
        schema.fields = orderedEntries(schema.fields, "struct fields")
        for _, entry in ipairs(schema.fields) do validateSchema(entry[2], ancestors) end
    else
        error("unsupported multiplayer schema type: " .. tostring(schema.type), 3)
    end
    ancestors[schema] = nil
end

local function jsonString(value)
    value = tostring(value)
    local result = { '"' }
    for index = 1, #value do
        local byte = value:byte(index)
        if byte == 0x22 then result[#result + 1] = '\\"'
        elseif byte == 0x5c then result[#result + 1] = "\\\\"
        elseif byte == 0x08 then result[#result + 1] = "\\b"
        elseif byte == 0x0c then result[#result + 1] = "\\f"
        elseif byte == 0x0a then result[#result + 1] = "\\n"
        elseif byte == 0x0d then result[#result + 1] = "\\r"
        elseif byte == 0x09 then result[#result + 1] = "\\t"
        elseif byte < 0x20 then result[#result + 1] = string.format("\\u%04x", byte)
        else result[#result + 1] = string.char(byte) end
    end
    result[#result + 1] = '"'
    return table.concat(result)
end

local schemaJson

local function fieldsJson(fields)
    local parts = {}
    for _, entry in ipairs(fields) do
        parts[#parts + 1] = jsonString(entry[1]) .. ":" .. schemaJson(entry[2])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

schemaJson = function(schema)
    if type(schema) == "string" then return jsonString(schema) end
    if schema.type == "string" or schema.type == "bytes" then
        return "{\"type\":" .. jsonString(schema.type) .. ",\"maxBytes\":" .. tostring(schema.maxBytes) .. "}"
    end
    if schema.type == "enum" then
        local values = {}
        for _, value in ipairs(schema.values) do values[#values + 1] = jsonString(value) end
        return "{\"type\":\"enum\",\"values\":[" .. table.concat(values, ",") .. "]}"
    end
    if schema.type == "array" then
        return "{\"type\":\"array\",\"items\":" .. schemaJson(schema.items)
            .. ",\"maxLength\":" .. tostring(schema.maxLength) .. "}"
    end
    return "{\"type\":\"struct\",\"fields\":" .. fieldsJson(schema.fields) .. "}"
end

local function definitionJson(definition)
    local parts = {
        "\"id\":" .. jsonString(definition.id),
        "\"version\":" .. tostring(definition.version),
        "\"roomInit\":" .. fieldsJson(definition.roomInit),
        "\"sharedState\":" .. fieldsJson(definition.sharedState),
        "\"seatState\":" .. fieldsJson(definition.seatState),
        "\"hostState\":" .. fieldsJson(definition.hostState),
        "\"input\":" .. fieldsJson(definition.input),
    }
    if definition.events ~= nil then
        local events = {}
        for _, entry in ipairs(definition.events) do
            events[#events + 1] = jsonString(entry[1]) .. ":" .. fieldsJson(entry[2])
        end
        parts[#parts + 1] = "\"events\":{" .. table.concat(events, ",") .. "}"
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function fnv1a64(value)
    local hash = -3750763034362895579 -- unsigned 0xcbf29ce484222325
    for index = 1, #value do
        hash = (hash ~ value:byte(index)) * 1099511628211
    end
    return string.format("%016x", hash)
end

local Writer = {}
Writer.__index = Writer

function Writer.New()
    return setmetatable({ chunks = {} }, Writer)
end

function Writer:Pack(format, value)
    self.chunks[#self.chunks + 1] = string.pack("<" .. format, value)
end

function Writer:Bytes(value)
    self.chunks[#self.chunks + 1] = value
end

function Writer:Finish()
    return table.concat(self.chunks)
end

local Reader = {}
Reader.__index = Reader

function Reader.New(bytes)
    if type(bytes) ~= "string" then error("binary payload must be a Lua string", 3) end
    return setmetatable({ bytes = bytes, offset = 1 }, Reader)
end

function Reader:Unpack(format)
    local ok, value, nextOffset = pcall(string.unpack, "<" .. format, self.bytes, self.offset)
    if not ok then error("binary payload ended early", 3) end
    self.offset = nextOffset
    return value
end

function Reader:Bytes(length)
    if length < 0 or self.offset + length - 1 > #self.bytes then error("binary payload ended early", 3) end
    local result = self.bytes:sub(self.offset, self.offset + length - 1)
    self.offset = self.offset + length
    return result
end

function Reader:Done()
    return self.offset == #self.bytes + 1
end

local function writeValue(writer, schema, value)
    if schema == "bool" then
        if type(value) ~= "boolean" then error("expected bool", 3) end
        writer:Pack("I1", value and 1 or 0)
    elseif schema == "u8" then writer:Pack("I1", integer(value, 0, 0xff))
    elseif schema == "i8" then writer:Pack("i1", integer(value, -0x80, 0x7f))
    elseif schema == "u16" then writer:Pack("I2", integer(value, 0, 0xffff))
    elseif schema == "i16" then writer:Pack("i2", integer(value, -0x8000, 0x7fff))
    elseif schema == "u32" then writer:Pack("I4", integer(value, 0, 0xffffffff))
    elseif schema == "i32" then writer:Pack("i4", integer(value, -0x80000000, 0x7fffffff))
    elseif schema == "f32" then
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            error("expected finite f32", 3)
        end
        writer:Pack("f", value)
    elseif schema.type == "string" or schema.type == "bytes" then
        if type(value) ~= "string" then error("expected " .. schema.type, 3) end
        if #value > schema.maxBytes then error(schema.type .. " exceeds configured bound", 3) end
        writer:Pack("I2", #value)
        writer:Bytes(value)
    elseif schema.type == "enum" then
        local id = nil
        for index, item in ipairs(schema.values) do
            if item == value then id = index - 1 break end
        end
        if id == nil then error("unknown enum value: " .. tostring(value), 3) end
        writer:Pack("I1", id)
    elseif schema.type == "array" then
        if type(value) ~= "table" then error("expected array", 3) end
        if #value > schema.maxLength then error("array exceeds configured bound", 3) end
        writer:Pack("I2", #value)
        for _, item in ipairs(value) do writeValue(writer, schema.items, item) end
    elseif schema.type == "struct" then
        if type(value) ~= "table" then error("expected object", 3) end
        for _, entry in ipairs(schema.fields) do writeValue(writer, entry[2], value[entry[1]]) end
    else
        error("unsupported multiplayer schema", 3)
    end
end

local function readValue(reader, schema)
    if schema == "bool" then return reader:Unpack("I1") ~= 0 end
    if schema == "u8" then return reader:Unpack("I1") end
    if schema == "i8" then return reader:Unpack("i1") end
    if schema == "u16" then return reader:Unpack("I2") end
    if schema == "i16" then return reader:Unpack("i2") end
    if schema == "u32" then return reader:Unpack("I4") end
    if schema == "i32" then return reader:Unpack("i4") end
    if schema == "f32" then return reader:Unpack("f") end
    if schema.type == "string" or schema.type == "bytes" then
        local length = reader:Unpack("I2")
        if length > schema.maxBytes then error(schema.type .. " exceeds configured bound", 3) end
        return reader:Bytes(length)
    end
    if schema.type == "enum" then
        local value = schema.values[reader:Unpack("I1") + 1]
        if value == nil then error("unknown enum id", 3) end
        return value
    end
    if schema.type == "array" then
        local length = reader:Unpack("I2")
        if length > schema.maxLength then error("array exceeds configured bound", 3) end
        local result = {}
        for index = 1, length do result[index] = readValue(reader, schema.items) end
        return result
    end
    local result = {}
    for _, entry in ipairs(schema.fields) do result[entry[1]] = readValue(reader, entry[2]) end
    return result
end

local function codec(fields)
    local schema = { type = "struct", fields = fields }
    return {
        Encode = function(value)
            local writer = Writer.New()
            writeValue(writer, schema, value)
            return writer:Finish()
        end,
        Decode = function(bytes)
            local reader = Reader.New(bytes)
            local value = readValue(reader, schema)
            if not reader:Done() then error("binary payload has trailing bytes", 2) end
            return value
        end,
    }
end

function MultiplayerProtocol.Define(definition)
    if type(definition) ~= "table" then error("multiplayer protocol definition is required", 2) end
    if type(definition.id) ~= "string" or not definition.id:match("^[A-Za-z0-9%._:%-]+$") or #definition.id > 64 then
        error("protocol id is invalid", 2)
    end
    integer(definition.version, 1, 0x7fffffff)
    for _, name in ipairs({ "roomInit", "sharedState", "seatState", "hostState", "input" }) do
        definition[name] = orderedEntries(definition[name], name)
        for _, entry in ipairs(definition[name]) do validateSchema(entry[2], {}) end
    end
    if definition.events ~= nil then
        definition.events = orderedEntries(definition.events, "events")
        if #definition.events > 255 then error("protocol supports at most 255 event types", 2) end
        for _, event in ipairs(definition.events) do
            event[2] = orderedEntries(event[2], "event fields")
            for _, field in ipairs(event[2]) do validateSchema(field[2], {}) end
        end
    end

    local roomInit = codec(definition.roomInit)
    local sharedState = codec(definition.sharedState)
    local seatState = codec(definition.seatState)
    local hostState = codec(definition.hostState)
    local input = codec(definition.input)
    local eventsByName, eventsById = {}, {}
    for index, entry in ipairs(definition.events or {}) do
        local event = { id = index, name = entry[1], codec = codec(entry[2]) }
        eventsByName[event.name] = event
        eventsById[event.id] = event
    end

    local protocol = {
        id = definition.id,
        version = definition.version,
        hash = "ga1_" .. fnv1a64(definitionJson(definition)),
    }
    function protocol.EncodeRoomInit(value) return roomInit.Encode(value) end
    function protocol.DecodeRoomInit(value) return roomInit.Decode(value) end
    function protocol.EncodeSharedState(value) return sharedState.Encode(value) end
    function protocol.DecodeSharedState(value) return sharedState.Decode(value) end
    function protocol.EncodeSeatState(value) return seatState.Encode(value) end
    function protocol.DecodeSeatState(value) return seatState.Decode(value) end
    function protocol.EncodeHostState(value) return hostState.Encode(value) end
    function protocol.DecodeHostState(value) return hostState.Decode(value) end
    function protocol.EncodeInput(value) return input.Encode(value) end
    function protocol.DecodeInput(value) return input.Decode(value) end
    function protocol.EncodeEvent(name, value)
        local event = eventsByName[name]
        if not event then error("unknown multiplayer event: " .. tostring(name), 2) end
        return string.char(event.id) .. event.codec.Encode(value)
    end
    function protocol.DecodeEvent(value)
        if type(value) ~= "string" or #value < 1 then error("invalid multiplayer event", 2) end
        local event = eventsById[value:byte(1)]
        if not event then error("unknown multiplayer event id: " .. tostring(value:byte(1)), 2) end
        return { type = event.name, payload = event.codec.Decode(value:sub(2)) }
    end
    return protocol
end

return MultiplayerProtocol
