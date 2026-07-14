---@meta
--- Portable SHA-256 used to verify immutable downloaded scripts.

local Sha256 = {}

local MOD = 4294967296
local floor = math.floor

local bitlib = rawget(_G, "bit32") or rawget(_G, "bit")

local function normalize(value)
    return value % MOD
end

local AND_NIBBLE = {}
local XOR_NIBBLE = {}
for left = 0, 15 do
    for right = 0, 15 do
        local andValue = 0
        local xorValue = 0
        local leftValue = left
        local rightValue = right
        local bitValue = 1
        for _ = 1, 4 do
            local leftBit = leftValue % 2
            local rightBit = rightValue % 2
            if leftBit == 1 and rightBit == 1 then andValue = andValue + bitValue end
            if leftBit ~= rightBit then xorValue = xorValue + bitValue end
            leftValue = floor(leftValue / 2)
            rightValue = floor(rightValue / 2)
            bitValue = bitValue * 2
        end
        local key = left * 16 + right
        AND_NIBBLE[key] = andValue
        XOR_NIBBLE[key] = xorValue
    end
end

local function fallbackBinary(left, right, lookup)
    left = normalize(left)
    right = normalize(right)
    local result = 0
    local multiplier = 1
    for _ = 1, 8 do
        local leftNibble = left % 16
        local rightNibble = right % 16
        result = result + lookup[leftNibble * 16 + rightNibble] * multiplier
        left = floor(left / 16)
        right = floor(right / 16)
        multiplier = multiplier * 16
    end
    return result
end

local function fallbackBand(left, right)
    return fallbackBinary(left, right, AND_NIBBLE)
end

local function fallbackBxor(left, right)
    return fallbackBinary(left, right, XOR_NIBBLE)
end

local function band(left, right)
    if bitlib then return normalize(bitlib.band(left, right)) end
    return fallbackBand(left, right)
end

local function bxor(left, right, ...)
    local result
    if bitlib then
        result = normalize(bitlib.bxor(left, right))
    else
        result = fallbackBxor(left, right)
    end
    if select("#", ...) > 0 then return bxor(result, ...) end
    return result
end

local function bnot(value)
    if bitlib then return normalize(bitlib.bnot(value)) end
    return 4294967295 - normalize(value)
end

local function rshift(value, bits)
    if bitlib then
        local fn = bitlib.rshift or bitlib.brshift
        return normalize(fn(value, bits))
    end
    return floor(normalize(value) / (2 ^ bits))
end

local function lshift(value, bits)
    if bitlib then
        local fn = bitlib.lshift or bitlib.blshift
        return normalize(fn(value, bits))
    end
    return normalize(value * (2 ^ bits))
end

local function rotateRight(value, bits)
    if bitlib and bitlib.rrotate then return normalize(bitlib.rrotate(value, bits)) end
    if bitlib and bitlib.ror then return normalize(bitlib.ror(value, bits)) end
    return normalize(rshift(value, bits) + lshift(value, 32 - bits))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function appendLength(message, bitLength)
    local high = floor(bitLength / MOD)
    local low = bitLength % MOD
    local bytes = {}
    for shift = 24, 0, -8 do bytes[#bytes + 1] = string.char(rshift(high, shift) % 256) end
    for shift = 24, 0, -8 do bytes[#bytes + 1] = string.char(rshift(low, shift) % 256) end
    return message .. table.concat(bytes)
end

function Sha256.hex(content)
    local message = tostring(content or "")
    local bitLength = #message * 8
    message = message .. string.char(0x80)
    local padding = (56 - (#message % 64)) % 64
    message = message .. string.rep(string.char(0), padding)
    message = appendLength(message, bitLength)

    local hash = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }

    for offset = 1, #message, 64 do
        local words = {}
        for index = 0, 15 do
            local position = offset + index * 4
            local b1, b2, b3, b4 = message:byte(position, position + 3)
            words[index] = normalize(b1 * 16777216 + b2 * 65536 + b3 * 256 + b4)
        end
        for index = 16, 63 do
            local value15 = words[index - 15]
            local value2 = words[index - 2]
            local s0 = bxor(rotateRight(value15, 7), rotateRight(value15, 18), rshift(value15, 3))
            local s1 = bxor(rotateRight(value2, 17), rotateRight(value2, 19), rshift(value2, 10))
            words[index] = normalize(words[index - 16] + s0 + words[index - 7] + s1)
        end

        local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
        local e, f, g, h = hash[5], hash[6], hash[7], hash[8]
        for index = 0, 63 do
            local sum1 = bxor(rotateRight(e, 6), rotateRight(e, 11), rotateRight(e, 25))
            local choice = bxor(band(e, f), band(bnot(e), g))
            local temp1 = normalize(h + sum1 + choice + K[index + 1] + words[index])
            local sum0 = bxor(rotateRight(a, 2), rotateRight(a, 13), rotateRight(a, 22))
            local majority = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = normalize(sum0 + majority)
            h, g, f, e, d, c, b, a = g, f, e, normalize(d + temp1), c, b, a, normalize(temp1 + temp2)
        end

        hash[1] = normalize(hash[1] + a)
        hash[2] = normalize(hash[2] + b)
        hash[3] = normalize(hash[3] + c)
        hash[4] = normalize(hash[4] + d)
        hash[5] = normalize(hash[5] + e)
        hash[6] = normalize(hash[6] + f)
        hash[7] = normalize(hash[7] + g)
        hash[8] = normalize(hash[8] + h)
    end

    local parts = {}
    for index = 1, 8 do
        for shift = 24, 0, -8 do
            parts[#parts + 1] = string.format("%02x", floor(rshift(hash[index], shift) % 256))
        end
    end
    return table.concat(parts)
end

function Sha256.hash(content)
    return "sha256:" .. Sha256.hex(content)
end

return Sha256
