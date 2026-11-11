import assert from "node:assert/strict";
import test from "node:test";

import { GameAlgoBrowserStorage, GameAlgoWebClient } from "./index.ts";
import { runQuickJSSandbox } from "./quickjs-sandbox.ts";

const SCRIPT_INPUT = {
  state: { level: 3 },
  config: { difficulty: "hard" },
  meta: {
    gameId: "web-game",
    userId: "web-user",
    environment: "live" as const,
    strategy: "difficulty",
    experimentId: "experiment-1",
    variant: "treatment",
  },
};

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

test("H5 config uses current TapTap system information and preserves explicit device overrides", async (t) => {
  const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const originalTap = Object.getOwnPropertyDescriptor(globalThis, "tap");
  t.after(() => {
    if (originalNavigator) Object.defineProperty(globalThis, "navigator", originalNavigator);
    else Reflect.deleteProperty(globalThis, "navigator");
    if (originalTap) Object.defineProperty(globalThis, "tap", originalTap);
    else Reflect.deleteProperty(globalThis, "tap");
  });
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: {
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X)",
    platform: "iPhone", maxTouchPoints: 5,
  } });
  let info: unknown = { platform: "ios", system: "26.5" };
  let fail = false;
  let legacyCalls = 0;
  const tap = {
    getDeviceInfo() { if (fail) throw new Error("bridge unavailable"); return info; },
    getSystemInfoSync() { legacyCalls++; throw new Error("permission API must not be called"); },
  };
  Object.defineProperty(globalThis, "tap", { configurable: true, value: tap });
  const requests: Record<string, unknown>[] = [];
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example.com", gameKey: "ga_live_test", userId: "platform-user",
    autoLifecycle: false, preloadConfigFiles: false, device: { custom: "preserved" },
    fetchImpl: async (_input, init) => {
      requests.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return Response.json({ contextId: "ctx-system", configVersion: "1", ttlSeconds: 60, experiments: [], configFiles: [] });
    },
  });
  t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  let device = requests.at(-1)!.device as Record<string, unknown>;
  assert.equal(requests.at(-1)!.platform, "web");
  assert.equal(device.os, "ios");
  assert.equal(device.osVersion, "26.5", "the host version takes precedence over the compatibility UA");

  info = { platform: "android", system: "Android 15" };
  await client.fetchConfig({ forceRefresh: true });
  device = requests.at(-1)!.device as Record<string, unknown>;
  assert.deepEqual({ os: device.os, version: device.osVersion, runtime: device.runtime, custom: device.custom },
    { os: "android", version: "15", runtime: "h5", custom: "preserved" });
  await client.fetchConfig({ forceRefresh: true, device: { os: "windows", osVersion: "11" } });
  device = requests.at(-1)!.device as Record<string, unknown>;
  assert.equal(device.os, "windows");
  assert.equal(device.osVersion, "11");

  for (const unavailable of ["missing", "throws", "invalid", "rejects"] as const) {
    Object.defineProperty(globalThis, "tap", { configurable: true, value: unavailable === "missing" ? undefined : tap });
    fail = unavailable === "throws";
    info = unavailable === "rejects" ? Promise.reject(new Error("async bridge failed")) : { platform: "unknown", system: "26.5" };
    await client.fetchConfig({ forceRefresh: true });
    device = requests.at(-1)!.device as Record<string, unknown>;
    assert.equal(device.os, "ios", unavailable);
    assert.equal(device.osVersion, undefined, "a frozen UA must not manufacture an OS version");
  }
  info = { platform: "ios", system: "iOS 26.5" };
  await client.fetchConfig({ forceRefresh: true });
  device = requests.at(-1)!.device as Record<string, unknown>;
  assert.equal(device.osVersion, "26.5", "host information can recover on a later config request");
  assert.equal(legacyCalls, 0);
});

test("H5 browser fallback distinguishes mobile systems and desktop iPad mode without inventing versions", async (t) => {
  const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  t.after(() => {
    if (originalNavigator) Object.defineProperty(globalThis, "navigator", originalNavigator);
    else Reflect.deleteProperty(globalThis, "navigator");
  });
  const cases = [
    { userAgent: "Mozilla/5.0 (Linux; Android 15)", platform: "Linux armv8l", maxTouchPoints: 5, os: "android" },
    { userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)", platform: "Win32", maxTouchPoints: 0, os: "windows" },
    { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", platform: "MacIntel", maxTouchPoints: 0, os: "macos" },
    { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", platform: "MacIntel", maxTouchPoints: 5, os: "ios" },
    { userAgent: "Mozilla/5.0 (X11; Linux x86_64)", platform: "Linux x86_64", maxTouchPoints: 0, os: "linux" },
    { userAgent: "Mozilla/5.0 (HarmonyOS NEXT)", platform: "unknown", maxTouchPoints: 5, os: "harmonyos" },
    { userAgent: "unknown", platform: "unknown", maxTouchPoints: 0, os: undefined },
  ];
  let device: Record<string, unknown> = {};
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example.com", gameKey: "ga_live_test", userId: "browser-system-user",
    autoLifecycle: false, preloadConfigFiles: false,
    fetchImpl: async (_input, init) => {
      device = JSON.parse(String(init?.body)).device;
      return Response.json({ contextId: "ctx-browser-system", configVersion: "1", ttlSeconds: 60, experiments: [], configFiles: [] });
    },
  });
  t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  for (const value of cases) {
    Object.defineProperty(globalThis, "navigator", { configurable: true, value });
    await client.fetchConfig({ forceRefresh: true });
    assert.equal(device.os, value.os, value.userAgent);
    assert.equal(device.osVersion, undefined);
    assert.equal(device.runtime, "h5");
  }
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

// A strategy script runs before its input is frozen, so it can replace any
// global the freeze relies on. Mirrors deep_freeze_survives_tampered_intrinsics
// in runtime/rust/src/lib.rs.
test("H5 QuickJS sandbox freezes input against tampered intrinsics", async () => {
  const tampering = [
    "Object.freeze = function (value) { return value; };",
    "Object.keys = function () { return []; };",
    "Array.prototype[Symbol.iterator] = function* () {};",
    "globalThis.Set = function () { throw new Error('denied'); };",
  ];
  for (const prologue of [...tampering, tampering.join("")]) {
    const output = await runQuickJSSandbox(
      "execute",
      `${prologue} function execute(input) {
        try { input.state.level = 99; } catch (error) {}
        return { payload: { level: input.state.level, frozen: Object.isFrozen(input.state) }, diagnostics: {} };
      }`,
      SCRIPT_INPUT,
    );
    assert.deepEqual(
      (output as { payload: unknown }).payload,
      { level: 3, frozen: true },
      `input stayed mutable after: ${prologue}`,
    );
  }
});

test("H5 QuickJS sandbox leaves no enumerable globals behind", async () => {
  const output = await runQuickJSSandbox(
    "execute",
    `function execute() {
      return { payload: { globals: Object.keys(globalThis), performance: typeof performance }, diagnostics: {} };
    }`,
    SCRIPT_INPUT,
  );
  assert.deepEqual((output as { payload: unknown }).payload, {
    globals: ["execute"],
    performance: "undefined",
  });
});

test("H5 QuickJS sandbox executes strategies without browser host access", async () => {
  const output = await runQuickJSSandbox(
    "execute",
    `function execute(input) {
      return {
        payload: {
          level: input.state.level,
          difficulty: input.config.difficulty,
          fetchType: typeof fetch,
          documentType: typeof document,
          randomType: typeof Math.random
        },
        diagnostics: { isolated: true }
      };
    }`,
    SCRIPT_INPUT,
  );
  assert.deepEqual(output, {
    payload: {
      level: 3,
      difficulty: "hard",
      fetchType: "undefined",
      documentType: "undefined",
      randomType: "undefined",
    },
    diagnostics: { isolated: true },
  });
});

test("H5 QuickJS sandbox blocks dynamic code generation and infinite loops", async () => {
  await assert.rejects(
    runQuickJSSandbox(
      "execute",
      `function execute() {
        return { payload: (function() {}).constructor("return 7")(), diagnostics: {} };
      }`,
      SCRIPT_INPUT,
    ),
    /not a function|undefined|execution failed/i,
  );

  await assert.rejects(
    runQuickJSSandbox(
      "execute",
      "function execute() { while (true) {} }",
      SCRIPT_INPUT,
      {
        scriptBytes: 10 * 1024 * 1024,
        inputBytes: 256 * 1024,
        outputBytes: 256 * 1024,
        memoryBytes: 64 * 1024 * 1024,
        stackBytes: 512 * 1024,
        timeoutMs: 50,
        interruptPolls: 5_000,
      },
    ),
    /resource limit|interrupted/i,
  );
});

test("H5 URL attribution uploads only allow-listed campaign fields", async () => {
  const requests: Array<{ url: string; body: Record<string, unknown> }> = [];
  const fetchImpl: typeof fetch = async (input, init = {}) => {
    const url = String(input);
    const body = init.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    requests.push({ url, body });
    if (url.endsWith("/v1/config")) {
      return Response.json({
        contextId: "ctx-web-attribution",
        gameId: "web-game",
        environment: "live",
        configVersion: "1",
        ttlSeconds: 60,
        serverTime: "2026-09-16T00:00:00.000Z",
        experiments: [],
        configFiles: [],
      });
    }
    if (url.endsWith("/v1/attribution")) {
      return Response.json({ ok: true, accepted: 1, attributionHash: body.attributionHash });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example.com",
    gameKey: "ga_live_test",
    userId: "web-attribution-user",
    fetchImpl,
    autoLifecycle: false,
    preloadConfigFiles: false,
  });
  assert.equal(await client.waitForReady(), true);
  await client.syncUrlAttribution({
    url: "https://game.example/play?utm_source=taptap&utm_campaign=launch&secret=omit&gclid=click-1",
    referrer: "https://www.taptap.cn/app/1?private=value",
  });
  const body = requests.find((request) => request.url.endsWith("/v1/attribution"))?.body;
  assert.ok(body);
  assert.deepEqual(body.attribution, {
    utm_source: "taptap",
    utm_campaign: "launch",
    gclid: "click-1",
    referrerHost: "www.taptap.cn",
  });
  client.close();
});
