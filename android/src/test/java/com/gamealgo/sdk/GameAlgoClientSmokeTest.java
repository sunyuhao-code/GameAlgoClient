package com.gamealgo.sdk;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class GameAlgoClientSmokeTest {
    public static void main(String[] args) throws Exception {
        testFetchConfigSendsHeadersAndCaches();
        testFetchConfigFile();
        testStartAsyncPreloadsConfigFilesAndExposesLocalExecutorAndConfigReaders();
        testExecutorExecutesPreloadedScriptAgainstLocalSnapshot();
        testStartRestoresPersistedSnapshotThenStillRefreshes();
        testStartGeneratesAndReusesAnonymousUserId();
        testStartBackfillsCreatedAtForPersistedLegacyUserId();
        testUploadEventsFillsDefaults();
        testTrackerQueuesAndFlushesEvents();
        testCustomEventsUseDimensionsAndMetrics();
    }

    private static void testFetchConfigSendsHeadersAndCaches() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse(configJson("v1")));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                httpClient,
                new FakeScriptRuntime(),
                null,
                null
        );

        GameAlgoConfigResponse first = client.fetchConfig("u1");
        GameAlgoConfigResponse second = client.fetchConfig("u1");

        check("Mahjong".equals(first.getGameId()), "gameId should decode");
        check("v1".equals(second.getConfigVersion()), "configVersion should decode");
        check(httpClient.requests.size() == 1, "config should be cached");
        GameAlgoHttpRequest request = httpClient.requests.get(0);
        check("ga_live_test_key_0123456789abcdef".equals(request.getHeaders().get("X-GameAlgo-Key")), "game key header should be sent");
        check(GameAlgoHttpMethod.POST.equals(request.getMethod()), "config should use POST");
        check("https://gamealgo.test/v1/config".equals(request.getUrl().toString()), "config URL should match Protocol v1");
        Map<String, Object> requestBody = requestBody(request);
        check("u1".equals(requestBody.get("userId")), "config body should include userId");
        check(requestBody.get("sessionId") instanceof String && ((String) requestBody.get("sessionId")).length() > 0, "config body should include sessionId");
        check("android".equals(requestBody.get("platform")), "config body should include platform");
        check("1.0.0".equals(requestBody.get("sdkVersion")), "config body should include sdkVersion");
    }

    private static void testFetchConfigFile() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("content-type", "application/json; charset=utf-8");
        headers.put("etag", "\"sha256:test\"");
        httpClient.enqueue(new GameAlgoHttpResponse(
                200,
                headers,
                "{\"difficulty\":\"normal\"}\n".getBytes(StandardCharsets.UTF_8)
        ));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                httpClient,
                new FakeScriptRuntime(),
                null,
                null
        );

        GameAlgoConfigFile file = client.fetchConfigFile("gameplay.json");

        check("gameplay.json".equals(file.getName()), "file name should decode");
        check("\"sha256:test\"".equals(file.getEtag()), "etag should decode");
        check("{\"difficulty\":\"normal\"}\n".equals(file.getContent()), "content should decode");
        check("https://gamealgo.test/v1/config-files/gameplay.json".equals(httpClient.requests.get(0).getUrl().toString()), "config file URL should match Protocol v1");
    }

    private static void testStartAsyncPreloadsConfigFilesAndExposesLocalExecutorAndConfigReaders() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse("{"
                + "\"contextId\":\"ctx-1\","
                + "\"gameId\":\"Mahjong\","
                + "\"environment\":\"live\","
                + "\"configVersion\":\"v1\","
                + "\"ttlSeconds\":60,"
                + "\"serverTime\":\"2026-05-28T10:00:00.000Z\","
                + "\"experiments\":[{"
                + "\"key\":\"level_generator\","
                + "\"experimentId\":\"exp-level-generator-001\","
                + "\"variant\":\"variant-a\","
                + "\"config\":{\"difficulty\":\"hard\",\"spawnRate\":0.7}"
                + "}],"
                + "\"configFiles\":[{"
                + "\"name\":\"gameplay.json\","
                + "\"url\":\"https://gamealgo.test/v1/config-files/gameplay.json\","
                + "\"hash\":\"sha256:test\""
                + "}]"
                + "}"));
        httpClient.enqueue(jsonResponse("{\"ads\":{\"rewarded\":{\"enabled\":false}},\"economy\":{\"startCoins\":120}}"));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                httpClient,
                new FakeScriptRuntime(),
                null,
                null
        );
        GameAlgoExperimentExecutor executor = client.executor("level_generator");

        check(!executor.isReady(), "executor should not be ready before start");
        check("control".equals(executor.variant("control")), "executor should use default variant before start");

        client.startAsync("u1").get();

        check(executor.isReady(), "executor should be ready after start");
        check("variant-a".equals(executor.variant("control")), "variant should decode");
        check("hard".equals(executor.string("difficulty", "normal")), "executor config should decode");
        check(Math.abs(executor.number("spawnRate", 0) - 0.7) < 0.0001, "executor number config should decode");
        check(!client.config().bool("ads.rewarded.enabled", true, "gameplay.json"), "config bool should decode");
        check(client.config().integer("economy.startCoins", 0) == 120, "config int should decode");
        check(httpClient.requests.size() == 2, "start should fetch config and preload file");
    }

    private static void testExecutorExecutesPreloadedScriptAgainstLocalSnapshot() throws Exception {
        String script = "function execute(input) { return { payload: input.config, diagnostics: input.meta }; }";
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse("{"
                + "\"contextId\":\"ctx-1\","
                + "\"gameId\":\"Mahjong\","
                + "\"environment\":\"live\","
                + "\"configVersion\":\"v1\","
                + "\"ttlSeconds\":60,"
                + "\"serverTime\":\"2026-05-28T10:00:00.000Z\","
                + "\"experiments\":[{"
                + "\"key\":\"level_generator\","
                + "\"experimentId\":\"exp-level-generator-001\","
                + "\"variant\":\"variant-a\","
                + "\"config\":{\"difficulty\":\"hard\"},"
                + "\"script\":{\"name\":\"level-generator.js\",\"url\":\"https://gamealgo.test/v1/config-files/level-generator.js\",\"hash\":\"" + sha256(script) + "\"}"
                + "}],"
                + "\"configFiles\":[]"
                + "}"));
        httpClient.enqueue(new GameAlgoHttpResponse(
                200,
                headers("text/plain; charset=utf-8"),
                script.getBytes(StandardCharsets.UTF_8)
        ));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                httpClient,
                new FakeScriptRuntime(),
                null,
                null
        );

        client.startAsync("u1").get();
        GameAlgoExecutionResult result = client.executor("level_generator").execute(new LinkedHashMap<String, Object>());

        check(result != null, "script result should be available");
        check("hard".equals(GameAlgoJson.readPath(result.getPayload(), "difficulty")), "script payload should decode");
        check("u1".equals(GameAlgoJson.readPath(result.getDiagnostics(), "userId")), "script meta should include userId");
    }

    private static void testStartRestoresPersistedSnapshotThenStillRefreshes() throws Exception {
        MemoryCacheStorage cache = new MemoryCacheStorage();
        FakeHttpClient firstHttpClient = new FakeHttpClient();
        firstHttpClient.enqueue(jsonResponse("{"
                + "\"contextId\":\"ctx-1\","
                + "\"gameId\":\"Mahjong\","
                + "\"environment\":\"live\","
                + "\"configVersion\":\"cached-v1\","
                + "\"ttlSeconds\":60,"
                + "\"serverTime\":\"2026-05-28T10:00:00.000Z\","
                + "\"experiments\":[{"
                + "\"key\":\"level_generator\","
                + "\"experimentId\":\"exp-level-generator-001\","
                + "\"variant\":\"variant-a\","
                + "\"config\":{\"difficulty\":\"cached-hard\"}"
                + "}],"
                + "\"configFiles\":[{\"name\":\"gameplay.json\",\"url\":\"https://gamealgo.test/v1/config-files/gameplay.json\",\"hash\":\"sha256:test\"}]"
                + "}"));
        firstHttpClient.enqueue(jsonResponse("{\"difficulty\":\"cached\"}"));
        GameAlgoClient first = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                firstHttpClient,
                new FakeScriptRuntime(),
                cache,
                "test-cache"
        );
        first.startAsync("u1").get();

        FakeHttpClient secondHttpClient = new FakeHttpClient();
        secondHttpClient.enqueueError(new java.io.IOException("offline"));
        GameAlgoClient second = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                secondHttpClient,
                new FakeScriptRuntime(),
                cache,
                "test-cache"
        );
        second.startAsync("u1").get();

        check("variant-a".equals(second.executor("level_generator").variant("control")), "cached variant should restore");
        check("cached".equals(second.config().string("difficulty", "", "gameplay.json")), "cached file should restore");
        check(secondHttpClient.requests.size() == 1, "start should still try to refresh");
    }

    private static void testStartGeneratesAndReusesAnonymousUserId() throws Exception {
        MemoryCacheStorage cache = new MemoryCacheStorage();
        FakeHttpClient firstHttpClient = new FakeHttpClient();
        firstHttpClient.enqueue(jsonResponse(configJson("v1")));
        GameAlgoClient first = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                firstHttpClient,
                new FakeScriptRuntime(),
                cache,
                "test-cache"
        );

        first.startAsync().get();
        String firstUserId = first.userId();

        FakeHttpClient secondHttpClient = new FakeHttpClient();
        secondHttpClient.enqueue(jsonResponse(configJson("v2")));
        GameAlgoClient second = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                secondHttpClient,
                new FakeScriptRuntime(),
                cache,
                "test-cache"
        );
        second.startAsync().get();

        check(firstUserId.length() > 0, "anonymous user id should be generated");
        check(firstUserId.equals(second.userId()), "anonymous user id should be persisted");
        check(firstUserId.equals(requestBody(firstHttpClient.requests.get(0)).get("userId")), "first config request should use generated user id");
        check(firstUserId.equals(requestBody(secondHttpClient.requests.get(0)).get("userId")), "second config request should reuse generated user id");
    }

    private static void testUploadEventsFillsDefaults() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse("{\"ok\":true,\"accepted\":1}"));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.2.3",
                "4.5.6",
                "android",
                httpClient
        );

        GameAlgoEventBatchResponse response = client.uploadEvents(Arrays.asList(
                new GameAlgoEvent("ctx-1", "u1", "s1", "session_start")
        ));
        Map<String, Object> body = GameAlgoJson.asObject(
                GameAlgoJson.parse(new String(httpClient.requests.get(0).getBody(), StandardCharsets.UTF_8)),
                "body"
        );
        List<Object> events = GameAlgoJson.asArray(body.get("events"), "events");
        Map<String, Object> event = GameAlgoJson.asObject(events.get(0), "events[]");

        check(response.getAccepted() == 1, "accepted should decode");
        check("ctx-1".equals(event.get("contextId")), "contextId should be preserved");
        check(Boolean.FALSE.equals(event.get("isDebug")), "isDebug should default false");
        check(event.get("timestamp") instanceof String, "timestamp should default");
        check(GameAlgoJson.asObject(event.get("dimensions"), "dimensions").isEmpty(), "dimensions should default empty");
        check(GameAlgoJson.asArray(event.get("metrics"), "metrics").isEmpty(), "metrics should default empty");
    }

    private static void testStartBackfillsCreatedAtForPersistedLegacyUserId() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse(configJson("v1")));
        httpClient.enqueue(jsonResponse("{\"ok\":true,\"accepted\":2}"));
        MemoryCacheStorage cache = new MemoryCacheStorage();
        cache.setItem("gamealgo_user_id", "legacy-user");
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                httpClient,
                new FakeScriptRuntime(),
                cache,
                "test-cache"
        );

        client.startAsync().get();
        check("legacy-user".equals(client.userId()), "legacy user id should be reused");
        check(cache.getItem("gamealgo_user_created_at") != null && cache.getItem("gamealgo_user_created_at").length() > 0, "legacy user createdAt should be backfilled");

        check(client.tracker().trackSessionStart(), "tracker should enqueue session_start for legacy user");
        client.tracker().flush();

        Map<String, Object> body = GameAlgoJson.asObject(
                GameAlgoJson.parse(new String(httpClient.requests.get(1).getBody(), StandardCharsets.UTF_8)),
                "body"
        );
        List<Object> events = GameAlgoJson.asArray(body.get("events"), "events");
        Map<String, Object> sessionStart = null;
        for (Object event : events) {
            Map<String, Object> parsed = GameAlgoJson.asObject(event, "events[]");
            if ("session_start".equals(parsed.get("eventType"))) {
                sessionStart = parsed;
                break;
            }
        }

        check(sessionStart != null, "session_start should be uploaded for legacy user");
        check("legacy-user".equals(sessionStart.get("userId")), "session_start should use legacy user id");
        Map<String, Object> dimensions = GameAlgoJson.asObject(sessionStart.get("dimensions"), "dimensions");
        check(cache.getItem("gamealgo_user_created_at").equals(dimensions.get("userCreatedAt")), "session_start should include backfilled userCreatedAt");
    }

    private static void testTrackerQueuesAndFlushesEvents() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse(configJsonWithExperiment("v1")));
        httpClient.enqueue(jsonResponse("{\"ok\":true,\"accepted\":3}"));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.2.3",
                "4.5.6",
                "android",
                httpClient
        );

        client.startAsync("u1").get();
        client.tracker().setDebug(true);
        check(client.tracker().trackSessionStart(), "tracker should enqueue session_start after start");
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("level", 3);
        check(client.tracker().trackLevelEnd(payload), "tracker should enqueue level_end");
        client.tracker().flush();

        Map<String, Object> body = GameAlgoJson.asObject(
                GameAlgoJson.parse(new String(httpClient.requests.get(1).getBody(), StandardCharsets.UTF_8)),
                "body"
        );
        List<Object> events = GameAlgoJson.asArray(body.get("events"), "events");
        Map<String, Object> first = GameAlgoJson.asObject(events.get(0), "events[]");
        Map<String, Object> second = GameAlgoJson.asObject(events.get(1), "events[]");
        Map<String, Object> third = GameAlgoJson.asObject(events.get(2), "events[]");

        check(httpClient.requests.size() == 2, "tracker flush should upload one event batch");
        check("https://gamealgo.test/v1/events/batch".equals(httpClient.requests.get(1).getUrl().toString()), "tracker should post to events batch");
        check(events.size() == 3, "tracker should upload config_loaded and queued events together");
        check("config_loaded".equals(first.get("eventType")), "tracker should upload config_loaded");
        check("ctx-1".equals(first.get("contextId")), "tracker should attach contextId");
        check("u1".equals(second.get("userId")), "tracker should use identified user");
        check(second.get("sessionId").equals(third.get("sessionId")), "tracker should keep session id");
        check("session_start".equals(second.get("eventType")), "tracker should upload session_start");
        Map<String, Object> secondDimensions = GameAlgoJson.asObject(second.get("dimensions"), "dimensions");
        check(secondDimensions.get("userCreatedAt") instanceof String && ((String) secondDimensions.get("userCreatedAt")).length() > 0, "session_start should include userCreatedAt");
        check("level_end".equals(third.get("eventType")), "tracker should upload level_end");
        check(Boolean.TRUE.equals(third.get("isDebug")), "tracker should preserve debug flag");
        List<Object> thirdMetrics = GameAlgoJson.asArray(third.get("metrics"), "metrics");
        Map<String, Object> levelMetric = GameAlgoJson.asObject(thirdMetrics.get(0), "metrics[]");
        check("level".equals(levelMetric.get("key")), "tracker should split numeric payload as metric");
        check(((Number) levelMetric.get("value")).doubleValue() == 3.0, "tracker should preserve metric value");
        client.tracker().close();
    }

    private static void testCustomEventsUseDimensionsAndMetrics() throws Exception {
        FakeHttpClient httpClient = new FakeHttpClient();
        httpClient.enqueue(jsonResponse(configJsonWithExperiment("v1")));
        httpClient.enqueue(jsonResponse("{\"ok\":true,\"accepted\":2}"));
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_test_key_0123456789abcdef",
                "https://gamealgo.test",
                "1.0.0",
                null,
                "android",
                httpClient
        );

        client.startAsync("u1").get();
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("button", "start");
        payload.put("value", 2);
        check(client.tracker().trackEvent("custom_action", payload), "custom event should enqueue");
        client.tracker().flush();

        Map<String, Object> body = GameAlgoJson.asObject(
                GameAlgoJson.parse(new String(httpClient.requests.get(1).getBody(), StandardCharsets.UTF_8)),
                "body"
        );
        List<Object> events = GameAlgoJson.asArray(body.get("events"), "events");
        Map<String, Object> event = GameAlgoJson.asObject(events.get(1), "events[]");
        Map<String, Object> eventDimensions = GameAlgoJson.asObject(event.get("dimensions"), "dimensions");
        List<Object> metrics = GameAlgoJson.asArray(event.get("metrics"), "metrics");
        Map<String, Object> metric = GameAlgoJson.asObject(metrics.get(0), "metrics[]");

        check("_custom_action".equals(event.get("eventType")), "custom event should be prefixed");
        check("start".equals(eventDimensions.get("button")), "custom string payload should become dimension");
        check("value".equals(metric.get("key")), "custom numeric payload should become metric");
        check(((Number) metric.get("value")).doubleValue() == 2.0, "custom metric value should be preserved");
        client.tracker().close();
    }

    private static String configJson(String version) {
        return "{"
                + "\"contextId\":\"ctx-1\","
                + "\"gameId\":\"Mahjong\","
                + "\"environment\":\"live\","
                + "\"configVersion\":\"" + version + "\","
                + "\"ttlSeconds\":60,"
                + "\"serverTime\":\"2026-05-28T10:00:00.000Z\","
                + "\"experiments\":[],"
                + "\"configFiles\":[]"
                + "}";
    }

    private static String configJsonWithExperiment(String version) {
        return "{"
                + "\"contextId\":\"ctx-1\","
                + "\"gameId\":\"Mahjong\","
                + "\"environment\":\"live\","
                + "\"configVersion\":\"" + version + "\","
                + "\"ttlSeconds\":60,"
                + "\"serverTime\":\"2026-05-28T10:00:00.000Z\","
                + "\"experiments\":[{"
                + "\"key\":\"level_generator\","
                + "\"experimentId\":\"exp-level-generator-001\","
                + "\"variant\":\"variant-a\","
                + "\"config\":{}"
                + "}],"
                + "\"configFiles\":[]"
                + "}";
    }

    private static Map<String, Object> requestBody(GameAlgoHttpRequest request) throws GameAlgoException {
        return GameAlgoJson.asObject(
                GameAlgoJson.parse(new String(request.getBody(), StandardCharsets.UTF_8)),
                "request"
        );
    }

    private static GameAlgoHttpResponse jsonResponse(String body) {
        return new GameAlgoHttpResponse(200, headers("application/json; charset=utf-8"), body.getBytes(StandardCharsets.UTF_8));
    }

    private static Map<String, String> headers(String contentType) {
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("content-type", contentType);
        return headers;
    }

    private static String sha256(String content) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] bytes = digest.digest(content.getBytes(StandardCharsets.UTF_8));
        StringBuilder builder = new StringBuilder("sha256:");
        for (byte value : bytes) {
            builder.append(String.format("%02x", value & 0xff));
        }
        return builder.toString();
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static final class FakeHttpClient implements GameAlgoHttpClient {
        private final List<GameAlgoHttpResponse> responses = new ArrayList<>();
        private final List<Exception> errors = new ArrayList<>();
        private final List<GameAlgoHttpRequest> requests = new ArrayList<>();

        void enqueue(GameAlgoHttpResponse response) {
            responses.add(response);
        }

        void enqueueError(Exception error) {
            errors.add(error);
        }

        @Override
        public GameAlgoHttpResponse send(GameAlgoHttpRequest request) throws java.io.IOException {
            requests.add(request);
            if (!errors.isEmpty()) {
                Exception error = errors.remove(0);
                if (error instanceof java.io.IOException) {
                    throw (java.io.IOException) error;
                }
                throw new AssertionError(error);
            }
            if (responses.isEmpty()) {
                throw new AssertionError("No mock response enqueued");
            }
            return responses.remove(0);
        }
    }

    private static final class FakeScriptRuntime implements GameAlgoScriptRuntime {
        @Override
        public Object execute(String script, GameAlgoScriptInput input) {
            Map<String, Object> output = new LinkedHashMap<>();
            output.put("payload", input.getConfig());
            output.put("diagnostics", input.getMeta());
            return output;
        }
    }

    private static final class MemoryCacheStorage implements GameAlgoCacheStorage {
        private final Map<String, String> values = new LinkedHashMap<>();

        @Override
        public String getItem(String key) {
            return values.get(key);
        }

        @Override
        public void setItem(String key, String value) {
            values.put(key, value);
        }

        @Override
        public void removeItem(String key) {
            values.remove(key);
        }
    }
}
