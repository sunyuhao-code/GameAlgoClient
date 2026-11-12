import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { GAMEPROPEL_CRAZYGAMES_SDK_VERSION, GamePropelCrazyGamesClient, GamePropelCrazyGamesStorage, type CrazyGamesHost, type GameAlgoStorage } from "./index.ts";
import type { CrazyGamesAdCallbacks } from "./host.ts";
import { CrazyGamesTransport } from "./transport.ts";

const placement = "gap_0123456789abcdef0123456789abcdef";
const turn = async () => { for (let i = 0; i < 4; i++) await new Promise(resolve => setImmediate(resolve)); };
function fixture(values = new Map<string, string>()) {
  const requests: Array<{ url: string; body: any; init: RequestInit }> = [];
  const ads: Array<{ type: string; callbacks: CrazyGamesAdCallbacks }> = [];
  let offline = false, blockNext = false, partialAcceptance = false;
  const storage: GameAlgoStorage = { getItem: key => values.get(key), setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } };
  const host: CrazyGamesHost = { init: async () => {}, environment: "crazygames",
    ad: { requestAd(type, callbacks) { ads.push({ type, callbacks }); } },
    user: { systemInfo: { os: { name: "iOS", version: "26.5" }, device: { type: "mobile" }, browser: { name: "Safari", version: "26.5" }, applicationType: "apple_store", locale: "zh-CN" } } };
  const fetchImpl: typeof fetch = async (input, init = {}) => {
    const url = String(input), body = init.body ? JSON.parse(String(init.body)) : {};
    requests.push({ url, body, init });
    if (url.endsWith("/v1/config")) return Response.json({ contextId: `ctx-${requests.length}`, gameId: "crazygames-test", configVersion: "1", environment: "live", ttlSeconds: 60,
      configFiles: [{ name: "settings.json", contentType: "application/json" }, { name: "script.js" }],
      experiments: [{ key: "difficulty", experimentId: "exp-1", variant: "a", config: { difficulty: 3 } },
        { key: "script", experimentId: "exp-2", variant: "a", config: {}, script: { name: "script.js", versionId: "v1", hash: "a".repeat(64), url: "/script.js" } }] });
    if (url.includes("/config-files/")) return Response.json({ theme: "dark" });
    if (blockNext) { blockNext = false; return new Promise(() => {}); }
    if (offline) throw new Error("offline");
    return Response.json({ ok: true, accepted: partialAcceptance ? 1 : body.events?.length ?? 1, rejected: [] });
  };
  return { host, ads, requests, values, storage, fetchImpl,
    options: { crazyGames: host, fetchImpl, storage, baseUrl: "https://gamealgo.test/algo_sdk", gameKey: "ga_live_local_test", eventFlushIntervalMs: 0 },
    events: () => requests.flatMap(request => request.body.events ?? []),
    offline(value: boolean) { offline = value; }, partialAcceptance() { partialAcceptance = true; }, blockNext() { blockNext = true; } };
}
function browser(t: TestContext) {
  const win = new EventTarget(), doc = Object.assign(new EventTarget(), { visibilityState: "visible" });
  for (const [key, value] of Object.entries({ window: win, document: doc })) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { configurable: true, value });
    t.after(() => { if (previous) Object.defineProperty(globalThis, key, previous); else Reflect.deleteProperty(globalThis, key); });
  }
  return { win, doc, hide() { doc.visibilityState = "hidden"; doc.dispatchEvent(new Event("visibilitychange")); },
    show() { doc.visibilityState = "visible"; doc.dispatchEvent(new Event("visibilitychange")); } };
}

test("waits for the real host initialization, fixes its wire platform, uses system info and preloads JSON only", async t => {
  const f = fixture(); let ready!: () => void;
  f.host.init = () => new Promise(resolve => { ready = resolve; });
  const pending = GamePropelCrazyGamesClient.init({ ...f.options, platform: "web", device: { runtimeMiniappId: "forged", runtime: "taptap" } } as never);
  assert.equal(f.requests.length, 0);
  ready();
  const client = await pending; t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  assert.equal(f.requests[0].body.platform, "crazygames");
  assert.equal(f.requests[0].body.sdkVersion, GAMEPROPEL_CRAZYGAMES_SDK_VERSION);
  assert.deepEqual({ os: f.requests[0].body.device.os, version: f.requests[0].body.device.osVersion, runtime: f.requests[0].body.device.runtime }, { os: "ios", version: "26.5", runtime: "crazygames" });
  assert.equal(f.requests[0].body.device.runtimeMiniappId, undefined);
  assert.equal(client.executor("difficulty").number("difficulty"), 3);
  assert.equal(client.config.string("theme", "light"), "dark");
  assert.equal(await client.executor("script").execute({}), undefined);
  assert.equal(f.requests.some(request => request.url.includes("script.js") || request.url.includes("/scripts/")), false);
  await client.fetchConfig({ platform: "web", forceRefresh: true });
  assert.equal(f.requests.at(-1)?.body.platform, "crazygames");
});

test("local host forces debug, missing or disabled hosts fail explicitly, and host initialization is bounded", async t => {
  const f = fixture(); Object.assign(f.host, { environment: "local" });
  const client = await GamePropelCrazyGamesClient.init({ ...f.options, isDebug: false }); t.after(() => client.close());
  await client.waitForReady();
  assert.equal(f.requests[0].body.isDebug, true);
  client.tracker.trackLevelStart({ levelId: "1" }); await client.flush();
  assert.equal(f.events()[0].isDebug, true);
  Object.assign(f.host, { environment: "disabled" });
  await assert.rejects(GamePropelCrazyGamesClient.init(f.options), /disabled/);
  await assert.rejects(GamePropelCrazyGamesClient.init({ ...f.options, crazyGames: undefined }), /Load https/);
  f.host.init = () => new Promise(() => {});
  await assert.rejects(GamePropelCrazyGamesClient.init({ ...f.options, hostInitTimeoutMs: 10 }), /timed out/);
});

test("adStarted enqueues once before business callbacks and flushes immediately with unavailable revenue", async t => {
  const f = fixture(); const client = await GamePropelCrazyGamesClient.init(f.options); t.after(() => client.close());
  await client.waitForReady();
  let started = 0, finished = 0;
  const request = client.createAdSpace({ adType: "rewarded" }).show(placement, {
    onStarted() { started++; assert.ok(f.values.size > 0); throw new Error("business error"); },
    onFinished() { finished++; },
  }, { trackId: "forged", revenue: 100, revenueStatus: "known" });
  assert.equal(f.events().length, 0);
  f.ads[0].callbacks.adStarted(); f.ads[0].callbacks.adStarted();
  await turn();
  const views = f.events().filter(event => event.eventType === "ad_view");
  assert.equal(views.length, 1);
  assert.deepEqual({ revenue: views[0].payload.revenue, status: views[0].payload.revenueStatus, type: views[0].payload.hostAdType, network: views[0].payload.network },
    { revenue: 0, status: "unavailable", type: "rewarded", network: "crazygames" });
  assert.equal(views[0].payload.trackId, undefined);
  assert.equal(f.requests.find(request => request.body.events?.some((event: any) => event.eventType === "ad_view"))?.init.keepalive, true);
  f.ads[0].callbacks.adFinished(); f.ads[0].callbacks.adError({ code: "other", message: "late error" });
  await request;
  assert.equal(started, 1); assert.equal(finished, 1);
});

test("ad errors do not invent impressions or rewards, native rejections settle, and both types share the host slot", async t => {
  const f = fixture(); const first = await GamePropelCrazyGamesClient.init(f.options);
  const second = await GamePropelCrazyGamesClient.init({ ...f.options, crazyGames: { ...f.host } }); t.after(() => { first.close(); second.close(); });
  await first.waitForReady(); await second.waitForReady();
  let finished = 0;
  const pending = first.createAdSpace({ adType: "midgame" }).show(placement, { onFinished() { finished++; } });
  await assert.rejects(second.createAdSpace({ adType: "rewarded" }).show(placement), /already pending/);
  f.ads[0].callbacks.adError({ code: "adblock", message: "blocked" });
  await assert.rejects(pending, { code: "adblock" });
  assert.equal(finished, 0); assert.equal(f.events().length, 0);
  f.host.ad.requestAd = async () => { throw new Error("native rejection"); };
  await assert.rejects(first.createAdSpace({ adType: "rewarded" }).show(placement), /native rejection/);
});

test("close cancels pending ads, ignores stale callbacks, and releases the shared host slot", async t => {
  const f = fixture(); const client = await GamePropelCrazyGamesClient.init(f.options);
  await client.waitForReady();
  const pending = client.createAdSpace({ adType: "rewarded" }).show(placement);
  const rejected = assert.rejects(pending, /closed/);
  client.close(); await rejected;
  f.ads[0].callbacks.adStarted(); f.ads[0].callbacks.adFinished();
  assert.equal(f.events().length, 0);
  const next = await GamePropelCrazyGamesClient.init(f.options); t.after(() => next.close());
  const again = next.createAdSpace({ adType: "rewarded" }).show(placement);
  f.ads[1].callbacks.adFinished(); await again;
});

test("visibility snapshots bypass an active upload, dedupe hide/pagehide, and resume preserves the session", async t => {
  const b = browser(t), f = fixture(); const client = await GamePropelCrazyGamesClient.init(f.options); t.after(() => client.close());
  await client.waitForReady(); const session = client.tracker.currentSessionId();
  f.blockNext(); client.tracker.trackLevelStart({ levelId: "1" });
  const pending = client.flush().catch(() => undefined); await turn();
  b.hide(); b.win.dispatchEvent(new Event("pagehide"));
  await turn();
  assert.equal(f.events().filter(event => event.eventType === "session_end").length, 1);
  assert.ok([...f.values.values()].some(value => value.includes("session_end")));
  b.show(); b.win.dispatchEvent(new Event("pageshow"));
  assert.equal(client.tracker.currentSessionId(), session);
  client.close(); await pending;
});

test("one-second samples exclude background and long gaps, recover without a resume callback and newSession closes the old one", async t => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const b = browser(t), f = fixture(); let now = 1_000_000;
  const client = await GamePropelCrazyGamesClient.init({ ...f.options, now: () => now }); t.after(() => client.close());
  await client.waitForReady();
  now += 1000; t.mock.timers.tick(1000); assert.equal(client.getForegroundTimeMs(), 1000);
  b.hide(); now += 60_000; t.mock.timers.tick(1000); assert.equal(client.getForegroundTimeMs(), 1000);
  b.doc.visibilityState = "visible";
  now += 1000; t.mock.timers.tick(1000);
  now += 20_000; t.mock.timers.tick(1000); assert.equal(client.getForegroundTimeMs(), 2000);
  const oldSession = client.tracker.currentSessionId(); client.tracker.newSession(); await turn();
  assert.notEqual(client.tracker.currentSessionId(), oldSession);
  assert.equal(client.getForegroundTimeMs(), 2000);
  assert.ok(f.events().some(event => event.sessionId === oldSession && event.payload.reason === "new_session" && event.payload.sessionDurationMs === 2000));
});

test("offline tails survive restart with their original IDs/context and partial acceptance stops retrying the batch", async t => {
  const f = fixture(); let first: GamePropelCrazyGamesClient | undefined, next: GamePropelCrazyGamesClient | undefined;
  t.after(() => { first?.close(); next?.close(); });
  first = await GamePropelCrazyGamesClient.init(f.options); await first.waitForReady(); f.offline(true);
  first.tracker.trackLevelEnd({ levelId: "old", outcome: "win" });
  await assert.rejects(first.flush(), /offline/);
  const old = f.events()[0]; first.close(); f.offline(false);
  next = await GamePropelCrazyGamesClient.init(f.options); await next.waitForReady(); await next.flush();
  const restored = f.events().findLast(event => event.eventId === old.eventId);
  assert.equal(restored.contextId, old.contextId); assert.equal(restored.sessionId, old.sessionId); assert.equal(restored.timestamp, old.timestamp);
  const count = f.events().length; await next.flush(); assert.equal(f.events().length, count);
  f.partialAcceptance();
  for (let i = 0; i < 3; i++) next.tracker.trackLevelEnd({ levelId: `partial-${i}` });
  await next.flush();
  const partialCount = f.events().length; await next.flush(); assert.equal(f.events().length, partialCount);
});

test("ordinary events flush every five seconds", async t => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const f = fixture(); const client = await GamePropelCrazyGamesClient.init({ ...f.options, eventFlushIntervalMs: undefined }); t.after(() => client.close());
  await client.waitForReady(); client.tracker.trackLevelStart({ levelId: "1" });
  t.mock.timers.tick(4999); await turn(); assert.equal(f.events().length, 0);
  t.mock.timers.tick(1); await turn(); assert.equal(f.events().length, 1);
});

test("the default storage never touches cloud-progress localStorage or pretends memory is durable", async t => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "window");
  let touched = 0;
  Object.defineProperty(globalThis, "window", { configurable: true, value: { get localStorage() { touched++; throw new Error("cloud-progress storage must not be touched"); } } });
  t.after(() => { if (previous) Object.defineProperty(globalThis, "window", previous); else Reflect.deleteProperty(globalThis, "window"); });
  const storage = new GamePropelCrazyGamesStorage({ indexedDB: null });
  assert.equal(await storage.getItem("identity"), undefined);
  await assert.rejects(storage.setItem("queue", "event"), /unavailable/);
  await assert.rejects(storage.removeItem("queue"), /unavailable/);
  assert.equal(touched, 0);
});

test("HTTP timeouts include body reads and close cancels active requests", async () => {
  const headersOnly = async () => ({ ok: true, status: 200, headers: new Headers(), text: () => new Promise(() => {}) });
  const transport = new CrazyGamesTransport(headersOnly as typeof fetch, 10);
  await assert.rejects(transport.fetch("https://gamealgo.test"), /timed out/);
  const pending = transport.fetch("https://gamealgo.test");
  const rejected = assert.rejects(pending, /closed/); transport.close(); await rejected;
});
