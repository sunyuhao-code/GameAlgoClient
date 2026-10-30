local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local files = {}

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
        gameKey = "ga_live_flush_recovery_" .. tostring(testSequence),
        userId = options.userId,
        userCreatedAt = options.userCreatedAt,
        userCreatedLocalAt = options.userCreatedLocalAt,
        sessionId = "flush-recovery-session-" .. tostring(testSequence),
        transport = transport,
        autoFetch = false,
        preloadConfigFiles = false,
        maxBatchSize = options.maxBatchSize or 100,
        maxQueueSize = options.maxQueueSize or 10000,
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
    local snapshot = cjson.decode(files["gamealgo_sdk_storage_v1.json"])
    local persisted = nil
    for _, value in pairs(snapshot.data) do
        if type(value) == "string" and value:find('"eventType":"session_end"', 1, true) then persisted = cjson.decode(value) end
    end
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
        local snapshot = cjson.decode(assert(files["gamealgo_sdk_storage_v1.json"]))
        local result = {}
        for key, value in pairs(snapshot.data) do
            if key:match(":events:jsonl$") and type(value) == "string" then
                for line in value:gmatch("[^\r\n]+") do
                    local event = cjson.decode(line)
                    if event.sessionId == sessionId then table.insert(result, event) end
                end
            end
        end
        return result
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
    end)
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
