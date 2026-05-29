import test from "node:test";
import assert from "node:assert/strict";
import { GameAlgoApiError, GameAlgoRestClient, createEvent } from "./client.ts";

const gameKey = "ga_live_test_key_0123456789abcdef";

test("fetchConfig sends Protocol v1 headers and caches by ttl", async () => {
  let calls = 0;
  const requests: Request[] = [];
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    sdkVersion: "1.0.0",
    now: () => 1000,
    fetchImpl: async (input, init) => {
      const request = new Request(input, init);
      requests.push(request);
      calls += 1;
      assert.equal(request.headers.get("X-GameAlgo-Key"), gameKey);
      assert.equal(new URL(request.url).searchParams.get("userId"), "u1");
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "v1",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: {},
        }],
        configFiles: [],
      });
    },
  });

  const first = await client.fetchConfig({ userId: "u1" });
  const second = await client.fetchConfig({ userId: "u1" });

  assert.equal(first.gameId, "Mahjong");
  assert.equal(second.configVersion, "v1");
  assert.equal(calls, 1);
  assert.equal(requests[0].url, "https://gamealgo.test/v1/config?userId=u1&platform=rest&sdkVersion=1.0.0");
});

test("fetchConfig can force refresh", async () => {
  let calls = 0;
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    now: () => 1000,
    fetchImpl: async () => {
      calls += 1;
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: `v${calls}`,
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: {},
        }],
        configFiles: [],
      });
    },
  });

  await client.fetchConfig({ userId: "u1" });
  const refreshed = await client.fetchConfig({ userId: "u1", forceRefresh: true });

  assert.equal(refreshed.configVersion, "v2");
  assert.equal(calls, 2);
});

test("fetchConfigFile returns text and etag", async () => {
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    fetchImpl: async (input) => {
      const request = new Request(input);
      assert.equal(request.url, "https://gamealgo.test/v1/config-files/gameplay.json");
      return new Response("{\"difficulty\":\"normal\"}\n", {
        status: 200,
        headers: {
          "content-type": "application/json; charset=utf-8",
          etag: "\"sha256:test\"",
        },
      });
    },
  });

  const file = await client.fetchConfigFile("gameplay.json");

  assert.equal(file.name, "gameplay.json");
  assert.equal(file.etag, "\"sha256:test\"");
  assert.equal(file.content, "{\"difficulty\":\"normal\"}\n");
});

test("start preloads config files and exposes local executor/config readers", async () => {
  const requests: Request[] = [];
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    sdkVersion: "1.0.0",
    fetchImpl: async (input, init) => {
      const request = new Request(input, init);
      requests.push(request);
      if (request.url.includes("/v1/config-files/gameplay.json")) {
        return new Response(JSON.stringify({ ads: { rewarded: { enabled: false } }, economy: { startCoins: 120 } }), {
          headers: { "content-type": "application/json; charset=utf-8" },
        });
      }
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "v1",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: { difficulty: "hard", spawnRate: 0.7 },
        }],
        configFiles: [{
          name: "gameplay.json",
          url: "https://gamealgo.test/v1/config-files/gameplay.json",
          hash: "sha256:test",
        }],
      });
    },
  });

  const executor = client.executor("level_generator");
  assert.equal(executor.isReady, false);
  assert.equal(executor.variant("control"), "control");

  await client.start({ userId: "u1" });

  assert.equal(executor.isReady, true);
  assert.equal(executor.variant("control"), "variant-a");
  assert.equal(executor.string("difficulty", "normal"), "hard");
  assert.equal(executor.number("spawnRate", 0), 0.7);
  assert.equal(client.config.bool("ads.rewarded.enabled", true, "gameplay.json"), false);
  assert.equal(client.config.number("economy.startCoins", 0), 120);
  assert.equal(requests.length, 2);
});

test("executor executes preloaded script against the local snapshot", async () => {
  const script = `
function execute(input) {
  return {
    payload: { difficulty: input.config.difficulty, turn: input.state.turn },
    diagnostics: { variant: input.meta.variant, userId: input.meta.userId }
  };
}
`;
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    sdkVersion: "1.0.0",
    fetchImpl: async (input) => {
      const request = new Request(input);
      if (request.url.includes("/v1/config-files/level-generator.js")) {
        return new Response(script, {
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "v1",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: { difficulty: "hard" },
          script: {
            name: "level-generator.js",
            url: "https://gamealgo.test/v1/config-files/level-generator.js",
            hash: "",
          },
        }],
        configFiles: [],
      });
    },
  });

  await client.start({ userId: "u1" });
  const result = await client.executor("level_generator").execute({ turn: 7 });

  assert.deepEqual(result?.payload, { difficulty: "hard", turn: 7 });
  assert.deepEqual(result?.diagnostics, { variant: "variant-a", userId: "u1" });
});

test("start restores persisted snapshot then still tries to refresh", async () => {
  const storage = new MapStorage();
  const first = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    storage,
    fetchImpl: async (input) => {
      const request = new Request(input);
      if (request.url.includes("/v1/config-files/gameplay.json")) {
        return new Response("{\"difficulty\":\"cached\"}\n", {
          headers: { "content-type": "application/json; charset=utf-8" },
        });
      }
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "cached-v1",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: { difficulty: "cached-hard" },
        }],
        configFiles: [{
          name: "gameplay.json",
          url: "https://gamealgo.test/v1/config-files/gameplay.json",
          hash: "sha256:test",
        }],
      });
    },
  });
  await first.start({ userId: "u1" });

  let refreshAttempts = 0;
  const second = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    storage,
    fetchImpl: async () => {
      refreshAttempts += 1;
      throw new Error("offline");
    },
  });

  await second.start({ userId: "u1" });

  assert.equal(refreshAttempts, 1);
  assert.equal(second.executor("level_generator").variant("control"), "variant-a");
  assert.equal(second.config.string("difficulty", "", "gameplay.json"), "cached");
});

test("start generates and reuses anonymous user id when userId is omitted", async () => {
  const storage = new MapStorage();
  const urls: string[] = [];
  const first = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    storage,
    now: () => Date.parse("2026-05-28T10:00:00.000Z"),
    fetchImpl: async (input) => {
      const request = new Request(input);
      urls.push(request.url);
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "v1",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: {},
        }],
        configFiles: [],
      });
    },
  });

  await first.start();
  const firstIdentity = await first.userIdentity();

  const second = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    storage,
    fetchImpl: async (input) => {
      const request = new Request(input);
      urls.push(request.url);
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "v2",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [],
        configFiles: [],
      });
    },
  });

  await second.start();
  const secondIdentity = await second.userIdentity();

  assert.equal(firstIdentity.userId, secondIdentity.userId);
  assert.equal(firstIdentity.userCreatedAt, "2026-05-28T10:00:00.000Z");
  assert.equal(new URL(urls[0]).searchParams.get("userId"), firstIdentity.userId);
  assert.equal(new URL(urls[1]).searchParams.get("userId"), firstIdentity.userId);
});

test("uploadEvents fills platform, sdkVersion, appVersion, and timestamp defaults", async () => {
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    sdkVersion: "1.2.3",
    appVersion: "4.5.6",
    now: () => Date.parse("2026-05-28T10:00:00.000Z"),
    fetchImpl: async (input, init) => {
      const request = new Request(input, init);
      assert.equal(request.method, "POST");
      assert.equal(request.url, "https://gamealgo.test/v1/events/batch");
      const body = await request.json() as { events: Array<Record<string, unknown>> };
      assert.equal(body.events[0].platform, "rest");
      assert.equal(body.events[0].sdkVersion, "1.2.3");
      assert.equal(body.events[0].appVersion, "4.5.6");
      assert.equal(body.events[0].timestamp, "2026-05-28T10:00:00.000Z");
      return jsonResponse({ ok: true, accepted: 1 });
    },
  });

  const result = await client.uploadEvents([{
    eventId: "event-1",
    userId: "u1",
    sessionId: "s1",
    eventType: "session_start",
    payload: {},
  }]);

  assert.equal(result.accepted, 1);
});

test("tracker queues and flushes events after start identifies user", async () => {
  let now = Date.parse("2026-05-28T10:00:00.000Z");
  const requests: Request[] = [];
  let uploadedEvents: Array<Record<string, unknown>> = [];
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    sdkVersion: "1.2.3",
    appVersion: "4.5.6",
    isDebug: true,
    eventFlushIntervalMs: 0,
    now: () => now,
    fetchImpl: async (input, init) => {
      const request = new Request(input, init);
      requests.push(request);
      if (request.url.endsWith("/v1/events/batch")) {
        const body = await request.json() as { events: Array<Record<string, unknown>> };
        uploadedEvents = body.events;
        return jsonResponse({ ok: true, accepted: body.events.length });
      }
      return jsonResponse({
        gameId: "Mahjong",
        environment: "live",
        configVersion: "v1",
        ttlSeconds: 60,
        serverTime: "2026-05-28T10:00:00.000Z",
        experiments: [{
          key: "level_generator",
          experimentId: "exp-level-generator-001",
          variant: "variant-a",
          config: {},
        }],
        configFiles: [],
      });
    },
  });

  await client.start({ userId: "u1" });
  assert.equal(client.tracker.trackSessionStart(), true);
  now += 1500;
  assert.equal(client.tracker.trackLevelEnd({ level: 3 }), true);
  const responses = await client.tracker.flush();

  assert.equal(responses[0].accepted, 3);
  assert.equal(requests.length, 2);
  assert.equal(requests[1].url, "https://gamealgo.test/v1/events/batch");
  assert.equal(uploadedEvents.length, 3);
  assert.equal(uploadedEvents[0].eventType, "config_loaded");
  assert.equal(uploadedEvents[1].userId, "u1");
  assert.equal(uploadedEvents[1].sessionId, uploadedEvents[2].sessionId);
  assert.equal(uploadedEvents[1].eventType, "session_start");
  assert.equal(uploadedEvents[2].eventType, "level_end");
  assert.equal(uploadedEvents[2].platform, "rest");
  assert.equal(uploadedEvents[2].sdkVersion, "1.2.3");
  assert.equal(uploadedEvents[2].appVersion, "4.5.6");
  assert.equal(uploadedEvents[2].isDebug, true);
  assert.deepEqual((uploadedEvents[2].payload as Record<string, unknown>).experiments, {
    level_generator: "variant-a",
  });
  client.tracker.close();
});

test("throws structured API errors", async () => {
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.test",
    gameKey,
    fetchImpl: async () => jsonResponse({ error: "invalid_game_key", message: "Unknown key" }, 403),
  });

  await assert.rejects(
    () => client.fetchConfig({ userId: "u1" }),
    (error) => {
      assert.ok(error instanceof GameAlgoApiError);
      assert.equal(error.status, 403);
      assert.equal(error.code, "invalid_game_key");
      return true;
    },
  );
});

test("createEvent fills eventId and timestamp", () => {
  const event = createEvent({
    userId: "u1",
    sessionId: "s1",
    eventType: "session_start",
    payload: {},
  });

  assert.equal(typeof event.eventId, "string");
  assert.equal(typeof event.timestamp, "string");
});

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });
}

class MapStorage {
  private readonly values = new Map<string, string>();

  getItem(key: string): string | undefined {
    return this.values.get(key);
  }

  setItem(key: string, value: string): void {
    this.values.set(key, value);
  }

  removeItem(key: string): void {
    this.values.delete(key);
  }
}
