package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public final class GameAlgoEventTracker implements AutoCloseable {
    private final GameAlgoClient client;
    private final int maxBatchSize;
    private final int queueLimit;
    private final long flushIntervalMillis;

    private String userId;
    private String sessionId = UUID.randomUUID().toString();
    private String contextId;
    private String timezone = TimeZone.getDefault().getID();
    private String userCreatedAt;
    private boolean isDebug;
    private long sessionStartMillis;
    private final List<GameAlgoEvent> queue = new ArrayList<>();
    private final List<GameAlgoEvent> retryBatch = new ArrayList<>();
    private ScheduledExecutorService scheduler;
    private boolean flushing;

    GameAlgoEventTracker(GameAlgoClient client) {
        this(client, 100, 1000, 30000L);
    }

    GameAlgoEventTracker(GameAlgoClient client, int maxBatchSize, int queueLimit, long flushIntervalMillis) {
        this.client = client;
        this.maxBatchSize = Math.max(1, Math.min(maxBatchSize, 100));
        this.queueLimit = Math.max(queueLimit, this.maxBatchSize);
        this.flushIntervalMillis = flushIntervalMillis;
    }

    public synchronized void identify(String userId) {
        if (!isBlank(userId)) {
            this.userId = userId;
        }
    }

    public synchronized void identify(String userId, String sessionId) {
        identify(userId, sessionId, null);
    }

    public synchronized void identify(String userId, String sessionId, String userCreatedAt) {
        identify(userId);
        if (!isBlank(sessionId)) {
            this.sessionId = sessionId;
        }
        if (!isBlank(userCreatedAt)) {
            this.userCreatedAt = userCreatedAt;
        }
    }

    public synchronized void newSession() {
        sessionId = UUID.randomUUID().toString();
        contextId = null;
        sessionStartMillis = System.currentTimeMillis();
    }

    public synchronized String currentSessionId() {
        return sessionId;
    }

    public synchronized void setContextId(String contextId) {
        this.contextId = isBlank(contextId) ? null : contextId;
    }

    public synchronized void setDebug(boolean isDebug) {
        this.isDebug = isDebug;
    }

    public synchronized void setTimezone(String timezone) {
        this.timezone = isBlank(timezone) ? TimeZone.getDefault().getID() : timezone;
    }

    public synchronized void setAssignments(List<GameAlgoExperimentAssignment> assignments) {
        // Experiment assignments are captured in the SDK context log, not copied onto each event.
    }

    public synchronized void markSessionStarted() {
        sessionStartMillis = System.currentTimeMillis();
    }

    public boolean track(String eventType) {
        return track(eventType, new LinkedHashMap<String, Object>());
    }

    public boolean track(String eventType, Map<String, Object> payload) {
        return trackInternal(eventType, payload);
    }

    private boolean trackInternal(String eventType, Map<String, Object> payload) {
        String resolvedUserId;
        String resolvedSessionId;
        String resolvedContextId;
        boolean resolvedIsDebug;
        synchronized (this) {
            if (isBlank(userId)) {
                return false;
            }
            if (isBlank(contextId)) {
                return false;
            }
            resolvedUserId = userId;
            resolvedSessionId = sessionId;
            resolvedContextId = contextId;
            resolvedIsDebug = isDebug;
        }

        GameAlgoEvent event = new GameAlgoEvent(resolvedContextId, resolvedUserId, resolvedSessionId, eventType)
                .payload(normalizePayload(payload))
                .isDebug(resolvedIsDebug);
        enqueue(event);
        return true;
    }

    public boolean trackEvent(String type) {
        return trackEvent(type, new LinkedHashMap<String, Object>());
    }

    public boolean trackEvent(String type, Map<String, Object> payload) {
        String eventType = type != null && type.startsWith("_") ? type : "_" + type;
        return trackInternal(eventType, payload);
    }

    public boolean trackSessionStart() {
        markSessionStarted();
        return true;
    }

    public boolean trackSessionEnd() {
        return trackSessionEnd(new LinkedHashMap<String, Object>());
    }

    public boolean trackSessionEnd(Map<String, Object> payload) {
        Map<String, Object> merged = copyPayload(payload);
        synchronized (this) {
            if (sessionStartMillis > 0L) {
                merged.put("sessionDurationMs", System.currentTimeMillis() - sessionStartMillis);
            }
        }
        return track("session_end", merged);
    }

    public boolean trackConfigLoaded() {
        return track("config_loaded");
    }

    public boolean trackLevelStart(Map<String, Object> payload) {
        return track("level_start", payload);
    }

    public boolean trackLevelEnd(Map<String, Object> payload) {
        return track("level_end", payload);
    }

    public boolean trackAdView(double cpm, String placement) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("cpm", cpm);
        if (!isBlank(placement)) {
            payload.put("placement", placement);
        }
        return track("ad_view", payload);
    }

    public boolean trackPurchase(String productId, Double revenue, String currency, Map<String, Object> payload) {
        Map<String, Object> merged = copyPayload(payload);
        if (!isBlank(productId)) {
            merged.put("productId", productId);
        }
        if (revenue != null) {
            merged.put("revenue", revenue);
        }
        if (!isBlank(currency)) {
            merged.put("currency", currency);
        }
        return track("purchase", merged);
    }

    public boolean gameStart(Map<String, Object> payload) {
        return track("game_start", payload);
    }

    public boolean gameOver(Map<String, Object> payload) {
        return track("game_over", payload);
    }

    public boolean move(Map<String, Object> payload) {
        return track("move", payload);
    }

    public boolean replay(Map<String, Object> payload) {
        return track("replay", payload);
    }

    public boolean quit(Map<String, Object> payload) {
        return track("quit", payload);
    }

    public void flush() throws GameAlgoException {
        synchronized (this) {
            if (flushing) {
                return;
            }
            flushing = true;
        }

        try {
            while (true) {
                List<GameAlgoEvent> batch;
                synchronized (this) {
                    if (retryBatch.isEmpty() && queue.isEmpty()) {
                        return;
                    }
                    List<GameAlgoEvent> pending = new ArrayList<>(retryBatch.size() + queue.size());
                    pending.addAll(retryBatch);
                    pending.addAll(queue);
                    int end = Math.min(maxBatchSize, pending.size());
                    batch = new ArrayList<>(pending.subList(0, end));
                    retryBatch.clear();
                    queue.clear();
                    if (end < pending.size()) {
                        queue.addAll(pending.subList(end, pending.size()));
                    }
                }

                try {
                    client.uploadEvents(batch);
                } catch (GameAlgoException error) {
                    synchronized (this) {
                        retryBatch.clear();
                        retryBatch.addAll(batch);
                    }
                    throw error;
                }
            }
        } finally {
            synchronized (this) {
                flushing = false;
            }
        }
    }

    public void flushAsync() {
        ensureScheduler();
        scheduler.execute(() -> {
            try {
                flush();
            } catch (GameAlgoException ignored) {
                // Keep the failed batch for the next flush.
            }
        });
    }

    @Override
    public synchronized void close() {
        if (scheduler != null) {
            scheduler.shutdownNow();
            scheduler = null;
        }
    }

    private void enqueue(GameAlgoEvent event) {
        boolean shouldFlush;
        synchronized (this) {
            queue.add(event);
            if (queue.size() > queueLimit) {
                queue.subList(0, queue.size() - queueLimit).clear();
            }
            ensureScheduler();
            shouldFlush = queue.size() >= maxBatchSize;
        }
        if (shouldFlush) {
            flushAsync();
        }
    }

    private synchronized void ensureScheduler() {
        if (scheduler != null) {
            return;
        }
        scheduler = Executors.newSingleThreadScheduledExecutor(runnable -> {
            Thread thread = new Thread(runnable, "GameAlgoEventTracker");
            thread.setDaemon(true);
            return thread;
        });
        if (flushIntervalMillis > 0) {
            scheduler.scheduleWithFixedDelay(() -> {
                try {
                    flush();
                } catch (GameAlgoException ignored) {
                    // Keep the failed batch for the next flush.
                }
            }, flushIntervalMillis, flushIntervalMillis, TimeUnit.MILLISECONDS);
        }
    }

    private static Map<String, Object> copyPayload(Map<String, Object> payload) {
        return payload == null ? new LinkedHashMap<String, Object>() : new LinkedHashMap<>(payload);
    }

    private static Map<String, Object> normalizePayload(Map<String, Object> payload) {
        Map<String, Object> normalized = new LinkedHashMap<>();
        Map<String, Object> source = copyPayload(payload);
        for (Map.Entry<String, Object> entry : source.entrySet()) {
            String key = entry.getKey();
            if (isBlank(key)) {
                continue;
            }
            Object value = entry.getValue();
            Object normalizedValue = payloadValue(value);
            if (normalizedValue != null || value == null) {
                normalized.put(key, normalizedValue);
            }
        }
        return normalized;
    }

    private static Object payloadValue(Object value) {
        if (value == null || value instanceof String || value instanceof Boolean) {
            return value;
        }
        if (value instanceof Number) {
            return isFiniteNumber((Number) value) ? value : null;
        }
        try {
            return GameAlgoJson.stringify(value);
        } catch (GameAlgoException ignored) {
            return null;
        }
    }

    private static boolean isFiniteNumber(Number value) {
        double doubleValue = value.doubleValue();
        return !Double.isNaN(doubleValue) && !Double.isInfinite(doubleValue);
    }

    private static boolean isBlank(String value) {
        return value == null || value.length() == 0;
    }

}
