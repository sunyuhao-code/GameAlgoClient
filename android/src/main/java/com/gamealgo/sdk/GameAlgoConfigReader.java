package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.List;

public final class GameAlgoConfigReader {
    private final GameAlgoSnapshotStore store;

    GameAlgoConfigReader(GameAlgoSnapshotStore store) {
        this.store = store;
    }

    public GameAlgoConfigFile file(String name) {
        return store.snapshot().getConfigFiles().get(name);
    }

    public Object jsonFile(String name, Object defaultValue) {
        GameAlgoConfigFile file = file(name);
        if (file == null) {
            return defaultValue;
        }
        try {
            return GameAlgoJson.parse(file.getContent());
        } catch (GameAlgoException error) {
            return defaultValue;
        }
    }

    public Object value(String path, Object defaultValue) {
        return value(path, defaultValue, null);
    }

    public Object value(String path, Object defaultValue, String fileName) {
        Object source = jsonSource(fileName);
        if (source == null) {
            return defaultValue;
        }
        Object value = GameAlgoJson.readPath(source, path);
        return value == null ? defaultValue : value;
    }

    public String string(String path, String defaultValue) {
        return string(path, defaultValue, null);
    }

    public String string(String path, String defaultValue, String fileName) {
        Object value = value(path, defaultValue, fileName);
        return value instanceof String ? (String) value : defaultValue;
    }

    public int integer(String path, int defaultValue) {
        return integer(path, defaultValue, null);
    }

    public int integer(String path, int defaultValue, String fileName) {
        Object value = value(path, defaultValue, fileName);
        return value instanceof Number ? ((Number) value).intValue() : defaultValue;
    }

    public double number(String path, double defaultValue) {
        return number(path, defaultValue, null);
    }

    public double number(String path, double defaultValue, String fileName) {
        Object value = value(path, defaultValue, fileName);
        return value instanceof Number ? ((Number) value).doubleValue() : defaultValue;
    }

    public boolean bool(String path, boolean defaultValue) {
        return bool(path, defaultValue, null);
    }

    public boolean bool(String path, boolean defaultValue, String fileName) {
        Object value = value(path, defaultValue, fileName);
        return value instanceof Boolean ? (Boolean) value : defaultValue;
    }

    private Object jsonSource(String fileName) {
        if (fileName != null) {
            return jsonFile(fileName, null);
        }

        List<GameAlgoConfigFile> jsonFiles = new ArrayList<>();
        for (GameAlgoConfigFile file : store.snapshot().getConfigFiles().values()) {
            if (file.getContentType().contains("application/json") || file.getName().endsWith(".json")) {
                jsonFiles.add(file);
            }
        }
        if (jsonFiles.size() != 1) {
            return null;
        }

        try {
            return GameAlgoJson.parse(jsonFiles.get(0).getContent());
        } catch (GameAlgoException error) {
            return null;
        }
    }
}
