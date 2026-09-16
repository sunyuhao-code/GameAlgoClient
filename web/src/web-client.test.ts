import assert from "node:assert/strict";
import test from "node:test";

import { GameAlgoBrowserStorage, GameAlgoWebClient } from "./index.ts";

test("H5 client always reports the web platform and flushes events", async () => {
  const requests: Array<{ url: string; body: Record<string, unknown>; keepalive: boolean }> = [];
  const fetchImpl: typeof fetch = async (input, init = {}) => {
    const url = String(input);
    const body = init.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    requests.push({ url, body, keepalive: init.keepalive === true });
    if (url.endsWith("/v1/config")) {
      return Response.json({
        contextId: "ctx-web",
        gameId: "web-game",
        environment: "live",
        configVersion: "1",
        ttlSeconds: 60,
        serverTime: "2026-09-16T00:00:00.000Z",
        experiments: [],
        configFiles: [],
      });
    }
    if (url.endsWith("/v1/events/batch")) return Response.json({ ok: true, accepted: 1 });
    throw new Error(`unexpected request: ${url}`);
  };
  const values = new Map<string, string>();
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example.com",
    gameKey: "ga_live_test",
    fetchImpl,
    autoLifecycle: false,
    preloadConfigFiles: false,
    storage: {
      getItem: (key) => values.get(key),
      setItem: (key, value) => { values.set(key, value); },
      removeItem: (key) => { values.delete(key); },
    },
  });

  assert.equal(await client.waitForReady(), true);
  assert.equal(requests[0].body.platform, "web");
  assert.equal((requests[0].body.device as Record<string, unknown>).runtime, "h5");

  assert.equal(client.tracker.trackLevelStart({ levelId: "level-1" }), true);
  await client.flush();
  const eventRequest = requests.find((request) => request.url.endsWith("/v1/events/batch"));
  assert.ok(eventRequest);
  assert.equal(eventRequest.keepalive, true);
  assert.equal((eventRequest.body.events as Array<Record<string, unknown>>)[0].eventType, "level_start");
  client.close();
});

test("browser storage falls back without IndexedDB", async () => {
  const values = new Map<string, string>();
  const localStorage = {
    get length() { return values.size; },
    clear: () => values.clear(),
    getItem: (key: string) => values.get(key) ?? null,
    key: (index: number) => [...values.keys()][index] ?? null,
    removeItem: (key: string) => { values.delete(key); },
    setItem: (key: string, value: string) => { values.set(key, value); },
  } satisfies Storage;
  const storage = new GameAlgoBrowserStorage({ localStorage });
  await storage.setItem("identity", "user-1");
  assert.equal(await storage.getItem("identity"), "user-1");
  await storage.removeItem("identity");
  assert.equal(await storage.getItem("identity"), undefined);
});

test("H5 event batches stay within the keepalive byte budget", async () => {
  const eventRequests: Array<{ events: unknown[]; keepalive: boolean }> = [];
  const fetchImpl: typeof fetch = async (input, init = {}) => {
    const url = String(input);
    if (url.endsWith("/v1/config")) {
      return Response.json({
        contextId: "ctx-web-budget",
        gameId: "web-game",
        environment: "live",
        configVersion: "1",
        ttlSeconds: 60,
        serverTime: "2026-09-16T00:00:00.000Z",
        experiments: [],
        configFiles: [],
      });
    }
    const body = JSON.parse(String(init.body)) as { events: unknown[] };
    eventRequests.push({ events: body.events, keepalive: init.keepalive === true });
    return Response.json({ ok: true, accepted: body.events.length });
  };
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example.com",
    gameKey: "ga_live_test",
    userId: "web-budget-user",
    fetchImpl,
    autoLifecycle: false,
    preloadConfigFiles: false,
  });
  assert.equal(await client.waitForReady(), true);
  const payload = { detail: "中".repeat(10_000) };
  client.tracker.track("level_start", payload);
  client.tracker.track("level_end", payload);
  await client.flush();
  assert.deepEqual(eventRequests.map((request) => request.events.length), [1, 1]);
  assert.ok(eventRequests.every((request) => request.keepalive));
  client.close();
});
