package.path = "lua/?.lua;lua/tests/support/?.lua;" .. package.path

local json = require("cjson")
package.preload.cjson = function() return json end
package.loaded.cjson = json

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "assertion failed") .. ": expected=" .. tostring(expected) .. ", actual=" .. tostring(actual), 2)
    end
end

local function createEnvironment()
    local files = {}
    local writeFilter = nil
    local writeCounts = {}
    local totalWrites = 0
    local handlers = {}
    local nowMs = 1000
    local configs = {}
    local batches = {}

    local function resetHooks()
        handlers = {}
    end

    local function installGlobals()
        FILE_READ = 0
        FILE_WRITE = 1
        File = function(path, mode)
            local obj = { _open = true, _path = path, _mode = mode, _written = nil }
            function obj:IsOpen()
                if self._mode == FILE_READ then return files[self._path] ~= nil end
                return self._open
            end
            function obj:GetSize()
                local data = files[self._path]
                return data and (#data + 1) or 0
            end
            function obj:ReadString()
                return files[self._path] or ""
            end
            function obj:WriteString(value)
                totalWrites = totalWrites + 1
                writeCounts[self._path] = (writeCounts[self._path] or 0) + 1
                if writeFilter then
                    local verdict = writeFilter(self._path, value)
                    if verdict == false then
                        return false
                    elseif type(verdict) == "string" then
                        -- Simulate partial/corrupt write committed to disk.
                        self._written = verdict
                        return true
                    end
                end
                self._written = value
                return true
            end
            function obj:Flush() return true end
            function obj:Close()
                if self._mode == FILE_WRITE and self._written ~= nil then
                    files[self._path] = self._written
                end
                self._open = false
                return true
            end
            return obj
        end
        fileSystem = {
            GetUserDocumentsDir = function() return "/sandbox/" end,
            DirExists = function() return true end,
            CreateDir = function() return true end,
            Delete = function(path) files[path] = nil; return true end,
        }
        Node = function()
            return {
                CreateScriptObject = function()
                    return {
                        SubscribeToEvent = function(_, eventName, callback)
                            handlers[eventName] = callback
                        end,
                    }
                end,
            }
        end
    end

    installGlobals()

    local env = {
        files = files,
        configs = configs,
        batches = batches,
    }

    function env.setNow(ms) nowMs = ms end
    function env.getNow() return nowMs end
    function env.setWriteFilter(fn) writeFilter = fn end
    function env.getTotalWrites() return totalWrites end
    function env.resetWriteCounts() totalWrites = 0; writeCounts = {} end
    function env.handlers() return handlers end

    function env.replyConfig(request, contextId)
        request.callback(nil, {
            status = 200,
            body = json.encode({
                contextId = contextId,
                configVersion = "cfg_" .. tostring(contextId),
                experiments = {},
                configFiles = {},
            }),
        })
    end

    function env.ack(request, count)
        request.callback(nil, {
            status = 200,
            body = json.encode({
                ok = true,
                accepted = count or #request.body.events,
            }),
        })
    end

    function env.stepSeconds(seconds, stepSec)
        local dt = stepSec or 1
        local steps = math.floor((seconds / dt) + 0.5)
        for _ = 1, steps do
            nowMs = nowMs + math.floor(dt * 1000 + 0.5)
            handlers.Update(nil, nil, { GetFloat = function() return dt end })
        end
    end

    function env.makeOptions(overrides)
        local opts = {
            gameKey = "ga_live_issue70",
            userId = "user-a",
            sessionId = "session-a",
            experimentIntegrationVersion = 1,
            autoFetch = false,
            preloadConfigFiles = false,
            logger = function() end,
            nowMs = function() return nowMs end,
            transport = {
                Request = function(request, callback)
                    local recorded = {
                        url = request.url,
                        body = json.decode(request.body),
                        headers = request.headers,
                        callback = callback,
                    }
                    if request.url:match("/v1/config$") then
                        table.insert(configs, recorded)
                    elseif request.url:match("/v1/events/batch$") then
                        table.insert(batches, recorded)
                    end
                    return recorded
                end,
                Cancel = function(request) request.cancelled = true end,
            },
        }
        for k, v in pairs(overrides or {}) do opts[k] = v end
        return opts
    end

    function env.coldStart(overrides)
        resetHooks()
        for _, name in ipairs({ "GameAlgo", "MakerAutoStorage", "HttpTransport", "LuaScriptRuntime", "Sha256", "DDA" }) do
            package.loaded[name] = nil
            package.loaded["sdk." .. name] = nil
        end
        local sdk = require("GameAlgo")
        sdk.Init(env.makeOptions(overrides))
        return sdk
    end

    function env.connect(sdk, contextId)
        local before = #configs
        sdk.FetchConfig()
        equal(#configs, before + 1, "expected config request")
        env.replyConfig(configs[#configs], contextId)
        equal(sdk.Snapshot().contextId, contextId)
    end

    return env
end

-- ============================================================
-- 1a. Queue full (maxQueueSize=1, maxBatchSize=1) during cold-start recovery
-- ============================================================
do
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_1a",
        sessionId = "s-1",
        maxQueueSize = 1,
        maxBatchSize = 1,
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(sdk, "ctx-1")
    env.stepSeconds(5) -- writes 5s checkpoint
    assert(sdk.TrackEvent("busy", { n = 1 }))
    env.setNow(env.getNow() + 6000)
    sdk.Update() -- persists busy event chunk to disk

    -- Cold start #1: queue is full with 1 business event; recovery must NOT delete checkpoint.
    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_1a",
        sessionId = "s-2",
        maxQueueSize = 1,
        maxBatchSize = 1,
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(sdk2.Snapshot().queuedEvents, 1, "1a: busy event restored")
    local before = #env.batches
    sdk2.Flush(nil)
    equal(#env.batches, before + 1, "1a: busy event flushed")
    equal(env.batches[#env.batches].body.events[1].eventType, "_busy")
    env.ack(env.batches[#env.batches])

    -- After ACK frees the queue slot, pending recovery checkpoint is automatically queued and flushed!
    equal(sdk2.Snapshot().queuedEvents, 1, "1a: pending checkpoint recovered once queue freed")
    if #env.batches == before + 1 then
        sdk2.Flush(nil)
    end
    equal(#env.batches, before + 2, "1a: recovered session_end flushed")
    local rec = env.batches[#env.batches].body.events[1]
    equal(rec.eventType, "session_end")
    equal(rec.sessionId, "s-1")
    equal(rec.payload.reason, "crash_recovery")
    equal(rec.payload.sessionDurationMs, 5000)
    env.ack(env.batches[#env.batches])

    -- Next cold start has 0 leftover events
    local sdk3 = env.coldStart({
        gameKey = "ga_live_i70_1a",
        sessionId = "s-3",
        maxQueueSize = 1,
        maxBatchSize = 1,
        flushIntervalMs = 0,
    })
    equal(sdk3.Snapshot().queuedEvents, 0, "1a: clean after ACK")
end

-- ============================================================
-- 1b. Chunk partial write failure during cold-start recovery keeps checkpoint & reuses eventId
-- ============================================================
do
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_1b",
        sessionId = "s-20",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(sdk, "ctx-20")
    env.stepSeconds(20) -- 20s checkpoint persisted

    -- Fail chunk writes twice with partial content
    local chunkFailures = 0
    env.setWriteFilter(function(path, value)
        if path:find("gaq_", 1, true) and chunkFailures < 2 then
            chunkFailures = chunkFailures + 1
            return value:sub(1, 10) -- truncated partial write fails readback verification
        end
        return true
    end)

    -- Cold start #1: recovery enqueued in memory, chunk persist fails -> old checkpoint stays on disk!
    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_1b",
        sessionId = "s-21",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(sdk2.Snapshot().queuedEvents, 1, "1b: in-memory recovered event present")
    -- Capture the in-memory eventId before simulating another crash
    sdk2.Flush(nil) -- will try to persist chunk (2nd failure) and send
    local firstAttemptEventId = env.batches[#env.batches].body.events[1].eventId

    -- Restore file writes and cold start #2 without ACKing batch #1
    env.setWriteFilter(nil)
    local sdk3 = env.coldStart({
        gameKey = "ga_live_i70_1b",
        sessionId = "s-22",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(sdk3.Snapshot().queuedEvents, 1, "1b: checkpoint survived failed chunk write and recovered")
    local beforeBatches = #env.batches
    sdk3.Flush(nil)
    equal(#env.batches, beforeBatches + 1)
    local recovered = env.batches[#env.batches].body.events[1]
    equal(recovered.eventType, "session_end")
    equal(recovered.sessionId, "s-20")
    equal(recovered.payload.sessionDurationMs, 20000)
    equal(recovered.eventId, firstAttemptEventId, "1b: retry reuses exact same deterministic eventId")
    env.ack(env.batches[#env.batches])
end

-- ============================================================
-- 1c. Immediate cold start after 30s heartbeat or TrackSessionEnd before Flush
-- ============================================================
do
    -- Heartbeat at 30s followed immediately by cold start
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_1c_hb",
        sessionId = "s-hb",
    })
    env.connect(sdk, "ctx-hb")
    env.stepSeconds(30) -- 30s heartbeat emitted & persisted

    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_1c_hb",
        sessionId = "s-hb-2",
    })
    equal(sdk2.Snapshot().queuedEvents, 1, "1c: 30s heartbeat survives immediate cold start")
    local before = #env.batches
    sdk2.Flush(nil)
    equal(#env.batches, before + 1)
    local ev = env.batches[#env.batches].body.events[1]
    equal(ev.eventType, "session_end")
    equal(ev.payload.reason, "heartbeat")
    equal(ev.payload.sessionDurationMs, 30000)
    env.ack(env.batches[#env.batches])

    -- TrackSessionEnd at 10s followed immediately by cold start BEFORE Flush
    local env2 = createEnvironment()
    local s1 = env2.coldStart({
        gameKey = "ga_live_i70_1c_end",
        sessionId = "s-end-1",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env2.connect(s1, "ctx-end-1")
    env2.stepSeconds(10) -- 5s checkpoint on disk
    assert(s1.TrackSessionEnd({ reason = "quit" }))
    -- Cold start immediately before Flush!
    local s2 = env2.coldStart({
        gameKey = "ga_live_i70_1c_end",
        sessionId = "s-end-2",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(s2.Snapshot().queuedEvents, 1, "1c: unpersisted TrackSessionEnd must not erase 5s checkpoint")
    s2.Flush(nil)
    local recovered = env2.batches[#env2.batches].body.events[1]
    equal(recovered.eventType, "session_end")
    equal(recovered.sessionId, "s-end-1")
    assert(recovered.payload.sessionDurationMs >= 5000, "1c: recovered at least 5s")
    env2.ack(env2.batches[#env2.batches])
end

-- ============================================================
-- 2. Queued / ACKed 30s heartbeat must NOT block 90s / 100s checkpoint
-- ============================================================
do
    -- 2a: 30s heartbeat queued (flushIntervalMs=0), foreground reaches 100s -> checkpoint 90s -> cold start delivers >= 90s
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_2a",
        sessionId = "s-long-a",
        flushIntervalMs = 0,
    })
    env.connect(sdk, "ctx-long-a")
    env.stepSeconds(100) -- 30s heartbeat queued; checkpoints written at 45s, 60s, 75s, 90s

    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_2a",
        sessionId = "s-long-a-next",
        flushIntervalMs = 0,
    })
    sdk2.Flush(nil)
    local maxDuration = 0
    for _, b in ipairs(env.batches) do
        for _, e in ipairs(b.body.events) do
            if e.eventType == "session_end" and e.sessionId == "s-long-a" then
                maxDuration = math.max(maxDuration, e.payload.sessionDurationMs or 0)
            end
        end
        env.ack(b)
    end
    assert(maxDuration >= 90000, "2a: expected >= 90000ms recovered, got " .. tostring(maxDuration))

    -- 2b: Config refresh at 100s while 30s heartbeat is queued, then ACK only 30s heartbeat -> cold start still recovers 100s
    local env2 = createEnvironment()
    local s1 = env2.coldStart({
        gameKey = "ga_live_i70_2b",
        sessionId = "s-long-b",
        flushIntervalMs = 0,
    })
    env2.connect(s1, "ctx-long-b")
    env2.stepSeconds(100)
    -- Refresh same config at 100s -> checkpoint must be 100s, ended=false (NOT ended=true!)
    env2.connect(s1, "ctx-long-b")
    -- Flush and ACK only the 30s heartbeat
    s1.Flush(nil)
    equal(#env2.batches, 1)
    equal(env2.batches[1].body.events[1].payload.sessionDurationMs, 30000)
    env2.ack(env2.batches[1])

    -- Cold start must recover 100s!
    local s2 = env2.coldStart({
        gameKey = "ga_live_i70_2b",
        sessionId = "s-long-b-next",
        flushIntervalMs = 0,
    })
    equal(s2.Snapshot().queuedEvents, 1, "2b: 100s checkpoint recovered after 30s heartbeat ACK")
    s2.Flush(nil)
    local rec = env2.batches[#env2.batches].body.events[1]
    equal(rec.payload.reason, "crash_recovery")
    equal(rec.payload.sessionDurationMs, 100000)
    env2.ack(env2.batches[#env2.batches])
end

-- ============================================================
-- 3. Generic Track("session_end", ...) ACKed suppresses crash_recovery on cold start
-- ============================================================
do
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_3",
        sessionId = "s-track-end",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(sdk, "ctx-track-end")
    env.stepSeconds(10) -- 5s checkpoint on disk
    assert(sdk.Track("session_end", { reason = "finished", sessionDurationMs = 10000 }))
    sdk.Flush(nil)
    equal(#env.batches, 1)
    equal(env.batches[1].body.events[1].payload.reason, "finished")
    env.ack(env.batches[1])
    equal(sdk.Snapshot().queuedEvents, 0)

    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_3",
        sessionId = "s-track-end-next",
        flushIntervalMs = 0,
    })
    equal(sdk2.Snapshot().queuedEvents, 0, "3: ACKed Track('session_end') must not trigger crash_recovery")
end

-- ============================================================
-- 4. In-process Init switching sessionId closes old session with live 10s duration (not crash_recovery 5s)
-- ============================================================
do
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_4",
        sessionId = "session-a",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(sdk, "ctx-a")
    env.stepSeconds(10) -- 5s checkpoint on disk, 10s live foreground time

    -- In-process re-Init on the SAME module instance with session-b
    sdk.Init(env.makeOptions({
        gameKey = "ga_live_i70_4",
        sessionId = "session-b",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    }))
    sdk.Flush(nil)
    equal(#env.batches, 1, "4: reinit session_end flushed")
    local ev = env.batches[1].body.events[1]
    equal(ev.eventType, "session_end")
    equal(ev.sessionId, "session-a")
    equal(ev.payload.reason, "reinit")
    equal(ev.payload.sessionDurationMs, 10000)
    env.ack(env.batches[1])

    -- Control: dropping module instance without Init still recovers crash_recovery
    local envCrash = createEnvironment()
    local c1 = envCrash.coldStart({
        gameKey = "ga_live_i70_4_ctrl",
        sessionId = "session-crash",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    envCrash.connect(c1, "ctx-crash")
    envCrash.stepSeconds(10)
    local c2 = envCrash.coldStart({
        gameKey = "ga_live_i70_4_ctrl",
        sessionId = "session-next",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    c2.Flush(nil)
    equal(envCrash.batches[1].body.events[1].payload.reason, "crash_recovery")
    equal(envCrash.batches[1].body.events[1].payload.sessionDurationMs, 5000)
end

-- ============================================================
-- 5. Reusing same sessionId recovers unended checkpoint and does not lose longer duration
-- ============================================================
do
    -- 5a: 20s checkpoint for session-a (ctx-1), cold start with same session-a + new ctx-2, 1s TrackSessionEnd + ACK -> next cold start 0
    local env = createEnvironment()
    local s1 = env.coldStart({
        gameKey = "ga_live_i70_5a",
        sessionId = "session-reuse",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(s1, "ctx-1")
    env.stepSeconds(20) -- 20s checkpoint on disk

    local s2 = env.coldStart({
        gameKey = "ga_live_i70_5a",
        sessionId = "session-reuse",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(s2, "ctx-2")
    env.stepSeconds(1)
    assert(s2.TrackSessionEnd({ reason = "short_exit" }))
    s2.Flush(nil)
    local progressed = true
    while progressed do
        progressed = false
        for _, b in ipairs(env.batches) do
            if not b.acked then
                b.acked = true
                env.ack(b)
                progressed = true
            end
        end
    end
    equal(s2.Snapshot().queuedEvents, 0)

    local s3 = env.coldStart({
        gameKey = "ga_live_i70_5a",
        sessionId = "session-other",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(s3.Snapshot().queuedEvents, 0, "5a: no stale 20s checkpoint left after reused session ended")

    -- 5b: 35s checkpoint for session-reuse, cold start with same session-reuse and run 5s -> 35s duration preserved
    local env2 = createEnvironment()
    local r1 = env2.coldStart({
        gameKey = "ga_live_i70_5b",
        sessionId = "session-reuse-b",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env2.connect(r1, "ctx-b1")
    env2.stepSeconds(35) -- 35s checkpoint on disk

    local r2 = env2.coldStart({
        gameKey = "ga_live_i70_5b",
        sessionId = "session-reuse-b",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env2.connect(r2, "ctx-b2")
    env2.stepSeconds(5)
    r2.Flush(nil)
    local maxRecovered = 0
    for _, b in ipairs(env2.batches) do
        for _, e in ipairs(b.body.events) do
            if e.eventType == "session_end" then
                maxRecovered = math.max(maxRecovered, e.payload.sessionDurationMs or 0)
            end
        end
        env2.ack(b)
    end
    equal(maxRecovered, 35000, "5b: 35s checkpoint must not be overwritten by 5s sample")
end

-- ============================================================
-- 6. Late FetchConfig response must NOT reopen an ACKed app_background snapshot
-- ============================================================
do
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_6",
        sessionId = "s-bg",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(sdk, "ctx-bg")
    env.stepSeconds(10)

    -- Start FetchConfig and hold response
    sdk.FetchConfig()
    local delayedConfig = env.configs[#env.configs]

    -- Background fires, sends 10s app_background and gets ACKed
    env.handlers().AppWillEnterBackground()
    equal(#env.batches, 1)
    equal(env.batches[1].body.events[1].payload.reason, "app_background")
    equal(env.batches[1].body.events[1].payload.sessionDurationMs, 10000)
    env.ack(env.batches[1])
    equal(sdk.Snapshot().queuedEvents, 0)

    -- Late config response arrives with 0 foreground Updates since background
    env.replyConfig(delayedConfig, "ctx-bg")

    -- Cold start must emit 0 duplicate crash_recovery events
    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_6",
        sessionId = "s-bg-next",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(sdk2.Snapshot().queuedEvents, 0, "6: late config response must not reopen ACKed background snapshot")

    -- Returning to foreground and adding 15s (total 25s) writes a fresh recoverable checkpoint
    local env2 = createEnvironment()
    local r1 = env2.coldStart({
        gameKey = "ga_live_i70_6b",
        sessionId = "s-bg-resume",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env2.connect(r1, "ctx-bg-resume")
    env2.stepSeconds(10)
    env2.handlers().AppWillEnterBackground()
    env2.ack(env2.batches[1])
    env2.stepSeconds(15) -- foreground now 25s (> 10s covered)
    local r2 = env2.coldStart({
        gameKey = "ga_live_i70_6b",
        sessionId = "s-bg-resume-2",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(r2.Snapshot().queuedEvents, 1, "6: additional foreground time after resume is recoverable")
    r2.Flush(nil)
    equal(env2.batches[#env2.batches].body.events[1].payload.sessionDurationMs, 25000)
end

-- ============================================================
-- 7. Auto heartbeat must NOT consume last queue slot and block TrackSessionEnd / NewSession
-- ============================================================
do
    -- 7a: TrackSessionEnd succeeds with 9 normal events preserved
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_7a",
        sessionId = "s-cap-a",
        maxQueueSize = 10,
        maxBatchSize = 10,
        flushIntervalMs = 0,
    })
    env.connect(sdk, "ctx-cap-a")
    for i = 1, 9 do
        assert(sdk.TrackEvent("biz", { idx = i }))
    end
    env.stepSeconds(30) -- heartbeat deferred because only 1 exit slot remains
    local ok, err = sdk.TrackSessionEnd({ reason = "explicit_exit" })
    assert(ok, "7a: TrackSessionEnd must succeed, got err=" .. tostring(err))
    equal(sdk.Snapshot().queuedEvents, 10, "7a: 9 business events + 1 explicit TrackSessionEnd")

    -- 7b: NewSession("session-b") succeeds with 9 normal events preserved
    local env2 = createEnvironment()
    local sdk2 = env2.coldStart({
        gameKey = "ga_live_i70_7b",
        sessionId = "s-cap-b",
        maxQueueSize = 10,
        maxBatchSize = 10,
        flushIntervalMs = 0,
    })
    env2.connect(sdk2, "ctx-cap-b")
    for i = 1, 9 do
        assert(sdk2.TrackEvent("biz", { idx = i }))
    end
    env2.stepSeconds(30)
    local nextId, newErr = sdk2.NewSession("session-b")
    equal(nextId, "session-b", "7b: NewSession must switch to session-b, err=" .. tostring(newErr))
    equal(sdk2.Snapshot().sessionId, "session-b")
    -- Verify all 9 business events + 1 new_session are preserved in the flushed batch
    equal(#env2.batches, 1)
    equal(#env2.batches[1].body.events, 10)
    local bizCount, newSessionCount = 0, 0
    for _, e in ipairs(env2.batches[1].body.events) do
        if e.eventType == "_biz" then bizCount = bizCount + 1 end
        if e.eventType == "session_end" and e.payload.reason == "new_session" then newSessionCount = newSessionCount + 1 end
    end
    equal(bizCount, 9, "7b: all 9 business events preserved")
    equal(newSessionCount, 1, "7b: new_session event queued")
end

-- ============================================================
-- 8. Checkpoint write failure uses backoff instead of retrying every 1/60s frame
-- ============================================================
do
    local env = createEnvironment()
    local sdk = env.coldStart({
        gameKey = "ga_live_i70_8",
        sessionId = "s-backoff",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    env.connect(sdk, "ctx-backoff")
    env.stepSeconds(4)
    env.resetWriteCounts()

    -- Fail all writes starting at 5s
    env.setWriteFilter(function() return false end)
    env.stepSeconds(1) -- reaches 5s -> 1 failed checkpoint write attempt
    local writesAfterFirstFail = env.getTotalWrites()
    assert(writesAfterFirstFail >= 1, "8: first checkpoint attempt occurred at 5s")

    -- Advance 60 frames at 1/60s (1.0s total, well within 2s backoff) -> 0 extra writes!
    env.stepSeconds(1, 1 / 60)
    equal(env.getTotalWrites(), writesAfterFirstFail, "8: 60 frames during backoff must trigger 0 extra writes")

    -- Restore file writes and advance past 2s backoff -> checkpoint succeeds with >= 7s!
    env.setWriteFilter(nil)
    env.stepSeconds(2) -- now at 8s foreground (> 2s backoff elapsed)
    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_8",
        sessionId = "s-backoff-next",
        flushIntervalMs = 0,
        autoSessionHeartbeat = false,
    })
    equal(sdk2.Snapshot().queuedEvents, 1, "8: recovered checkpoint after write recovery")
    sdk2.Flush(nil)
    assert(env.batches[#env.batches].body.events[1].payload.sessionDurationMs >= 7000, "8: saved >= 7s foreground duration")
end

-- ============================================================
-- 9. First-time isOldUser write failure must not send conflicting values across restarts
-- ============================================================
do
    local env = createEnvironment()
    -- Fail all disk writes on first run for user-a with isOldUser=true
    env.setWriteFilter(function() return false end)
    local sdk1 = env.coldStart({
        gameKey = "ga_live_i70_9",
        userId = "user-a",
        sessionId = "s-old-1",
        isOldUser = true,
    })
    sdk1.FetchConfig()
    local firstReq = env.configs[#env.configs].body
    equal(firstReq.isOldUser, nil, "9: unpersisted first isOldUser must be omitted on persistent host")
    env.replyConfig(env.configs[#env.configs], "ctx-old-1")

    -- Restore writes; cold start user-a with isOldUser=false -> persists and sends false
    env.setWriteFilter(nil)
    local sdk2 = env.coldStart({
        gameKey = "ga_live_i70_9",
        userId = "user-a",
        sessionId = "s-old-2",
        isOldUser = false,
    })
    sdk2.FetchConfig()
    equal(env.configs[#env.configs].body.isOldUser, false, "9: persisted classification sent after recovery")
    env.replyConfig(env.configs[#env.configs], "ctx-old-2")

    -- Subsequent cold start for user-a passing opposite value true still sends locked false
    local sdk3 = env.coldStart({
        gameKey = "ga_live_i70_9",
        userId = "user-a",
        sessionId = "s-old-3",
        isOldUser = true,
    })
    sdk3.FetchConfig()
    equal(env.configs[#env.configs].body.isOldUser, false, "9: locked classification stays false across restarts")

    -- Different user (user-b) is isolated and persists/sends true
    local sdkB = env.coldStart({
        gameKey = "ga_live_i70_9",
        userId = "user-b",
        sessionId = "s-old-b1",
        isOldUser = true,
    })
    sdkB.FetchConfig()
    equal(env.configs[#env.configs].body.isOldUser, true, "9: user-b classification is isolated from user-a")
end

print("Lua SDK Issue #70 regression tests passed (all 9 items)")
