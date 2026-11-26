import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { GameAlgoWebClient, type GameAlgoStorage, type GameAlgoWebClientOptions } from "./index.ts";
import type { GameEvent } from "../../rest-api/src/types.ts";

const turn = async () => { for (let n = 0; n < 3; n++) await new Promise<void>(resolve => setImmediate(resolve)); };
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
const config = (contextId: unknown = "ctx-recovered", extra = {}) => Response.json({
  contextId, gameId: "recovery", environment: "live", configVersion: "1", ttlSeconds: 60,
  experiments: [], configFiles: [], ...extra,
});
const accepted = (events: GameEvent[]) => Response.json({ ok: true, accepted: events.length });

function fixture(t: TestContext, options: Partial<GameAlgoWebClientOptions> = {}, values = new Map<string, string>()) {
  const configs: any[] = [], events: GameEvent[] = [], signals: AbortSignal[] = [];
  const control = {
    config: (_body: any): Response | Promise<Response> => config(),
    events: (batch: GameEvent[]): Response | Promise<Response> => accepted(batch),
    file: (): Response | Promise<Response> => Response.json({}),
  };
  const storage: GameAlgoStorage = { getItem: key => values.get(key),
    setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } };
  const client = new GameAlgoWebClient({
    baseUrl: "https://recovery.test", gameKey: "ga_live_recovery_test", experimentIntegrationVersion: 1, storage,
    autoLifecycle: false, eventFlushIntervalMs: 0, preloadConfigFiles: false,
    fetchImpl: async (input, init = {}) => {
      const url = String(input), body = JSON.parse(String(init.body ?? "{}"));
      if (init.signal) signals.push(init.signal);
      if (url.endsWith("/v1/config")) { configs.push(body); return control.config(body); }
      if (url.endsWith("/v1/events/batch")) { events.push(...body.events); return control.events(body.events); }
      if (url.includes("/v1/config-files/")) return control.file();
      if (url.includes("/v1/diagnostics/")) return Response.json({ ok: true, accepted: 1 });
      throw new Error(`Unexpected path: ${url}`);
    }, ...options,
  });
  t.after(() => client.close());
  return { client, configs, events, signals, control, values, storage,
    pending: () => [...values].filter(([key]) => key.includes(":event-queue:") && !key.endsWith(":milestones"))
      .flatMap(([, value]) => {
        const root = JSON.parse(value);
        return root.format === "gamealgo-event-chunks-v2"
          ? root.chunks.flatMap((ref: { key: string }) => JSON.parse(values.get(ref.key)!).rows.map((row: { event: string }) => JSON.parse(row.event)))
          : value.split("\n").map(row => JSON.parse(row));
      }) as GameEvent[],
  };
}

test("initial config retries with bounded backoff, keeps its session and releases unbound events", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const f = fixture(t);
  f.control.config = () => f.configs.length < 8 ? Response.json({}, { status: 503 }) : config();
  await turn();
  assert.equal(f.configs.length, 1);
  assert.equal(f.client.tracker.trackLevelEnd({ level: 1 }), true);
  await f.client.flush();
  const original = f.pending()[0];
  assert.equal(original.contextId, "");
  for (const [n, delay] of [1000, 2000, 4000, 8000, 16000, 30000, 30000].entries()) {
    t.mock.timers.tick(delay - 1); await turn();
    assert.equal(f.configs.length, n + 1);
    t.mock.timers.tick(1); await turn();
    assert.equal(f.configs.length, n + 2);
  }
  assert.equal(await f.client.waitForReady(), true);
  await f.client.flush();
  assert.ok(f.configs.every(body => body.sessionId === original.sessionId));
  assert.equal(f.events[0].eventId, original.eventId);
  assert.equal(f.events[0].timestamp, original.timestamp);
  assert.equal(f.events[0].contextId, "ctx-recovered");
  t.mock.timers.tick(120_000); await turn();
  assert.equal(f.configs.length, 8, "success stops automatic requests");
});

test("an offline snapshot stays usable while a fresh session context recovers automatically", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const first = fixture(t); await first.client.waitForReady(); first.client.close();
  const f = fixture(t, {}, first.values);
  f.control.config = () => { throw new TypeError("offline"); };
  assert.equal(await f.client.waitForReady(), true);
  f.client.tracker.trackLevelEnd(); await f.client.flush();
  assert.equal(f.events.length, 0, "cached Context is not reused for the new session");
  const original = f.pending()[0];
  f.control.config = () => config("ctx-fresh");
  t.mock.timers.tick(1000); await turn();
  await f.client.flush();
  assert.equal(f.events[0].eventId, original.eventId);
  assert.equal(f.events[0].contextId, "ctx-fresh");
});

test("restored ordinary events automatically flush without new gameplay events", async t => {
  for (const format of ["chunks", "legacy"]) for (const incremental of [true, false]) {
    await t.test(`${format}, persistOnEnqueue=${incremental}`, async t => {
      t.mock.timers.enable({ apis: ["setInterval"] });
      const first = fixture(t);
      await first.client.waitForReady();
      first.control.events = () => { throw new TypeError("offline"); };
      first.client.tracker.trackLevelEnd({ level_id: "restored-level" });
      await assert.rejects(first.client.flush(), /offline/);
      const original = first.pending()[0];
      first.client.close();
      if (format === "legacy") {
        const rootKey = [...first.values.keys()].find(key => key.includes(":event-queue:") && !key.endsWith(":milestones"))!;
        first.values.set(rootKey, JSON.stringify(original));
      }

      const next = fixture(t, { eventFlushIntervalMs: 5000, eventPersistOnEnqueue: incremental }, first.values);
      await next.client.waitForReady();
      await turn();
      assert.equal(next.events.length, 0);
      t.mock.timers.tick(4999); await turn();
      assert.equal(next.events.length, 0);
      t.mock.timers.tick(1); await turn();
      assert.equal(next.events.length, 1, "restoring a queue arms the normal flush timer");
      assert.deepEqual(next.events[0], original, "replay keeps the original event, Session and Context");
      assert.equal(next.pending().length, 0, "successful acknowledgement clears durable data");
    });
  }
});

test("invalid Context responses retry; authorization errors do not", async t => {
  for (const mode of ["invalid", "unauthorized", "forbidden"]) await t.test(mode, async t => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
    const f = fixture(t);
    f.control.config = () => mode === "invalid" ? config("") : Response.json({}, { status: mode === "unauthorized" ? 401 : 403 });
    await turn();
    if (mode === "invalid") {
      f.control.config = () => config(); t.mock.timers.tick(1000); await turn();
      assert.equal(await f.client.waitForReady(), true);
      assert.equal(f.configs.length, 2);
    } else {
      assert.equal(await f.client.waitForReady(), false);
      t.mock.timers.tick(60_000); await turn();
      assert.equal(f.configs.length, 1);
    }
  });
});

test("explicit recovery wakes initialization without another scheduled config request", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const f = fixture(t);
  f.control.config = () => Response.json({}, { status: 503 }); await turn();
  f.control.config = () => config("ctx-explicit");
  await f.client.fetchConfig({ forceRefresh: true });
  assert.equal(await f.client.waitForReady(), true);
  t.mock.timers.tick(60_000); await turn();
  assert.equal(f.configs.length, 2);
});

test("closing or changing the session stops pending initial config retries", async t => {
  for (const action of ["close", "rotate"]) await t.test(action, async t => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
    const f = fixture(t);
    f.control.config = () => Response.json({}, { status: 503 }); await turn();
    if (action === "close") f.client.close(); else f.client.tracker.newSession("explicit-next");
    t.mock.timers.tick(60_000); await turn();
    assert.equal(f.configs.length, 1);
    assert.equal(await f.client.waitForReady(), false);
  });
});

test("a failed preload never causes a second config request", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const f = fixture(t, { preloadConfigFiles: true });
  f.control.config = () => config("ctx-with-file", { configFiles: [{ name: "settings.json" }] });
  f.control.file = () => { throw new TypeError("file offline"); };
  assert.equal(await f.client.waitForReady(), true);
  t.mock.timers.tick(60_000); await turn();
  assert.equal(f.configs.length, 1);
});

test("a stalled initial fetch times out and its late response cannot overwrite recovery", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const stalled = deferred<Response>();
  const f = fixture(t);
  f.control.config = () => f.configs.length === 1 ? stalled.promise : config("ctx-after-timeout");
  await turn();
  t.mock.timers.tick(12_000); await turn();
  assert.equal(f.signals[0].aborted, true);
  t.mock.timers.tick(1000); await turn();
  assert.equal(await f.client.waitForReady(), true);
  stalled.resolve(config("ctx-late")); await turn();
  f.client.tracker.trackLevelEnd(); await f.client.flush();
  assert.equal(f.events[0].contextId, "ctx-after-timeout");
  assert.equal(f.configs.length, 2);
});

test("event timeout includes a stalled response body and retries the original durable event", async t => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const f = fixture(t); await f.client.waitForReady();
  const body = deferred<string>();
  f.control.events = () => Object.assign(Response.json({}), { text: () => body.promise });
  f.client.tracker.trackLevelEnd();
  const failed = assert.rejects(f.client.flush(), /timed out/); await turn();
  const original = f.events[0];
  t.mock.timers.tick(15_000); await failed;
  assert.equal(f.signals.at(-1)?.aborted, true);
  assert.equal(f.pending()[0].eventId, original.eventId);
  f.control.events = accepted;
  await f.client.flush();
  assert.deepEqual(f.events[1], original);
  body.resolve(JSON.stringify({ ok: true, accepted: 1 })); await turn();
  assert.equal(f.pending().length, 0);
});

test("direct-only incomplete or invalid ACKs retain events; valid terminal receipts clear them", async t => {
  for (const reply of [null, {}, { ok: false, accepted: 1 }, { accepted: -1 }, { accepted: 1.5 },
    { accepted: 2 }, { ok: true, accepted: 0 }, { ok: true, accepted: 0, rejected: [] }]) {
    await t.test(JSON.stringify(reply), async t => {
      const f = fixture(t); await f.client.waitForReady();
      f.control.events = () => Response.json(reply);
      f.client.tracker.trackLevelEnd();
      await assert.rejects(f.client.flush(), /invalid telemetry batch acknowledgement/);
      assert.equal(f.pending().length, 1);
      const original = f.events[0]; f.control.events = accepted;
      await f.client.flush();
      assert.deepEqual(f.events[1], original);
      assert.equal(f.pending().length, 0);
    });
  }
  for (const reply of [{ ok: true, accepted: 1 }, { ok: true, accepted: 0, rejected: [{ index: 0, reason: "invalid" }] }]) {
    const f = fixture(t); await f.client.waitForReady();
    f.control.events = () => Response.json(reply); f.client.tracker.trackLevelEnd();
    await f.client.flush(); await f.client.flush();
    assert.equal(f.events.length, 1); assert.equal(f.pending().length, 0);
  }
});

test("an early hide is buffered once with its original time, duration, ID and session", async t => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const identity = deferred<undefined>();
  let now = 1000;
  const win = new EventTarget(), doc = Object.assign(new EventTarget(), { visibilityState: "visible" });
  for (const [key, value] of Object.entries({ window: win, document: doc })) {
    const original = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { configurable: true, value });
    t.after(() => original ? Object.defineProperty(globalThis, key, original) : Reflect.deleteProperty(globalThis, key));
  }
  const values = new Map<string, string>();
  const f = fixture(t, { now: () => now, autoLifecycle: true, storage: {
    getItem: key => key.includes(":identity:") ? identity.promise : values.get(key),
    setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); },
  } }, values);
  f.control.events = () => Response.json({}, { status: 503 });
  const session = f.client.tracker.currentSessionId();
  for (let n = 0; n < 2; n++) { now += 1000; t.mock.timers.tick(1000); }
  now = 3500;
  doc.visibilityState = "hidden"; doc.dispatchEvent(new Event("visibilitychange"));
  win.dispatchEvent(new Event("pagehide")); doc.dispatchEvent(new Event("visibilitychange"));
  now = 90_000; identity.resolve(undefined);
  assert.equal(await f.client.waitForReady(), true); await turn();
  assert.equal(f.pending().length, 1);
  const original = f.pending()[0];
  assert.equal(original.sessionId, session); assert.equal(original.contextId, "ctx-recovered");
  assert.equal(original.timestamp, new Date(3500).toISOString());
  assert.equal(original.payload?.sessionDurationMs, 2500);
  f.control.events = accepted; await f.client.flush();
  assert.ok(f.events.every(event => event.eventId === original.eventId));
  assert.equal(f.pending().length, 0);
  doc.visibilityState = "visible"; doc.dispatchEvent(new Event("visibilitychange"));
  now += 1000; t.mock.timers.tick(1000);
  doc.visibilityState = "hidden"; doc.dispatchEvent(new Event("visibilitychange"));
  await f.client.flush();
  assert.equal(f.events.at(-1)?.payload?.sessionDurationMs, 3500,
    "identity hydration cannot reset a duration already reported in an early snapshot");
  assert.equal(f.configs.length, 1, "foreground restoration never starts another config request");
});

test("a buffered early snapshot cannot inherit a later explicit session's Context", async t => {
  const identity = deferred<undefined>();
  const values = new Map<string, string>();
  const f = fixture(t, { accountUserId: "real-account", storage: {
    getItem: key => key.includes(":identity:") ? identity.promise : values.get(key),
    setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); },
  } }, values);
  const oldSession = f.client.tracker.currentSessionId();
  assert.equal(f.client.tracker.trackSessionEndSnapshot({ reason: "early" }), true);
  f.client.tracker.newSession("later-session");
  identity.resolve(undefined); assert.equal(await f.client.waitForReady(), true);
  await f.client.flush();
  assert.equal(f.configs[0].sessionId, "later-session");
  assert.equal(f.events.length, 0);
  const original = f.pending()[0];
  assert.equal(original.sessionId, oldSession); assert.equal(original.contextId, "");
  assert.equal(original.accountUserId, "real-account");
});
