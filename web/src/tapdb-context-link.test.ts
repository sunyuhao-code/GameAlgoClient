import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";

import { GameAlgoWebClient, type GameAlgoWebClientOptions, type GameAlgoStorage } from "./index.ts";
import { GameAlgoRestClient } from "../../rest-api/src/client.ts";

type LinkEvent = {
  name: string;
  properties: Record<string, string | boolean>;
  success: (result: unknown) => void;
  fail: (result: unknown) => void;
  complete: (result: unknown) => void;
};

const tick = () => new Promise<void>((resolve) => setImmediate(resolve));
const configResponse = (contextId: unknown) => Response.json({
  contextId, gameId: "web-test", environment: "live", configVersion: "1",
  ttlSeconds: 60, serverTime: new Date().toISOString(), experiments: [], configFiles: [],
  eventQuota: { mode: "enforce", policyVersion: 1, ordinaryEventLimit: 1, quotaDate: "2026-10-27", resetAt: "2026-10-28T00:00:00Z", exemptEventTypes: ["session_end"] },
});

function tapHost(t: TestContext, value: unknown): void {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "tap");
  Object.defineProperty(globalThis, "tap", { configurable: true, value });
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, "tap", previous);
    else Reflect.deleteProperty(globalThis, "tap");
  });
}

function harness(t: TestContext, options: Partial<GameAlgoWebClientOptions> & { autoStart?: boolean } = {}) {
  const values = new Map<string, string>();
  const storage: GameAlgoStorage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => { values.set(key, value); },
    removeItem: (key) => { values.delete(key); },
  };
  const requests: Array<{ url: string; body: Record<string, any> }> = [];
  const logs: string[] = [];
  const control = { config: (_body: Record<string, unknown>): Response | Promise<Response> => configResponse("ctx-first") };
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example", gameKey: "ga_live_tapdb_web_test", storage,
    autoLifecycle: false, preloadConfigFiles: false, eventFlushIntervalMs: 0,
    logger: (message) => { logs.push(message); },
    fetchImpl: async (input, init) => {
      const url = String(input);
      const body = JSON.parse(String(init?.body ?? "{}"));
      requests.push({ url, body });
      if (url.endsWith("/v1/config")) return control.config(body);
      if (url.endsWith("/v1/events/batch")) return Response.json({ ok: true, accepted: body.events.length });
      if (url.endsWith("/v1/diagnostics/sdk")) return Response.json({ ok: true, accepted: 1 });
      throw new Error(`Unexpected URL: ${url}`);
    },
    ...options,
  });
  t.after(() => client.close());
  return { client, control, storage, requests, logs };
}

test("H5 initialization sends one flat TapDB identity link using the verified object/callback signature", async (t) => {
  const calls: LinkEvent[] = [];
  const host = {
    logEvent(this: unknown, ...args: LinkEvent[]) {
      assert.equal(this, host);
      assert.equal(args.length, 1);
      calls.push(args[0]);
      args[0].success({ errno: 0, errMsg: "tap.logEvent:ok" });
      args[0].complete({ errno: 0, errMsg: "tap.logEvent:ok" });
    },
  };
  tapHost(t, host);
  const h = harness(t, { accountUserId: "account-is-not-device-id", deviceId: "external-id-is-not-user-id" });
  assert.equal(await h.client.waitForReady(), true);
  const request = h.requests.find((request) => request.url.endsWith("/v1/config"))!.body;
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "gamealgo_context_link");
  assert.deepEqual(calls[0].properties, {
    gamealgo_context_id: "ctx-first", gamealgo_device_id: request.userId, gamealgo_is_debug: false,
  });
  assert.notEqual(calls[0].properties.gamealgo_device_id, request.accountUserId);
  assert.notEqual(calls[0].properties.gamealgo_device_id, request.device.deviceId);
  assert.equal(h.logs.some((message) => message.includes("TapDB")), false, "success is silent");
  assert.equal(h.client.tracker.track("ordinary_probe", {}), true, "link does not consume the event quota");
  await h.client.flush();
  const events = h.requests.filter((request) => request.url.endsWith("/v1/events/batch")).flatMap((request) => request.body.events);
  assert.equal(events.length, 1);
  assert.notEqual(events[0].eventType, "gamealgo_context_link", "link must not enter the GameAlgo event queue");

  await h.client.fetchConfig();
  await h.client.fetchConfig({ forceRefresh: true });
  h.client.tracker.newSession("second-session");
  await h.client.fetchConfig({ forceRefresh: true });
  assert.equal(calls.length, 1, "cache hits, refreshes and session changes must not repeat the event");
  const next = harness(t, { storage: h.storage, isDebug: true });
  assert.equal(await next.client.waitForReady(), true);
  assert.equal(calls.length, 2, "new client initialization may report again");
  assert.equal(calls[1].properties.gamealgo_device_id, request.userId);
  assert.equal(calls[1].properties.gamealgo_is_debug, true);
});

test("failed or invalid config responses do not consume the first valid link", async (t) => {
  const calls: LinkEvent[] = [];
  tapHost(t, { logEvent: (options: LinkEvent) => { calls.push(options); } });
  const h = harness(t, { userId: "explicit-user", isDebug: false, autoStart: false });
  h.control.config = () => Response.json({ error: "unavailable" }, { status: 503 });
  await assert.rejects(h.client.fetchConfig());
  for (const contextId of [undefined, null, "", "  ", 123]) {
    h.control.config = () => configResponse(contextId);
    await h.client.fetchConfig({ forceRefresh: true });
    assert.equal(calls.length, 0);
  }
  h.control.config = () => configResponse("ctx-recovered");
  await h.client.fetchConfig({ forceRefresh: true, userId: "request-user", isDebug: true });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].properties, {
    gamealgo_context_id: "ctx-recovered", gamealgo_device_id: "request-user", gamealgo_is_debug: true,
  });
});

test("TapDB uses the config request identity even if current identity changes before the response", async (t) => {
  const calls: LinkEvent[] = [];
  tapHost(t, { logEvent: (options: LinkEvent) => { calls.push(options); } });
  const h = harness(t, { autoStart: false });
  let release!: (response: Response) => void;
  h.control.config = () => new Promise((resolve) => { release = resolve; });
  const pending = h.client.fetchConfig({ userId: "request-identity", isDebug: true });
  await tick();
  await h.client.userIdentity("later-current-identity");
  release(configResponse("ctx-original-request"));
  await pending;
  assert.deepEqual(calls[0].properties, {
    gamealgo_context_id: "ctx-original-request", gamealgo_device_id: "request-identity", gamealgo_is_debug: true,
  });
});

test("an old session response and a closed client cannot emit a late identity link", async (t) => {
  const calls: LinkEvent[] = [];
  tapHost(t, { logEvent: (options: LinkEvent) => { calls.push(options); } });
  const h = harness(t, { autoStart: false });
  let release!: (response: Response) => void;
  h.control.config = () => new Promise((resolve) => { release = resolve; });
  const pending = h.client.fetchConfig({ userId: "old-user", sessionId: "old-session" });
  await tick();
  h.client.tracker.newSession("new-session");
  release(configResponse("ctx-old-session"));
  await pending;
  assert.equal(calls.length, 0);
  h.control.config = () => configResponse("ctx-current");
  await h.client.fetchConfig({ forceRefresh: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].properties.gamealgo_context_id, "ctx-current");

  const closed = harness(t, { autoStart: false });
  closed.control.config = () => new Promise((resolve) => { release = resolve; });
  const afterClose = closed.client.fetchConfig();
  await tick();
  closed.client.close();
  release(configResponse("ctx-after-close"));
  await afterClose;
  assert.equal(calls.length, 1);
});

test("restored offline snapshots do not link until a new server context is obtained", async (t) => {
  tapHost(t, undefined);
  const initial = harness(t);
  assert.equal(await initial.client.waitForReady(), true);
  initial.client.close();
  const calls: LinkEvent[] = [];
  Object.defineProperty(globalThis, "tap", { configurable: true, value: { logEvent: (options: LinkEvent) => { calls.push(options); } } });
  const restored = harness(t, { storage: initial.storage });
  restored.control.config = () => { throw new Error("offline"); };
  assert.equal(await restored.client.waitForReady(), true, "existing offline snapshot remains usable");
  assert.equal(calls.length, 0);
  restored.control.config = () => configResponse("ctx-online");
  await restored.client.fetchConfig({ forceRefresh: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].properties.gamealgo_context_id, "ctx-online");
});

test("a late TapDB bridge sends the first config identity once without another config request", async (t) => {
  for (const unavailable of [undefined, {}, { get logEvent() { throw new Error("bridge loading"); } }]) {
    await t.test(String(unavailable), async (t) => {
      t.mock.timers.enable({ apis: ["setInterval"] });
      tapHost(t, unavailable);
      const calls: LinkEvent[] = [];
      const h = harness(t, { userId: "first-user", isDebug: true });
      assert.equal(await h.client.waitForReady(), true);
      h.client.tracker.newSession("later-session");
      h.control.config = () => configResponse("ctx-later");
      await h.client.fetchConfig({ userId: "later-user", isDebug: false, forceRefresh: true });
      const requestCount = h.requests.filter((request) => request.url.endsWith("/v1/config")).length;
      const host = { logEvent(this: unknown, options: LinkEvent) {
        assert.equal(this, host);
        calls.push(options);
        options.success({ errno: 0 });
      } };
      Object.defineProperty(globalThis, "tap", { configurable: true, value: host });
      t.mock.timers.tick(500);
      assert.equal(calls.length, 1);
      assert.deepEqual(calls[0].properties, {
        gamealgo_context_id: "ctx-first", gamealgo_device_id: "first-user", gamealgo_is_debug: true,
      });
      t.mock.timers.tick(30_000);
      assert.equal(calls.length, 1);
      assert.equal(h.requests.filter((request) => request.url.endsWith("/v1/config")).length, requestCount);
    });
  }
});

test("closing a client cancels its pending TapDB link without affecting a new client", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  tapHost(t, undefined);
  const old = harness(t, { userId: "closed-user" });
  assert.equal(await old.client.waitForReady(), true);
  old.client.close();
  const calls: LinkEvent[] = [];
  Object.defineProperty(globalThis, "tap", { configurable: true, value: { logEvent: (options: LinkEvent) => { calls.push(options); } } });
  t.mock.timers.tick(1_000);
  assert.equal(calls.length, 0);
  const next = harness(t, { userId: "new-user" });
  assert.equal(await next.client.waitForReady(), true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].properties.gamealgo_device_id, "new-user");
});

test("bridge discovery stops after ten seconds and a later config can still send the pending first link", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  let lookups = 0;
  tapHost(t, { get logEvent() { lookups++; return undefined; } });
  const h = harness(t);
  assert.equal(await h.client.waitForReady(), true);
  t.mock.timers.tick(10_000);
  const stoppedAt = lookups;
  assert.ok(stoppedAt > 1);
  t.mock.timers.tick(60_000);
  assert.equal(lookups, stoppedAt, "a missing optional bridge must not be polled forever");
  const calls: LinkEvent[] = [];
  Object.defineProperty(globalThis, "tap", { configurable: true, value: { logEvent: (options: LinkEvent) => { calls.push(options); } } });
  h.control.config = () => configResponse("ctx-after-window");
  await h.client.fetchConfig({ forceRefresh: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].properties.gamealgo_context_id, "ctx-first");
});

test("optional or failing hosts never block readiness or retry the link", async (t) => {
  for (const mode of ["absent", "missing_method", "getter_error", "throw", "false", "rejected_promise", "pending_promise", "no_callback", "failure_callback"]) {
    await t.test(mode, async (t) => {
      let attempts = 0;
      let options: LinkEvent | undefined;
      const host = {
        logEvent(value: LinkEvent) {
          attempts++;
          options = value;
          if (mode === "throw") throw new Error("bridge error");
          if (mode === "false") return false;
          if (mode === "rejected_promise") return Promise.reject(new Error("native failure"));
          if (mode === "pending_promise") return new Promise(() => {});
          if (mode === "failure_callback") {
            value.fail({ errno: 1001 });
            value.complete({ errno: 1001 });
          }
        },
      };
      tapHost(t, mode === "absent" ? undefined : mode === "missing_method" ? {} : mode === "getter_error"
        ? { get logEvent() { throw new Error("bridge unavailable"); } } : host);
      const h = harness(t);
      assert.equal(await h.client.waitForReady(), true);
      await tick();
      const failures = h.logs.filter((line) => line.includes("TapDB context link failed"));
      assert.equal(failures.length, ["throw", "false", "rejected_promise", "failure_callback"].includes(mode) ? 1 : 0);
      await h.client.fetchConfig({ forceRefresh: true });
      assert.ok(attempts <= 1);
      if (mode === "no_callback") {
        options!.success({ errno: 0 });
        options!.complete({ errno: 0 });
        assert.equal(h.logs.filter((line) => line.includes("TapDB")).length, 0);
      }
    });
  }
});

test("a failing logger cannot turn a TapDB rejection into an initialization failure", async (t) => {
  tapHost(t, { logEvent: (options: LinkEvent) => { options.fail({ errno: 1001 }); } });
  const h = harness(t, { logger: (message) => { if (message.includes("TapDB")) throw new Error("bad logger"); } });
  assert.equal(await h.client.waitForReady(), true);
});

test("the shared REST client does not report TapDB events", async (t) => {
  let calls = 0;
  tapHost(t, { logEvent: () => { calls++; } });
  const client = new GameAlgoRestClient({
    baseUrl: "https://gamealgo.example", gameKey: "ga_live_rest_test", userId: "rest-user",
    eventFlushIntervalMs: 0, preloadConfigFiles: false, logger: false,
    fetchImpl: async () => configResponse("ctx-rest"),
  });
  t.after(() => client.tracker.close());
  assert.equal(await client.waitForReady(), true);
  assert.equal(calls, 0);
});
