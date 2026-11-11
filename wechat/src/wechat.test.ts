import assert from "node:assert/strict";
import test from "node:test";
import { GameAlgoWechatClient, GameAlgoWechatStorage, GameAlgoWechatTransport, type WechatHost } from "./index.ts";
import { sha256HexSync } from "../../rest-api/src/sha256.ts";
import { encodeUtf8 } from "../../rest-api/src/utf8.ts";
import { parseHttpBaseUrl, resolveHttpUrl } from "../../rest-api/src/http-url.ts";

const placement = "gap_0123456789abcdef0123456789abcdef";
const turn = async () => { for (let i = 0; i < 3; i++) await new Promise(resolve => setImmediate(resolve)); };

function fixture(values = new Map<string, string>()) {
  const requests: Array<{ url: string; body: any; options: Parameters<WechatHost["request"]>[0] }> = [];
  const hide = new Set<() => void>(), show = new Set<() => void>(), network = new Set<(value: any) => void>();
  let offline = false, blockEvents = false;
  let config: any = { gameId: "wechat-test", environment: "live", configVersion: "1", ttlSeconds: 60, experiments: [
    { key: "difficulty", experimentId: "exp-1", variant: "treatment", config: { difficulty: 3 } },
    { key: "script", experimentId: "exp-2", variant: "treatment", config: {}, script: { name: "remote.js", versionId: "script-1", url: "/v1/scripts/script-1", hash: "sha256:" + "a".repeat(64) } },
  ], configFiles: [{ name: "settings.json", contentType: "application/json" }, { name: "remote.js" }] };
  const wx: WechatHost = {
    request(options) {
      const body = options.data ? JSON.parse(options.data) : {};
      requests.push({ url: options.url, body, options });
      if (blockEvents && options.url.endsWith("/events/batch")) return { abort() {} };
      queueMicrotask(() => {
        if (options.url.endsWith("/config")) options.success({ statusCode: 200, data: { ...config, contextId: `ctx-${requests.length}` } });
        else if (options.url.includes("/config-files/")) options.success({ statusCode: 200, data: '{"theme":"dark"}', header: { "Content-Type": "application/json" } });
        else if (offline) options.fail({ errMsg: "request:fail offline" });
        else options.success({ statusCode: 200, data: JSON.stringify({ ok: true, accepted: body.events?.length ?? 1, rejected: [] }) });
      });
      return { abort() {} };
    },
    getStorageSync: key => values.get(key) ?? "",
    setStorageSync: (key, value) => { values.set(key, value); },
    removeStorageSync: key => { values.delete(key); },
    getDeviceInfo: () => ({ platform: "ios", system: "iOS 18.7", brand: "Apple", model: "iPhone" }),
    getAccountInfoSync: () => ({ miniProgram: { appId: "wx0123456789abcdef" } }),
    onHide: callback => { hide.add(callback); }, offHide: callback => { hide.delete(callback); },
    onShow: callback => { show.add(callback); }, offShow: callback => { show.delete(callback); },
    onNetworkStatusChange: callback => { network.add(callback); }, offNetworkStatusChange: callback => { network.delete(callback); },
  };
  const options = { wx, baseUrl: "https://gamealgo.test/algo_sdk", gameKey: "ga_live_wechat_test", eventFlushIntervalMs: 0 };
  return { wx, options, values, requests, hide, show, network,
    setOffline(value: boolean) { offline = value; }, setBlockEvents(value: boolean) { blockEvents = value; },
    setConfig(value: any) { config = value; },
    events() { return requests.flatMap(request => request.body.events ?? []); },
  };
}

test("WeChat uses native requests, keeps the URL prefix, reports its own host and loads parameter/JSON config only", async t => {
  const f = fixture();
  const client = new GameAlgoWechatClient({ ...f.options, platform: "ios", device: { wechatAppId: "forged", runtimeMiniappId: "tapmc-forged" } } as never);
  t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  assert.equal(f.requests[0].url, "https://gamealgo.test/algo_sdk/v1/config");
  assert.equal(f.requests[0].options.header?.["X-GameAlgo-Key"], f.options.gameKey);
  assert.equal(f.requests[0].body.platform, "wechat");
  assert.deepEqual({ os: f.requests[0].body.device.os, version: f.requests[0].body.device.osVersion, appId: f.requests[0].body.device.wechatAppId },
    { os: "ios", version: "18.7", appId: "wx0123456789abcdef" });
  assert.equal(f.requests[0].body.device.runtimeMiniappId, undefined);
  assert.equal(client.config.string("theme", "light"), "dark");
  assert.equal(client.executor("difficulty").number("difficulty"), 3);
  assert.deepEqual((await client.executor("difficulty").execute({}))?.payload, { difficulty: 3 });
  assert.equal(await client.executor("script").execute({}), undefined);
  assert.equal(f.requests.some(request => request.url.includes("remote.js") || request.url.includes("/scripts/")), false);
  client.tracker.trackLevelStart({ level_id: "关卡🙂" });
  await client.flush();
  assert.equal(f.events()[0].eventType, "level_start");
});

test("hide snapshots flush during an ordinary upload, and repeated foreground callbacks keep the session", async t => {
  const f = fixture();
  const client = new GameAlgoWechatClient(f.options);
  t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  const session = client.tracker.currentSessionId();
  f.setBlockEvents(true);
  client.tracker.trackLevelStart({ level_id: "one" });
  const pending = client.flush().catch(() => undefined);
  await turn();
  for (const callback of f.hide) callback();
  assert.ok(f.events().some((event: any) => event.eventType === "session_end"));
  assert.ok(f.requests.filter(request => request.url.endsWith("/events/batch")).length >= 2);
  await turn();
  assert.ok([...f.values.values()].some(value => value.includes("session_end")));
  for (const callback of f.hide) callback();
  assert.equal(f.events().filter((event: any) => event.eventType === "session_end").length, 1);
  for (let i = 0; i < 2; i++) for (const callback of f.show) callback();
  assert.equal(client.tracker.currentSessionId(), session);
  client.close();
  await pending;
});

test("foreground sampling excludes background time and caps a delayed callback at one second", async t => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  const f = fixture();
  let now = 1_000_000;
  const client = new GameAlgoWechatClient({ ...f.options, now: () => now });
  t.after(() => client.close());
  await client.waitForReady();
  now += 1000; t.mock.timers.tick(1000);
  assert.equal(client.getForegroundTimeMs(), 1000);
  for (const callback of f.hide) callback();
  now += 60_000; t.mock.timers.tick(1000);
  assert.equal(client.getForegroundTimeMs(), 1000);
  for (const callback of f.show) callback();
  now += 20_000; t.mock.timers.tick(1000);
  assert.equal(client.getForegroundTimeMs(), 2000);
  const elapsed = client.getForegroundTimeMs();
  client.tracker.newSession();
  assert.equal(client.getForegroundTimeMs(), elapsed);
});

test("offline events and old session snapshots survive restart with their original IDs and context", async t => {
  const f = fixture();
  let first: GameAlgoWechatClient | undefined, second: GameAlgoWechatClient | undefined;
  t.after(() => { first?.close(); second?.close(); });
  first = new GameAlgoWechatClient(f.options);
  await first.waitForReady();
  const identity = await first.userIdentity();
  const session = first.tracker.currentSessionId();
  f.setOffline(true);
  first.tracker.trackLevelEnd({ level_id: "last" });
  for (const callback of f.hide) callback();
  await first.flush().catch(() => undefined);
  await turn();
  const original = f.events().filter((event: any) => event.eventType === "session_end")[0];
  assert.ok(original);
  first.close();
  f.setOffline(false);
  f.requests.length = 0;
  second = new GameAlgoWechatClient(f.options);
  assert.equal(await second.waitForReady(), true);
  assert.equal((await second.userIdentity()).userId, identity.userId);
  assert.notEqual(second.tracker.currentSessionId(), session);
  await second.flush();
  const recovered = f.events().find((event: any) => event.eventId === original.eventId);
  assert.ok(recovered);
  assert.equal(recovered.sessionId, original.sessionId);
  assert.equal(recovered.contextId, original.contextId);
  assert.equal(recovered.timestamp, original.timestamp);
});

test("native storage faults remain failures and never replace unread data with a memory success", () => {
  const f = fixture();
  const storage = new GameAlgoWechatStorage(f.wx);
  f.values.set("root", "old");
  f.wx.getStorageSync = () => { throw new Error("storage unavailable"); };
  assert.throws(() => storage.getItemDurably("root"), /unavailable/);
  f.wx.setStorageSync = () => { throw new Error("disk full"); };
  assert.throws(() => storage.setItemDurably("root", "new"), /disk full/);
  assert.equal(f.values.get("root"), "old");
});

test("stalled native requests time out once and close cancels pending tasks", async () => {
  const f = fixture();
  let aborts = 0;
  f.wx.request = () => ({ abort() { aborts++; } });
  const transport = new GameAlgoWechatTransport(f.wx, 10);
  await assert.rejects(transport.fetch("https://gamealgo.test"), /timed out/);
  assert.equal(aborts, 1);
  const pending = transport.fetch("https://gamealgo.test");
  transport.close();
  await assert.rejects(pending, /client is closed/);
  assert.equal(aborts, 2);
  await assert.rejects(transport.fetch("https://gamealgo.test"), /client is closed/);
});

test("rewarded video closes report once before business callbacks, retain native reward flags and never invent revenue or a track ID", async t => {
  const f = fixture();
  const closes = new Set<(...values: any[]) => void>(), errors = new Set<(...values: any[]) => void>();
  let shows = 0, loads = 0;
  f.wx.createRewardedVideoAd = () => ({
    load: async () => { loads++; }, show: async () => { shows++; },
    onClose: callback => { closes.add(callback); }, offClose: callback => { closes.delete(callback); },
    onError: callback => { errors.add(callback); }, offError: callback => { errors.delete(callback); }, destroy() {},
  });
  const client = new GameAlgoWechatClient(f.options);
  t.after(() => client.close());
  await client.waitForReady();
  const space = client.createAdSpace({ adUnitId: "wechat-existing-unit" });
  let rewarded: unknown;
  await space.show(placement, { onClose(result) {
    rewarded = result?.isEnded;
    assert.ok(f.events().some((event: any) => event.eventType === "ad_view"), "enqueue/upload happens before business callback");
  } }, { trackId: "stale-taptap-id", revenue: 999 });
  assert.equal(shows, 1);
  assert.ok(loads >= 1);
  const callback = [...closes][0];
  callback({ isEnded: false }); callback({ isEnded: false });
  await client.flush();
  const ads = f.events().filter((event: any) => event.eventType === "ad_view");
  assert.equal(ads.length, 1);
  assert.equal(rewarded, false);
  assert.deepEqual({ revenue: ads[0].payload.revenue, status: ads[0].payload.revenueStatus, trackId: ads[0].payload.trackId, network: ads[0].payload.network },
    { revenue: 0, status: "unavailable", trackId: undefined, network: "wechat" });
});

test("portable UTF-8/hash and URL handling work when browser primitives do not exist", t => {
  const encoder = Object.getOwnPropertyDescriptor(globalThis, "TextEncoder");
  const url = Object.getOwnPropertyDescriptor(globalThis, "URL");
  const vectors = ["", "ASCII", "关卡🙂", "\ud800x\udc00"].map(value => ({ value, bytes: encodeUtf8(value), hash: sha256HexSync(value) }));
  t.after(() => { Object.defineProperty(globalThis, "TextEncoder", encoder!); Object.defineProperty(globalThis, "URL", url!); });
  Object.defineProperty(globalThis, "TextEncoder", { configurable: true, value: undefined });
  Object.defineProperty(globalThis, "URL", { configurable: true, value: undefined });
  for (const { value, bytes, hash } of vectors) { assert.deepEqual(encodeUtf8(value), bytes); assert.equal(sha256HexSync(value), hash); }
  const base = parseHttpBaseUrl("https://EXAMPLE.com:443/algo_sdk/");
  assert.equal(base.origin, "https://example.com");
  assert.equal(resolveHttpUrl("../v1/config", base), "https://example.com/v1/config");
  assert.throws(() => parseHttpBaseUrl("https://user:secret@example.com"), /Invalid/);
});
