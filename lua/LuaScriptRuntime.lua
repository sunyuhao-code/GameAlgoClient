---@meta
--- Executes downloaded experiment Lua in a restricted environment.

local LuaScriptRuntime = {}

local function readonlyLibrary(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

local WORD = 4294967296
local HALF_WORD = 2147483648
-- Double-only Lua hosts can represent every offset in this fallback interval.
local minInteger = math.mininteger or -4503599627370496
local maxInteger = math.maxinteger or 4503599627370495
local executionSeed = 0

local function checkInteger(value)
    if math.tointeger then
        local integer = math.tointeger(value)
        assert(integer, "integer expected")
        return integer
    end
    local number = tonumber(value)
    assert(number and number >= minInteger and number <= maxInteger and number == math.floor(number), "integer expected")
    return number
end

-- Keep equal-sized buckets and discard the tail to avoid modulo bias.
local function boundedWord(nextWord, limit)
    local bucket = math.floor(WORD / (limit + 1))
    repeat
        local value = math.floor(nextWord() / bucket)
        if value <= limit then return value end
    until false
end

local function randomOffset(nextWord, limit)
    if limit < WORD then return boundedWord(nextWord, limit) end
    -- Remove the low word before floating-point division to preserve 64-bit limits.
    local high = math.floor((limit - limit % WORD) / WORD)
    repeat
        local value = boundedWord(nextWord, high) * WORD + nextWord()
        if value <= limit then return value end
    until false
end

local function privateMathLibrary()
    local library = readonlyLibrary(math)
    local z, w
    -- Marsaglia's two multiply-with-carry generators. All intermediate words
    -- are exact on both the integer VM and older double-only Lua hosts.
    local function nextWord()
        z = 36969 * (z % 65536) + math.floor(z / 65536)
        w = 18000 * (w % 65536) + math.floor(w / 65536)
        return ((z % 65536) * 65536 + w) % WORD
    end

    function library.randomseed(...)
        local first, second = ...
        if select("#", ...) == 0 then
            first, second = nextWord(), nextWord()
        else
            first = checkInteger(first)
            second = second ~= nil and checkInteger(second) or 0
        end
        -- Exclude the absorbing states zero and multiplier * 65536 - 1.
        local zRange, wRange = 36969 * 65536 - 2, 18000 * 65536 - 2
        z = 1 + first % zRange
        w = 1 + (first % wRange + second % wRange) % wRange
        for _ = 1, 4 do nextWord() end
        return first, second
    end

    function library.random(...)
        local count = select("#", ...)
        if count == 0 then
            local high = nextWord()
            return (high * 2097152 + math.floor(nextWord() / 2048)) / 9007199254740992
        end
        local lower, upper = ...
        if count == 1 then
            lower, upper = 1, checkInteger(lower)
            if upper == 0 then lower, upper = minInteger, maxInteger end
        elseif count == 2 then
            lower, upper = checkInteger(lower), checkInteger(upper)
        else
            error("wrong number of arguments to random")
        end
        assert(lower <= upper, "interval is empty")
        local span = upper - lower
        if span >= 0 then return lower + randomOffset(nextWord, span) end
        -- A signed integer overflow means this interval covers over half of
        -- the VM's integers. Sample the full signed range until it lands inside.
        repeat
            local value = randomOffset(nextWord, maxInteger)
            if nextWord() >= HALF_WORD then value = -1 - value end
            if value >= lower and value <= upper then return value end
        until false
    end

    executionSeed = (executionSeed + 1) % WORD
    library.randomseed(os and os.time and os.time() or 0, executionSeed)
    return library
end

local instructionLimitExceeded = {}

local function protectedCallResults(ok, ...)
    -- Ordinary pcall results may include trailing nils. Only the host's budget signal escapes.
    if not ok and rawequal((...), instructionLimitExceeded) then error(instructionLimitExceeded, 0) end
    return ok, ...
end

local function sandboxEnvironment()
    local environment = {
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = function(...) return protectedCallResults(pcall(...)) end,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack or (table and table.unpack),
        math = privateMathLibrary(),
        string = readonlyLibrary(string),
        table = readonlyLibrary(table),
    }
    environment._G = environment
    return environment
end

local function compile(source, chunkName, environment)
    if _VERSION == "Lua 5.1" then
        if type(loadstring) ~= "function" or type(setfenv) ~= "function" then
            return nil, "Lua 5.1 runtime does not expose loadstring/setfenv"
        end
        local chunk, compileError = loadstring(source, chunkName)
        if not chunk then return nil, compileError end
        setfenv(chunk, environment)
        return chunk, nil
    end

    if type(load) ~= "function" then return nil, "Lua runtime does not expose load" end
    return load(source, chunkName, "t", environment)
end

local function executeWithLimit(execute, input, instructionLimit)
    local debugLibrary = rawget(_G, "debug")
    if not debugLibrary or type(debugLibrary.sethook) ~= "function" then
        return false, "instruction limit unavailable: debug.sethook is not available"
    end

    if type(debugLibrary.gethook) ~= "function" then
        return false, "instruction limit unavailable: debug.gethook is not available"
    end

    local inspected, hookState = pcall(function()
        local previousHook, previousMask, previousCount = debugLibrary.gethook()
        return { previousHook, previousMask, previousCount }
    end)
    if not inspected then
        return false, "instruction limit unavailable: failed to inspect existing hook: " .. tostring(hookState)
    end

    local previousHook, previousMask, previousCount = hookState[1], hookState[2], hookState[3]
    if previousHook ~= nil and type(previousHook) ~= "function" then
        return false, "instruction limit unavailable: existing hook is not a Lua function"
    end

    local hookStep = 1000
    local consumed = 0
    local running = false
    local installed, installError = pcall(function()
        debugLibrary.sethook(function()
            if not running then return end
            consumed = consumed + hookStep
            if consumed > instructionLimit then error(instructionLimitExceeded, 0) end
        end, "", hookStep)
    end)
    if not installed then
        return false, "instruction limit unavailable: failed to install hook: " .. tostring(installError)
    end

    -- Stop counting on both return paths before restoring the host hook.
    local function stopCounting(value)
        running = false
        return value
    end
    local ok, result = xpcall(function()
        running = true
        local value = execute(input)
        return stopCounting(value)
    end, stopCounting)
    local restored, restoreError = pcall(function()
        if previousHook then
            debugLibrary.sethook(previousHook, previousMask, previousCount)
        else
            debugLibrary.sethook()
        end
    end)
    if not restored then
        pcall(function() debugLibrary.sethook() end)
        return false, "instruction limit cleanup failed: " .. tostring(restoreError)
    end
    if consumed > instructionLimit then return false, "script instruction limit exceeded" end
    return ok, result
end

--- Returns whether Execute() can enforce its instruction budget on this host.
--- Mirrors the fail-closed checks above so callers can tell a scripted
--- experiment that will refuse to run apart from one that is merely loading.
function LuaScriptRuntime.CanEnforceLimit()
    local debugLibrary = rawget(_G, "debug")
    if not debugLibrary or type(debugLibrary.sethook) ~= "function" then return false end
    if type(debugLibrary.gethook) ~= "function" then return false end
    local inspected, hook = pcall(debugLibrary.gethook)
    if not inspected then return false end
    return hook == nil or type(hook) == "function"
end

--- Runs an experiment chunk and its execute function under the instruction limit.
--- Exceeding a stage's budget terminates that stage, including protected calls within it.
--- Both stages share a private math.random stream. Explicit seeds reproduce that
--- stream across executions, independently of the game's RNG.
---@param source string
---@param input any
---@param options table|nil Optional chunkName and instructionLimit.
---@return table|nil result
---@return string|nil err
function LuaScriptRuntime.Execute(source, input, options)
    options = options or {}
    local instructionLimit = tonumber(options.instructionLimit) or 200000
    local environment = sandboxEnvironment()
    local chunk, compileError = compile(tostring(source or ""), options.chunkName or "@gamealgo-script", environment)
    if not chunk then return nil, "compile failed: " .. tostring(compileError) end

    local ok, exported = executeWithLimit(chunk, nil, instructionLimit)
    if not ok then return nil, "load failed: " .. tostring(exported) end

    local execute = nil
    if type(exported) == "function" then
        execute = exported
    elseif type(exported) == "table" and type(exported.execute) == "function" then
        execute = exported.execute
    elseif type(environment.execute) == "function" then
        execute = environment.execute
    end
    if not execute then return nil, "script must return a function/table.execute or define execute(input)" end

    local executed, result = executeWithLimit(execute, input, instructionLimit)
    if not executed then return nil, "execute failed: " .. tostring(result) end
    if type(result) ~= "table" then return nil, "execute(input) must return a table" end
    if result.payload == nil then return nil, "execute(input) result must contain payload" end
    if result.diagnostics == nil then result.diagnostics = {} end
    return result, nil
end

return LuaScriptRuntime
