package com.gamealgo.sdk;

import java.util.Collections;
import java.util.List;

public final class GameAlgoConfigResponse {
    private final String contextId;
    private final String gameId;
    private final String environment;
    private final String configVersion;
    private final int ttlSeconds;
    private final String serverTime;
    private final List<GameAlgoExperimentAssignment> experiments;
    private final List<GameAlgoConfigFileRef> configFiles;

    GameAlgoConfigResponse(
            String contextId,
            String gameId,
            String environment,
            String configVersion,
            int ttlSeconds,
            String serverTime,
            List<GameAlgoExperimentAssignment> experiments,
            List<GameAlgoConfigFileRef> configFiles) {
        this.contextId = contextId;
        this.gameId = gameId;
        this.environment = environment;
        this.configVersion = configVersion;
        this.ttlSeconds = ttlSeconds;
        this.serverTime = serverTime;
        this.experiments = Collections.unmodifiableList(experiments);
        this.configFiles = Collections.unmodifiableList(configFiles);
    }

    public String getContextId() {
        return contextId;
    }

    public String getGameId() {
        return gameId;
    }

    public String getEnvironment() {
        return environment;
    }

    public String getConfigVersion() {
        return configVersion;
    }

    public int getTtlSeconds() {
        return ttlSeconds;
    }

    public String getServerTime() {
        return serverTime;
    }

    public List<GameAlgoExperimentAssignment> getExperiments() {
        return experiments;
    }

    public List<GameAlgoConfigFileRef> getConfigFiles() {
        return configFiles;
    }
}
