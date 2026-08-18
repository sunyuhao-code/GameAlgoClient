package com.gamealgo.demo;

import com.gamealgo.sdk.GameAlgoClient;
import com.gamealgo.sdk.GameAlgoExecutionResult;
import com.gamealgo.sdk.GameAlgoHttpClient;
import com.gamealgo.sdk.GameAlgoHttpRequest;
import com.gamealgo.sdk.GameAlgoHttpResponse;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

public final class DemoScenario {
    private static final String SCRIPT = "function execute(input) { return { payload: { difficulty: input.config.difficulty, native: true }, diagnostics: {} }; }";

    private DemoScenario() {}

    public static String run() throws Exception {
        FakeHttpClient http = new FakeHttpClient();
        GameAlgoClient client = new GameAlgoClient(
                "ga_live_demo_key",
                "https://gamealgo.demo",
                "integration-demo",
                "1.0",
                "android",
                http
        );

        try {
            if (!client.waitForReady(3000)) {
                throw new IllegalStateException("SDK initialization timed out");
            }
            if (!"demo_variant".equals(client.executor("demo_strategy").variant("missing"))) {
                throw new IllegalStateException("experiment assignment was not decoded");
            }
            GameAlgoExecutionResult result = client.executor("demo_strategy").execute(Collections.emptyMap());
            if (result == null || !(result.getPayload() instanceof Map)) {
                throw new IllegalStateException("native script strategy did not execute");
            }
            Map<?, ?> payload = (Map<?, ?>) result.getPayload();
            if (!"normal".equals(payload.get("difficulty")) || !Boolean.TRUE.equals(payload.get("native"))) {
                throw new IllegalStateException("native script returned an unexpected payload");
            }
            if (!client.tracker().trackLevelStart(Collections.<String, Object>singletonMap("level", 1))) {
                throw new IllegalStateException("event was not queued");
            }
            client.tracker().flush();
            if (http.requestCount() != 3) {
                throw new IllegalStateException("expected config, script and event requests");
            }
            return "PASSED\nAAR API, config, experiment and event flow are working.";
        } finally {
            client.tracker().close();
        }
    }

    private static final class FakeHttpClient implements GameAlgoHttpClient {
        private final List<String> urls = new ArrayList<>();

        @Override
        public synchronized GameAlgoHttpResponse send(GameAlgoHttpRequest request) throws IOException {
            urls.add(request.getUrl().toString());
            String body;
            if (request.getUrl().getPath().endsWith("/v1/config")) {
                body = "{"
                        + "\"contextId\":\"ctx-demo\","
                        + "\"gameId\":\"demo\","
                        + "\"environment\":\"live\","
                        + "\"configVersion\":\"demo-v1\","
                        + "\"ttlSeconds\":60,"
                        + "\"serverTime\":\"2026-08-18T00:00:00.000Z\","
                        + "\"experiments\":[{"
                        + "\"key\":\"demo_strategy\","
                        + "\"experimentId\":\"exp-demo\","
                        + "\"variant\":\"demo_variant\","
                        + "\"config\":{\"difficulty\":\"normal\"},"
                        + "\"script\":{"
                        + "\"versionId\":\"sv-demo\","
                        + "\"name\":\"demo.js\","
                        + "\"url\":\"/v1/scripts/sv-demo\","
                        + "\"hash\":\"sha256:6be8effff09cf253f938c61335b13e3a13893e684168ee0a56c0f42e2f6bd457\""
                        + "}"
                        + "}],"
                        + "\"configFiles\":[]"
                        + "}";
            } else if (request.getUrl().getPath().endsWith("/v1/scripts/sv-demo")) {
                return new GameAlgoHttpResponse(
                        200,
                        Collections.singletonMap("content-type", "application/javascript"),
                        SCRIPT.getBytes(StandardCharsets.UTF_8)
                );
            } else if (request.getUrl().getPath().endsWith("/v1/events/batch")) {
                body = "{\"ok\":true,\"accepted\":1}";
            } else {
                throw new IOException("unexpected request: " + request.getUrl());
            }
            return new GameAlgoHttpResponse(
                    200,
                    Collections.singletonMap("content-type", "application/json"),
                    body.getBytes(StandardCharsets.UTF_8)
            );
        }

        synchronized int requestCount() {
            return urls.size();
        }
    }
}
