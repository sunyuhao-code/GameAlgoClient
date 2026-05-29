package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoScriptInput {
    private final Object state;
    private final Object config;
    private final Map<String, Object> meta;

    GameAlgoScriptInput(Object state, Object config, Map<String, Object> meta) {
        this.state = state;
        this.config = config;
        this.meta = meta;
    }

    public Object getState() {
        return state;
    }

    public Object getConfig() {
        return config;
    }

    public Map<String, Object> getMeta() {
        return meta;
    }

    public Map<String, Object> toJson() {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("state", state);
        object.put("config", config);
        object.put("meta", meta);
        return object;
    }
}
