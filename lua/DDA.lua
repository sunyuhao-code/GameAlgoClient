---@meta
--- Local behavior windows and safe DDA decisions.

local cjson = require("cjson")

local DDA = {}

local function emptyState()
    return {
        schemaVersion = 1,
        current = {},
        lifetime = {},
        recentSteps = {},
        completedSteps = 0,
    }
end

local function copyCounts(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if type(key) == "string" and type(value) == "number" and value > 0 then result[key] = value end
    end
    return result
end

local function normalizeState(value)
    if type(value) ~= "table" then return emptyState() end
    local state = emptyState()
    state.current = copyCounts(value.current)
    state.lifetime = copyCounts(value.lifetime)
    state.completedSteps = math.max(0, math.floor(tonumber(value.completedSteps) or 0))
    if type(value.recentSteps) == "table" then
        for _, step in ipairs(value.recentSteps) do
            if type(step) == "table" then
                table.insert(state.recentSteps, {
                    stepId = step.stepId and tostring(step.stepId) or nil,
                    behaviors = copyCounts(step.behaviors),
                })
            end
        end
    end
    return state
end

local function aggregateRecent(steps)
    local result = {}
    for _, step in ipairs(steps or {}) do
        for behaviorType, amount in pairs(step.behaviors or {}) do
            result[behaviorType] = (result[behaviorType] or 0) + amount
        end
    end
    return result
end

local function fallbackDecision(reason, assignment)
    return {
        adjustment = "keep",
        payload = { adjustment = "keep" },
        diagnostics = { fallback = true, reason = reason },
        assignment = assignment,
        isFallback = true,
    }
end

function DDA.New(options)
    options = options or {}
    local executor = assert(options.executor, "DDA executor is required")
    local storageKey = assert(options.storageKey, "DDA storageKey is required")
    local windowSize = tonumber(options.recentWindowSize) or 10
    if windowSize % 1 ~= 0 or windowSize < 1 or windowSize > 100 then
        error("DDA recentWindowSize must be an integer between 1 and 100")
    end

    local state = emptyState()
    if type(options.storageGet) == "function" then
        local ok, encoded = pcall(options.storageGet, storageKey)
        if ok and encoded and encoded ~= "" then
            local decoded, value = pcall(cjson.decode, encoded)
            if decoded then state = normalizeState(value) end
        end
    end
    while #state.recentSteps > windowSize do table.remove(state.recentSteps, 1) end

    local function persist()
        if type(options.storageSet) ~= "function" then return end
        local encoded, value = pcall(cjson.encode, state)
        if encoded then pcall(options.storageSet, storageKey, value) end
    end

    local controller = {}

    function controller.RecordBehavior(behaviorType, amount)
        behaviorType = tostring(behaviorType or "")
        if behaviorType == "" then error("DDA behavior type is required") end
        if #behaviorType > 128 then error("DDA behavior type must be at most 128 characters") end
        if amount == nil then amount = 1 else amount = tonumber(amount) end
        if not amount or amount ~= amount or amount == math.huge or amount == -math.huge or amount <= 0 then
            error("DDA behavior amount must be a finite number greater than 0")
        end
        state.current[behaviorType] = (state.current[behaviorType] or 0) + amount
        state.lifetime[behaviorType] = (state.lifetime[behaviorType] or 0) + amount
        persist()
    end

    function controller.CompleteStep(stepId)
        table.insert(state.recentSteps, {
            stepId = stepId and tostring(stepId) or nil,
            behaviors = copyCounts(state.current),
        })
        while #state.recentSteps > windowSize do table.remove(state.recentSteps, 1) end
        state.current = {}
        state.completedSteps = state.completedSteps + 1
        persist()
    end

    function controller.Reset(scope)
        scope = scope or "all"
        if scope == "all" then
            state = emptyState()
        elseif scope == "current" then
            state.current = {}
        elseif scope == "recent" then
            state.recentSteps = {}
        else
            error("unsupported DDA reset scope: " .. tostring(scope))
        end
        persist()
    end

    function controller.Snapshot(context)
        local recentSteps = {}
        for _, step in ipairs(state.recentSteps) do
            table.insert(recentSteps, {
                stepId = step.stepId,
                behaviors = copyCounts(step.behaviors),
            })
        end
        return {
            context = type(context) == "table" and context or {},
            behavior = {
                current = copyCounts(state.current),
                recent = aggregateRecent(state.recentSteps),
                lifetime = copyCounts(state.lifetime),
                recentSteps = recentSteps,
                completedSteps = state.completedSteps,
                windowSize = windowSize,
            },
        }
    end

    function controller.Decide(context)
        local ok, result = pcall(executor.Execute, controller.Snapshot(context))
        if not ok or type(result) ~= "table" then return fallbackDecision(ok and "executor_not_ready" or "execution_failed") end
        local payload = result.payload
        local adjustment = type(payload) == "table" and payload.adjustment or nil
        if adjustment ~= "increase" and adjustment ~= "keep" and adjustment ~= "decrease" then
            return fallbackDecision("invalid_adjustment", result.assignment)
        end
        return {
            adjustment = adjustment,
            payload = payload,
            diagnostics = result.diagnostics or {},
            assignment = result.assignment,
            isFallback = false,
        }
    end

    return controller
end

return DDA
