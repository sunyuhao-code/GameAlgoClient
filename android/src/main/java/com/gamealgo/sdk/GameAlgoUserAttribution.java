package com.gamealgo.sdk;

import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoUserAttribution {
    private final String provider;
    private final Map<String, Object> attribution;
    private String status = "attributed";
    private String userId;
    private String userCreatedAt;
    private String sessionId;
    private String contextId;
    private String platform;
    private String attributedAt;
    private String attributionHash;

    public GameAlgoUserAttribution(String provider, Map<String, Object> attribution) {
        this.provider = provider;
        this.attribution = attribution == null ? new LinkedHashMap<String, Object>() : new LinkedHashMap<>(attribution);
    }

    public GameAlgoUserAttribution status(String status) {
        this.status = status;
        return this;
    }

    public GameAlgoUserAttribution userId(String userId) {
        this.userId = userId;
        return this;
    }

    public GameAlgoUserAttribution userCreatedAt(String userCreatedAt) {
        this.userCreatedAt = userCreatedAt;
        return this;
    }

    public GameAlgoUserAttribution sessionId(String sessionId) {
        this.sessionId = sessionId;
        return this;
    }

    public GameAlgoUserAttribution contextId(String contextId) {
        this.contextId = contextId;
        return this;
    }

    public GameAlgoUserAttribution platform(String platform) {
        this.platform = platform;
        return this;
    }

    public GameAlgoUserAttribution attributedAt(String attributedAt) {
        this.attributedAt = attributedAt;
        return this;
    }

    public GameAlgoUserAttribution attributionHash(String attributionHash) {
        this.attributionHash = attributionHash;
        return this;
    }

    public String getProvider() {
        return provider;
    }

    public Map<String, Object> getAttribution() {
        return new LinkedHashMap<>(attribution);
    }

    public String getStatus() {
        return status;
    }

    public String getUserId() {
        return userId;
    }

    public String getUserCreatedAt() {
        return userCreatedAt;
    }

    public String getSessionId() {
        return sessionId;
    }

    public String getContextId() {
        return contextId;
    }

    public String getPlatform() {
        return platform;
    }

    public String getAttributedAt() {
        return attributedAt;
    }

    public String getAttributionHash() {
        return attributionHash;
    }
}
