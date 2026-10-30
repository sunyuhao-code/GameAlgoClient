package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** One durable record owns pending events and the unfinished session marker. */
final class GameAlgoLifecycleJournal {
    private final GameAlgoCacheStorage storage;
    private final String key;
    private final int queueLimit;
    private final Map<String, GameAlgoEvent> events = new LinkedHashMap<>();
    private final Map<String, String> configRequests = new LinkedHashMap<>();
    private Map<String, Object> session;
    private boolean active;
    private boolean foreground;
    private boolean durable;
    private long sampleAt;
    private boolean sampleForeground;

    GameAlgoLifecycleJournal(GameAlgoCacheStorage storage, String key, boolean foreground, int queueLimit) {
        this.storage = storage;
        this.key = key;
        this.queueLimit = queueLimit;
        this.foreground = foreground;
        if (storage == null || key == null) return;
        try {
            String raw = storage.getItem(key);
            if (raw == null) return;
            Map<String, Object> value = GameAlgoJson.asObject(GameAlgoJson.parse(raw), "lifecycle journal");
            Object savedEvents = value.get("events");
            if (savedEvents instanceof List) {
                for (Object item : (List<?>) savedEvents) {
                    GameAlgoEvent event = GameAlgoEvent.fromJson(GameAlgoJson.asObject(item, "event"));
                    events.put(event.getEventId(), event);
                }
            }
            if (value.get("session") instanceof Map) session = GameAlgoJson.asObject(value.get("session"), "session");
            if (value.get("configRequests") instanceof Map) {
                for (Map.Entry<String, Object> entry : GameAlgoJson.asObject(value.get("configRequests"), "config requests").entrySet()) {
                    if (entry.getValue() instanceof String) configRequests.put(entry.getKey(), (String) entry.getValue());
                }
            }
        } catch (GameAlgoException ignored) { /* A malformed journal must not prevent startup. */ }
    }

    synchronized void activate(GameAlgoEvent template, long startedAt, boolean hasEnd, List<GameAlgoEvent> pending) {
        merge(pending);
        if (!active && session != null && Boolean.TRUE.equals(session.get("open"))) {
            GameAlgoEvent recovered = end("process_restart", number("lastSeenMs"), true);
            if (recovered != null) events.put(recovered.getEventId(), recovered);
        }
        if (!active || session == null || !template.getSessionId().equals(session.get("sessionId"))) {
            session = new LinkedHashMap<>();
            session.put("sessionId", template.getSessionId());
            session.put("startedAtMs", startedAt);
            session.put("durationMs", 0L);
            sampleAt = startedAt;
            sampleForeground = foreground;
            session.put("lastSeenMs", startedAt);
            session.put("open", foreground);
            session.put("hasEnd", hasEnd);
            session.put("eventId", UUID.randomUUID().toString());
            session.put("timestamp", GameAlgoClient.isoTimestamp(new Date(startedAt)));
            session.put("createdLocalAt", GameAlgoClient.localTimestamp(new Date(startedAt)));
        }
        if (number("startedAtMs") != startedAt) {
            session.put("durationMs", 0L);
            sampleAt = startedAt;
        }
        session.put("startedAtMs", startedAt);
        Date start = new Date(startedAt);
        session.put("event", template.toJson(GameAlgoClient.isoTimestamp(start), GameAlgoClient.localTimestamp(start)));
        active = true;
        persist();
    }

    synchronized void record(GameAlgoEvent event) {
        events.put(event.getEventId(), event);
        if (session != null && event.getSessionId().equals(session.get("sessionId")) && "session_end".equals(event.getEventType())) {
            session.put("open", false);
            session.put("hasEnd", true);
        }
        persist();
    }

    synchronized void observe(boolean nextForeground, long now) {
        sample(nextForeground, now);
        boolean changed = foreground != nextForeground;
        foreground = nextForeground;
        if (!active || session == null) return;
        session.put("lastSeenMs", Math.max(now, number("startedAtMs")));
        session.put("timestamp", GameAlgoClient.isoTimestamp(new Date(now)));
        session.put("createdLocalAt", GameAlgoClient.localTimestamp(new Date(now)));
        if (changed && nextForeground) {
            session.put("open", true);
            session.put("eventId", UUID.randomUUID().toString());
        } else if (changed) {
            GameAlgoEvent ended = end("background", now, false);
            if (ended != null) events.put(ended.getEventId(), ended);
            session.put("open", false);
            session.put("hasEnd", true);
        }
        persist();
    }

    /** Memory only; the caller reads current OS visibility on every tick. */
    synchronized void sample(boolean currentForeground, long now) {
        if (!active || session == null) return;
        if (currentForeground && sampleForeground) {
            session.put("durationMs", number("durationMs") + Math.min(1000L, Math.max(0L, now - sampleAt)));
        }
        if (currentForeground) session.put("lastSeenMs", Math.max(now, number("startedAtMs")));
        sampleAt = now;
        sampleForeground = currentForeground;
    }

    synchronized long duration(String sessionId) {
        return active && session != null && sessionId.equals(session.get("sessionId")) ? number("durationMs") : 0L;
    }

    synchronized void bind(String sessionId, String contextId) {
        for (Map.Entry<String, GameAlgoEvent> entry : events.entrySet()) {
            GameAlgoEvent event = entry.getValue();
            if (sessionId.equals(event.getSessionId()) && blank(event.getContextId())) entry.setValue(event.withContextId(contextId));
        }
        configRequests.remove(sessionId);
        persist();
    }

    synchronized void retainConfig(String sessionId, String body) { configRequests.put(sessionId, body); persist(); }
    synchronized Map<String, String> unboundConfigs() {
        Map<String, String> result = new LinkedHashMap<>();
        for (GameAlgoEvent event : events.values()) {
            if (blank(event.getContextId()) && configRequests.containsKey(event.getSessionId())) result.put(event.getSessionId(), configRequests.get(event.getSessionId()));
        }
        return result;
    }

    synchronized List<GameAlgoEvent> pending() { return new ArrayList<>(events.values()); }
    synchronized boolean isDurable() { return durable; }

    synchronized boolean hasEnd(String sessionId) {
        return session != null && sessionId.equals(session.get("sessionId")) && Boolean.TRUE.equals(session.get("hasEnd"));
    }

    synchronized void mergePending(List<GameAlgoEvent> pending) { merge(pending); persist(); }

    synchronized void acknowledge(List<GameAlgoEvent> batch) {
        for (GameAlgoEvent event : batch) events.remove(event.getEventId());
        persist();
    }

    private void merge(List<GameAlgoEvent> pending) {
        for (GameAlgoEvent event : pending) events.put(event.getEventId(), event);
    }

    private GameAlgoEvent end(String reason, long at, boolean recovered) {
        try {
            GameAlgoEvent template = GameAlgoEvent.fromJson(GameAlgoJson.asObject(session.get("event"), "session event"));
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("reason", reason);
            payload.put("recovered", recovered);
            payload.put("endTimeEstimated", recovered);
            payload.put("sessionDurationMs", session.containsKey("durationMs") ? number("durationMs") : Math.max(0L, number("lastSeenMs") - number("startedAtMs")));
            Date date = new Date(at);
            return template.eventId((String) session.get("eventId")).payload(payload)
                    .timestamp(recovered && session.get("timestamp") instanceof String ? (String) session.get("timestamp") : GameAlgoClient.isoTimestamp(date))
                    .createdLocalAt(recovered && session.get("createdLocalAt") instanceof String ? (String) session.get("createdLocalAt") : GameAlgoClient.localTimestamp(date));
        } catch (GameAlgoException ignored) { return null; }
    }

    private long number(String name) { Object value = session.get(name); return value instanceof Number ? ((Number) value).longValue() : 0L; }
    private static boolean blank(String value) { return value == null || value.trim().isEmpty(); }

    private void persist() {
        while (events.size() > queueLimit) events.remove(events.keySet().iterator().next());
        java.util.Set<String> sessions = new java.util.HashSet<>();
        for (GameAlgoEvent event : events.values()) sessions.add(event.getSessionId());
        if (session != null) sessions.add((String) session.get("sessionId"));
        configRequests.keySet().retainAll(sessions);
        durable = false;
        if (storage == null || key == null) return;
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("version", 1);
        List<Object> rows = new ArrayList<>();
        try {
            if (active && session != null) {
                Date observed = new Date(number("lastSeenMs"));
                session.put("timestamp", GameAlgoClient.isoTimestamp(observed));
                session.put("createdLocalAt", GameAlgoClient.localTimestamp(observed));
            }
            Date now = new Date();
            for (GameAlgoEvent event : events.values()) rows.add(event.toJson(GameAlgoClient.isoTimestamp(now), GameAlgoClient.localTimestamp(now)));
            value.put("events", rows);
            value.put("session", session);
            value.put("configRequests", configRequests);
            storage.setItem(key, GameAlgoJson.stringify(value));
            durable = true;
        } catch (GameAlgoException ignored) { /* Retain the in-memory state for the next write/flush. */ }
    }
}
