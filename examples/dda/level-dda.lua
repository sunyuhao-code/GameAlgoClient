return function(input)
    local behavior = (input.state and input.state.behavior) or {}
    local recent = behavior.recent or {}
    local recentSteps = behavior.recentSteps or {}
    local config = input.config or {}
    local weights = config.behaviorWeights or {
        level_failed = 1,
        level_retry = 0.75,
        item_used = 0.25,
        mistake = 0.5,
    }

    local friction = 0
    for behaviorType, weight in pairs(weights) do
        friction = friction + (tonumber(recent[behaviorType]) or 0) * (tonumber(weight) or 0)
    end
    local recentStepCount = #recentSteps
    local frictionPerStep = friction / math.max(1, recentStepCount)
    local minRecentSteps = tonumber(config.minRecentSteps) or 3
    local decreaseThreshold = tonumber(config.decreaseThreshold) or 0.8
    local increaseThreshold = tonumber(config.increaseThreshold) or 0

    local adjustment = "keep"
    if recentStepCount >= minRecentSteps then
        if frictionPerStep >= decreaseThreshold then
            adjustment = "decrease"
        elseif frictionPerStep <= increaseThreshold then
            adjustment = "increase"
        end
    end

    return {
        payload = { adjustment = adjustment },
        diagnostics = {
            friction = friction,
            frictionPerStep = frictionPerStep,
            recentStepCount = recentStepCount,
        },
    }
end
