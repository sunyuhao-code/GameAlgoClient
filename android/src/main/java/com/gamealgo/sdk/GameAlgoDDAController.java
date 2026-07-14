package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class GameAlgoDDAController {
    private final GameAlgoExperimentExecutor executor;
    private final GameAlgoCacheStorage storage;
    private final String storageKey;
    private final int recentWindowSize;
    private final GameAlgoLogger logger;
    private Map<String, Double> current = new LinkedHashMap<>();
    private Map<String, Double> lifetime = new LinkedHashMap<>();
    private List<Step> recentSteps = new ArrayList<>();
    private int completedSteps;

    GameAlgoDDAController(
            GameAlgoExperimentExecutor executor,
            GameAlgoCacheStorage storage,
            String storageKey,
            int recentWindowSize,
            GameAlgoLogger logger) {
        if (recentWindowSize < 1 || recentWindowSize > 100) {
            throw new IllegalArgumentException("recentWindowSize must be between 1 and 100");
        }
        this.executor = executor;
        this.storage = storage;
        this.storageKey = storageKey;
        this.recentWindowSize = recentWindowSize;
        this.logger = logger;
        restore();
    }

    public synchronized void recordBehavior(String type) {
        recordBehavior(type, 1.0);
    }

    public synchronized void recordBehavior(String type, double amount) {
        String behaviorType = type == null ? "" : type.trim();
        if (behaviorType.length() == 0) throw new IllegalArgumentException("DDA behavior type is required");
        if (behaviorType.length() > 128) throw new IllegalArgumentException("DDA behavior type must be at most 128 characters");
        if (!Double.isFinite(amount) || amount <= 0) throw new IllegalArgumentException("DDA behavior amount must be greater than 0");
        current.put(behaviorType, current.containsKey(behaviorType) ? current.get(behaviorType) + amount : amount);
        lifetime.put(behaviorType, lifetime.containsKey(behaviorType) ? lifetime.get(behaviorType) + amount : amount);
        persist();
    }

    public synchronized void completeStep() {
        completeStep(null);
    }

    public synchronized void completeStep(String stepId) {
        recentSteps.add(new Step(clean(stepId), new LinkedHashMap<>(current)));
        while (recentSteps.size() > recentWindowSize) recentSteps.remove(0);
        current = new LinkedHashMap<>();
        completedSteps += 1;
        persist();
    }

    public synchronized void reset() {
        reset("all");
    }

    public synchronized void reset(String scope) {
        if ("all".equals(scope)) {
            current = new LinkedHashMap<>();
            lifetime = new LinkedHashMap<>();
            recentSteps = new ArrayList<>();
            completedSteps = 0;
        } else if ("current".equals(scope)) {
            current = new LinkedHashMap<>();
        } else if ("recent".equals(scope)) {
            recentSteps = new ArrayList<>();
        } else {
            throw new IllegalArgumentException("Unsupported DDA reset scope: " + scope);
        }
        persist();
    }

    public synchronized Map<String, Object> snapshot() {
        return snapshot(new LinkedHashMap<String, Object>());
    }

    public synchronized Map<String, Object> snapshot(Object context) {
        Map<String, Double> recent = new LinkedHashMap<>();
        List<Object> steps = new ArrayList<>();
        for (Step step : recentSteps) {
            Map<String, Object> encoded = new LinkedHashMap<>();
            if (step.stepId != null) encoded.put("stepId", step.stepId);
            encoded.put("behaviors", new LinkedHashMap<>(step.behaviors));
            steps.add(encoded);
            for (Map.Entry<String, Double> entry : step.behaviors.entrySet()) {
                recent.put(entry.getKey(), recent.containsKey(entry.getKey()) ? recent.get(entry.getKey()) + entry.getValue() : entry.getValue());
            }
        }
        Map<String, Object> behavior = new LinkedHashMap<>();
        behavior.put("current", new LinkedHashMap<>(current));
        behavior.put("recent", recent);
        behavior.put("lifetime", new LinkedHashMap<>(lifetime));
        behavior.put("recentSteps", steps);
        behavior.put("completedSteps", completedSteps);
        behavior.put("windowSize", recentWindowSize);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("context", context == null ? new LinkedHashMap<String, Object>() : context);
        result.put("behavior", behavior);
        return result;
    }

    public GameAlgoDDADecision decide() {
        return decide(new LinkedHashMap<String, Object>());
    }

    public GameAlgoDDADecision decide(Object context) {
        GameAlgoExecutionResult execution = executor.execute(snapshot(context));
        if (execution == null) return fallback("executor_not_ready", null);
        if (!(execution.getPayload() instanceof Map)) return fallback("invalid_adjustment", execution.getAssignment());
        @SuppressWarnings("unchecked")
        Map<String, Object> payload = (Map<String, Object>) execution.getPayload();
        GameAlgoDDAAdjustment adjustment = GameAlgoDDAAdjustment.fromValue(payload.get("adjustment"));
        if (adjustment == null) return fallback("invalid_adjustment", execution.getAssignment());
        return new GameAlgoDDADecision(adjustment, execution.getPayload(), execution.getDiagnostics(), execution.getAssignment(), false);
    }

    private synchronized void restore() {
        if (storage == null) return;
        try {
            String encoded = storage.getItem(storageKey);
            if (encoded == null || encoded.length() == 0) return;
            Map<String, Object> state = GameAlgoJson.asObject(GameAlgoJson.parse(encoded), "DDA state");
            current = counts(state.get("current"));
            lifetime = counts(state.get("lifetime"));
            Object rawCompleted = state.get("completedSteps");
            completedSteps = rawCompleted instanceof Number ? Math.max(0, ((Number) rawCompleted).intValue()) : 0;
            Object rawSteps = state.get("recentSteps");
            if (rawSteps instanceof List) {
                for (Object rawStep : (List<?>) rawSteps) {
                    if (!(rawStep instanceof Map)) continue;
                    @SuppressWarnings("unchecked")
                    Map<String, Object> step = (Map<String, Object>) rawStep;
                    recentSteps.add(new Step(clean(step.get("stepId")), counts(step.get("behaviors"))));
                }
            }
            while (recentSteps.size() > recentWindowSize) recentSteps.remove(0);
        } catch (Exception error) {
            log("DDA state load failed; using empty state: " + error.getMessage());
            current = new LinkedHashMap<>();
            lifetime = new LinkedHashMap<>();
            recentSteps = new ArrayList<>();
            completedSteps = 0;
        }
    }

    private synchronized void persist() {
        if (storage == null) return;
        Map<String, Object> state = new LinkedHashMap<>();
        state.put("schemaVersion", 1);
        state.put("current", current);
        state.put("lifetime", lifetime);
        List<Object> steps = new ArrayList<>();
        for (Step step : recentSteps) {
            Map<String, Object> encoded = new LinkedHashMap<>();
            if (step.stepId != null) encoded.put("stepId", step.stepId);
            encoded.put("behaviors", step.behaviors);
            steps.add(encoded);
        }
        state.put("recentSteps", steps);
        state.put("completedSteps", completedSteps);
        try {
            storage.setItem(storageKey, GameAlgoJson.stringify(state));
        } catch (GameAlgoException error) {
            log("DDA state save failed: " + error.getMessage());
        }
    }

    private GameAlgoDDADecision fallback(String reason, GameAlgoExperimentAssignment assignment) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("adjustment", "keep");
        Map<String, Object> diagnostics = new LinkedHashMap<>();
        diagnostics.put("fallback", true);
        diagnostics.put("reason", reason);
        return new GameAlgoDDADecision(GameAlgoDDAAdjustment.KEEP, payload, diagnostics, assignment, true);
    }

    private static Map<String, Double> counts(Object value) {
        Map<String, Double> result = new LinkedHashMap<>();
        if (!(value instanceof Map)) return result;
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
            if (entry.getKey() instanceof String && entry.getValue() instanceof Number) {
                double amount = ((Number) entry.getValue()).doubleValue();
                if (Double.isFinite(amount) && amount > 0) result.put((String) entry.getKey(), amount);
            }
        }
        return result;
    }

    private static String clean(Object value) {
        if (!(value instanceof String)) return null;
        String cleaned = ((String) value).trim();
        return cleaned.length() == 0 ? null : cleaned;
    }

    private void log(String message) {
        if (logger != null) logger.log("[GameAlgoSDK] " + message);
    }

    private static final class Step {
        private final String stepId;
        private final Map<String, Double> behaviors;

        private Step(String stepId, Map<String, Double> behaviors) {
            this.stepId = stepId;
            this.behaviors = behaviors;
        }
    }
}
