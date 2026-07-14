package com.gamealgo.sdk;

public enum GameAlgoDDAAdjustment {
    INCREASE("increase"),
    KEEP("keep"),
    DECREASE("decrease");

    private final String value;

    GameAlgoDDAAdjustment(String value) {
        this.value = value;
    }

    public String getValue() {
        return value;
    }

    static GameAlgoDDAAdjustment fromValue(Object value) {
        if (!(value instanceof String)) return null;
        for (GameAlgoDDAAdjustment adjustment : values()) {
            if (adjustment.value.equals(value)) return adjustment;
        }
        return null;
    }
}
