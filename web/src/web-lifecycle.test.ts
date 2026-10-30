import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { GameAlgoWebClient, type GameAlgoWebClientOptions, type GameAlgoStorage } from "./index.ts";
import type { GameEvent } from "../../rest-api/src/types.ts";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

const tick = () => new Promise<void>((done) => setImmediate(done));
const accepted = (events: GameEvent[]) => Response.json({ ok: true, accepted: events.length });

function browser(t: TestContext) {
  const win = Object.assign(new EventTarget(), { innerWidth: 390, innerHeight: 844, devicePixelRatio: 3 });
  const doc = Object.assign(new EventTarget(), { visibilityState: "visible" });
  for (const [key, value] of Object.entries({ window: win, document: doc })) {
    const original = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { configurable: true, value });
    t.after(() => {
      if (original) Object.defineProperty(globalThis, key, original);
      else Reflect.deleteProperty(globalThis, key);
    });
  }
  return {
    hide() { doc.visibilityState = "hidden"; doc.dispatchEvent(new Event("visibilitychange")); },
    show() { doc.visibilityState = "visible"; doc.dispatchEvent(new Event("visibilitychange")); },
    pagehide() { win.dispatchEvent(new Event("pagehide")); },
    pageshow() { win.dispatchEvent(new Event("pageshow")); },
    visibility(state: string) { doc.visibilityState = state; },
  };
}

function tapHost(t: TestContext, offMethods = true) {
  const original = Object.getOwnPropertyDescriptor(globalThis, "tap");
  const hide = new Set<() => void>();
  const show = new Set<() => void>();
  Object.defineProperty(globalThis, "tap", { configurable: true, value: {
    onHide: (callback: () => void) => { hide.add(callback); },
    onShow: (callback: () => void) => { show.add(callback); },
    ...(offMethods ? {
      offHide: (callback: () => void) => { hide.delete(callback); },
      offShow: (callback: () => void) => { show.delete(callback); },
    } : {}),
  } });
  t.after(() => {
    if (original) Object.defineProperty(globalThis, "tap", original);
    else Reflect.deleteProperty(globalThis, "tap");
  });
  return {
    hide: () => { for (const callback of hide) callback(); },
    show: () => { for (const callback of show) callback(); },
    listeners: () => ({ hide: hide.size, show: show.size }),
  };
}

function harness(t: TestContext, options: Partial<GameAlgoWebClientOptions> = {}) {
  const values = new Map<string, string>();
  const requests: Array<{ events: GameEvent[]; keepalive: boolean }> = [];
  const contexts: Array<{ sessionId: string; contextId: string }> = [];
  const storage: GameAlgoStorage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => { values.set(key, value); },
    removeItem: (key) => { values.delete(key); },
  };
  const control = {
    onEvents: (events: GameEvent[]): Response | Promise<Response> => accepted(events),
  };
  const fetchImpl: typeof fetch = async (input, init = {}) => {
    const url = String(input);
    const body = JSON.parse(String(init.body ?? "{}"));
    if (url.endsWith("/v1/config")) {
      const contextId = `ctx-${contexts.length + 1}`;
      contexts.push({ sessionId: body.sessionId, contextId });
      return Response.json({
        contextId, gameId: "web-test", environment: "live", configVersion: "1",
        ttlSeconds: 60, serverTime: new Date().toISOString(), experiments: [], configFiles: [],
      });
    }
    if (url.endsWith("/v1/events/batch")) {
      assert.equal(new Headers(init.headers).get("X-GameAlgo-Key"), "ga_live_web_lifecycle_test");
      requests.push({ events: body.events, keepalive: init.keepalive === true });
      return control.onEvents(body.events);
    }
    if (url.endsWith("/v1/diagnostics/sdk")) return Response.json({ ok: true, accepted: 1 });
    throw new Error(`unexpected request: ${url}`);
  };
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example", gameKey: "ga_live_web_lifecycle_test",
    storage, fetchImpl, preloadConfigFiles: false, eventFlushIntervalMs: 0,
    ...options,
  });
  t.after(() => client.close());
  return {
    client, storage, values, requests, contexts, control,
    events: () => requests.flatMap((request) => request.events),
    pending: () => [...values.entries()].filter(([key]) => key.includes(":event-queue:") && !key.endsWith(":milestones"))
      .flatMap(([, value]) => value.split("\n").map((line) => JSON.parse(line) as GameEvent)),
  };
}

test("H5 samples running time in memory, freezes hidden time and resets only on rotation", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const page = browser(t);
  let now = 0;
  const h = harness(t, { now: () => now });
  await h.client.waitForReady();
  const oldSession = h.client.tracker.currentSessionId();
  const stored = [...h.values];
  const advance = (ms: number) => { now += ms; t.mock.timers.tick(ms); };
  advance(1000);
  advance(750);
  assert.equal(h.requests.length, 0, "duration sampling does not upload events");
  assert.deepEqual([...h.values], stored, "duration sampling does not write storage");
  page.hide();
  await h.client.flush();
  assert.equal(h.events()[0].payload?.sessionDurationMs, 1750, "hide captures the subsecond tail");
  advance(60_000);
  page.show();
  await tick();
  advance(1000);
  advance(250);
  page.hide();
  await h.client.flush();
  assert.equal(h.events()[1].payload?.sessionDurationMs, 3000, "hidden minute was excluded");
  assert.equal(h.client.tracker.currentSessionId(), oldSession);
  advance(60_000);
  h.client.tracker.newSession("next-running-session");
  await h.client.flush();
  assert.equal(h.events()[2].payload?.sessionDurationMs, 3000, "rotation uses the same sampled duration");
  page.show();
  await tick();
  advance(250);
  h.client.tracker.trackSessionEnd({ reason: "manual" });
  await h.client.flush();
  assert.equal(h.events()[3].sessionId, "next-running-session");
  assert.equal(h.events()[3].payload?.sessionDurationMs, 250, "new session duration starts at zero");
  h.client.close();
  advance(60_000);
  assert.equal(h.events().length, 4, "closing the client leaves no ticking upload work");
});

test("H5 delayed callbacks add at most one second and manual endings share that clock", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  let now = 0;
  const h = harness(t, { now: () => now, autoLifecycle: false });
  await h.client.waitForReady();
  now = 41_000; // The WebView was suspended; only one timer callback can run now.
  t.mock.timers.tick(1000);
  now += 1000;
  t.mock.timers.tick(1000);
  h.client.tracker.trackSessionEnd();
  await h.client.flush();
  assert.equal(h.events()[0].payload?.sessionDurationMs, 2000);
});

test("H5 live visibility recovers from missing show callbacks and a spurious host hide cannot freeze time", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const page = browser(t);
  const tap = tapHost(t);
  let now = 0;
  const h = harness(t, { now: () => now });
  await h.client.waitForReady();
  const advance = (ms: number) => { now += ms; t.mock.timers.tick(ms); };
  advance(1000);
  tap.hide(); // A host hide that never changes the live visibility must not freeze sampling.
  await h.client.flush();
  advance(1000);
  h.client.tracker.trackSessionEndSnapshot();
  await h.client.flush();
  assert.equal(h.events().at(-1)?.payload?.sessionDurationMs, 2000);
  page.visibility("hidden"); // Neither transition dispatches a lifecycle callback.
  advance(1000);
  advance(30_000);
  page.visibility("visible");
  advance(1000); // Observe foreground and establish the new sampling baseline.
  advance(1000);
  h.client.tracker.trackSessionEndSnapshot();
  await h.client.flush();
  assert.equal(h.events().at(-1)?.payload?.sessionDurationMs, 4000,
    "timer observations resume counting even when every show notification was missed");
});

for (const [label, configured, interval] of [
  ["default", undefined, 5_000],
  ["custom", 1_250, 1_250],
  ["disabled", 0, 0],
] as const) {
  test(`H5 ordinary event flush interval: ${label}`, async (t) => {
    t.mock.timers.enable({ apis: ["setInterval"] });
    const h = harness(t, { autoLifecycle: false, eventFlushIntervalMs: configured });
    assert.equal(await h.client.waitForReady(), true);
    assert.equal(h.client.tracker.trackLevelEnd({ level: 1 }), true);
    assert.equal(h.requests.length, 0, "ordinary events stay buffered below the batch threshold");
    if (interval === 0) {
      t.mock.timers.tick(60_000);
      await tick();
      assert.equal(h.requests.length, 0, "explicit zero disables periodic uploads");
      await h.client.flush();
    } else {
      t.mock.timers.tick(interval - 1);
      await tick();
      assert.equal(h.requests.length, 0, "no upload before the configured interval");
      t.mock.timers.tick(1);
      await tick();
    }
    assert.equal(h.requests.length, 1);
    assert.equal(h.events()[0].eventType, "level_end");
    assert.equal(h.requests[0].keepalive, true);
    assert.equal(h.pending().length, 0);
  });
}

test("H5 ad_view starts a keepalive request in the enqueue call, below batch and timer thresholds", async (t) => {
  const h = harness(t, { autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  assert.equal(h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01), true);
  assert.equal(h.requests.length, 1, "request starts before any timer, await or storage callback");
  assert.equal(h.requests[0].keepalive, true);
  assert.equal(h.events()[0].eventType, "ad_view");
  assert.equal(h.client.tracker.track("ad_view", { placement: "direct" }), true);
  await h.client.flush();
  assert.equal(h.events().length, 2, "the active lane drains ads added while uploading");
  assert.equal(new Set(h.events().map((event) => event.eventId)).size, 2);
  await h.client.flush();
  assert.equal(h.events().length, 2, "ordinary flush does not replay acknowledged urgent rows");
});

test("H5 registered ad starts the existing urgent keepalive lane and does not replay after acknowledgement", async (t) => {
  const h = harness(t, { autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  const id = "gap_0123456789abcdef0123456789abcdef";
  assert.equal(h.client.tracker.trackAdPlacement(id, 0, { trackId: "callback-track" }), true);
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].keepalive, true);
  assert.equal(h.events()[0].eventType, "ad_view");
  assert.deepEqual(h.events()[0].payload, { adPlacementId: id, revenue: 0, trackId: "callback-track" });
  await h.client.flush();
  await h.client.flush();
  assert.equal(h.events().length, 1);
});

test("H5 urgent upload does not wait for a blocked event-store transaction", async (t) => {
  const write = deferred<void>();
  const response = deferred<Response>();
  let blocked = false;
  const values = new Map<string, string>();
  const storage: GameAlgoStorage = {
    getItem: (key) => values.get(key),
    setItem: async (key, value) => {
      if (blocked && key.includes(":event-queue:")) await write.promise;
      values.set(key, value);
    },
    removeItem: (key) => { values.delete(key); },
  };
  const h = harness(t, { storage, autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  blocked = true;
  h.control.onEvents = () => response.promise;
  h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01);
  assert.equal(h.requests.length, 1);
  await tick();
  response.resolve(accepted(h.events()));
  await tick();
  blocked = false;
  write.resolve();
  await h.client.flush();
  assert.equal(h.events().length, 1);
  assert.equal([...values.keys()].some((key) => key.includes(":event-queue:")), false,
    "serialized ACK cleanup cannot be overwritten by the late enqueue write");
});

test("H5 ad enqueue also drains ordinary events buffered before the ad", async (t) => {
  const h = harness(t, { autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  h.client.tracker.trackLevelEnd({ level: 1 });
  assert.equal(h.requests.length, 0);
  h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01);
  assert.equal(h.events()[0].eventType, "ad_view", "ad starts first without waiting for storage");
  await tick();
  assert.deepEqual(h.events().map((event) => event.eventType), ["ad_view", "level_end"]);
  assert.equal(h.pending().length, 0);
});

test("explicit H5 flush waits for urgent acknowledgement and its durable cleanup", async (t) => {
  const response = deferred<Response>();
  const removal = deferred<void>();
  const values = new Map<string, string>();
  const storage: GameAlgoStorage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => { values.set(key, value); },
    removeItem: async (key) => {
      if (key.includes(":event-queue:")) await removal.promise;
      values.delete(key);
    },
  };
  const h = harness(t, { storage, autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  h.control.onEvents = () => response.promise;
  h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01);
  let finished = false;
  const flushing = h.client.flush().then(() => { finished = true; });
  await tick();
  assert.equal(finished, false);
  response.resolve(accepted(h.events()));
  await tick();
  assert.equal(finished, false, "HTTP acknowledgement alone is not durable queue cleanup");
  removal.resolve();
  await flushing;
  assert.equal(finished, true);
  assert.equal(h.events().length, 1);
  assert.equal([...values.keys()].some((key) => key.includes(":event-queue:")), false);
});

test("H5 ad and session_end bypass ordinary in-flight uploads without losing durable rows", async (t) => {
  const page = browser(t);
  const ordinary = deferred<Response>();
  const ad = deferred<Response>();
  const h = harness(t);
  assert.equal(await h.client.waitForReady(), true);
  h.control.onEvents = (events) => {
    if (events[0].eventType === "level_end") return ordinary.promise;
    if (events[0].eventType === "ad_view") return ad.promise;
    return accepted(events);
  };
  h.client.tracker.trackLevelEnd({ level: 1 });
  const flushing = h.client.flush();
  await tick();
  assert.equal(h.requests.length, 1);
  h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01);
  assert.equal(h.requests.length, 2, "ad does not wait for the ordinary request");
  await tick();
  assert.deepEqual(h.pending().map((event) => event.eventType).sort(), ["ad_view", "level_end"],
    "enqueue persistence still includes the ordinary in-flight batch");
  page.hide();
  assert.equal(h.requests.length, 3, "session_end does not wait for the pending ad either");
  assert.equal(h.events()[2].eventType, "session_end");
  assert.ok(h.requests.every((request) => request.keepalive));
  await tick();
  assert.deepEqual(h.pending().map((event) => event.eventType).sort(), ["ad_view", "level_end"]);
  ordinary.resolve(accepted([h.events()[0]]));
  ad.resolve(accepted([h.events()[1]]));
  await flushing;
  await h.client.flush();
  assert.equal(h.events().length, 3);
  assert.equal(h.pending().length, 0);
});

test("H5 failed immediate ad upload retries the same event ID and timestamp", async (t) => {
  const h = harness(t, { autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  h.control.onEvents = () => Response.json({ error: "offline" }, { status: 503 });
  h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01);
  await tick();
  assert.equal(h.pending().length, 1);
  const original = h.events()[0];
  h.control.onEvents = accepted;
  await h.client.flush();
  assert.equal(h.events().length, 2);
  assert.deepEqual(h.events()[1], original);
  assert.equal(h.pending().length, 0);
});

test("H5 context readiness immediately sends an ad buffered in the current session", async (t) => {
  const h = harness(t, { autoLifecycle: false });
  assert.equal(await h.client.waitForReady(), true);
  h.client.tracker.newSession();
  h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01);
  assert.equal(h.requests.length, 1, "rotation immediately sends the old bound session end");
  assert.equal(h.events()[0].eventType, "session_end");
  await h.client.fetchConfig({ forceRefresh: true });
  await h.client.flush();
  assert.equal(h.events().length, 2);
  assert.equal(h.events()[1].contextId, "ctx-2");
  assert.equal(h.events()[1].sessionId, h.client.tracker.currentSessionId());
});

test("H5 foreground restoration preserves the session and accumulated running duration across repeated hides", async (t) => {
  const page = browser(t);
  let now = 10_000;
  const h = harness(t, { now: () => now });
  assert.equal(await h.client.waitForReady(), true);
  const oldSession = h.client.tracker.currentSessionId();
  now = 12_500;
  page.hide();
  assert.equal(h.events().length, 1, "session_end starts sending in the lifecycle callback");
  const end = h.events()[0];
  assert.equal(end.eventType, "session_end");
  assert.equal(end.sessionId, oldSession);
  assert.equal(end.contextId, "ctx-1");
  assert.equal(end.payload?.sessionDurationMs, 1000, "a delayed sample never catches up more than one second");
  assert.equal(end.payload?.reason, "visibility_hidden");
  page.pagehide();
  page.hide();
  await h.client.flush();
  assert.equal(h.events().length, 1);
  page.show();
  assert.equal(h.client.tracker.currentSessionId(), oldSession);
  page.pageshow();
  await tick();
  assert.equal(h.client.tracker.currentSessionId(), oldSession);
  assert.equal(h.contexts.length, 2);
  assert.ok(h.contexts.every(context => context.sessionId === oldSession), "context refresh must not create a session");
  now = 13_500;
  page.hide();
  await h.client.flush();
  assert.equal(h.events().length, 2);
  assert.equal(h.events()[1].sessionId, oldSession);
  assert.equal(h.events()[1].contextId, "ctx-2");
  assert.equal(h.events()[1].payload?.sessionDurationMs, 2000, "foreground restoration continues the accumulated duration");
  assert.notEqual(h.events()[1].eventId, end.eventId, "a later background generates a distinct end event");
});

test("an explicit session switch after hidden is not rotated again by the stale pageshow state", async (t) => {
  const page = browser(t);
  let now = 1000;
  const h = harness(t, { now: () => now });
  await h.client.waitForReady();
  now = 3000;
  page.hide();
  await h.client.flush();
  now = 10_000;
  h.client.tracker.newSession("explicit-new");
  page.show();
  page.pageshow();
  await tick();
  assert.equal(h.client.tracker.currentSessionId(), "explicit-new");
  const ends = h.events().filter(event => event.eventType === "session_end");
  assert.equal(ends.length, 2, "a lifecycle snapshot does not replace the explicit session boundary");
  assert.equal(ends[0].sessionId, ends[1].sessionId);
  assert.equal(ends[0].payload?.sessionDurationMs, 1000);
  assert.equal(ends[1].payload?.reason, "new_session");
  assert.equal(ends[1].payload?.sessionDurationMs, 1000, "rotation does not add hidden wall time");
  assert.equal(h.contexts.at(-1)?.sessionId, "explicit-new", "resume still obtains the explicit session's context");
  h.client.tracker.trackLevelStart();
  await h.client.flush();
  assert.equal(h.events().at(-1)?.contextId, h.contexts.at(-1)?.contextId);
});

test("H5 fullscreen ad hides upload session snapshots and revenue without rotating the session", async (t) => {
  const page = browser(t);
  const tap = tapHost(t);
  const h = harness(t);
  assert.equal(await h.client.waitForReady(), true);
  const session = h.client.tracker.currentSessionId();
  h.client.setAdShowing(true);
  tap.hide();
  assert.equal(h.events().length, 1, "Tap hide starts uploading while the document is still visible");
  assert.equal(h.events()[0].eventType, "session_end");
  assert.equal(h.events()[0].payload?.reason, "taptap_hide");
  page.hide();
  page.pagehide();
  assert.equal(h.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0.01), true);
  assert.equal(h.events().length, 2);
  assert.equal(h.events()[1].eventType, "ad_view");
  page.hide();
  h.client.setAdShowing(false);
  assert.equal(h.events().length, 2, "the ad-close flag does not create another snapshot");
  page.show();
  tap.show();
  page.pageshow();
  await h.client.flush();
  assert.equal(h.client.tracker.currentSessionId(), session);
  assert.equal(h.contexts.length, 2);
  page.hide();
  await h.client.flush();
  const ends = h.events().filter(event => event.eventType === "session_end");
  assert.equal(ends.length, 2);
  assert.ok(ends.every(event => event.sessionId === session));
});

test("Tap lock-screen callback jitter while hidden preserves the session and pending end", async (t) => {
  const page = browser(t);
  const tap = tapHost(t);
  let now = 1000;
  const h = harness(t, { now: () => now });
  await h.client.waitForReady();
  const session = h.client.tracker.currentSessionId();
  now = 2500;
  tap.hide();
  page.hide();
  tap.show(); // Observed on iOS during lock, while document.visibilityState is hidden.
  tap.hide();
  await h.client.flush();
  assert.equal(h.events().length, 1);
  assert.equal(h.events()[0].payload?.sessionDurationMs, 1000);
  assert.equal(h.contexts.length, 1, "a hidden onShow must not refresh the context");
  now = 5000;
  page.show();
  tap.show();
  await tick();
  assert.equal(h.client.tracker.currentSessionId(), session);
  assert.equal(h.contexts.length, 2);
  assert.deepEqual(tap.listeners(), { hide: 1, show: 1 }, "page events must not duplicate host subscriptions");
  now = 6000;
  tap.hide();
  await h.client.flush();
  assert.equal(h.events().length, 2);
  assert.equal(h.events()[1].payload?.sessionDurationMs, 2000);
  assert.equal(h.events()[1].sessionId, session);
  h.client.close();
  assert.deepEqual(tap.listeners(), { hide: 0, show: 0 });
});

test("Tap can be injected after H5 initialization", async (t) => {
  browser(t);
  t.mock.timers.enable({ apis: ["setInterval"] });
  const h = harness(t);
  await h.client.waitForReady();
  const tap = tapHost(t);
  t.mock.timers.tick(500);
  assert.deepEqual(tap.listeners(), { hide: 1, show: 1 });
  tap.hide();
  assert.equal(h.events()[0].payload?.reason, "taptap_hide");
  await h.client.flush();
});

test("Tap lifecycle opt-outs and retained callbacks after close are respected", async (t) => {
  browser(t);
  const tap = tapHost(t, false);
  const manual = harness(t, { autoSessionLifecycle: false });
  await manual.client.waitForReady();
  manual.client.tracker.trackLevelEnd();
  tap.hide();
  await manual.client.flush();
  assert.deepEqual(manual.events().map(event => event.eventType), ["level_end"]);
  manual.client.close();
  const detached = harness(t, { autoLifecycle: false });
  await detached.client.waitForReady();
  assert.deepEqual(tap.listeners(), { hide: 1, show: 1 }, "opted-out clients do not subscribe to Tap");
  tap.hide();
  tap.show();
  await tick();
  assert.equal(detached.events().length, 0);
  assert.equal(manual.events().length, 1, "callbacks retained by the host become inert after close");
  assert.equal(manual.contexts.length, 1);
});

test("lifecycle snapshots bypass gameplay quotas and persist even when ordinary enqueue persistence is disabled", async (t) => {
  browser(t);
  const tap = tapHost(t);
  const h = harness(t, { eventPersistOnEnqueue: false });
  await h.client.waitForReady();
  h.client.tracker.setEventQuota({ mode: "enforce", ordinaryEventLimit: 0, exemptEventTypes: [] });
  h.control.onEvents = () => Response.json({ error: "offline" }, { status: 503 });
  tap.hide();
  assert.equal(h.events().length, 1);
  await tick();
  assert.deepEqual(h.pending(), h.events(), "the offline snapshot is durable with its original ID and time");
  h.control.onEvents = accepted;
  await h.client.flush();
  assert.equal(h.events().length, 2);
  assert.deepEqual(h.events()[1], h.events()[0]);
  assert.equal(h.pending().length, 0);
});

test("H5 pagehide remains a fallback and explicit lifecycle opt-outs/close are respected", async (t) => {
  const page = browser(t);
  const h = harness(t);
  assert.equal(await h.client.waitForReady(), true);
  page.pagehide();
  await h.client.flush();
  assert.equal(h.events()[0].payload?.reason, "pagehide");
  h.client.close();
  const manual = harness(t, { autoSessionLifecycle: false });
  assert.equal(await manual.client.waitForReady(), true);
  const session = manual.client.tracker.currentSessionId();
  manual.client.tracker.trackLevelEnd();
  page.hide();
  page.pagehide();
  page.show();
  page.pageshow();
  await manual.client.flush();
  assert.equal(manual.events().some((event) => event.eventType === "session_end"), false);
  assert.equal(manual.client.tracker.currentSessionId(), session);
  manual.client.close();
  const detached = harness(t, { autoLifecycle: false });
  assert.equal(await detached.client.waitForReady(), true);
  page.hide();
  page.pagehide();
  assert.equal(detached.events().length, 0);
  detached.client.close();
  page.show();
  page.pagehide();
  assert.equal(h.events().length, 1, "closed clients cannot generate another session boundary");
});

test("H5 restart retries a generated but unacknowledged session_end with its original context", async (t) => {
  browser(t);
  const tap = tapHost(t);
  const first = harness(t);
  assert.equal(await first.client.waitForReady(), true);
  first.control.onEvents = () => Response.json({ error: "offline" }, { status: 503 });
  tap.hide();
  await tick();
  const original = first.events()[0];
  assert.equal(first.pending().length, 1);
  first.client.close();
  const second = harness(t, { storage: first.storage });
  assert.equal(await second.client.waitForReady(), true);
  await second.client.flush();
  assert.equal(second.events().length, 1);
  assert.deepEqual(second.events()[0], original);
  assert.notEqual(second.client.tracker.currentSessionId(), original.sessionId);
  assert.equal(first.pending().length, 0);
});
