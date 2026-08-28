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

    function transport.Request(request, callback)
        if request.url:match("/v1/config$") then
            callback(nil, {
                status = 200,
                body = cjson.encode({
                    contextId = "ctx-flush-" .. tostring(testSequence),
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
    sdk.FetchConfig(function(error) assert(error == nil, tostring(error)) end)

    return {
        sdk = sdk,
        setTime = function(value) currentTime = value end,
        requests = function() return requestCount end,
        sent = function() return sentCount end,
        cancels = function() return cancelCount end,
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

-- Init subscribes an internal Update handler, so developers do not need to
-- wire GameAlgo.Update into their own game loop.
do
    local updateHandler = nil
    SubscribeToEvent = function(eventType, handlerName)
        equal(eventType, "Update", "SDK subscribes the Maker Update event")
        updateHandler = handlerName
    end
    local harness = makeSdk(function(_, callback, batch)
        success(callback, #batch)
    end)
    assert(type(updateHandler) == "string" and type(_G[updateHandler]) == "function",
        "automatic Update handler must be registered")
    assert(harness.sdk.TrackEvent("timer_event", {}))
    harness.setTime(4999)
    _G[updateHandler]("Update", nil)
    equal(harness.requests(), 0, "timer must not fire early")
    harness.setTime(5000)
    _G[updateHandler]("Update", nil)
    equal(harness.requests(), 1, "timer flushes queued events")
    equal(harness.sdk.Snapshot().queuedEvents, 0, "timer drains the queue")
    SubscribeToEvent = nil
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
    assert(harness.sdk.TrackEvent("first", { sequence = 1 }))
    local timeoutError = nil
    harness.sdk.Flush(function(error) timeoutError = error end)
    for sequence = 2, 2000 do
        assert(harness.sdk.TrackEvent("queued", { sequence = sequence }))
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

-- Partial 2xx acceptance is a retryable error rather than silent data loss.
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
