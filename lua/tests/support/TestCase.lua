-- Shared assertions for the regression suites ported from UrhoX.
local cjson = require("cjson")
local TestCase = {}

local function equal(actual, expected, seen)
    if actual == expected then return true end
    if type(actual) ~= "table" or type(expected) ~= "table" then return false end
    seen = seen or {}
    if seen[actual] == expected then return true end
    seen[actual] = expected
    for key, value in pairs(actual) do
        if not equal(value, expected[key], seen) then return false end
    end
    for key in pairs(expected) do
        if actual[key] == nil then return false end
    end
    return true
end

local function describe(value)
    local ok, encoded = pcall(cjson.encode, value)
    return ok and encoded or tostring(value)
end

function TestCase.assertEquals(actual, expected, message)
    assert(equal(actual, expected), message or (describe(actual) .. " differs from " .. describe(expected)))
end

function TestCase.assertNotEquals(actual, expected, message)
    assert(not equal(actual, expected), message or "values must differ")
end

function TestCase.assertTrue(value, message) assert(value == true, message or "expected true") end
function TestCase.assertFalse(value, message) assert(value == false, message or "expected false") end
function TestCase.assertNil(value, message) assert(value == nil, message or ("expected nil: " .. describe(value))) end
function TestCase.assertNotNil(value, message) assert(value ~= nil, message or "expected a value") end
function TestCase.assertIsString(value) assert(type(value) == "string", "expected string") end
function TestCase.assertIsTable(value) assert(type(value) == "table", "expected table") end
function TestCase.assertIsFunction(value) assert(type(value) == "function", "expected function") end

function TestCase.assertStrContains(value, substring)
    assert(type(value) == "string" and value:find(substring, 1, true),
        describe(value) .. " does not contain " .. describe(substring))
end

--- Runs named test methods with per-case setup and teardown; raises on failure.
---@param suites table[] Suites containing test_* methods and optional fixtures.
function TestCase.run(suites)
    local count = 0
    for _, suite in ipairs(suites) do
        local names = {}
        for name in pairs(suite) do
            if name:match("^test_") then table.insert(names, name) end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local ok, reason = xpcall(function()
                if suite.setUp then suite:setUp() end
                suite[name](suite)
            end, debug.traceback)
            local cleaned, cleanupError = pcall(function()
                if suite.tearDown then suite:tearDown() end
            end)
            assert(ok, name .. ": " .. tostring(reason))
            assert(cleaned, name .. " teardown: " .. tostring(cleanupError))
            count = count + 1
        end
    end
    print("Passed " .. count .. " regression cases")
end

return TestCase
