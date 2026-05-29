package com.gamealgo.sdk;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoExperimentExecutor {
    private final String key;
    private final GameAlgoSnapshotStore store;
    private final GameAlgoScriptRuntime scriptRuntime;

    GameAlgoExperimentExecutor(String key, GameAlgoSnapshotStore store, GameAlgoScriptRuntime scriptRuntime) {
        this.key = key;
        this.store = store;
        this.scriptRuntime = scriptRuntime;
    }

    public boolean isReady() {
        return assignment() != null;
    }

    public GameAlgoExperimentAssignment assignment() {
        GameAlgoConfigResponse config = store.snapshot().getConfig();
        if (config == null) {
            return null;
        }
        for (GameAlgoExperimentAssignment assignment : config.getExperiments()) {
            if (key.equals(assignment.getKey())) {
                return assignment;
            }
        }
        return null;
    }

    public String variant(String defaultValue) {
        GameAlgoExperimentAssignment assignment = assignment();
        return assignment == null ? defaultValue : assignment.getVariant();
    }

    public Object config(Object defaultValue) {
        GameAlgoExperimentAssignment assignment = assignment();
        return assignment == null ? defaultValue : assignment.getConfig();
    }

    public Object value(String path, Object defaultValue) {
        GameAlgoExperimentAssignment assignment = assignment();
        if (assignment == null) {
            return defaultValue;
        }
        Object value = GameAlgoJson.readPath(assignment.getConfig(), path);
        return value == null ? defaultValue : value;
    }

    public String string(String path, String defaultValue) {
        Object value = value(path, defaultValue);
        return value instanceof String ? (String) value : defaultValue;
    }

    public int integer(String path, int defaultValue) {
        Object value = value(path, defaultValue);
        return value instanceof Number ? ((Number) value).intValue() : defaultValue;
    }

    public double number(String path, double defaultValue) {
        Object value = value(path, defaultValue);
        return value instanceof Number ? ((Number) value).doubleValue() : defaultValue;
    }

    public boolean bool(String path, boolean defaultValue) {
        Object value = value(path, defaultValue);
        return value instanceof Boolean ? (Boolean) value : defaultValue;
    }

    public GameAlgoExecutionResult execute(Object state) {
        GameAlgoSnapshot snapshot = store.snapshot();
        GameAlgoConfigResponse config = snapshot.getConfig();
        GameAlgoExperimentAssignment assignment = assignment();
        if (config == null || assignment == null) {
            return null;
        }

        if (assignment.getScript() == null) {
            Map<String, Object> diagnostics = new LinkedHashMap<>();
            diagnostics.put("mode", "config-only");
            return new GameAlgoExecutionResult(assignment.getConfig(), diagnostics, assignment);
        }

        GameAlgoConfigFile scriptFile = snapshot.getConfigFiles().get(assignment.getScript().getName());
        if (scriptFile == null) {
            return null;
        }
        if (assignment.getScript().getHash() == null || !assignment.getScript().getHash().equals(sha256(scriptFile.getContent()))) {
            return null;
        }

        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("gameId", config.getGameId());
        meta.put("userId", snapshot.getUserId() == null ? "" : snapshot.getUserId());
        meta.put("environment", config.getEnvironment());
        meta.put("strategy", assignment.getKey());
        meta.put("experimentId", assignment.getExperimentId());
        meta.put("variant", assignment.getVariant());

        try {
            Object output = scriptRuntime.execute(scriptFile.getContent(), new GameAlgoScriptInput(state, assignment.getConfig(), meta));
            if (!(output instanceof Map)) {
                return null;
            }
            @SuppressWarnings("unchecked")
            Map<String, Object> object = (Map<String, Object>) output;
            if (!object.containsKey("payload")) {
                return null;
            }
            Object diagnostics = object.containsKey("diagnostics") ? object.get("diagnostics") : new LinkedHashMap<String, Object>();
            return new GameAlgoExecutionResult(object.get("payload"), diagnostics, assignment);
        } catch (GameAlgoException error) {
            return null;
        }
    }

    private static String sha256(String content) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] bytes = digest.digest(content.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder builder = new StringBuilder("sha256:");
            for (byte value : bytes) {
                builder.append(String.format("%02x", value & 0xff));
            }
            return builder.toString();
        } catch (NoSuchAlgorithmException error) {
            return "";
        }
    }
}
