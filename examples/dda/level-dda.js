function execute(input) {
  const behavior = input.state?.behavior ?? {};
  const recent = behavior.recent ?? {};
  const recentSteps = behavior.recentSteps ?? [];
  const config = input.config ?? {};
  const weights = config.behaviorWeights ?? {
    level_failed: 1,
    level_retry: 0.75,
    item_used: 0.25,
    mistake: 0.5,
  };

  let friction = 0;
  for (const [type, weight] of Object.entries(weights)) {
    friction += Number(recent[type] ?? 0) * Number(weight ?? 0);
  }
  const frictionPerStep = friction / Math.max(1, recentSteps.length);
  const minRecentSteps = Number(config.minRecentSteps ?? 3);
  const decreaseThreshold = Number(config.decreaseThreshold ?? 0.8);
  const increaseThreshold = Number(config.increaseThreshold ?? 0);

  let adjustment = "keep";
  if (recentSteps.length >= minRecentSteps) {
    if (frictionPerStep >= decreaseThreshold) adjustment = "decrease";
    else if (frictionPerStep <= increaseThreshold) adjustment = "increase";
  }

  return {
    payload: { adjustment },
    diagnostics: {
      friction,
      frictionPerStep,
      recentStepCount: recentSteps.length,
    },
  };
}
