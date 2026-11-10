import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { GameAlgoWebClient, type GameAlgoRewardVideoAdOptions, type GameAlgoStorage } from "./index.ts";
import type { GameEvent } from "../../rest-api/src/types.ts";

const placement = `gap_${"a".repeat(32)}`;
type Callback = (...values: unknown[]) => void;

function nativeAd() {
  const calls: string[] = [];
  let close: Callback = () => {};
  let error: Callback = () => {};
  const ad = {
    load: async () => { calls.push("load"); },
    show: async () => { calls.push("show"); },
    onClose(callback: Callback) { calls.push("onClose"); close = callback; },
    onError(callback: Callback) { calls.push("onError"); error = callback; },
    offClose(callback: Callback) { assert.equal(callback, close); calls.push("offClose"); },
    offError(callback: Callback) { assert.equal(callback, error); calls.push("offError"); },
    destroy() { calls.push("destroy"); },
  };
  return { ad, calls, close: (...values: unknown[]) => close(...values), error: (...values: unknown[]) => error(...values) };
}

async function harness(t: TestContext) {
  const original = Object.getOwnPropertyDescriptor(globalThis, "tap");
  const ads: ReturnType<typeof nativeAd>[] = [];
  const host = {
    createRewardedVideoAd(options: { adUnitId: string }) {
      assert.equal(this, host);
      assert.deepEqual(options, { adUnitId: "native-unit" });
      const native = nativeAd();
      ads.push(native);
      return native.ad;
    },
  };
  Object.defineProperty(globalThis, "tap", { configurable: true, value: host });
  t.after(() => {
    if (original) Object.defineProperty(globalThis, "tap", original);
    else Reflect.deleteProperty(globalThis, "tap");
  });
  const values = new Map<string, string>();
  const storage: GameAlgoStorage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => { values.set(key, value); },
    removeItem: (key) => { values.delete(key); },
  };
  const requests: Array<{ events: GameEvent[]; keepalive?: boolean }> = [];
  const logs: string[] = [];
  const client = new GameAlgoWebClient({
    baseUrl: "https://gamealgo.example", gameKey: "ga_live_ad_test",
    autoLifecycle: false, eventFlushIntervalMs: 0, preloadConfigFiles: false,
    storage, logger: (message) => { logs.push(message); },
    fetchImpl: async (input, init = {}) => {
      const body = JSON.parse(String(init.body ?? "{}"));
      if (String(input).endsWith("/v1/config")) return Response.json({
        contextId: "ctx-ad", gameId: "ad-test", configVersion: "1",
        ttlSeconds: 60, experiments: [], configFiles: [],
      });
      if (String(input).endsWith("/v1/events/batch")) {
        requests.push({ events: body.events, keepalive: init.keepalive });
        return Response.json({ ok: true, accepted: body.events.length });
      }
      throw new Error(`Unexpected request: ${String(input)}`);
    },
  });
  t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  return { client, host, ads, requests, logs, events: () => requests.flatMap((r) => r.events).filter((e) => e.eventType === "ad_view") };
}

test("TapTap wrapper preserves raw close arguments, reports once before game logic and flushes urgently", async (t) => {
  const h = await harness(t);
  const raw = { isEnded: false, code: 500, msg: "early close" };
  const extra = { extra: JSON.stringify({ track_id: "  original+/=  " }) };
  const payload = { source: "revive", trackId: "stale", detail: { level: 2 } };
  const order: string[] = [];
  const track = h.client.tracker.trackAdPlacement.bind(h.client.tracker);
  h.client.tracker.trackAdPlacement = (...args: Parameters<typeof track>) => {
    order.push("track");
    return track(...args);
  };
  await h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose(result, second) {
    order.push("game");
    assert.equal(result, raw);
    assert.equal(second, extra);
  } }, payload);
  assert.deepEqual(h.ads[0].calls, ["onClose", "onError", "load", "show"]);
  assert.equal(h.events().length, 0, "load/show are not exposure boundaries; Promise resolves before close");
  payload.source = "mutated";
  payload.detail.level = 99;
  h.ads[0].close(raw, extra);
  h.ads[0].close({ isEnded: true, trackId: "duplicate" });
  assert.deepEqual(order, ["track", "game"]);
  // No manual flush: the critical-event path must deliver even with its timer disabled.
  for (let i = 0; i < 10 && h.events().length === 0; i++) await new Promise(setImmediate);
  assert.equal(h.events().length, 1);
  assert.deepEqual(h.events()[0].payload, {
    source: "revive", detail: '{"level":2}', trackId: "  original+/=  ",
    adPlacementId: placement, revenue: 0, network: "taptap",
  });
  assert.equal(h.events()[0].contextId, "ctx-ad");
  assert.equal(h.requests.find((r) => r.events.some((e) => e.eventType === "ad_view"))?.keepalive, true);
  assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 1);
});

test("missing track ID still reports without a stale ID; each playback has its own close guard", async (t) => {
  const h = await harness(t);
  let closes = 0;
  for (const result of [undefined, { isEnded: true, trackId: "real-second" }]) {
    await h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose() { closes++; } }, { trackId: "stale" });
    h.ads.at(-1)!.close(result);
    h.ads.at(-1)!.close(result);
  }
  await h.client.flush();
  assert.equal(closes, 2);
  assert.equal(h.events().length, 2);
  assert.equal(h.events()[0].payload?.trackId, undefined);
  assert.equal(h.events()[1].payload?.trackId, "real-second");
  assert.ok(h.logs.some((l) => l.includes("hasTrackId=false")));
});

test("native onError is forwarded once without exposure; a queued later close still reports", async (t) => {
  const h = await harness(t);
  const errors: unknown[][] = [];
  const error = { errCode: 1001 };
  let closes = 0;
  await h.client.showRewardVideoAd(placement, {
    adUnitId: "native-unit", onError: (...args) => { errors.push(args); }, onClose() { closes++; },
  });
  h.ads[0].error(error, "raw-detail");
  h.ads[0].error({ errCode: 1002 });
  await h.client.flush();
  assert.equal(h.events().length, 0);
  assert.deepEqual(errors, [[error, "raw-detail"]]);
  h.ads[0].close({ isEnded: false, trackId: "late-close" });
  await h.client.flush();
  assert.equal(closes, 1);
  assert.equal(h.events()[0].payload?.trackId, "late-close");
  assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 1);
});

test("native creation/load/show failures reject without synthetic callbacks or exposure", async (t) => {
  for (const phase of ["create", "load", "show"] as const) {
    await t.test(phase, async (t) => {
      const h = await harness(t);
      const error = new Error(phase);
      const create = h.host.createRewardedVideoAd;
      h.host.createRewardedVideoAd = function (options) {
        if (phase === "create") throw error;
        const ad = create.call(this, options);
        ad[phase] = async () => { throw error; };
        return ad;
      };
      const unexpected = () => { assert.fail("must not invent host callbacks"); };
      await assert.rejects(h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose: unexpected, onError: unexpected }), (e) => e === error);
      await h.client.flush();
      assert.equal(h.events().length, 0);
      if (phase !== "create") assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 1);
    });
  }
});

test("load error events skip show; cleanup-generated close never creates an exposure", async (t) => {
  const h = await harness(t);
  const create = h.host.createRewardedVideoAd;
  let errors = 0;
  h.host.createRewardedVideoAd = function (options) {
    const ad = create.call(this, options);
    ad.load = async () => { h.ads[0].error("no fill"); };
    ad.destroy = () => { h.ads[0].close({ isEnded: false, trackId: "cleanup-only" }); };
    return ad;
  };
  await h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onError() { errors++; } });
  await h.client.flush();
  assert.equal(errors, 1);
  assert.equal(h.ads[0].calls.includes("show"), false);
  assert.equal(h.events().length, 0);
});

test("game, telemetry and cleanup exceptions stay isolated", async (t) => {
  const h = await harness(t);
  let callbacks = 0;
  await h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose() { callbacks++; throw new Error("game"); } });
  h.ads[0].ad.offClose = () => { throw new Error("offClose"); };
  h.ads[0].ad.destroy = () => { throw new Error("destroy"); };
  assert.doesNotThrow(() => h.ads[0].close({ trackId: "first" }));
  await h.client.flush();
  assert.equal(h.events().length, 1);
  h.client.tracker.trackAdPlacement = () => { throw new Error("telemetry"); };
  await h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", async onClose() { callbacks++; throw new Error("async game"); } });
  assert.doesNotThrow(() => h.ads[1].close({ trackId: "second" }));
  await new Promise(setImmediate);
  assert.equal(callbacks, 2);
  assert.ok(h.logs.some((l) => l.includes("ad_view enqueue failed")));
  assert.equal(h.logs.filter((l) => l.includes("business callback failed")).length, 2);
  await h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose() { callbacks++; } });
  assert.doesNotThrow(() => h.ads[2].close({ get trackId() { throw new Error("host result getter"); } }));
  assert.equal(callbacks, 3, "callback parsing errors must not block game cleanup");
});

test("client.close releases pending ads and makes retained host callbacks inert", async (t) => {
  const h = await harness(t);
  let resolve!: () => void;
  const loading = new Promise<void>((done) => { resolve = done; });
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function (options) {
    const ad = create.call(this, options);
    ad.load = () => loading;
    return ad;
  };
  const pending = h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose() { assert.fail("closed"); } });
  h.client.close();
  h.ads[0].close({ trackId: "after-client-close" });
  resolve();
  await assert.rejects(pending, /client is closed/);
  assert.equal(h.ads[0].calls.includes("show"), false);
  assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 1);
  assert.equal(h.events().length, 0);
  await assert.rejects(h.client.showRewardVideoAd(placement, { adUnitId: "native-unit" }), /client is closed/);
});

test("invalid arguments and missing host reject before creating an ad", async (t) => {
  const h = await harness(t);
  await assert.rejects(h.client.showRewardVideoAd("name-not-id", { adUnitId: "native-unit" }), /adPlacementId/);
  await assert.rejects(h.client.showRewardVideoAd(placement, { adUnitId: " " }), /options/);
  await assert.rejects(h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onClose: true } as unknown as GameAlgoRewardVideoAdOptions), /options/);
  await assert.rejects(h.client.showRewardVideoAd(placement, { adUnitId: "native-unit" }, [] as never), /payload/);
  assert.equal(h.ads.length, 0);
  Reflect.deleteProperty(globalThis, "tap");
  await assert.rejects(h.client.showRewardVideoAd(placement, { adUnitId: "native-unit" }), /unavailable/);
});
