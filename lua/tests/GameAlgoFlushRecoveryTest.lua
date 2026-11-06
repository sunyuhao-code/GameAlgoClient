local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local savedEventsFromFiles = require("tests.support.PersistedEvents")

local files = {}
local localWrites = 0
local failLocalWrites = false

FILE_READ = 1
FILE_WRITE = 2

function File(name, mode)
    local readable = mode == FILE_READ and files[name] ~= nil
    local writable = mode == FILE_WRITE
    local buffer = files[name] or ""
    return {
        IsOpen = function() return readable or writable end,
        ReadString = function() return buffer end,
        WriteString = function(_, value)
            if failLocalWrites then error("simulated local write failure") end
            localWrites = localWrites + 1
            buffer = value
            files[name] = value
        end,
        Flush = function() files[name] = buffer end,
        Close = function() end,
    }
end

lobby = {
    GetMyUserId = function() return "flush-recovery-user" end,
}

local testSequence = 0

local function equal(actual, expected, message)
    assert(actual == expected, (message or "values differ")
        .. ": expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
end

local function makeSdk(eventHandler, options)
    options = options or {}
    testSequence = testSequence + 1
    local currentTime = 0
    local requestCount = 0
    local sentCount = 0
    local cancelCount = 0
    local logs = {}
    local transport = {}
    local dataGameId = options.dataGameId or "data-game-flush"

    function transport.Request(request, callback)
        if request.url:match("/v1/config$") then
            if options.configHandler then
                return options.configHandler(cjson.decode(request.body), callback)
            end
            callback(nil, {
                status = 200,
                body = cjson.encode({
                    contextId = "ctx-flush-" .. tostring(testSequence),
                    gameId = dataGameId,
                    configVersion = "flush-recovery",
                    experiments = {},
                    configFiles = {},
                }),
                headers = {},
            })
            return nil
        end
        assert(request.url:match("/v1/events/batch$"), request.url)
        local batch = cjson.decode(request.body).events
        requestCount = requestCount + 1
        sentCount = sentCount + #batch
        return eventHandler(request, callback, batch, requestCount)
    end

    function transport.Cancel()
        cancelCount = cancelCount + 1
        return true
    end

    function transport.Update()
        if options.updateThrows then error("simulated update failure") end
    end

    local sdk = dofile("lua/GameAlgo.lua")
    sdk.Init({
        gameKey = options.gameKey or ("ga_live_flush_recovery_" .. tostring(testSequence)),
        userId = options.userId,
        userCreatedAt = options.userCreatedAt,
        userCreatedLocalAt = options.userCreatedLocalAt,
        sessionId = "flush-recovery-session-" .. tostring(testSequence),
        transport = transport,
        autoFetch = false,
        preloadConfigFiles = false,
        maxBatchSize = options.maxBatchSize or 100,
        maxQueueSize = options.maxQueueSize,
        flushIntervalMs = options.flushIntervalMs == nil and 5000 or options.flushIntervalMs,
        flushTimeoutMs = options.flushTimeoutMs or 15000,
        nowMs = function() return currentTime end,
        logger = function(message) table.insert(logs, message) end,
    })
    if not options.skipConfig then
        sdk.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
    end

    return {
        sdk = sdk,
        setTime = function(value) currentTime = value end,
        requests = function() return requestCount end,
        sent = function() return sentCount end,
        cancels = function() return cancelCount end,
        setDataGameId = function(value) dataGameId = value end,
        logs = logs,
    }
end

local function success(callback, batchSize)
    callback(nil, {
        status = 200,
        body = cjson.encode({ ok = true, accepted = batchSize }),
        headers = {},
    })
end

-- Idle queues have no send deadline and never inspect availability. The first
-- queued event arms the deadline; retry backoff also waits without count polling.
do
    local held, checks = {}, 0
    local harness = makeSdk(function(_, callback)
        table.insert(held, callback)
        return { request = "held" }
    end)
    local index, original = 1, nil
    while true do
        local name, value = debug.getupvalue(harness.sdk.Update, index)
        assert(name, "Update's queue-availability probe must be measurable")
        if name == "hasFlushableEvents" then original = value; break end
        index = index + 1
    end
    debug.setupvalue(harness.sdk.Update, index, function()
        checks = checks + 1
        return original()
    end)
    for _ = 1, 200 do harness.sdk.Update() end
    equal(checks, 0, "idle frames must not inspect the event count")
    harness.setTime(5000)
    harness.sdk.Update()
    equal(checks, 0, "empty queues must not arm a send timer")
    for _ = 1, 200 do harness.sdk.Update() end
    equal(checks, 0, "idle elapsed time must not cause repeated empty-queue checks")

    harness.setTime(5001)
    assert(harness.sdk.TrackLevelEnd({ result = "quit" }))
    for _ = 1, 200 do harness.sdk.Update() end
    equal(checks, 0, "a small batch waits for its timer without count polling")
    harness.setTime(10000)
    harness.sdk.Update()
    equal(checks, 0, "the first event owns the five-second deadline")
    harness.setTime(10001)
    harness.sdk.Update()
    equal(checks, 1)
    equal(harness.requests(), 1, "the scheduled batch still sends on time")
    held[1]("offline", nil)
    for _ = 1, 200 do harness.sdk.Update() end
    equal(checks, 1, "backoff must not poll the unchanged event count")
    harness.setTime(11001)
    harness.sdk.Update()
    equal(checks, 2)
    equal(harness.requests(), 2, "retry sends at its deadline")
    success(held[2], 1)
    local afterAck = checks
    harness.setTime(100000)
    for _ = 1, 200 do harness.sdk.Update() end
    equal(checks, afterAck, "drained queues return to the idle fast path")
    debug.setupvalue(harness.sdk.Update, index, original)
end

-- An inflight request does not shorten the normal five-second save interval.
-- Explicit exit Flush still checkpoints the tail immediately before returning.
do
    local harness = makeSdk(function() return { request = "held" } end)
    local sessionId = harness.sdk.Snapshot().sessionId
    assert(harness.sdk.TrackLevelStart({ level_attempt_id = "checkpoint-interval" }))
    harness.sdk.Flush(nil)
    local savedWrites = localWrites
    harness.setTime(100)
    assert(harness.sdk.TrackLevelEnd({ level_attempt_id = "checkpoint-interval", result = "quit" }))
    for _, time in ipairs({ 1000, 4999 }) do
        harness.setTime(time)
        harness.sdk.Update()
        equal(localWrites, savedWrites, "busy requests must not save before five seconds")
        equal(#savedEventsFromFiles(files, sessionId), 1, "tail stays in memory until its save boundary")
    end
    harness.setTime(5000)
    harness.sdk.Update()
    equal(localWrites, savedWrites + 1, "five-second boundary saves only the changed chunk")
    equal(#savedEventsFromFiles(files, sessionId), 2)
    equal(harness.requests(), 1, "checkpoint must not start a parallel HTTP request")
    harness.setTime(6000)
    assert(harness.sdk.TrackSessionEnd({ reason = "business_exit" }))
    equal(localWrites, savedWrites + 1, "next tail waits for the same save interval")
    harness.sdk.Flush(nil)
    equal(localWrites, savedWrites + 2, "explicit Flush saves immediately without waiting five seconds")
    equal(#savedEventsFromFiles(files, sessionId), 3)
    equal(harness.requests(), 1)
    for _ = 1, 20 do harness.sdk.Update() end
    equal(localWrites, savedWrites + 2, "unchanged queues must not be written again")
end

-- Ordinary tracking and busy Flush polling must not repeatedly rewrite the
-- SDK snapshot. A new tail still checkpoints immediately, and failed local
-- writes must never make a later Flush treat that tail as already durable.
do
    local harness = makeSdk(function() return { request = "held" } end)
    local beforeTracking = localWrites
    for sequence = 1, 50 do
        assert(harness.sdk.TrackLevelEnd({ level_attempt_id = "perf-" .. sequence, result = "quit" }))
    end
    equal(localWrites, beforeTracking, "ordinary tracking must not rewrite unchanged identity")
    harness.setTime(1000)
    harness.sdk.Update()
    equal(localWrites, beforeTracking, "optimization must preserve the pre-flush persistence cadence")
    harness.sdk.Flush(nil)
    local savedWrites = localWrites
    equal(savedWrites, beforeTracking + 2, "first Flush creates a small directory and one chunk")

    local originalEncode = cjson.encode
    local encodes = 0
    cjson.encode = function(...)
        encodes = encodes + 1
        return originalEncode(...)
    end
    for _ = 1, 25 do harness.sdk.Flush(nil) end
    cjson.encode = originalEncode
    equal(encodes, 0, "unchanged busy Flush must not serialize the queue or storage snapshot")
    equal(localWrites, savedWrites, "unchanged busy Flush must not rewrite storage")

    assert(harness.sdk.TrackSessionEnd({ reason = "business_exit" }))
    local oldSnapshot = files["gamealgo_sdk_storage_v1.json"]
    failLocalWrites = true
    harness.sdk.Flush(nil)
    equal(files["gamealgo_sdk_storage_v1.json"], oldSnapshot, "failed checkpoint must leave old disk contents")
    failLocalWrites = false
    harness.sdk.Flush(nil)
    equal(localWrites, savedWrites + 1, "repeated Flush retries the unpersisted tail")
    equal(savedEventsFromFiles(files, harness.sdk.Snapshot().sessionId)[51].payload.reason, "business_exit", "retry must persist the new session_end")
    harness.sdk.Flush(nil)
    equal(localWrites, savedWrites + 1, "successful retry makes later busy Flush a no-op")
end

-- Cached storage keys must follow Init's game and user, including returning to
-- an earlier namespace. Reusing one SDK module must not mix their event queues.
do
    local previousFileSystem = fileSystem
    fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
    local sdk = dofile("lua/GameAlgo.lua")
    local identities = {
        { "ga_live_storage_cache_a", "cache-user-a" },
        { "ga_live_storage_cache_a", "cache-user-b" },
        { "ga_live_storage_cache_b", "cache-user-b" },
        { "ga_live_storage_cache_a", "cache-user-a" },
    }
    for index, identity in ipairs(identities) do
        sdk.Init({ gameKey = identity[1], userId = identity[2], autoFetch = false,
            sessionId = "storage-cache-" .. index, logger = function() end,
            preloadConfigFiles = false, nowMs = function() return 0 end })
        equal(sdk.Snapshot().queuedEvents, index == 4 and 1 or 0, "each game/user restores only its own queue")
        if index < 4 then
            assert(sdk.TrackLevelEnd({ level_attempt_id = "cache-" .. index, result = "quit" }))
            sdk.Flush(nil)
        end
    end
    fileSystem = previousFileSystem
end

-- Business timing uses the same instance clock across session boundaries.
do
    local previousNode = Node
    local onUpdate
    Node = function() return { CreateScriptObject = function()
        return { SubscribeToEvent = function(_, eventName, handler)
            if eventName == "Update" then onUpdate = handler end
        end }
    end } end
    local sent = {}
    local harness = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(sent, event) end
        success(callback, #batch)
    end)
    local function frame() onUpdate(nil, nil, { GetFloat = function() return 0.25 end }) end
    equal(harness.sdk.GetForegroundTimeMs(), 0)
    for _ = 1, 4 do frame() end
    local start = harness.sdk.GetForegroundTimeMs()
    equal(start, 1000)
    local saved, requests = files["gamealgo_sdk_storage_v1.json"], harness.requests()
    harness.setTime(60000) -- reading does not advance the frame-driven clock
    for _ = 1, 100 do equal(harness.sdk.GetForegroundTimeMs(), start) end
    equal(files["gamealgo_sdk_storage_v1.json"], saved, "reads never write storage")
    equal(harness.requests(), requests, "reads never perform HTTP")
    harness.sdk.NewSession("foreground-clock-next")
    equal(harness.sdk.GetForegroundTimeMs(), start, "rotation preserves the instance clock")
    harness.sdk.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
    equal(harness.sdk.GetForegroundTimeMs(), start, "config refresh preserves the clock")
    frame(); frame()
    harness.sdk.TrackSessionEnd()
    harness.sdk.Flush(nil)
    equal(harness.sdk.GetForegroundTimeMs() - start, 500)
    equal(sent[#sent].payload.sessionDurationMs, 500, "session duration uses its clock offset")
    local restarted = makeSdk(function(_, callback, batch) success(callback, #batch) end)
    equal(restarted.sdk.GetForegroundTimeMs(), 0, "initialization resets the instance clock")
    Node = previousNode
end

-- Explicit session boundaries belong to the SDK, independently of lifecycle
-- callbacks. A same-ID call is a no-op and a manual end is never extended.
do
    local sent = {}
    local harness = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(sent, event) end
        success(callback, #batch)
    end)
    local previous = harness.sdk.Snapshot()
    harness.setTime(1000)
    equal(harness.sdk.NewSession(previous.sessionId), previous.sessionId, "same session remains active")
    equal(harness.requests(), 0, "same session ID does not flush")
    harness.setTime(3500)
    equal(harness.sdk.NewSession("rotation-next"), "rotation-next", "rotation does not await upload")
    equal(#sent, 1, "rotation immediately flushes its old end")
    equal(sent[1].eventType, "session_end")
    equal(sent[1].sessionId, previous.sessionId)
    equal(sent[1].contextId, previous.contextId)
    equal(sent[1].payload.reason, "new_session")
    equal(sent[1].payload.sessionDurationMs, 0, "wall time without engine frames must not accrue duration")
    harness.setTime(4500)
    assert(harness.sdk.TrackSessionEnd({ reason = "manual" }))
    harness.setTime(100000)
    harness.sdk.NewSession("rotation-third")
    equal(#sent, 2, "already-ended session is not ended again")
    equal(sent[2].payload.reason, "manual")
    equal(sent[2].payload.sessionDurationMs, 0, "manual duration excludes wall time without engine frames")
end

do
    local failed = true
    local attempted = {}
    local harness = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(attempted, event) end
        if failed then callback("offline", nil) else success(callback, #batch) end
    end)
    local old = harness.sdk.Snapshot().sessionId
    harness.sdk.NewSession("offline-next")
    equal(harness.sdk.Snapshot().sessionId, "offline-next", "network errors do not undo rotation")
    equal(harness.sdk.Snapshot().queuedEvents, 1, "unacknowledged old end stays queued")
    local persisted = savedEventsFromFiles(files, old)[1]
    assert(persisted, "rotation must persist its end before any transport success")
    equal(persisted.sessionId, old)
    equal(persisted.eventId, attempted[1].eventId)
    failed = false
    harness.sdk.Flush(nil)
    equal(attempted[#attempted].eventId, persisted.eventId, "retry retains its event ID")
    equal(harness.sdk.Snapshot().queuedEvents, 0)
end

-- Config requests queued by overlapping rotations retain their original
-- session IDs. Late historical configs only bind their own events/callbacks.
do
    local configs, events, completions = {}, {}, {}
    local harness = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(events, event) end
        success(callback, #batch)
    end, { skipConfig = true, configHandler = function(body, callback)
        table.insert(configs, { body = body, callback = callback })
    end })
    local first = harness.sdk.Snapshot().sessionId
    harness.sdk.FetchConfig(function(error, config)
        assert(error == nil)
        table.insert(completions, config.configVersion)
    end)
    harness.sdk.NewSession("overlap-middle", function(error, config)
        assert(error == nil)
        table.insert(completions, config.configVersion)
    end)
    harness.sdk.NewSession("overlap-last", function(error, config)
        assert(error == nil)
        table.insert(completions, config.configVersion)
    end)
    equal(#events, 0, "unbound old ends must not upload under a new context")
    local sessions = { first, "overlap-middle", "overlap-last" }
    for index, session in ipairs(sessions) do
        equal(configs[index].body.sessionId, session, "each queued config keeps original request ownership")
        configs[index].callback(nil, { status = 200, body = cjson.encode({
            contextId = "context-" .. session, gameId = "overlap", configVersion = session,
            experiments = {}, configFiles = {},
        }) })
        equal(completions[index], session, "new-session callback waits for its own config")
        if index < 3 then equal(harness.sdk.Snapshot().contextId, nil, "old config cannot publish into the current session") end
    end
    equal(#events, 2)
    for index, event in ipairs(events) do
        equal(event.sessionId, sessions[index])
        equal(event.contextId, "context-" .. sessions[index])
        equal(event.eventType, "session_end")
    end
    equal(harness.sdk.Snapshot().contextId, "context-overlap-last")
end

do
    local pending = nil
    local harness = makeSdk(function(_, callback)
        pending = callback
    end, { maxBatchSize = 1, maxQueueSize = 1 })
    local previous = harness.sdk.Snapshot().sessionId
    assert(harness.sdk.TrackLevelStart({}))
    local nextId, error = harness.sdk.NewSession("queue-full-next")
    equal(nextId, nil, "rotation fails truthfully when its end cannot enter a fully in-flight queue")
    assert(tostring(error):find("queue is full", 1, true))
    equal(harness.sdk.Snapshot().sessionId, previous, "failed end admission preserves the old session")
    success(pending, 1)
end

-- Milestones derive elapsed time from registration and deduplicate locally
-- across sessions and data-version switches.
do
    local uploaded = nil
    local harness = makeSdk(function(_, callback, batch)
        uploaded = batch
        success(callback, #batch)
    end, {
        userId = "milestone-user",
        userCreatedAt = "1970-01-01T00:00:00.000Z",
        userCreatedLocalAt = "1970-01-01T00:00:00.000Z",
        dataGameId = "data-game-milestone",
    })
    harness.setTime(5000)
    assert(harness.sdk.Track("milestone", {
        milestoneType = "new_user",
        milestonePoint = "完成引导",
        elapsedSinceRegistrationMs = 999999,
    }))
    local duplicate, duplicateError = harness.sdk.Track("milestone", {
        milestoneType = "new_user",
        milestonePoint = "完成引导",
    })
    equal(duplicate, false, "duplicate milestone is suppressed")
    equal(duplicateError, "duplicate milestone", "duplicate reason is explicit")
    harness.sdk.Flush(nil)
    equal(#uploaded, 1, "only one milestone is uploaded")
    equal(uploaded[1].payload.elapsedSinceRegistrationMs, 5000,
        "SDK owns elapsed time since registration")

    harness.setDataGameId("data-game-milestone-v2")
    harness.sdk.NewSession("milestone-session-2", function(error) assert(error == nil, tostring(error)) end)
    local nextSessionDuplicate = harness.sdk.Track("milestone", {
        milestoneType = "new_user",
        milestonePoint = "完成引导",
    })
    equal(nextSessionDuplicate, false, "milestone dedupe survives session and data-version changes")
end

-- Init owns an independent LuaScriptObject Update receiver. It must not touch
-- or replace the game's global Update subscription.
do
    local sdkUpdateHandler = nil
    local globalUpdateSubscriptions = 0
    SubscribeToEvent = function(eventType, handlerName)
        globalUpdateSubscriptions = globalUpdateSubscriptions + 1
    end
    Node = function()
        return {
            CreateScriptObject = function(_, className)
                equal(className, "LuaScriptObject", "SDK creates an isolated event receiver")
                return {
                    SubscribeToEvent = function(_, eventName, callback)
                        equal(eventName, "Update", "isolated receiver subscribes to Update")
                        sdkUpdateHandler = callback
                    end,
                }
            end,
        }
    end
    local harness = makeSdk(function(_, callback, batch)
        success(callback, #batch)
    end)
    equal(globalUpdateSubscriptions, 0, "SDK must preserve the game's global Update handler")
    assert(type(sdkUpdateHandler) == "function", "automatic Update handler must be registered")
    assert(harness.sdk.TrackEvent("timer_event", {}))
    harness.setTime(4999)
    sdkUpdateHandler("Update", nil)
    equal(harness.requests(), 0, "timer must not fire early")
    harness.setTime(5000)
    sdkUpdateHandler("Update", nil)
    equal(harness.requests(), 1, "timer flushes queued events")
    equal(harness.sdk.Snapshot().queuedEvents, 0, "timer drains the queue")
    Node = nil
    SubscribeToEvent = nil
end

-- Maker lifecycle callbacks report snapshots, including fullscreen-ad pauses.
-- They must persist before transport and leave the session open for rotation.
do
    local receivers = {}
    local subscriptions = 0
    Node = function()
        local handlers = {}
        table.insert(receivers, handlers)
        return {
            CreateScriptObject = function()
                return {
                    SubscribeToEvent = function(_, eventName, callback)
                        subscriptions = subscriptions + 1
                        handlers[eventName] = callback
                    end,
                }
            end,
        }
    end

    local function persistedEvents(sessionId)
        return savedEventsFromFiles(files, sessionId)
    end

    local sent = {}
    local function acceptPersisted(_, callback, batch)
        for _, event in ipairs(batch) do
            local found = false
            for _, saved in ipairs(persistedEvents(event.sessionId)) do
                if saved.eventId == event.eventId then found = true end
            end
            assert(found, "lifecycle event must be persisted before starting HTTP")
            table.insert(sent, event)
        end
        success(callback, #batch)
    end
    local harness = makeSdk(acceptPersisted)
    local handlers = receivers[#receivers]
    local function frames(target, seconds)
        for _ = 1, math.floor(seconds * 60 + 0.5) do
            target.Update(nil, nil, { GetFloat = function(_, field)
                equal(field, "TimeStep")
                return 1 / 60
            end })
        end
    end
    local previous = harness.sdk.Snapshot()
    harness.setTime(3000)
    for _, delta in ipairs({ -1, 0, math.huge, 0 / 0 }) do
        handlers.Update(nil, nil, { GetFloat = function() return delta end })
    end
    handlers.Update(nil, nil, { GetFloat = function() error("missing TimeStep") end })
    frames(handlers, 3)
    harness.sdk.NewSession(previous.sessionId)
    handlers.AppWillEnterBackground()
    equal(harness.requests(), 1, "background flushes without waiting for Update or five-second timer")
    equal(sent[1].eventType, "session_end")
    equal(sent[1].payload.reason, "app_background")
    equal(sent[1].payload.lifecycleEvent, "AppWillEnterBackground")
    equal(sent[1].payload.sessionDurationMs, 3000)
    equal(sent[1].sessionId, previous.sessionId)
    equal(sent[1].contextId, previous.contextId)
    equal(harness.sdk.Snapshot().sessionId, previous.sessionId, "background does not rotate session")
    harness.setTime(8000)
    frames(handlers, 1.25)
    handlers.AppWillEnterBackground()
    equal(#sent, 2, "another background can report the same session again")
    equal(sent[2].payload.sessionDurationMs, 4250, "resumed engine frames count even without a foreground notification")
    assert(sent[1].eventId ~= sent[2].eventId, "separate backgrounds are distinct events")
    harness.setTime(12000)
    harness.sdk.NewSession("after-lifecycle-snapshots")
    equal(#sent, 3, "an ad/background snapshot must not suppress explicit rotation's end")
    equal(sent[3].sessionId, previous.sessionId)
    equal(sent[3].payload.reason, "new_session")
    equal(sent[3].payload.sessionDurationMs, 4250, "rotation closes the frozen old duration")
    harness.setTime(14000)
    frames(handlers, 2.5)
    handlers.ExitRequested()
    harness.setTime(15000)
    frames(handlers, 0.5)
    handlers.AppTerminating()
    equal(sent[4].payload.reason, "exit_requested")
    equal(sent[5].payload.reason, "app_terminating")
    equal(sent[5].sessionId, "after-lifecycle-snapshots")
    equal(sent[5].payload.sessionDurationMs, 3000)

    local oldSubscriptions = subscriptions
    local reinitTime = 20000
    harness.sdk.Init({
        gameKey = "ga_live_lifecycle_reinit", sessionId = "lifecycle-reinit",
        nowMs = function() return reinitTime end, preloadConfigFiles = false,
        logger = function() end,
        transport = { Request = function(request, callback)
            if request.url:match("/v1/config$") then
                callback(nil, { status = 200, body = cjson.encode({ contextId = "ctx-reinit",
                    experiments = {}, configFiles = {} }), headers = {} })
            else acceptPersisted(request, callback, cjson.decode(request.body).events) end
        end },
    })
    equal(subscriptions, oldSubscriptions, "reinitialization reuses the independent event receiver")
    reinitTime = 22000
    frames(handlers, 2)
    handlers.AppWillEnterBackground()
    equal(#sent, 6, "reinitialization must not duplicate lifecycle listeners")
    equal(sent[6].sessionId, "lifecycle-reinit", "existing handler uses current SDK state")
    equal(sent[6].payload.sessionDurationMs, 2000)

    local quotaSent = {}
    local quota = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(quotaSent, event) end
        success(callback, #batch)
    end, { configHandler = function(_, callback)
        callback(nil, { status = 200, body = cjson.encode({ contextId = "ctx-lifecycle-quota",
            experiments = {}, configFiles = {}, eventQuota = {
                mode = "enforce", ordinaryEventLimit = 0, policyVersion = 1,
            } }), headers = {} })
    end })
    receivers[#receivers].AppWillEnterBackground()
    equal(#quotaSent, 1, "lifecycle end bypasses exhausted ordinary-event quota")
    equal(quotaSent[1].eventType, "session_end")

    local firstCallback, attemptedEnd = nil, nil
    local busy = makeSdk(function(_, callback, batch, requestCount)
        if requestCount == 1 then firstCallback = callback
        elseif requestCount == 2 then
            attemptedEnd = batch[1]
            callback("offline", nil)
        else
            equal(batch[1].eventId, attemptedEnd.eventId, "retry preserves background event identity")
            success(callback, #batch)
        end
    end)
    local busySession = busy.sdk.Snapshot().sessionId
    assert(busy.sdk.TrackEvent("busy", {}))
    busy.sdk.Flush(nil)
    busy.setTime(1700)
    frames(receivers[#receivers], 1.7)
    receivers[#receivers].AppWillEnterBackground()
    equal(busy.requests(), 1, "background coalesces with active HTTP request")
    local saved = persistedEvents(busySession)
    equal(#saved, 2, "active batch and new background end are both durable")
    equal(saved[2].eventType, "session_end")
    equal(saved[2].payload.sessionDurationMs, 1700)
    success(firstCallback, 1)
    equal(busy.requests(), 2, "background end flushes when the earlier request completes")
    equal(busy.sdk.Snapshot().queuedEvents, 1, "failed background upload remains queued")
    equal(persistedEvents(busySession)[1].eventId, attemptedEnd.eventId)
    busy.sdk.Flush(nil)
    equal(busy.sdk.Snapshot().queuedEvents, 0)

    local cloudRead = nil
    clientCloud = {
        Get = function(_, _, callbacks) cloudRead = callbacks end,
        Set = function(_, _, _, callbacks) callbacks.ok() end,
    }
    local delayedSent = {}
    local delayed = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(delayedSent, event) end
        success(callback, #batch)
    end, { skipConfig = true })
    assert(cloudRead, "first storage read must still be pending")
    local delayedSession = delayed.sdk.Snapshot().sessionId
    delayed.setTime(2500)
    frames(receivers[#receivers], 2.5)
    receivers[#receivers].AppWillEnterBackground()
    equal(delayed.sdk.Snapshot().pendingEvents, 1, "early background waits for storage identity")
    delayed.setTime(9000)
    cloudRead.ok({})
    equal(delayed.sdk.Snapshot().pendingEvents, 0)
    local delayedSaved = persistedEvents(delayedSession)
    equal(#delayedSaved, 1, "storage readiness persists pending end even without a config context")
    equal(delayedSaved[1].payload.sessionDurationMs, 2500, "initialization delay cannot inflate duration")
    delayed.sdk.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
    equal(#delayedSent, 1, "config binding triggers the pending background flush")
    equal(delayedSent[1].eventId, delayedSaved[1].eventId)
    delayed.setTime(11000)
    delayed.sdk.NewSession("delayed-lifecycle-next")
    equal(#delayedSent, 2, "pending background snapshot must also preserve rotation's final end")
    equal(delayedSent[2].payload.reason, "new_session")
    equal(delayedSent[2].payload.sessionDurationMs, 2500, "storage and background delays do not inflate rotation")
    clientCloud = nil
    Node = nil
end

-- A manual exit Flush must checkpoint events appended during an earlier HTTP
-- request, before either request completes or another Update gets to run.
do
    local previousFileSystem = fileSystem
    fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
    local function savedEvents(sessionId)
        return savedEventsFromFiles(files, sessionId)
    end

    for _, acknowledgeFirst in ipairs({ false, true }) do
        local held = {}
        local options = { gameKey = "ga_live_exit_checkpoint_" .. tostring(acknowledgeFirst),
            userId = "exit-checkpoint-user" }
        local harness = makeSdk(function(_, callback, batch)
            table.insert(held, { callback = callback, batch = batch })
            return { request = "held" }
        end, options)
        local original = harness.sdk.Snapshot()
        assert(harness.sdk.TrackLevelStart({ level_attempt_id = "exit-attempt", level_id = "main_1" }))
        harness.sdk.Flush(nil)
        equal(#savedEvents(original.sessionId), 1, "first request is already durable")

        harness.setTime(100) -- below the five-second persistence interval
        assert(harness.sdk.TrackLevelEnd({ level_attempt_id = "exit-attempt", level_id = "main_1", result = "quit" }))
        assert(harness.sdk.TrackEvent("exit_summary", { completedLevels = 3 }))
        assert(harness.sdk.TrackSessionEnd({ reason = "business_exit", completedLevels = 3 }))
        equal(#savedEvents(original.sessionId), 1, "tail has not reached the periodic persistence boundary")
        local finished = false
        harness.sdk.Flush(function() finished = true end)
        equal(harness.requests(), 1, "exit Flush cannot start a parallel request")
        equal(finished, false, "inflight flush callback is not completed prematurely")
        local saved = savedEvents(original.sessionId)
        equal(#saved, 4, "exit Flush synchronously persists the inflight batch and every tail event")
        equal(saved[2].eventType, "level_end")
        equal(saved[3].eventType, "_exit_summary")
        equal(saved[4].eventType, "session_end")
        equal(saved[4].payload.completedLevels, 3)
        for _, event in ipairs(saved) do equal(event.contextId, original.contextId, "checkpoint retains context") end

        local expectedStart = 1
        if acknowledgeFirst then
            success(held[1].callback, #held[1].batch)
            expectedStart = 2
            equal(harness.requests(), 2, "ACK starts the held tail request")
            equal(#savedEvents(original.sessionId), 3, "ACK only removes the first batch from disk")
            success(held[1].callback, #held[1].batch) -- stale duplicate ACK
            equal(#savedEvents(original.sessionId), 3, "stale ACK cannot erase the persisted tail")
        end

        -- Simulate destruction: no Update, lifecycle notification, timeout or
        -- remaining transport callbacks. The replacement SDK only has File.
        local restoredEvents = {}
        local restarted = makeSdk(function(_, callback, batch)
            for _, event in ipairs(batch) do table.insert(restoredEvents, event) end
            success(callback, #batch)
        end, { gameKey = options.gameKey, userId = options.userId, skipConfig = true })
        equal(restarted.sdk.Snapshot().queuedEvents, 5 - expectedStart, "cold start restores every unacknowledged event")
        restarted.sdk.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
        restarted.sdk.Flush(nil)
        equal(#restoredEvents, 5 - expectedStart)
        for index, event in ipairs(restoredEvents) do
            local previous = saved[index + expectedStart - 1]
            equal(event.eventId, previous.eventId, "recovery keeps event ID")
            equal(event.sessionId, original.sessionId, "recovery keeps old session")
            equal(event.contextId, original.contextId, "new config cannot take ownership of old events")
            equal(event.timestamp, previous.timestamp, "recovery keeps occurrence time")
        end
        equal(#savedEvents(original.sessionId), 0, "only successful ACK clears the durable tail")
    end
    -- Missing config is another early-return path: persist before delivering
    -- the error callback, then send these same events once config is available.
    local sent = {}
    local unbound = makeSdk(function(_, callback, batch)
        for _, event in ipairs(batch) do table.insert(sent, event) end
        success(callback, #batch)
    end, { skipConfig = true })
    local unboundSession = unbound.sdk.Snapshot().sessionId
    assert(unbound.sdk.TrackLevelEnd({ level_attempt_id = "unbound-exit", result = "quit" }))
    assert(unbound.sdk.TrackSessionEnd({ reason = "business_exit" }))
    local unboundError, savedBeforeCallback = nil, 0
    unbound.sdk.Flush(function(error)
        unboundError = error
        savedBeforeCallback = #savedEvents(unboundSession)
    end)
    equal(savedBeforeCallback, 2, "unbound tail is saved before Flush calls back")
    equal(unboundError, "context not ready")
    equal(unbound.requests(), 0, "unbound events do not bypass config ownership")
    unbound.sdk.FetchConfig(function(error) assert(error == nil, tostring(error)) end)
    equal(#sent, 2, "config completion drains the saved unbound tail")
    equal(#savedEvents(unboundSession), 0, "unbound tail is cleared after ACK")
    fileSystem = previousFileSystem
end

-- A missing callback times out, rolls back the inflight batch, ignores the late
-- callback, and drains every queued batch after retry backoff.
do
    local firstCallback = nil
    local mode = "hold"
    local harness = makeSdk(function(_, callback, batch)
        if mode == "hold" then
            firstCallback = callback
            return { request = "held" }
        end
        success(callback, #batch)
        return { request = "complete" }
    end, { maxQueueSize = 2500 })
    assert(harness.sdk.Track("level_start", { sequence = 1 }))
    local timeoutError = nil
    harness.sdk.Flush(function(error) timeoutError = error end)
    for sequence = 2, 2000 do
        assert(harness.sdk.Track("level_start", { sequence = sequence }))
        harness.sdk.Flush(nil)
    end
    equal(harness.requests(), 1, "only one request is active before timeout")
    equal(harness.sdk.Snapshot().queuedEvents, 2000, "snapshot includes inflight events")

    harness.setTime(15001)
    harness.sdk.Update()
    assert(tostring(timeoutError):find("timed out", 1, true), tostring(timeoutError))
    equal(harness.cancels(), 1, "watchdog cancels the retained request")
    equal(harness.sdk.Snapshot().flushing, false, "watchdog unlocks flush state")
    equal(harness.sdk.Snapshot().queuedEvents, 2000, "watchdog requeues inflight events")

    firstCallback(nil, {
        status = 200,
        body = cjson.encode({ ok = true, accepted = 1 }),
        headers = {},
    })
    equal(harness.requests(), 1, "late callback cannot start a new request")

    mode = "success"
    harness.setTime(16001)
    harness.sdk.Update()
    equal(harness.requests(), 21, "retry drains all twenty batches")
    equal(harness.sdk.Snapshot().queuedEvents, 0, "retry drains the full backlog")
    equal(harness.sdk.Snapshot().flushing, false, "retry finishes unlocked")
end

-- Default capacity is 500 including the inflight batch. Reducing the default
-- must not truncate a larger, already durable queue from an older SDK.
do
    local harness = makeSdk(function() return { request = "held" } end)
    for sequence = 1, 500 do
        assert(harness.sdk.TrackLevelEnd({ level_attempt_id = "bounded-" .. sequence, result = "quit" }))
    end
    local accepted, error = harness.sdk.TrackLevelEnd({ result = "quit" })
    equal(accepted, false)
    equal(error, "event queue is full (max=500)")
    equal(harness.sdk.Snapshot().queuedEvents, 500)

    local previousFileSystem = fileSystem
    fileSystem = { FileExists = function(_, name) return files[name] ~= nil end }
    local Sha256 = require("Sha256")
    local gameKey, userId = "ga_live_legacy_over_capacity", "legacy-over-capacity-user"
    local key = "gamealgo:v2:game:" .. Sha256.hex(gameKey) .. ":user:" .. Sha256.hex(userId) .. ":events:jsonl"
    local snapshot, snapshotFile = require("tests.support.PersistedSnapshot")(files)
    local lines = {}
    for sequence = 1, 620 do
        lines[sequence] = cjson.encode({ eventId = "legacy-capacity-" .. sequence,
            sessionId = "legacy-capacity-session", contextId = "legacy-capacity-context",
            eventType = "level_end", payload = { result = "quit" } })
    end
    snapshot.data[key] = table.concat(lines, "\n")
    snapshot.revision = snapshot.revision + 1
    files[snapshotFile] = cjson.encode(snapshot)
    local legacy = makeSdk(function(_, callback, batch) success(callback, #batch) end,
        { gameKey = gameKey, userId = userId, skipConfig = true })
    equal(legacy.sdk.Snapshot().queuedEvents, 620, "upgrade must keep all existing events")
    equal(legacy.sdk.TrackLevelEnd({ result = "quit" }), false, "full legacy backlog rejects new events")
    legacy.sdk.Flush(nil)
    equal(legacy.sdk.Snapshot().queuedEvents, 0, "existing backlog can drain past the reduced admission limit")
    equal(legacy.sent(), 620)
    fileSystem = previousFileSystem
end

-- Payloads are rejected before entering the queue if cjson cannot encode them.
do
    local harness = makeSdk(function(_, callback, batch)
        success(callback, #batch)
    end)
    local sparse = {}
    sparse[1000] = "invalid"
    local tracked, trackError = harness.sdk.TrackEvent("sparse", sparse)
    equal(tracked, false, "sparse payload is rejected")
    assert(tostring(trackError):find("not JSON serializable", 1, true), tostring(trackError))
    harness.sdk.Flush(nil)
    equal(harness.requests(), 0, "rejected payload never reaches transport")
    equal(harness.sdk.Snapshot().flushing, false, "serialization rejection cannot lock flush")
end

-- Synchronous transport exceptions are converted to retryable errors.
do
    local shouldThrow = true
    local harness = makeSdk(function(_, callback, batch)
        if shouldThrow then error("simulated Send exception") end
        success(callback, #batch)
    end)
    assert(harness.sdk.TrackEvent("send_exception", {}))
    local flushError = nil
    local callOk = pcall(function()
        harness.sdk.Flush(function(error) flushError = error end)
    end)
    equal(callOk, true, "transport exception is contained")
    assert(tostring(flushError):find("request failed", 1, true), tostring(flushError))
    equal(harness.sdk.Snapshot().flushing, false, "transport exception unlocks flush")
    equal(harness.sdk.Snapshot().queuedEvents, 1, "transport exception requeues the batch")
    shouldThrow = false
    harness.sdk.Flush(nil)
    equal(harness.sdk.Snapshot().queuedEvents, 0, "manual retry succeeds")
end

-- Zero acceptance without complete rejection details remains retryable.
do
    local partial = true
    local harness = makeSdk(function(_, callback, batch)
        callback(nil, {
            status = 200,
            body = cjson.encode({ ok = true, accepted = partial and 0 or #batch }),
            headers = {},
        })
    end)
    for sequence = 1, 10 do assert(harness.sdk.TrackEvent("partial", { sequence = sequence })) end
    local partialError = nil
    harness.sdk.Flush(function(error) partialError = error end)
    assert(tostring(partialError):find("partial flush acceptance", 1, true), tostring(partialError))
    equal(harness.sdk.Snapshot().queuedEvents, 10, "partially accepted batch is retained")
    partial = false
    harness.sdk.Flush(nil)
    equal(harness.sdk.Snapshot().queuedEvents, 0, "partial batch can be retried")
end

-- Share the progress-first wire policy with both Godot implementations.
do
    local file = assert(io.open("protocol/fixtures/event-batch-ack.json", "r"))
    local fixture = cjson.decode(file:read("*a"))
    file:close()
    for _, case in ipairs(fixture.cases) do
        local harness = makeSdk(function(_, callback)
            callback(nil, { status = 200, body = cjson.encode(case.response), headers = {} })
        end)
        for sequence = 1, fixture.batchSize do
            assert(harness.sdk.TrackEvent("batch_completion", { sequence = sequence }))
        end
        local flushError, flushResult = "not invoked", nil
        harness.sdk.Flush(function(error, result)
            flushError, flushResult = error, result
        end)
        if case.terminal then
            equal(flushError, nil, case.name .. ": terminal response completes")
            equal(flushResult.accepted, case.accepted, case.name .. ": reports actual acceptance")
            equal(harness.sdk.Snapshot().queuedEvents, 0, case.name .. ": entire batch leaves queue")
            harness.sdk.Flush(nil)
            equal(harness.requests(), 1, case.name .. ": no whole-batch replay")
        else
            assert(flushError ~= nil, case.name .. ": incomplete or invalid response must fail")
            equal(harness.sdk.Snapshot().queuedEvents, fixture.batchSize, case.name .. ": retains batch")
        end
    end
end

-- A server response that accounts for every row as accepted or explicitly
-- rejected is terminal. The rejected row must not poison and replay the batch.
do
    local harness = makeSdk(function(_, callback, batch)
        callback(nil, {
            status = 200,
            body = cjson.encode({
                ok = true,
                accepted = #batch - 1,
                rejected = {{
                    index = #batch - 1,
                    eventId = batch[#batch].eventId,
                    reason = "payload contains a non-JSON value",
                }},
            }),
            headers = {},
        })
    end)
    for sequence = 1, 10 do
        assert(harness.sdk.TrackEvent("isolated_rejection", { sequence = sequence }))
    end
    local flushError = "callback not invoked"
    local flushResult = nil
    harness.sdk.Flush(function(error, result)
        flushError = error
        flushResult = result
    end)
    equal(flushError, nil, "accounted rejection completes successfully")
    equal(flushResult.accepted, 9, "callback reports accepted rows")
    equal(flushResult.rejectedCount, 1, "callback reports rejected rows")
    equal(harness.requests(), 1, "accounted rejection is not retried")
    equal(harness.sdk.Snapshot().queuedEvents, 0, "accounted rejection drains the batch")
    assert(table.concat(harness.logs, "\n"):find("flush event rejected", 1, true),
        "rejected event must be logged")
end

-- A duplicate terminal callback cannot unlock a newer request.
do
    local held = {}
    local harness = makeSdk(function(_, callback, batch, requestNumber)
        if requestNumber <= 2 then
            held[requestNumber] = { callback = callback, size = #batch }
        else
            success(callback, #batch)
        end
    end)
    for sequence = 1, 150 do
        assert(harness.sdk.TrackEvent("duplicate_callback", { sequence = sequence }))
        harness.sdk.Flush(nil)
    end
    success(held[1].callback, held[1].size)
    equal(harness.requests(), 2, "first completion starts the next batch")
    success(held[1].callback, held[1].size)
    assert(harness.sdk.TrackEvent("after_duplicate", {}))
    harness.sdk.Flush(nil)
    equal(harness.requests(), 2, "duplicate callback cannot create a concurrent request")
    success(held[2].callback, held[2].size)
    equal(harness.requests(), 3, "remaining events drain after the real second callback")
    equal(harness.sdk.Snapshot().queuedEvents, 0, "duplicate callback test drains cleanly")
end

-- The queue cap includes the inflight batch and prevents unbounded growth.
do
    local harness = makeSdk(function() return { request = "held" } end, {
        maxBatchSize = 5,
        maxQueueSize = 10,
    })
    assert(harness.sdk.TrackEvent("queue_cap", { sequence = 1 }))
    harness.sdk.Flush(nil)
    for sequence = 2, 10 do assert(harness.sdk.TrackEvent("queue_cap", { sequence = sequence })) end
    local tracked, queueError = harness.sdk.TrackEvent("queue_cap", { sequence = 11 })
    equal(tracked, false, "queue cap rejects excess events")
    assert(tostring(queueError):find("queue is full", 1, true), tostring(queueError))
    equal(harness.sdk.Snapshot().queuedEvents, 10, "queue cap includes inflight events")
end

-- HttpTransport itself retains request clients and settles callbacks once.
do
    HTTP_GET, HTTP_POST, HTTP_PUT, HTTP_DELETE, HTTP_PATCH = 1, 2, 3, 4, 5
    local weakClient = setmetatable({}, { __mode = "v" })
    local callbackCount = 0
    http = {
        Create = function()
            local client = {}
            function client:SetUrl() return self end
            function client:SetMethod() return self end
            function client:SetTimeout() return self end
            function client:AddHeader() return self end
            function client:SetContentType() return self end
            function client:SetBody() return self end
            function client:OnSuccess(callback) self.successCallback = callback; return self end
            function client:OnError(callback) self.errorCallback = callback; return self end
            function client:Send() return self end
            weakClient[1] = client
            return client
        end,
    }
    package.loaded["HttpTransport"] = nil
    package.loaded["sdk.HttpTransport"] = nil
    local HttpTransport = require("HttpTransport")
    local returned = HttpTransport.Request({ method = "GET", url = "https://example.test" },
        function() callbackCount = callbackCount + 1 end)
    returned = nil
    collectgarbage("collect")
    assert(weakClient[1] ~= nil, "active request client must be retained")
    equal(HttpTransport.Diagnostics().activeRequests, 1, "transport reports retained request")
    local retained = weakClient[1]
    retained.successCallback(retained, {
        statusCode = 200,
        success = true,
        dataAsString = "{}",
    })
    retained.errorCallback(retained, 500, "late error")
    equal(callbackCount, 1, "transport settles duplicate callbacks once")
    equal(HttpTransport.Diagnostics().activeRequests, 0, "settled request is released")
end

print("Lua SDK flush recovery tests passed")
