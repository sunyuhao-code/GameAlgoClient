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
    private String createdLocalAt;
    private String accountUserId;
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

    public GameAlgoEvent createdLocalAt(String createdLocalAt) {
        this.createdLocalAt = createdLocalAt;
        return this;
    }

    public GameAlgoEvent accountUserId(String accountUserId) {
        this.accountUserId = accountUserId;
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

    public String getCreatedLocalAt() {
        return createdLocalAt;
    }

    public String getAccountUserId() {
        return accountUserId;
    }

    public Map<String, Object> getPayload() {
        return Collections.unmodifiableMap(payload);
    }

    GameAlgoEvent withContextId(String contextId) {
        return new GameAlgoEvent(contextId, userId, sessionId, eventType)
                .eventId(eventId)
                .isDebug(isDebug)
                .timestamp(timestamp)
                .createdLocalAt(createdLocalAt)
                .accountUserId(accountUserId)
                .payload(payload);
    }

    Map<String, Object> toJson(String defaultTimestamp, String defaultCreatedLocalAt) {
        Map<String, Object> object = new LinkedHashMap<>();
        object.put("eventId", isBlank(eventId) ? java.util.UUID.randomUUID().toString() : eventId);
        object.put("contextId", contextId);
        object.put("userId", userId);
        object.put("sessionId", sessionId);
        object.put("eventType", eventType);
        object.put("isDebug", isDebug == null ? Boolean.FALSE : isDebug);
        object.put("timestamp", isBlank(timestamp) ? defaultTimestamp : timestamp);
        object.put("createdLocalAt", isBlank(createdLocalAt) ? defaultCreatedLocalAt : createdLocalAt);
        if (!isBlank(accountUserId)) {
            object.put("accountUserId", accountUserId);
        }
        object.put("payload", payload);
        return object;
    }

    static GameAlgoEvent fromJson(Map<String, Object> object) throws GameAlgoException {
        GameAlgoEvent event = new GameAlgoEvent(
                GameAlgoJson.stringValue(object, "contextId", false),
                GameAlgoJson.stringValue(object, "userId", true),
                GameAlgoJson.stringValue(object, "sessionId", true),
                GameAlgoJson.stringValue(object, "eventType", true)
        );
        Object debug = object.get("isDebug");
        if (debug instanceof Boolean) event.isDebug((Boolean) debug);
        Object payload = object.get("payload");
        if (payload instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> values = (Map<String, Object>) payload;
            event.payload(values);
        }
        return event
                .eventId(GameAlgoJson.stringValue(object, "eventId", false))
                .timestamp(GameAlgoJson.stringValue(object, "timestamp", false))
                .createdLocalAt(GameAlgoJson.stringValue(object, "createdLocalAt", false))
                .accountUserId(GameAlgoJson.stringValue(object, "accountUserId", false));
    }

    private static boolean isBlank(String value) {
        return value == null || value.length() == 0;
    }
}
