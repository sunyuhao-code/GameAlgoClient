package com.gamealgo.sdk;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

final class GameAlgoLifecycleTest {
    static void runAll() throws Exception {
        recoveryUsesLastObservationAndKeepsEventIds();
        backgroundPersistsBeforeTransportAndKeepsSession();
        historicalConfigKeepsItsOriginalSession();
        trackerRecoversHistoricalConfigWithoutSwitchingCurrentSession();
        processVisibilityIncludesAdvertisingActivities();
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static GameAlgoEvent template(String session, String context, long start) {
        return new GameAlgoEvent(context, "user", session, "session_end").eventId("template")
                .timestamp(GameAlgoClient.isoTimestamp(new Date(start))).createdLocalAt(GameAlgoClient.localTimestamp(new Date(start)));
    }
    private static void recoveryUsesLastObservationAndKeepsEventIds() throws Exception {
        Memory storage = new Memory();
        GameAlgoLifecycleJournal first = new GameAlgoLifecycleJournal(storage, "journal", true, 1000);
        first.activate(template("old", "ctx-old", 1000), 1000, false, Collections.emptyList());
        first.observe(true, 4000);
        GameAlgoLifecycleJournal second = new GameAlgoLifecycleJournal(storage, "journal", true, 1000);
        second.activate(template("new", "ctx-new", 100_000), 100_000, false, Collections.emptyList());
        GameAlgoEvent recovered = second.pending().get(0);
        check(recovered.getSessionId().equals("old") && recovered.getContextId().equals("ctx-old"), "recovery keeps ownership");
        check(recovered.getPayload().get("reason").equals("process_restart"), "recover an unfinished session");
        check(((Number) recovered.getPayload().get("sessionDurationMs")).longValue() == 3000, "offline time is excluded");
        check(Boolean.TRUE.equals(recovered.getPayload().get("endTimeEstimated")), "recovered duration is estimated");
        check(recovered.getTimestamp().equals(GameAlgoClient.isoTimestamp(new Date(4000))), "use the last observed time");
        GameAlgoLifecycleJournal third = new GameAlgoLifecycleJournal(storage, "journal", true, 1000);
        third.activate(template("third", "ctx-third", 200_000), 200_000, false, Collections.emptyList());
        List<GameAlgoEvent> old = new ArrayList<>();
        for (GameAlgoEvent event : third.pending()) if (event.getSessionId().equals("old")) old.add(event);
        check(old.size() == 1 && old.get(0).getEventId().equals(recovered.getEventId()), "restarting again retries the same recovery ID");
        third.acknowledge(old);
        GameAlgoLifecycleJournal fourth = new GameAlgoLifecycleJournal(storage, "journal", true, 1000);
        fourth.activate(template("fourth", "ctx-fourth", 300_000), 300_000, false, Collections.emptyList());
        for (GameAlgoEvent event : fourth.pending()) check(!event.getSessionId().equals("old"), "ACK is durable");
    }
    private static void backgroundPersistsBeforeTransportAndKeepsSession() throws Exception {
        Memory storage = new Memory();
        List<GameAlgoEvent> sent = new CopyOnWriteArrayList<>();
        GameAlgoHttpClient http = request -> {
            try {
                Map<String, Object> body = GameAlgoJson.asObject(GameAlgoJson.parse(new String(request.getBody(), java.nio.charset.StandardCharsets.UTF_8)), "batch");
                String journal = storage.getItem("queue:lifecycle");
                List<?> rows = (List<?>) body.get("events");
                for (Object row : rows) {
                    GameAlgoEvent event = GameAlgoEvent.fromJson(GameAlgoJson.asObject(row, "event"));
                    check(journal.contains(event.getEventId()), "every in-flight event is already durable");
                    sent.add(event);
                }
                return new GameAlgoHttpResponse(200, Collections.emptyMap(), ("{\"ok\":true,\"accepted\":" + rows.size() + "}").getBytes(java.nio.charset.StandardCharsets.UTF_8));
            } catch (GameAlgoException error) { throw new IOException(error); }
        };
        GameAlgoClient client = new GameAlgoClient("ga_live_local_lifecycle", "https://local.test", "test", null, "android",
                http, (script, input) -> null, null, null, null, false);
        GameAlgoEventTracker tracker = new GameAlgoEventTracker(client, 100, 1000, 0, storage, "queue");
        try {
            tracker.identify("user", "same-session"); tracker.setContextId("ctx"); tracker.enableLifecycle(true);
            tracker.trackLevelStart(Collections.emptyMap());
            tracker.observeLifecycle(false, System.currentTimeMillis()); tracker.flush();
            check(sent.stream().anyMatch(e -> e.getEventType().equals("session_end")), "background generates an end without gameplay code");
            tracker.observeLifecycle(true, System.currentTimeMillis());
            tracker.observeLifecycle(false, System.currentTimeMillis()); tracker.flush();
            check(sent.stream().filter(e -> e.getEventType().equals("session_end")).count() == 2, "another background can end the same session again");
            check(tracker.currentSessionId().equals("same-session"), "resume does not rotate identity");
            for (GameAlgoEvent event : sent) check(event.getSessionId().equals("same-session"), "all events keep the original session");
            GameAlgoLifecycleJournal restart = new GameAlgoLifecycleJournal(storage, "queue:lifecycle", true, 1000);
            restart.activate(template("next", "next-context", 500_000), 500_000, false, Collections.emptyList());
            check(restart.pending().isEmpty(), "normal background + ACK must not be recovered again");
        } finally { tracker.close(); client.tracker().close(); }
    }
    private static void historicalConfigKeepsItsOriginalSession() {
        Memory storage = new Memory();
        GameAlgoLifecycleJournal old = new GameAlgoLifecycleJournal(storage, "journal", true, 1000);
        old.activate(template("old", "", 1000), 1000, false, Collections.emptyList());
        old.retainConfig("old", "{\"sessionId\":\"old\",\"userId\":\"user\"}"); old.observe(true, 3000);
        GameAlgoLifecycleJournal current = new GameAlgoLifecycleJournal(storage, "journal", true, 1000);
        current.activate(template("current", "current-context", 50_000), 50_000, false, Collections.emptyList());
        check(current.unboundConfigs().get("old").contains("\"old\""), "retain the exact old config request");
        current.bind("old", "old-context");
        check(current.pending().get(0).getContextId().equals("old-context"), "new context cannot claim the recovered old event");
        check(current.unboundConfigs().isEmpty(), "stop recovering a context once it is bound");
    }
    private static void trackerRecoversHistoricalConfigWithoutSwitchingCurrentSession() throws Exception {
        Memory storage = new Memory();
        String gameKey = "ga_live_lifecycle_recovery";
        StringBuilder hash = new StringBuilder();
        for (byte value : java.security.MessageDigest.getInstance("SHA-256").digest(gameKey.getBytes(java.nio.charset.StandardCharsets.UTF_8))) hash.append(String.format("%02x", value & 255));
        String key = "gamealgo:v1:event-queue:https://native.test:" + hash + ":user:lifecycle";
        String originalBody = "{\"sessionId\":\"old\",\"userId\":\"user\",\"device\":{\"marker\":\"original\"}}";
        GameAlgoLifecycleJournal original = new GameAlgoLifecycleJournal(storage, key, true, 1000);
        original.activate(template("old", "", 1000), 1000, false, Collections.emptyList());
        original.retainConfig("old", originalBody); original.observe(true, 2000);
        List<GameAlgoEvent> sent = new CopyOnWriteArrayList<>();
        GameAlgoHttpClient http = request -> {
            try {
                String body = new String(request.getBody(), java.nio.charset.StandardCharsets.UTF_8);
                if (request.getUrl().getPath().endsWith("/config")) {
                    check(body.equals(originalBody), "historical config request is replayed unchanged");
                    String response = "{\"contextId\":\"old-context\",\"gameId\":\"test\",\"environment\":\"live\",\"configVersion\":\"1\",\"ttlSeconds\":60,\"serverTime\":\"2026-10-26T00:00:00Z\",\"experiments\":[],\"configFiles\":[]}";
                    return new GameAlgoHttpResponse(200, Collections.emptyMap(), response.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                }
                List<?> rows = (List<?>) GameAlgoJson.asObject(GameAlgoJson.parse(body), "batch").get("events");
                for (Object row : rows) sent.add(GameAlgoEvent.fromJson(GameAlgoJson.asObject(row, "event")));
                return new GameAlgoHttpResponse(200, Collections.emptyMap(), ("{\"ok\":true,\"accepted\":"+rows.size()+"}").getBytes(java.nio.charset.StandardCharsets.UTF_8));
            } catch (GameAlgoException error) { throw new IOException(error); }
        };
        GameAlgoClient client = new GameAlgoClient(gameKey, "https://native.test", "test", null, "android", http,
                (script,input)->null, storage, null, null, new GameAlgoFetchConfigRequest("user"), false);
        GameAlgoEventTracker tracker = client.tracker();
        try {
            tracker.identify("user", "new"); tracker.setContextId("new-context"); tracker.enableLifecycle(true); tracker.flush();
            check(sent.size() == 1, "recovered old end uploads after historical context resolution");
            check(sent.get(0).getSessionId().equals("old") && sent.get(0).getContextId().equals("old-context"), "recovered event retains old context ownership");
            check(tracker.currentSessionId().equals("new"), "config replay cannot rotate the live session");
        } finally { tracker.close(); }
    }

    private static void processVisibilityIncludesAdvertisingActivities() {
        List<Runnable> scheduled = new ArrayList<>(); List<Boolean> transitions = new ArrayList<>();
        GameAlgoProcessVisibility visibility = new GameAlgoProcessVisibility(new GameAlgoProcessVisibility.Scheduler() {
            public void later(Runnable task, long delay) { check(delay == 100, "same stop grace as Godot"); scheduled.add(task); }
            public void cancel(Runnable task) { scheduled.remove(task); }
        }, transitions::add);
        Object game = new Object(), ad = new Object();
        visibility.started(game); visibility.resumed(game, true); visibility.paused(game);
        visibility.started(ad); visibility.stopped(game, false); visibility.resumed(ad, true);
        check(transitions.equals(Collections.singletonList(true)), "normal ads keep the process foreground");
        visibility.uiHidden(); visibility.stopped(ad, false);
        check(transitions.size() == 2 && !transitions.get(1), "UI hidden immediately backgrounds the whole process");
        visibility.screenOff(); visibility.screenOn(true);
        check(!visibility.isForeground(), "screen-on at the launcher does not reopen a session");
        visibility.started(game); visibility.resumed(game, true); visibility.screenOff();
        check(transitions.size() == 4 && !transitions.get(3), "screen-off is an independent background boundary");
    }
    private static final class Memory implements GameAlgoCacheStorage {
        final Map<String, String> values = new ConcurrentHashMap<>();
        public String getItem(String key) { return values.get(key); }
        public void setItem(String key, String value) { values.put(key, value); }
        public void removeItem(String key) { values.remove(key); }
    }
}
