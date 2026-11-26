-- Exercise the public SDK with deterministic request ordering and a process-local save.
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local lu = require("tests.support.TestCase")
local json = require("cjson")
local sha = require("Sha256")
local runtime = require("LuaScriptRuntime")
local canEnforce = runtime.CanEnforceLimit
local module = "GameAlgo"
local game, requests, clock

local function init(options)
    options = options or {}
    options.gameKey = options.gameKey or "game-A"
    options.sessionId = options.sessionId or "session-A"
    options.userId = options.userId or "user-A"
    options.baseUrl = "https://api.example/game"
    options.logger = function() end
    options.autoFetch = false
    options.nowMs = function() return clock end
    options.transport = { Request = function(request, complete)
        requests[#requests + 1] = { url = request.url, headers = request.headers,
            body = request.body ~= "" and json.decode(request.body) or nil, complete = complete }
    end }
    game.Init(options)
end

local function respond(request, value, raw)
    request.complete(nil, { status = 200, body = raw and value or json.encode(value) })
end

local function config(fields, callback)
    fields = fields or {}
    fields.contextId = fields.contextId or "ctx"
    game.FetchConfig(callback)
    local request = requests[#requests]
    lu.assertStrContains(request.url, "/v1/config")
    respond(request, fields)
    return request.body
end

local function result()
    local r = { count = 0 }
    r.callback = function(err, value) r.count, r.err, r.value = r.count + 1, err, value end
    return r
end

local function scriptRef(content, url, version)
    return { versionId = version or "v1", name = "policy.lua", hash = sha.hash(content), url = url }
end

TestGameAlgoConfig = {}
function TestGameAlgoConfig:setUp()
    File, Node, sdk, lobby = nil, nil, nil, {}
    requests, clock = {}, 1782907260000
    package.loaded[module] = nil
    game = require(module)
    init()
end

function TestGameAlgoConfig:tearDown()
    runtime.CanEnforceLimit = canEnforce
end

function TestGameAlgoConfig:test_script_callbacks_cache_and_headers_belong_to_the_request()
    local old, current = result(), result()
    game.FetchScript(scriptRef("old", "/v1/scripts/v1"), old.callback)
    local first = requests[#requests]
    lu.assertEquals(first.headers["X-GameAlgo-Key"], "game-A")
    init({ gameKey = "game-B" })
    local ref = scriptRef("new", "https://cdn.example/script")
    game.FetchScript(ref, current.callback)
    local second = requests[#requests]
    lu.assertNil(second.headers["X-GameAlgo-Key"])
    respond(first, "old", true)
    lu.assertEquals(old.count, 1)
    lu.assertNotNil(old.err)
    lu.assertNil(next(game.Snapshot().scripts))
    respond(second, "new", true)
    lu.assertEquals(current.value.content, "new")
    current.value.content = "changed"
    game.Snapshot().scripts["version:v1"].hash = "changed"
    local hit = result()
    game.FetchScript(ref, hit.callback)
    lu.assertEquals(hit.value.content, "new")
    lu.assertEquals(#requests, 2)
    local mismatch = result()
    game.FetchScript(scriptRef("different"), mismatch.callback)
    lu.assertNotNil(mismatch.err)
    lu.assertNil(mismatch.value)
    init({ gameKey = "game-A" })
    local staleDisk = result()
    game.FetchScript(scriptRef("old"), staleDisk.callback)
    lu.assertNotNil(staleDisk.err)
end

function TestGameAlgoConfig:test_reinit_cancels_partial_verification_and_releases_waiters()
    local source = ("-- chunk"):rep(200)
    local ref = scriptRef(source, "/policy", "pending")
    local a, b = result(), result()
    game.FetchScript(ref, a.callback)
    respond(requests[1], source, true)
    game.FetchScript(ref, b.callback)
    game.Update()
    lu.assertEquals(a.count, 0)
    init({ gameKey = "game-B" })
    lu.assertEquals(a.count, 1)
    lu.assertEquals(b.err, "stale script response")
    for _ = 1, 10 do game.Update() end
    lu.assertNil(next(game.Snapshot().scripts))
    lu.assertNil(a.value)
end

function TestGameAlgoConfig:test_script_key_is_bound_to_https_origin_including_port()
    for i, url in ipairs({ "https://API.EXAMPLE:443/file", "https://api.example:444/file",
        "http://api.example/file", "//assets.example/file", "https://api.example.other/file" }) do
        game.FetchScript(scriptRef("return {}", url, tostring(i)))
        local request = requests[#requests]
        lu.assertEquals(request.headers["X-GameAlgo-Key"], i == 1 and "game-A" or nil)
        lu.assertEquals(request.url, i == 4 and "https:" .. url or url)
        respond(request, "return {}", true)
    end
end

function TestGameAlgoConfig:test_optional_preload_checks_budget_and_shares_download_and_hash()
    local content = string.rep("-- a line\n", 200)
    local ref = scriptRef(content, "/script")
    local fields = { experiments = { { key = "a", script = ref }, { key = "b", script = ref } } }
    runtime.CanEnforceLimit = function() return false end
    config(fields)
    lu.assertEquals(#requests, 1)
    runtime.CanEnforceLimit = function() return true end
    config(fields)
    lu.assertEquals(#requests, 3)
    local one, two = result(), result()
    game.FetchScript(ref, one.callback)
    respond(requests[3], content, true)
    game.FetchScript(ref, two.callback)
    lu.assertEquals(#requests, 3)
    lu.assertEquals(one.count, 0)
    for _ = 1, 100 do game.Update(); if one.count > 0 then break end end
    lu.assertEquals(one.count, 1)
    lu.assertEquals(two.count, 1)
    lu.assertEquals(two.value.content, content)
    lu.assertTrue(game.Executor("b").IsReady())
end

function TestGameAlgoConfig:test_config_file_preload_joins_callback_and_supersedes_old_revision()
    local manual, joined, stale, fresh = result(), result(), result(), result()
    local fields = { configVersion = "one", configFiles = { { name = "levels.json" } } }
    config(fields, function() game.FetchConfigFile("levels.json", manual.callback) end)
    game.FetchConfigFile("levels.json", joined.callback)
    lu.assertEquals(#requests, 2)
    respond(requests[2], { rows = { { difficulty = 7 }, false }, object = { ["0"] = "literal" } })
    lu.assertEquals(manual.count, 1)
    lu.assertNil(manual.err)
    lu.assertEquals(joined.value, manual.value)
    lu.assertEquals(game.ConfigValue("rows.0.difficulty", -1, "levels.json"), 7)
    lu.assertEquals(game.ConfigValue("rows.1", true, "levels.json"), false)
    lu.assertEquals(game.ConfigValue("object.0", nil, "levels.json"), "literal")
    game.FetchConfigFile("levels.json", stale.callback)
    local old = requests[#requests]
    fields.configVersion = "two"
    config(fields, function() game.FetchConfigFile("levels.json", fresh.callback) end)
    local new = requests[#requests]
    respond(new, { version = 2 }); respond(old, { version = 1 })
    lu.assertNotNil(stale.err)
    lu.assertNil(fresh.err)
    lu.assertEquals(game.ConfigValue("version", nil, "levels.json"), 2)
end

function TestGameAlgoConfig:test_config_only_executor_keeps_values_and_returns_independent_assignment()
    config({ experiments = { { key = "flag", variant = "B", config = false },
        { key = "tune", variant = "A", config = { levels = { { adjustment = "keep" } }, ["0"] = "zero" } } } })
    local flag = game.Executor("flag").Execute()
    lu.assertEquals(flag.payload, false)
    lu.assertEquals(flag.assignment.key, "flag")
    local e = game.Executor("tune")
    local first = e.Execute()
    first.payload.levels[1].adjustment = "other"
    first.assignment.config.levels[1] = false
    lu.assertEquals(e.Value("levels.0.adjustment"), "keep")
    lu.assertEquals(e.Value("0"), "zero")
    lu.assertEquals(e.Execute().assignment.variant, "A")
end

function TestGameAlgoConfig:test_retained_dda_cannot_overwrite_progress()
    local old = game.DDA("pace")
    old.RecordBehavior("win")
    init()
    local active = game.DDA("pace")
    active.RecordBehavior("win")
    old.RecordBehavior("loss"); old.Reset()
    lu.assertTrue(old.Decide().isFallback)
    lu.assertEquals(old.Snapshot().diagnostics.reason, "stale_controller")
    init()
    lu.assertEquals(game.DDA("pace").Snapshot().behavior.lifetime, { win = 2 })
end

function TestGameAlgoConfig:test_reentrant_init_detaches_old_session_waiters()
    local queued, fresh = result(), result()
    game.FetchConfig(function()
        init({ gameKey = "new", sessionId = "B" })
        game.FetchConfig(fresh.callback)
    end)
    local old = requests[#requests]
    game.NewSession("B", queued.callback)
    respond(old, { contextId = "old" })
    local new = requests[#requests]
    lu.assertEquals(new.headers["X-GameAlgo-Key"], "new")
    respond(new, { contextId = "new" })
    lu.assertNil(queued.value)
    lu.assertEquals(fresh.count, 1)
    lu.assertEquals(fresh.value.contextId, "new")
end

function TestGameAlgoConfig:test_late_config_completion_leaves_new_scheduler_timeout_armed()
    local function scheduler()
        local s = { tasks = {}, nextId = 0 }
        function s:Schedule(_, fn) self.nextId = self.nextId + 1; self.tasks[self.nextId] = fn; return self.nextId end
        function s:Cancel(id) self.tasks[id] = nil end
        return s
    end
    init({ _scheduler = scheduler() })
    game.FetchConfig()
    local old = requests[#requests]
    local nextScheduler = scheduler()
    init({ _scheduler = nextScheduler })
    game.FetchConfig()
    respond(old, { contextId = "old" })
    lu.assertIsFunction(nextScheduler.tasks[1])
    nextScheduler.tasks[1]()
    lu.assertIsFunction(nextScheduler.tasks[2])
    nextScheduler.tasks[2]()
    lu.assertEquals(#requests, 3)
end

function TestGameAlgoConfig:test_malformed_optional_config_keeps_fetch_slot_available()
    local first, nextCall = result(), result()
    config({ eventQuota = true, experiments = { true }, configFiles = true }, first.callback)
    lu.assertEquals(first.value.contextId, "ctx")
    config({ contextId = "retry", eventQuota = { mode = "enforce", ordinaryEventLimit = {} } }, nextCall.callback)
    lu.assertEquals(nextCall.count, 1)
    lu.assertEquals(nextCall.value.contextId, "retry")
end

function TestGameAlgoConfig:test_per_user_creation_dates_offsets_and_milestone_elapsed()
    init({ userCreatedAt = "2026-07-01T12:00:00Z" })
    local first = config()
    local localDate = os.date("%Y-%m-%dT%H:%M:%S", 1782907200)
    lu.assertEquals(first.userCreatedLocalAt:sub(1, 19), localDate)
    init({ userId = "user-B" })
    lu.assertNotEquals(config().userCreatedAt, first.userCreatedAt)
    init({ userId = "user-B", userCreatedAt = "2026-07-01T07:30:00.250-04:30" })
    local second = config()
    lu.assertEquals(second.userCreatedLocalAt:sub(1, 19), localDate)
    lu.assertTrue(game.TrackMilestone("start", "first"))
    game.Flush()
    local batch = requests[#requests]
    lu.assertEquals(batch.body.events[1].payload.elapsedSinceRegistrationMs, 59750)
    respond(batch, { ok = true, accepted = 1 })
    init()
    lu.assertEquals(config().userCreatedAt, first.userCreatedAt)
end

function TestGameAlgoConfig:test_standard_experiments_only_consume_ordinary_quota()
    config({ eventQuota = { mode = "enforce", ordinaryEventLimit = 102 } })
    for i = 1, 100 do lu.assertTrue(game.TrackEvent("business" .. i)) end
    lu.assertTrue(game.Track("experiment_exposure"))
    lu.assertTrue(game.Track("experiment_execution"))
    local accepted, reason = game.Track("experiment_exposure")
    lu.assertFalse(accepted)
    lu.assertStrContains(reason, "context event quota")
end

function TestGameAlgoConfig:test_full_direct_receipt_counts_native_handoffs()
    local attempts = 0
    sdk = { LogEvent = function() attempts = attempts + 1; return true end }
    config({ tapdbStandardReportingEnabled = true })
    lu.assertTrue(game.TrackLevelStart())
    local receipt = result()
    game.Flush(receipt.callback)
    respond(requests[#requests], { ok = true, accepted = 1 })
    lu.assertEquals(attempts, 1)
    lu.assertEquals(receipt.value.tapdbAttempted, attempts)
end

lu.run({ TestGameAlgoConfig })
