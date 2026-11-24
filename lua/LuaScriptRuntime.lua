---@meta
--- Executes downloaded experiment Lua in a restricted environment.

local LuaScriptRuntime = {}

local function readonlyLibrary(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

local function sandboxEnvironment()
    local environment = {
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack or (table and table.unpack),
        math = readonlyLibrary(math),
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
    local installed, installError = pcall(function()
        debugLibrary.sethook(function()
            consumed = consumed + hookStep
            if consumed > instructionLimit then error("script instruction limit exceeded") end
        end, "", hookStep)
    end)
    if not installed then
        return false, "instruction limit unavailable: failed to install hook: " .. tostring(installError)
    end

    local ok, result = pcall(execute, input)
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
    return ok, result
end

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
