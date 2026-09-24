package com.gamealgo.sdk;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.UUID;
import java.text.SimpleDateFormat;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public final class GameAlgoEventTracker implements AutoCloseable {
    private static final Set<String> STANDARD_EVENT_TYPES = new HashSet<>(Arrays.asList(
            "session_end", "level_start", "level_end", "ad_view", "purchase", "milestone"));

    private static final class CustomCountBucket {
        int total;
        final Map<String, Integer> byType = new LinkedHashMap<>();
    }

    private static final class MilestoneDecision {
        final boolean duplicate;
        final String key;
        final boolean durable;

        MilestoneDecision(boolean duplicate, String key, boolean durable) {
            this.duplicate = duplicate;
            this.key = key;
            this.durable = durable;
        }
    }

    private final GameAlgoClient client;
    private final int maxBatchSize;
    private final int queueLimit;
    private final long flushIntervalMillis;
    private final GameAlgoCacheStorage storage;
    private final String persistenceKey;
    private final String milestonePersistenceKey;

    private String userId;
    private String sessionId = UUID.randomUUID().toString();
    private String contextId;
    private String timezone = TimeZone.getDefault().getID();
    private String userCreatedAt;
    private String accountUserId;
    private boolean isDebug;
    private long sessionStartMillis;
    private final List<GameAlgoEvent> queue = new ArrayList<>();
    private final List<GameAlgoEvent> retryBatch = new ArrayList<>();
    private ScheduledExecutorService scheduler;
    private boolean flushing;
    private int consecutiveFailures;
    private boolean hasPersistedQueue;
    private final Map<String, CustomCountBucket> customCounts = new LinkedHashMap<>();
    private final Set<String> diagnosticKeys = new HashSet<>();
    private int diagnosticCount;
    private final Set<String> reachedMilestoneKeys = new HashSet<>();
    private final Set<String> pendingMilestoneKeys = new HashSet<>();

    GameAlgoEventTracker(GameAlgoClient client) {
        this(client, 100, 1000, 30000L, null, null);
    }

    GameAlgoEventTracker(GameAlgoClient client, int maxBatchSize, int queueLimit, long flushIntervalMillis) {
        this(client, maxBatchSize, queueLimit, flushIntervalMillis, null, null);
    }

    GameAlgoEventTracker(
            GameAlgoClient client,
            int maxBatchSize,
            int queueLimit,
            long flushIntervalMillis,
            GameAlgoCacheStorage storage,
            String persistenceKey) {
        this.client = client;
        this.maxBatchSize = Math.max(1, Math.min(maxBatchSize, 100));
        this.queueLimit = Math.max(queueLimit, this.maxBatchSize);
        this.flushIntervalMillis = flushIntervalMillis;
        this.storage = storage;
        this.persistenceKey = persistenceKey;
        this.milestonePersistenceKey = isBlank(persistenceKey) ? null : persistenceKey + ":milestones";
        restorePersistedQueue();
        restorePersistedMilestones();
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
        identify(userId, sessionId, userCreatedAt, null);
    }

    public synchronized void identify(String userId, String sessionId, String userCreatedAt, String accountUserId) {
        identify(userId);
        if (!isBlank(sessionId)) {
            this.sessionId = sessionId;
        }
        if (!isBlank(userCreatedAt)) {
            this.userCreatedAt = userCreatedAt;
        }
        if (!isBlank(accountUserId)) {
            this.accountUserId = accountUserId;
        }
    }

    public synchronized void newSession() {
        String previousSessionId = sessionId;
        removeUnboundEvents(retryBatch, previousSessionId);
        removeUnboundEvents(queue, previousSessionId);
        sessionId = UUID.randomUUID().toString();
        diagnosticKeys.clear();
        diagnosticCount = 0;
        pendingMilestoneKeys.clear();
        contextId = null;
        sessionStartMillis = System.currentTimeMillis();
        if (hasPersistedQueue) persistPendingQueue();
    }

    public synchronized String currentSessionId() {
        return sessionId;
    }

    public synchronized void setContextId(String contextId) {
        this.contextId = isBlank(contextId) ? null : contextId;
        if (this.contextId == null) return;
        mergeCustomCountBucket("pending:" + sessionId, "context:" + this.contextId);
        bindCurrentSession(retryBatch, this.contextId);
        bindCurrentSession(queue, this.contextId);
        rememberBoundMilestones(this.contextId);
        if (hasPersistedQueue) persistPendingQueue();
    }

    public synchronized void setDebug(boolean isDebug) {
        this.isDebug = isDebug;
    }

    public synchronized boolean isDebug() {
        return isDebug;
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
        Date eventDate = new Date();
        Map<String, Object> normalizedPayload = normalizePayload(payload);
        String resolvedUserId;
        String resolvedSessionId;
        String resolvedContextId;
        boolean resolvedIsDebug;
        String resolvedAccountUserId;
        MilestoneDecision milestone = null;
        synchronized (this) {
            if (isBlank(userId)) {
                return false;
            }
            if (!consumeCustomEventQuota(eventType, isBlank(contextId) ? null : contextId, sessionId)) {
                return false;
            }
            resolvedUserId = userId;
            resolvedSessionId = sessionId;
            resolvedContextId = isBlank(contextId) ? "" : contextId;
            resolvedIsDebug = isDebug;
            resolvedAccountUserId = accountUserId;
            if ("milestone".equals(eventType)) {
                milestone = prepareMilestone(
                        resolvedUserId,
                        resolvedContextId,
                        resolvedIsDebug,
                        normalizedPayload,
                        eventDate
                );
                if (milestone.duplicate) return false;
                if (milestone.key != null) rememberMilestone(milestone.key, milestone.durable);
            }
        }

        GameAlgoEvent event = new GameAlgoEvent(resolvedContextId, resolvedUserId, resolvedSessionId, eventType)
                .eventId(UUID.randomUUID().toString())
                .payload(normalizedPayload)
                .isDebug(resolvedIsDebug)
                .timestamp(GameAlgoClient.isoTimestamp(eventDate))
                .createdLocalAt(GameAlgoClient.localTimestamp(eventDate))
                .accountUserId(resolvedAccountUserId);
        enqueue(event);
        return true;
    }

    private MilestoneDecision prepareMilestone(
            String resolvedUserId,
            String resolvedContextId,
            boolean resolvedIsDebug,
            Map<String, Object> payload,
            Date eventDate) {
        payload.remove("elapsedSinceRegistrationMs");
        Date registeredAt = parseIsoTimestamp(userCreatedAt);
        if (registeredAt != null) {
            payload.put("elapsedSinceRegistrationMs", Math.max(0L, eventDate.getTime() - registeredAt.getTime()));
        }

        String milestoneType = cleanPayloadString(payload.get("milestoneType"));
        String milestonePoint = cleanPayloadString(payload.get("milestonePoint"));
        if (milestoneType == null || milestonePoint == null) {
            return new MilestoneDecision(false, null, false);
        }
        boolean durable = !isBlank(resolvedContextId);
        String key = milestoneKey(resolvedUserId, resolvedIsDebug, milestoneType, milestonePoint);
        boolean duplicate = durable ? reachedMilestoneKeys.contains(key) : pendingMilestoneKeys.contains(key);
        return new MilestoneDecision(duplicate, key, durable);
    }

    private void rememberMilestone(String key, boolean durable) {
        if (!durable) {
            pendingMilestoneKeys.add(key);
            return;
        }
        if (reachedMilestoneKeys.add(key)) persistReachedMilestones();
    }

    private void rememberBoundMilestones(String resolvedContextId) {
        boolean changed = false;
        List<GameAlgoEvent> events = new ArrayList<>(retryBatch.size() + queue.size());
        events.addAll(retryBatch);
        events.addAll(queue);
        for (GameAlgoEvent event : events) {
            if (!resolvedContextId.equals(event.getContextId()) || !"milestone".equals(event.getEventType())) continue;
            String milestoneType = cleanPayloadString(event.getPayload().get("milestoneType"));
            String milestonePoint = cleanPayloadString(event.getPayload().get("milestonePoint"));
            if (milestoneType == null || milestonePoint == null) continue;
            String key = milestoneKey(
                    event.getUserId(),
                    Boolean.TRUE.equals(event.getIsDebug()),
                    milestoneType,
                    milestonePoint
            );
            if (reachedMilestoneKeys.add(key)) changed = true;
        }
        if (changed) persistReachedMilestones();
    }

    private static String milestoneKey(
            String resolvedUserId,
            boolean resolvedIsDebug,
            String milestoneType,
            String milestonePoint) {
        String[] parts = {
                resolvedIsDebug ? "debug" : "live",
                resolvedUserId,
                milestoneType,
                milestonePoint,
        };
        StringBuilder key = new StringBuilder();
        for (String part : parts) key.append(part.length()).append(':').append(part);
        return key.toString();
    }

    private static String cleanPayloadString(Object value) {
        if (!(value instanceof String)) return null;
        String normalized = ((String) value).trim();
        return normalized.length() == 0 ? null : normalized;
    }

    private static Date parseIsoTimestamp(String value) {
        if (isBlank(value)) return null;
        for (String pattern : Arrays.asList("yyyy-MM-dd'T'HH:mm:ss.SSSX", "yyyy-MM-dd'T'HH:mm:ssX")) {
            try {
                SimpleDateFormat formatter = new SimpleDateFormat(pattern, Locale.US);
                formatter.setLenient(false);
                return formatter.parse(value);
            } catch (Exception ignored) {
                // Try the next supported ISO-8601 shape.
            }
        }
        return null;
    }

    private boolean consumeCustomEventQuota(String eventType, String resolvedContextId, String resolvedSessionId) {
        if (STANDARD_EVENT_TYPES.contains(eventType)) return true;
        String bucketKey = resolvedContextId == null ? "pending:" + resolvedSessionId : "context:" + resolvedContextId;
        CustomCountBucket bucket = customCounts.get(bucketKey);
        if (bucket == null) bucket = new CustomCountBucket();
        int current = bucket.byType.containsKey(eventType) ? bucket.byType.get(eventType) : 0;
        String scope = null;
        int limit = 0;
        if (!bucket.byType.containsKey(eventType) && bucket.byType.size() >= 100) {
            scope = "distinct_event_types";
            limit = 100;
        } else if (current >= 1000) {
            scope = "context_event_type";
            limit = 1000;
        } else if (bucket.total >= 5000) {
            scope = "context_total";
            limit = 5000;
        }
        if (scope != null) {
            int observed = "context_total".equals(scope)
                    ? bucket.total + 1
                    : "distinct_event_types".equals(scope) ? bucket.byType.size() + 1 : current + 1;
            reportQuotaDiagnostic(eventType, resolvedSessionId, resolvedContextId, scope, limit,
                    observed);
            return false;
        }
        bucket.total += 1;
        bucket.byType.put(eventType, current + 1);
        customCounts.put(bucketKey, bucket);
        return true;
    }

    private void mergeCustomCountBucket(String from, String to) {
        CustomCountBucket pending = customCounts.remove(from);
        if (pending == null) return;
        CustomCountBucket target = customCounts.get(to);
        if (target == null) target = new CustomCountBucket();
        target.total += pending.total;
        for (Map.Entry<String, Integer> entry : pending.byType.entrySet()) {
            Integer current = target.byType.get(entry.getKey());
            target.byType.put(entry.getKey(), (current == null ? 0 : current) + entry.getValue());
        }
        customCounts.put(to, target);
    }

    private void reportQuotaDiagnostic(String eventType, String resolvedSessionId, String resolvedContextId,
                                       String scope, int limit, int observed) {
        String key = resolvedSessionId + "\u0000" + eventType + "\u0000" + scope;
        if (diagnosticKeys.contains(key) || diagnosticCount >= 10) return;
        diagnosticKeys.add(key);
        diagnosticCount += 1;
        String safeEventType = eventType == null ? "" : eventType.replace(';', '_').replace('\n', '_').replace('\r', '_');
        if (safeEventType.length() > 96) safeEventType = safeEventType.substring(0, 96);
        client.reportEventGuardDiagnostic(
                userId, resolvedSessionId, resolvedContextId, isDebug,
                "eventType=" + safeEventType + ";scope=" + scope + ";limit=" + limit + ";observed=" + observed + ";dropped=1");
    }

    public boolean trackEvent(String type) {
        return trackEvent(type, new LinkedHashMap<String, Object>());
    }

    public boolean trackEvent(String type, Map<String, Object> payload) {
        String eventType = type != null && type.startsWith("_") ? type : "_" + type;
        return trackInternal(eventType, payload);
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

    public boolean trackLevelStart(Map<String, Object> payload) {
        return track("level_start", payload);
    }

    public boolean trackLevelEnd(Map<String, Object> payload) {
        return track("level_end", payload);
    }

    public boolean trackMilestone(String milestoneType, String milestonePoint) {
        return trackMilestone(milestoneType, milestonePoint, new LinkedHashMap<String, Object>());
    }

    public boolean trackMilestone(String milestoneType, String milestonePoint, Map<String, Object> payload) {
        Map<String, Object> merged = copyPayload(payload);
        merged.put("milestoneType", milestoneType);
        merged.put("milestonePoint", milestonePoint);
        return track("milestone", merged);
    }

    public boolean trackAd(String placement, String adType, double revenue, String currency) {
        return trackAd(placement, adType, revenue, currency, null, new LinkedHashMap<String, Object>());
    }

    public boolean trackAd(String placement, String adType, double revenue, String currency, String network) {
        return trackAd(placement, adType, revenue, currency, network, new LinkedHashMap<String, Object>());
    }

    public boolean trackAd(String placement, String adType, double revenue, String currency, String network, Map<String, Object> payload) {
        Map<String, Object> merged = copyPayload(payload);
        merged.put("placement", placement);
        merged.put("adType", adType);
        merged.put("revenue", revenue);
        merged.put("currency", currency);
        if (!isBlank(network)) {
            merged.put("network", network);
        }
        return track("ad_view", merged);
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
                    if (hasMissingContextId(batch)) {
                        retryBatch.clear();
                        queue.clear();
                        queue.addAll(pending);
                        return;
                    }
                    retryBatch.clear();
                    queue.clear();
                    if (end < pending.size()) {
                        queue.addAll(pending.subList(end, pending.size()));
                    }
                }

                try {
                    client.uploadEvents(batch);
                    synchronized (this) {
                        consecutiveFailures = 0;
                    }
                } catch (GameAlgoException error) {
                    synchronized (this) {
                        retryBatch.clear();
                        retryBatch.addAll(batch);
                        consecutiveFailures += 1;
                        if (consecutiveFailures >= 3) {
                            hasPersistedQueue = true;
                            persistPendingQueue();
                        }
                    }
                    throw error;
                }
            }
        } finally {
            synchronized (this) {
                flushing = false;
                if (hasPersistedQueue && retryBatch.isEmpty() && queue.isEmpty()) {
                    clearPersistedQueue();
                }
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

    private static boolean hasMissingContextId(List<GameAlgoEvent> events) {
        for (GameAlgoEvent event : events) {
            if (isBlank(event.getContextId())) {
                return true;
            }
        }
        return false;
    }

    private synchronized void bindCurrentSession(List<GameAlgoEvent> events, String contextId) {
        for (int index = 0; index < events.size(); index += 1) {
            GameAlgoEvent event = events.get(index);
            if (isBlank(event.getContextId()) && sessionId.equals(event.getSessionId())) {
                events.set(index, event.withContextId(contextId));
            }
        }
    }

    private static void removeUnboundEvents(List<GameAlgoEvent> events, String sessionId) {
        events.removeIf(event -> isBlank(event.getContextId()) && sessionId.equals(event.getSessionId()));
    }

    private void restorePersistedQueue() {
        if (storage == null || isBlank(persistenceKey)) return;
        try {
            String raw = storage.getItem(persistenceKey);
            if (isBlank(raw)) return;
            for (String line : raw.split("\\r?\\n")) {
                if (isBlank(line)) continue;
                GameAlgoEvent event = GameAlgoEvent.fromJson(GameAlgoJson.asObject(GameAlgoJson.parse(line), "event"));
                if (!isBlank(event.getContextId())) retryBatch.add(event);
            }
            hasPersistedQueue = !retryBatch.isEmpty();
        } catch (GameAlgoException ignored) {
            // A malformed or unavailable persistence file must not block SDK startup.
        }
    }

    private void restorePersistedMilestones() {
        if (storage == null || isBlank(milestonePersistenceKey)) return;
        try {
            String raw = storage.getItem(milestonePersistenceKey);
            if (isBlank(raw)) return;
            for (Object value : GameAlgoJson.asArray(GameAlgoJson.parse(raw), "milestones")) {
                if (value instanceof String && !isBlank((String) value)) {
                    reachedMilestoneKeys.add((String) value);
                }
            }
        } catch (GameAlgoException ignored) {
            try {
                storage.removeItem(milestonePersistenceKey);
            } catch (GameAlgoException ignoredCleanup) {
                // A malformed optional cache must not block SDK startup.
            }
        }
    }

    private synchronized void persistReachedMilestones() {
        if (storage == null || isBlank(milestonePersistenceKey)) return;
        List<String> keys = new ArrayList<>(reachedMilestoneKeys);
        Collections.sort(keys);
        try {
            storage.setItem(milestonePersistenceKey, GameAlgoJson.stringify(keys));
        } catch (GameAlgoException ignored) {
            // Milestone deduplication remains active in memory when persistence is unavailable.
        }
    }

    private synchronized void persistPendingQueue() {
        if (storage == null || isBlank(persistenceKey)) return;
        List<GameAlgoEvent> pending = new ArrayList<>(retryBatch.size() + queue.size());
        pending.addAll(retryBatch);
        pending.addAll(queue);
        if (pending.isEmpty()) {
            clearPersistedQueue();
            return;
        }
        List<String> lines = new ArrayList<>(pending.size());
        Date now = new Date();
        for (GameAlgoEvent event : pending) {
            try {
                lines.add(GameAlgoJson.stringify(event.toJson(
                        GameAlgoClient.isoTimestamp(now),
                        GameAlgoClient.localTimestamp(now)
                )));
            } catch (GameAlgoException ignored) {
                // Skip only the malformed record; preserve the rest of the queue.
            }
        }
        try {
            storage.setItem(persistenceKey, String.join("\n", lines));
        } catch (GameAlgoException ignored) {
            // Persistence is a fallback and must not replace the transport error.
        }
    }

    private synchronized void clearPersistedQueue() {
        if (storage != null && !isBlank(persistenceKey)) {
            try {
                storage.removeItem(persistenceKey);
            } catch (GameAlgoException ignored) {
                // The next successful flush will retry cleanup.
            }
        }
        hasPersistedQueue = false;
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
