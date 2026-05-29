package com.gamealgo.sdk;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoSnapshot {
    private final GameAlgoConfigResponse config;
    private final Map<String, GameAlgoConfigFile> configFiles;
    private final long updatedAtMillis;
    private final String userId;

    GameAlgoSnapshot() {
        this(null, new LinkedHashMap<String, GameAlgoConfigFile>(), 0, null);
    }

    GameAlgoSnapshot(GameAlgoConfigResponse config, Map<String, GameAlgoConfigFile> configFiles, long updatedAtMillis, String userId) {
        this.config = config;
        this.configFiles = Collections.unmodifiableMap(new LinkedHashMap<>(configFiles));
        this.updatedAtMillis = updatedAtMillis;
        this.userId = userId;
    }

    public GameAlgoConfigResponse getConfig() {
        return config;
    }

    public Map<String, GameAlgoConfigFile> getConfigFiles() {
        return configFiles;
    }

    public long getUpdatedAtMillis() {
        return updatedAtMillis;
    }

    public String getUserId() {
        return userId;
    }
}
