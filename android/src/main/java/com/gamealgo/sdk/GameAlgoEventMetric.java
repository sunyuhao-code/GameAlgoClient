package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoEventMetric {
    private final String key;
    private final double value;

    public GameAlgoEventMetric(String key, double value) {
        this.key = key;
        this.value = value;
    }

    public String getKey() {
        return key;
    }

    public double getValue() {
        return value;
    }

    Map<String, Object> toJson() {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("key", key);
        object.put("value", value);
        return object;
    }
}
