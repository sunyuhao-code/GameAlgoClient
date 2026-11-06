package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Incremental durable records share a small unfinished-session marker. */
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
    private long foregroundTimeMs;
    private long sessionForegroundStartMs;
    private final java.util.Set<String> dirtyEvents = new java.util.LinkedHashSet<>();
    private final java.util.Set<String> removedEvents = new java.util.LinkedHashSet<>();
    private boolean configsDirty;
    private boolean journalReady = true;
    private long sequence;
    private int operations;
    private long formattedAt = Long.MIN_VALUE;

    GameAlgoLifecycleJournal(GameAlgoCacheStorage storage, String key, boolean foreground, int queueLimit) {
        this.storage = storage;
        this.key = key;
        this.queueLimit = queueLimit;
        this.foreground = foreground;
        if (storage == null || key == null) return;
        try {
            String raw = storage.getItem(key);
            if (raw != null) restore(GameAlgoJson.asObject(GameAlgoJson.parse(raw), "lifecycle journal"), false);
            if (storage instanceof GameAlgoJournalStorage) {
                for (String record : ((GameAlgoJournalStorage) storage).readJournalRecords(key)) {
                    Map<String,Object> value = GameAlgoJson.asObject(GameAlgoJson.parse(record), "journal record");
                    if (((Number) value.get("journalSequence")).longValue() > sequence) { restore(value, true); operations++; }
                }
            }
        } catch (GameAlgoException | RuntimeException ignored) { journalReady = false; }
    }

    private void restore(Map<String,Object> value, boolean incremental) throws GameAlgoException {
        Object saved = value.get(incremental ? "put" : "events");
        if (saved instanceof List) for (Object row : (List<?>) saved) {
            GameAlgoEvent event = GameAlgoEvent.fromJson(GameAlgoJson.asObject(row, "event"));
            events.put(event.getEventId(), event);
        }
        Object removed = value.get("remove");
        if (removed instanceof List) for (Object id : (List<?>) removed) events.remove(id);
        if (value.get("session") instanceof Map) session = GameAlgoJson.asObject(value.get("session"), "session");
        if (value.get("configRequests") instanceof Map) {
            configRequests.clear();
            for (Map.Entry<String,Object> entry : GameAlgoJson.asObject(value.get("configRequests"), "config requests").entrySet()) {
                if (entry.getValue() instanceof String) configRequests.put(entry.getKey(), (String) entry.getValue());
            }
        }
        if (value.get("journalSequence") instanceof Number) sequence = ((Number)value.get("journalSequence")).longValue();
    }

    synchronized void activate(GameAlgoEvent template, long startedAt, boolean hasEnd, List<GameAlgoEvent> pending) {
        merge(pending);
        if (!active && session != null && Boolean.TRUE.equals(session.get("open"))) {
            GameAlgoEvent recovered = end("process_restart", number("lastSeenMs"), true);
            if (recovered != null) put(recovered);
        }
        if (!active || session == null || !template.getSessionId().equals(session.get("sessionId"))) {
            session = new LinkedHashMap<>();
            session.put("sessionId", template.getSessionId());
            session.put("startedAtMs", startedAt);
            session.put("durationMs", 0L);
            sessionForegroundStartMs = foregroundTimeMs;
            sampleAt = startedAt;
            if (!active) sampleForeground = foreground;
            session.put("lastSeenMs", startedAt);
            session.put("open", foreground);
            session.put("hasEnd", hasEnd);
            session.put("eventId", UUID.randomUUID().toString());
            session.put("timestamp", GameAlgoClient.isoTimestamp(new Date(startedAt)));
            session.put("createdLocalAt", GameAlgoClient.localTimestamp(new Date(startedAt)));
        }
        if (number("startedAtMs") != startedAt) {
            session.put("durationMs", 0L);
            sessionForegroundStartMs = foregroundTimeMs;
            sampleAt = startedAt;
        }
        session.put("startedAtMs", startedAt);
        Date start = new Date(startedAt);
        session.put("event", template.toJson(GameAlgoClient.isoTimestamp(start), GameAlgoClient.localTimestamp(start)));
        active = true;
        persist();
    }

    synchronized void record(GameAlgoEvent event) {
        put(event);
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
            if (ended != null) put(ended);
            session.put("open", false);
            session.put("hasEnd", true);
        }
        persist();
    }

    /** Memory only; the caller reads current OS visibility on every tick. */
    synchronized void sample(boolean currentForeground, long now) {
        if (!active || session == null) return;
        if (currentForeground && sampleForeground) {
            foregroundTimeMs += Math.min(1000L, Math.max(0L, now - sampleAt));
        }
        session.put("durationMs", Math.max(0L, foregroundTimeMs - sessionForegroundStartMs));
        if (currentForeground) session.put("lastSeenMs", Math.max(now, number("startedAtMs")));
        sampleAt = now;
        sampleForeground = currentForeground;
    }

    synchronized long duration(String sessionId) {
        return active && session != null && sessionId.equals(session.get("sessionId")) ? Math.max(0L, foregroundTimeMs - sessionForegroundStartMs) : 0L;
    }

    synchronized long getForegroundTimeMs() { return foregroundTimeMs; }

    synchronized void bind(String sessionId, String contextId) {
        for (Map.Entry<String, GameAlgoEvent> entry : events.entrySet()) {
            GameAlgoEvent event = entry.getValue();
            if (sessionId.equals(event.getSessionId()) && blank(event.getContextId())) { entry.setValue(event.withContextId(contextId)); dirtyEvents.add(event.getEventId()); }
        }
        configsDirty |= configRequests.remove(sessionId) != null;
        persist();
    }

    synchronized void retainConfig(String sessionId, String body) { configRequests.put(sessionId, body); configsDirty = true; persist(); }
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
        for (GameAlgoEvent event : batch) remove(event.getEventId());
        persist();
    }

    private void merge(List<GameAlgoEvent> pending) {
        for (GameAlgoEvent event : pending) if (events.get(event.getEventId()) != event) put(event);
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

    private void put(GameAlgoEvent event) {
        events.put(event.getEventId(), event);
        dirtyEvents.add(event.getEventId());
        removedEvents.remove(event.getEventId());
    }

    private void remove(String id) {
        if (events.remove(id) != null) removedEvents.add(id);
        dirtyEvents.remove(id);
    }

    private Map<String,Object> eventJson(GameAlgoEvent event) {
        Date now = new Date();
        return event.toJson(event.getTimestamp() == null ? GameAlgoClient.isoTimestamp(now) : event.getTimestamp(),
                event.getCreatedLocalAt() == null ? GameAlgoClient.localTimestamp(now) : event.getCreatedLocalAt());
    }

    private Map<String,Object> snapshot() {
        Map<String,Object> value = new LinkedHashMap<>();
        value.put("version", 2); value.put("journalSequence", sequence);
        List<Object> rows = new ArrayList<>();
        for (GameAlgoEvent event : events.values()) rows.add(eventJson(event));
        value.put("events", rows); value.put("session", session); value.put("configRequests", configRequests);
        return value;
    }

    private void persist() {
        while (events.size() > queueLimit) remove(events.keySet().iterator().next());
        if (!removedEvents.isEmpty()) {
            java.util.Set<String> sessions = new java.util.HashSet<>();
            for (GameAlgoEvent event : events.values()) sessions.add(event.getSessionId());
            if (session != null) sessions.add((String)session.get("sessionId"));
            configsDirty |= configRequests.keySet().retainAll(sessions);
        }
        durable = false;
        if (storage == null || key == null || !journalReady) return;
        try {
            if (active && session != null && formattedAt != number("lastSeenMs")) {
                Date observed = new Date(number("lastSeenMs"));
                session.put("timestamp", GameAlgoClient.isoTimestamp(observed));
                session.put("createdLocalAt", GameAlgoClient.localTimestamp(observed));
                formattedAt = number("lastSeenMs");
            }
            if (storage instanceof GameAlgoJournalStorage) {
                Map<String,Object> value = new LinkedHashMap<>();
                value.put("version", 2); value.put("journalSequence", ++sequence);
                List<Object> rows = new ArrayList<>();
                for (String id : dirtyEvents) if (events.containsKey(id)) rows.add(eventJson(events.get(id)));
                value.put("put", rows); value.put("remove", new ArrayList<>(removedEvents));
                value.put("session", session);
                if (configsDirty) value.put("configRequests", configRequests);
                GameAlgoJournalStorage journal = (GameAlgoJournalStorage)storage;
                journal.appendJournalRecord(key, sequence, GameAlgoJson.stringify(value));
                if (++operations >= 256) {
                    operations = 0;
                    try { journal.compactJournal(key, GameAlgoJson.stringify(snapshot())); }
                    catch (GameAlgoException ignored) { /* The incremental record is already committed. */ }
                }
            } else storage.setItem(key, GameAlgoJson.stringify(snapshot()));
            dirtyEvents.clear(); removedEvents.clear(); configsDirty = false;
            durable = true;
        } catch (GameAlgoException ignored) { /* Retry all uncommitted changes on the next write. */ }
    }
}
