-- Script verification, instruction budgets and experiment RNG on the standalone game Lua VM.
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local lu = require("tests.support.TestCase")
local Sha256 = require("Sha256")
local Runtime = require("LuaScriptRuntime")

local function frameScheduler()
    local scheduler = { pending = {} }
    function scheduler:Schedule(delay, callback)
        assert(delay == 0)
        local timer = { run = callback }
        table.insert(self.pending, timer)
        return timer
    end
    function scheduler:Cancel(timer) timer.cancelled = true end
    function scheduler:update()
        local due = self.pending
        self.pending = {}
        for _, timer in ipairs(due) do
            if not timer.cancelled then timer.run() end
        end
    end
    return scheduler
end

local function recorder()
    local replies = {}
    return replies, function(err, digest) table.insert(replies, { err = err, digest = digest }) end
end

TestGameAlgoSha256 = {}

function TestGameAlgoSha256:test_known_digests_and_inline_padding_boundaries()
    local vectors = {
        { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        { ("a"):rep(55), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
        { ("a"):rep(56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
        { ("a"):rep(63), "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34" },
        { ("a"):rep(64), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
        { ("a"):rep(247), "d1c97f05a04d45d67be0d82b39f93d8e06e52db3aeb4752067c9b5e61583b641" },
    }
    for _, vector in ipairs(vectors) do
        local content, expected = vector[1], vector[2]
        lu.assertEquals(Sha256.hex(content), expected)
        lu.assertEquals(Sha256.hash(content), "sha256:" .. expected)
        local replies, done = recorder()
        lu.assertNil(Sha256.hashAsync(content, nil, done))
        lu.assertEquals(replies, { { digest = "sha256:" .. expected } })
    end
end

function TestGameAlgoSha256:test_padding_spans_frames()
    local scheduler = frameScheduler()
    local replies, done = recorder()
    local task = Sha256.hashAsync(("a"):rep(248), scheduler, done)
    lu.assertIsTable(task)
    scheduler:update()
    lu.assertEquals(#replies, 0)
    scheduler:update()
    lu.assertEquals(replies, { { digest = "sha256:fdff3ab023a901d4e6d47d39905cc6a4d394b9297d2605ac17efbf10da969fd2" } })
end

function TestGameAlgoSha256:test_concurrent_binary_and_text_digests_survive_duplicate_timers()
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
    local scheduler = frameScheduler()
    local binary, completeBinary = recorder()
    local text, completeText = recorder()
    local task = Sha256.hashAsync(table.concat(bytes):rep(16), scheduler, completeBinary)
    Sha256.hashAsync(("b"):rep(1537), scheduler, completeText)
    lu.assertEquals({ #binary, #text }, { 0, 0 })
    local frames = 0
    while #scheduler.pending > 0 do
        local previous = scheduler.pending[1]
        scheduler:update()
        previous.run()
        frames = frames + 1
        lu.assertTrue(frames < 32)
        if frames == 1 then lu.assertEquals({ #binary, #text }, { 0, 0 }) end
        if #binary > 0 then lu.assertEquals(#text, 1) end
    end
    task:Cancel()
    lu.assertEquals(binary, { { digest = "sha256:c8f5d0341d54d951a71b136e6e2afcb14d11ed8489a7ae126a8fee0df6ecf193" } })
    lu.assertEquals(text, { { digest = "sha256:326e9b460bdbb79c4179a0593403c7d57d42b999c218c5e87569b08710f16e57" } })
end

function TestGameAlgoSha256:test_cancel_releases_completion_even_if_due_timer_still_runs()
    for _, afterFirstFrame in ipairs({ false, true }) do
        local scheduler = frameScheduler()
        if afterFirstFrame then scheduler.Cancel = nil end
        local replies, done = recorder()
        local weak = setmetatable({ done }, { __mode = "v" })
        local task = Sha256.hashAsync(("x"):rep(2048), scheduler, done)
        done = nil
        if afterFirstFrame then scheduler:update() end
        local stale = scheduler.pending[1]
        task:Cancel()
        task:Cancel()
        if scheduler.Cancel then lu.assertTrue(stale.cancelled) end
        stale.run()
        scheduler:update()
        collectgarbage("collect")
        lu.assertNil(weak[1])
        lu.assertEquals({ #replies, #scheduler.pending }, { 0, 0 })
    end
end

function TestGameAlgoSha256:test_unavailable_rejected_and_inline_schedulers_fail_once()
    local stale
    local schedulers = {
        false, {},
        { Schedule = function(_, _, run) stale = run; return nil end },
        { Schedule = function(_, _, run) stale = run; error("stopped") end },
        { Schedule = function(_, _, run) stale = run; run(); return {} end },
    }
    for _, scheduler in ipairs(schedulers) do
        stale = nil
        local replies, done = recorder()
        lu.assertNil(Sha256.hashAsync(("x"):rep(8192), scheduler or nil, done))
        if stale then stale() end
        lu.assertEquals(#replies, 1)
        lu.assertIsString(replies[1].err)
        lu.assertNil(replies[1].digest)
    end
end

function TestGameAlgoSha256:test_refusal_or_cancellation_while_registering_next_frame()
    for _, cancel in ipairs({ false, true }) do
        local scheduler = frameScheduler()
        local replies, done = recorder()
        local task = Sha256.hashAsync(("x"):rep(2048), scheduler, done)
        local schedule = scheduler.Schedule
        local stale
        function scheduler:Schedule(delay, run)
            stale = run
            if cancel then
                task:Cancel()
                return schedule(self, delay, run)
            end
            return nil
        end
        scheduler:update()
        stale()
        if cancel then
            lu.assertTrue(scheduler.pending[1].cancelled)
            lu.assertEquals(#replies, 0)
        else
            lu.assertEquals(#replies, 1)
            lu.assertIsString(replies[1].err)
            lu.assertNil(replies[1].digest)
        end
        scheduler:update()
        task:Cancel()
        lu.assertEquals(#scheduler.pending, 0)
    end
end

local function execute(source, input)
    local result, err = Runtime.Execute(source, input)
    lu.assertNil(err)
    return result.payload
end

TestGameAlgoScriptBudget = {}

function TestGameAlgoScriptBudget:test_protected_calls_preserve_values_and_ordinary_errors()
    local calls = execute([[
        return function()
            local calls = 0
            local function read(a, b)
                calls = calls + 1
                return nil, a, b, nil
            end
            local values = table.pack(pcall(read, 17, 23))
            assert(values.n == 5 and values[1] and values[2] == nil and values[3] == 17
                and values[4] == 23 and values[5] == nil)
            assert(select("#", pcall(function() end)) == 1)
            local reason = {}
            local ok, err = pcall(error, reason, 0)
            assert(not ok and err == reason)
            return { payload = calls }
        end
    ]])
    lu.assertEquals(calls, 1)
end

function TestGameAlgoScriptBudget:test_budget_ends_optional_work_before_result_delivery()
    local delivered = false
    local input = {
        read = function()
            local total = 0
            for i = 1, 10000 do total = total + i end
            return total
        end,
        deliver = function() delivered = true end,
    }
    local source = [[
        return function(input)
            local ok, value = pcall(input.read)
            input.deliver(ok, value)
            return { payload = ok }
        end
    ]]
    local previous, mask, count = debug.gethook()
    local function hostHook() end
    debug.sethook(hostHook, "", 50000)
    local ran, result, err = pcall(Runtime.Execute, source, input, { instructionLimit = 2000 })
    local restored, restoredMask, restoredCount = debug.gethook()
    debug.sethook(previous, mask, count)

    lu.assertTrue(ran)
    lu.assertNil(result)
    lu.assertEquals(err, "execute failed: script instruction limit exceeded")
    lu.assertFalse(delivered)
    lu.assertEquals({ restored, restoredMask, restoredCount }, { hostHook, "", 50000 })
end

function TestGameAlgoScriptBudget:test_hook_restoration_is_outside_the_script_budget()
    local hostDebug, countHook, restorations = debug, nil, 0
    debug = {
        gethook = function() return nil end,
        sethook = function(hook)
            if hook then
                countHook = hook
            else
                countHook() -- Model a count tick as the host enters hook cleanup.
                restorations = restorations + 1
            end
        end,
    }
    local ok, result, err = pcall(Runtime.Execute, "return function() return { payload = 1 } end", nil,
        { instructionLimit = 100 })
    debug = hostDebug
    lu.assertTrue(ok)
    lu.assertNil(err)
    lu.assertEquals(result.payload, 1)
    lu.assertEquals(restorations, 2)
end

TestGameAlgoScriptRandom = {}

function TestGameAlgoScriptRandom:test_chunk_and_execute_leave_host_sequence_intact()
    math.randomseed(81725, 9)
    local expected = { math.random(), math.random(997), math.random(0) }
    math.randomseed(81725, 9)
    local first = math.random()
    execute([[
        math.random()
        math.randomseed(1, 2)
        return function()
            math.randomseed()
            return { payload = math.random(1000) }
        end
    ]])
    lu.assertEquals({ first, math.random(997), math.random(0) }, expected)
end

function TestGameAlgoScriptRandom:test_nested_execution_preserves_both_seeded_streams()
    local source = [[
        local x, y = math.randomseed(37, 91)
        local first = math.random()
        return function(interleave)
            interleave()
            local second = math.random(0)
            math.randomseed(x, y)
            assert(math.random() == first and math.random(0) == second)
            return { payload = { first, second } }
        end
    ]]
    local expected = execute(source, function() end)
    local actual = execute(source, function()
        execute("math.randomseed(88); return function() return { payload = math.random(0) } end")
    end)
    lu.assertEquals(actual, expected)
end

function TestGameAlgoScriptRandom:test_private_default_and_both_seed_arguments()
    local source = [[
        return function(seed)
            local x, y
            if seed then x, y = math.randomseed(seed[1], seed[2]) else x, y = math.randomseed() end
            local first, second = math.random(), math.random(0)
            math.randomseed(x, y)
            assert(math.random() == first and math.random(0) == second)
            return { payload = { x, y, first, second } }
        end
    ]]
    local default = execute(source)
    lu.assertNotEquals(default, execute(source))
    lu.assertEquals(execute(source, { default[1], default[2] }), default)
    local first = execute(source, { 77 })
    lu.assertEquals({ first[1], first[2] }, { 77, 0 })
    lu.assertEquals(execute(source, { 77, 0 }), first)
    local other = execute(source, { 77, 1 })
    lu.assertNotEquals({ first[3], first[4] }, { other[3], other[4] })
end

function TestGameAlgoScriptRandom:test_integer_ranges_and_argument_validation()
    lu.assertTrue(execute([[
        return function()
            math.randomseed(math.mininteger, math.maxinteger)
            for i = 1, 20 do
                local fraction = math.random()
                assert(fraction >= 0 and fraction < 1)
                for _, range in ipairs({ { -42, 7 }, { 18, 18 }, { math.mininteger, math.mininteger + 9 },
                    { math.maxinteger - 9, math.maxinteger }, { 0, math.maxinteger - 1 },
                    { math.mininteger, 35 }, { -33, math.maxinteger } }) do
                    local value = math.random(range[1], range[2])
                    assert(math.type(value) == "integer" and value >= range[1] and value <= range[2])
                end
                local die = math.random(6)
                assert(die >= 1 and die <= 6 and math.type(math.random(0)) == "integer")
            end
            assert(math.random(0, 0) == 0)
            assert(not pcall(math.random, -1) and not pcall(math.random, 5, 4))
            assert(not pcall(math.random, 1.5) and not pcall(math.random, 1, 2, 3))
            assert(not pcall(math.random, nil) and not pcall(math.randomseed, "x"))
            return { payload = true }
        end
    ]]))
end

lu.run({ TestGameAlgoSha256, TestGameAlgoScriptBudget, TestGameAlgoScriptRandom })
