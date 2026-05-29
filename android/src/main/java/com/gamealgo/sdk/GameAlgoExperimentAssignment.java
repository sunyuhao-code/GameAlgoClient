package com.gamealgo.sdk;

public final class GameAlgoExperimentAssignment {
    private final String key;
    private final String experimentId;
    private final String variant;
    private final Object config;
    private final GameAlgoConfigFileRef script;

    GameAlgoExperimentAssignment(String key, String experimentId, String variant, Object config, GameAlgoConfigFileRef script) {
        this.key = key;
        this.experimentId = experimentId;
        this.variant = variant;
        this.config = config;
        this.script = script;
    }

    public String getKey() {
        return key;
    }

    public String getExperimentId() {
        return experimentId;
    }

    public String getVariant() {
        return variant;
    }

    public Object getConfig() {
        return config;
    }

    public GameAlgoConfigFileRef getScript() {
        return script;
    }
}
