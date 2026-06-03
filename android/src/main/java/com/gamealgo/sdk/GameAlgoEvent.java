package com.gamealgo.sdk;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public final class GameAlgoEvent {
    private String eventId;
    private final String contextId;
    private final String userId;
    private final String sessionId;
    private final String eventType;
    private Boolean isDebug;
    private String timestamp;
    private Map<String, Object> payload;

    public GameAlgoEvent(String contextId, String userId, String sessionId, String eventType) {
        this.contextId = contextId;
        this.userId = userId;
        this.sessionId = sessionId;
        this.eventType = eventType;
        this.payload = new LinkedHashMap<>();
    }

    public GameAlgoEvent eventId(String eventId) {
        this.eventId = eventId;
        return this;
    }

    public GameAlgoEvent isDebug(Boolean isDebug) {
        this.isDebug = isDebug;
        return this;
    }

    public GameAlgoEvent timestamp(String timestamp) {
        this.timestamp = timestamp;
        return this;
    }

    public GameAlgoEvent payload(Map<String, Object> payload) {
        this.payload = payload == null ? new LinkedHashMap<String, Object>() : new LinkedHashMap<>(payload);
        return this;
    }

    public String getEventId() {
        return eventId;
    }

    public String getContextId() {
        return contextId;
    }

    public String getUserId() {
        return userId;
    }

    public String getSessionId() {
        return sessionId;
    }

    public String getEventType() {
        return eventType;
    }

    public Boolean getIsDebug() {
        return isDebug;
    }

    public String getTimestamp() {
        return timestamp;
    }

    public Map<String, Object> getPayload() {
        return Collections.unmodifiableMap(payload);
    }

    Map<String, Object> toJson(String defaultTimestamp) {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("eventId", isBlank(eventId) ? java.util.UUID.randomUUID().toString() : eventId);
        object.put("contextId", contextId);
        object.put("userId", userId);
        object.put("sessionId", sessionId);
        object.put("eventType", eventType);
        object.put("isDebug", isDebug == null ? Boolean.FALSE : isDebug);
        object.put("timestamp", isBlank(timestamp) ? defaultTimestamp : timestamp);
        object.put("payload", payload);
        return object;
    }

    private static boolean isBlank(String value) {
        return value == null || value.length() == 0;
    }
}
