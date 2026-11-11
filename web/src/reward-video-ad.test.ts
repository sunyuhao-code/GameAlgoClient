import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { GameAlgoWebClient, type GameAlgoRewardVideoAdOptions, type GameAlgoStorage, type GameAlgoWebClientOptions } from "./index.ts";
import type { GameEvent } from "../../rest-api/src/types.ts";

const placement = `gap_${"a".repeat(32)}`;
type Callback = (...values: unknown[]) => void;

function nativeAd() {
  const calls: string[] = [];
  const closes = new Set<Callback>();
  const errors = new Set<Callback>();
  const loads = new Set<Callback>();
  const closeCallbacks: Callback[] = [];
  const ad = {
    load: async () => { calls.push("load"); },
    show: async () => { calls.push("show"); },
    onLoad(callback: Callback) { calls.push("onLoad"); loads.add(callback); },
    offLoad(callback: Callback) { calls.push("offLoad"); loads.delete(callback); },
    onClose(callback: Callback) { calls.push("onClose"); closes.add(callback); closeCallbacks.push(callback); },
    onError(callback: Callback) { calls.push("onError"); errors.add(callback); },
    offClose(callback: Callback) { calls.push("offClose"); closes.delete(callback); },
    offError(callback: Callback) { calls.push("offError"); errors.delete(callback); },
    destroy() { calls.push("destroy"); },
  };
  return {
    ad, calls, closeCallbacks,
    loaded: () => { for (const callback of [...loads]) callback(); },
    close: (...values: unknown[]) => { for (const callback of [...closes]) callback(...values); },
    error: (...values: unknown[]) => { for (const callback of [...errors]) callback(...values); },
  };
}

async function harness(t: TestContext) {
  const original = Object.getOwnPropertyDescriptor(globalThis, "tap");
  const ads: ReturnType<typeof nativeAd>[] = [];
  const createdUnits: string[] = [];
  const host = {
    createRewardedVideoAd(options: { adUnitId: string }) {
      assert.equal(this, host);
      assert.ok(options.adUnitId);
      createdUnits.push(options.adUnitId);
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
  const makeClient = (overrides: Partial<GameAlgoWebClientOptions> = {}) => new GameAlgoWebClient({
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
    ...overrides,
  });
  const client = makeClient();
  t.after(() => client.close());
  assert.equal(await client.waitForReady(), true);
  return { client, makeClient, host, ads, createdUnits, requests, logs, events: () => requests.flatMap((r) => r.events).filter((e) => e.eventType === "ad_view") };
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
  assert.deepEqual(h.ads[0].calls.filter((c) => c === "load" || c === "show"), ["load", "show"]);
  const retainedClose = h.ads[0].closeCallbacks[0];
  assert.equal(h.events().length, 0, "load/show are not exposure boundaries; Promise resolves before close");
  payload.source = "mutated";
  payload.detail.level = 99;
  h.ads[0].close(raw, extra);
  retainedClose({ isEnded: true, trackId: "duplicate" });
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
  assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 0, "normal close preserves the reusable native ad");
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
  h.ads[0].closeCallbacks[0]({ isEnded: false, trackId: "late-close" });
  await h.client.flush();
  assert.equal(closes, 1);
  assert.equal(h.events()[0].payload?.trackId, "late-close");
  assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 0);
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
      if (phase !== "create") assert.equal(h.ads[0].calls.filter((c) => c === "destroy").length, 0, "a load/show rejection permits a later explicit retry");
    });
  }
});

test("a stale prepared ad reloads and retries once, ignoring the failed attempt's callbacks", async t => {
  for (const failure of ["throw", "reject"] as const) {
    await t.test(failure, async t => {
      const h = await harness(t);
      const space = h.client.createAdSpace({ adUnitId: "native-unit" });
      await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
      const native = h.ads[0];
      const error = new Error("cached ad unavailable");
      let shows = 0;
      native.ad.show = () => {
        native.calls.push("show");
        if (++shows === 1) {
          if (failure === "throw") throw error;
          native.error(error, "first-attempt");
          return Promise.reject(error);
        }
        return Promise.resolve();
      };
      let closes = 0;
      const errors: unknown[][] = [];
      const payload = { source: "supply" };
      const showing = space.show(placement, { onClose() { closes++; }, onError: (...args) => { errors.push(args); } }, payload);
      assert.equal(shows, 1, "a cached ad still starts in the click stack");
      payload.source = "changed";
      await showing;
      assert.deepEqual(native.calls.filter(c => c === "load" || c === "show"), ["load", "show", "load", "show"]);
      assert.equal(h.ads.length, 1, "recovery reuses the native object");
      assert.deepEqual(errors, [], "a recovered request does not surface an intermediate business error");
      native.closeCallbacks[0]({ trackId: "failed-attempt" });
      await h.client.flush();
      assert.equal(h.events().length, 0, "a retained callback from the failed show cannot finish the retry");
      native.close({ isEnded: false, trackId: "retry-close" });
      native.close({ isEnded: false, trackId: "retry-close" });
      await h.client.flush();
      assert.equal(closes, 1);
      assert.equal(h.events().length, 1);
      assert.equal(h.events()[0].payload?.source, "supply");
      assert.equal(h.events()[0].payload?.trackId, "retry-close");
      assert.equal(h.logs.filter(line => line.includes("reloading for one retry")).length, 1);
    });
  }
});

test("two unsuccessful shows preserve the final rejection and forward only its raw native error once", async t => {
  const h = await harness(t);
  const first = new Error("first show");
  const final = new Error("second show");
  const raw = { errCode: 1004, errMsg: "no ad" };
  const create = h.host.createRewardedVideoAd;
  let shows = 0;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.show = async () => {
      h.ads[0].calls.push("show");
      const error = ++shows === 1 ? first : final;
      h.ads[0].error(shows === 1 ? first : raw, "native-detail");
      h.ads[0].error(error, "duplicate-error");
      throw error;
    };
    return ad;
  };
  const errors: unknown[][] = [];
  await assert.rejects(h.client.showRewardVideoAd(placement, {
    adUnitId: "native-unit", onError: (...args) => { errors.push(args); }, onClose() { assert.fail("failed shows must not complete"); },
  }), error => error === final);
  assert.equal(shows, 2);
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 2);
  assert.deepEqual(errors, [[raw, "native-detail"]]);
  h.ads[0].error(first);
  await h.client.flush();
  assert.equal(errors.length, 1);
  assert.equal(h.events().length, 0);
});

test("a recovery load failure ends the request without another show or retry loop", async t => {
  for (const failure of ["reject", "event"] as const) {
    await t.test(failure, async t => {
      const h = await harness(t);
      const error = new Error("reload failed");
      const create = h.host.createRewardedVideoAd;
      let loads = 0;
      let shows = 0;
      h.host.createRewardedVideoAd = function(options) {
        const ad = create.call(this, options);
        ad.load = async () => {
          if (++loads === 1) return;
          if (failure === "event") h.ads[0].error(error, "reload-detail");
          else throw error;
        };
        ad.show = async () => { shows++; throw new Error("stale show"); };
        return ad;
      };
      const errors: unknown[][] = [];
      const showing = h.client.showRewardVideoAd(placement, { adUnitId: "native-unit", onError: (...args) => { errors.push(args); } });
      if (failure === "reject") await assert.rejects(showing, e => e === error);
      else await showing;
      assert.equal(loads, 2);
      assert.equal(shows, 1);
      assert.deepEqual(errors, failure === "event" ? [[error, "reload-detail"]] : []);
      await h.client.flush();
      assert.equal(h.events().length, 0);
    });
  }
});

test("recovery keeps the shared host lock and client.close prevents the retry show", async t => {
  for (const finish of ["resume", "close"] as const) {
    await t.test(finish, async t => {
      const h = await harness(t);
      const other = h.makeClient();
      t.after(() => other.close());
      const pending = deferred();
      const create = h.host.createRewardedVideoAd;
      let loads = 0;
      let shows = 0;
      h.host.createRewardedVideoAd = function(options) {
        const ad = create.call(this, options);
        ad.load = () => ++loads === 1 ? Promise.resolve() : pending.promise;
        ad.show = async () => { if (++shows === 1) throw new Error("stale ad"); };
        return ad;
      };
      const showing = h.client.showRewardVideoAd(placement, { adUnitId: "native-unit" });
      await waitUntil(() => loads === 2);
      await assert.rejects(other.showRewardVideoAd(placement, { adUnitId: "native-unit" }), /busy/);
      await assert.rejects(other.showRewardVideoAd(placement, { adUnitId: "other-unit" }), /busy/);
      if (finish === "close") h.client.close();
      pending.resolve();
      if (finish === "close") {
        await assert.rejects(showing, /client is closed/);
        assert.equal(shows, 1);
        assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
      } else {
        await showing;
        assert.equal(shows, 2);
        h.ads[0].close({ trackId: "after-recovery" });
      }
    });
  }
});

test("a real close followed by a rejected show is still reported once without reopening the ad", async t => {
  const h = await harness(t);
  const error = new Error("late show rejection");
  const create = h.host.createRewardedVideoAd;
  let shows = 0;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.show = async () => {
      shows++;
      h.ads[0].close({ isEnded: false, trackId: "already-closed" });
      throw error;
    };
    return ad;
  };
  let closes = 0;
  await assert.rejects(h.client.showRewardVideoAd(placement, {
    adUnitId: "native-unit", onClose() { closes++; },
  }), e => e === error);
  await h.client.flush();
  assert.equal(shows, 1);
  assert.equal(closes, 1);
  assert.equal(h.events().length, 1);
  assert.equal(h.logs.some(line => line.includes("reloading for one retry")), false);
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
  assert.doesNotThrow(() => h.ads.at(-1)!.close({ get trackId() { throw new Error("host result getter"); } }));
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

async function waitUntil(condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 1000;
  while (!condition()) {
    if (Date.now() > deadline) assert.fail("automatic ad preparation did not reach the expected state");
    await new Promise(resolve => setTimeout(resolve, 2));
  }
}

function deferred() {
  let resolve!: () => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

test("ad-space handles return before automatic preparation and early clicks still load/show", async (t) => {
  const h = await harness(t);
  const options = { adUnitId: "native-unit" };
  const space = h.client.createAdSpace(options);
  assert.equal(space, h.client.createAdSpace({ adUnitId: "native-unit" }));
  options.adUnitId = "changed-after-creation";
  assert.equal(h.ads.length, 0, "a logical handle does not request an ad");
  await space.show(placement);
  assert.deepEqual(h.createdUnits, ["native-unit"]);
  assert.deepEqual(h.ads[0].calls.filter(c => c === "load" || c === "show"), ["load", "show"]);
  h.ads[0].close({ trackId: "direct-space" });
  await h.client.flush();
  assert.equal(h.events().length, 1);
});

test("startup automatically prepares one ad without manual preload or exposure", async t => {
  const h = await harness(t);
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  assert.equal("preload" in space, false);
  assert.equal("preloadRewardVideoAd" in h.client, false);
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  assert.equal(h.ads.length, 1);
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 1);
  assert.equal(h.ads[0].calls.includes("show"), false);
  assert.equal(h.ads[0].calls.includes("onClose"), false);
  assert.equal(h.events().length, 0);
  const showing = space.show(placement);
  assert.equal(h.ads[0].calls.at(-1), "show", "a prepared ad is shown in the click stack");
  await showing;
  h.ads[0].close({ isEnded: false, trackId: "auto-first" });
  await waitUntil(() => h.ads[0].calls.filter(c => c === "load").length === 2);
  assert.equal(h.ads[0].calls.includes("destroy"), false);
  await h.client.flush();
  assert.equal(h.events().length, 1, "preparing the next ad is not an exposure");
});

test("successive business placements reuse one ad and retained callbacks keep their original context", async (t) => {
  const h = await harness(t);
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  const second = `gap_${"b".repeat(32)}`;
  const callbacks: string[] = [];
  const payload = { level: 1 };
  await space.show(placement, { onClose() { callbacks.push("first"); } }, payload);
  const oldClose = h.ads[0].closeCallbacks[0];
  payload.level = 99;
  h.ads[0].close({ trackId: "space-first" });
  await space.show(second, { onClose() { callbacks.push("second"); } }, { level: 2 });
  oldClose({ trackId: "stale-first" });
  await assert.rejects(space.show(placement), /busy/, "an old callback cannot unlock a newer playback");
  h.ads[0].close({ trackId: "space-second" });
  await h.client.flush();
  assert.deepEqual(callbacks, ["first", "second"]);
  assert.equal(h.ads.length, 1);
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 2);
  assert.deepEqual(h.events().map(e => [e.payload?.adPlacementId, e.payload?.level]), [[placement, 1], [second, 2]]);
});

test("a click joins automatic preparation instead of issuing another native load", async t => {
  const h = await harness(t);
  const pending = deferred();
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.load = () => { h.ads[0].calls.push("load"); return pending.promise; };
    return ad;
  };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.ads[0]?.calls.includes("load") === true);
  const showing = space.show(placement);
  await assert.rejects(space.show(placement), /busy/);
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 1);
  assert.equal(h.ads[0].calls.includes("show"), false);
  pending.resolve(); await showing;
  assert.equal(h.ads[0].calls.filter(c => c === "show").length, 1);
  h.ads[0].close({ trackId: "joined-automatic-load" });
});

test("background preparation never steals another unit and explicit playback switches only while idle", async t => {
  const h = await harness(t);
  const first = h.client.createAdSpace({ adUnitId: "native-unit" });
  const second = h.client.createAdSpace({ adUnitId: "other-unit" });
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  assert.deepEqual(h.createdUnits, ["native-unit"]);
  await first.show(placement);
  await assert.rejects(second.show(placement), /busy/);
  assert.equal(h.ads[0].calls.includes("destroy"), false);
  h.ads[0].close({ trackId: "before-switch" });
  await second.show(placement);
  assert.deepEqual(h.createdUnits, ["native-unit", "other-unit"]);
  assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
  assert.equal(h.ads[1].calls.filter(c => c === "load").length, 1);
  h.ads[1].close({ trackId: "after-switch" });
});

test("an idle host's automatic next-load notification is reused without another manual load", async (t) => {
  const h = await harness(t);
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await space.show(placement);
  h.ads[0].close({ trackId: "auto-first" });
  h.ads[0].loaded();
  const next = space.show(placement);
  assert.equal(h.ads[0].calls.at(-1), "show");
  await next;
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 1);
  h.ads[0].close({ trackId: "auto-second" });
});

test("failed automatic preparation does not loop and the next click retries the same instance", async t => {
  const h = await harness(t);
  let loads = 0;
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.load = async () => { if (++loads === 1) throw new Error("no fill"); };
    return ad;
  };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload failed")));
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(loads, 1);
  assert.equal(h.events().length, 0);
  await space.show(placement);
  assert.equal(loads, 2);
  assert.equal(h.ads.length, 1);
  h.ads[0].close({ trackId: "after-automatic-failure" });
});

test("native errors during automatic preparation produce neither business callbacks nor exposure", async t => {
  const h = await harness(t);
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.load = async () => { h.ads[0].error({ errCode: 1001 }); };
    return ad;
  };
  h.client.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload failed")));
  assert.equal(h.events().length, 0);
  assert.equal(h.ads[0].calls.includes("onClose"), false);
  assert.equal(h.ads[0].calls.includes("show"), false);
});

test("event-only automatic preparation and a waiting click finish on native onLoad", async t => {
  const h = await harness(t);
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.load = (() => { h.ads[0].calls.push("load"); }) as typeof ad.load;
    return ad;
  };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.ads[0]?.calls.includes("load") === true);
  const showing = space.show(placement);
  assert.equal(h.ads[0].calls.includes("show"), false);
  h.ads[0].loaded(); await showing;
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 1);
  h.ads[0].close({ trackId: "event-only-auto" });
});

test("closing the client retires pending automatic preparation and prevents a later show", async t => {
  const h = await harness(t);
  const pending = deferred();
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.load = () => { h.ads[0].calls.push("load"); return pending.promise; };
    return ad;
  };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.ads[0]?.calls.includes("load") === true);
  h.client.close(); pending.resolve();
  assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
  assert.throws(() => h.client.createAdSpace({ adUnitId: "native-unit" }), /client is closed/);
  await assert.rejects(space.show(placement), /client is closed/);
  assert.equal(h.ads[0].calls.includes("show"), false);
});

test("multiple WebClients share the host lock and retain an instance while another client owns it", async (t) => {
  const h = await harness(t);
  const other = h.makeClient();
  t.after(() => other.close());
  assert.equal(await other.waitForReady(), true);
  const first = h.client.createAdSpace({ adUnitId: "native-unit" });
  const second = other.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  assert.equal(h.ads.length, 1);
  await first.show(placement);
  await assert.rejects(second.show(placement), /busy/);
  h.ads[0].close({ trackId: "owner-first" });
  h.client.close();
  assert.equal(h.ads[0].calls.includes("destroy"), false);
  await second.show(placement);
  h.ads[0].close({ trackId: "owner-second" });
  other.close();
  assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
});

test("hosts without offClose retire safely instead of accumulating playback listeners", async (t) => {
  const h = await harness(t);
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function (options) {
    const ad = create.call(this, options);
    Reflect.deleteProperty(ad, "offClose");
    return ad;
  };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await space.show(placement);
  h.ads[0].close({ trackId: "no-off-first" });
  assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
  await space.show(placement);
  h.ads[1].close({ trackId: "no-off-second" });
  await h.client.flush();
  assert.equal(h.events().length, 2);
});

test("invalid ad-space input fails before creating an ad", async (t) => {
  const h = await harness(t);
  assert.throws(() => h.client.createAdSpace({ adUnitId: " " }), /options/);
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await assert.rejects(space.show(placement, null as never), /options/);
  await assert.rejects(space.show(placement, [] as never), /options/);
  assert.equal(h.ads.length, 0);
});

test("a close received before native show is not an exposure or a game completion", async (t) => {
  const h = await harness(t);
  const pending = deferred();
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function (options) {
    const ad = create.call(this, options);
    ad.load = () => pending.promise;
    return ad;
  };
  let closes = 0;
  const showing = h.client.createAdSpace({ adUnitId: "native-unit" }).show(placement, { onClose() { closes++; } });
  h.ads[0].close({ trackId: "before-show" });
  assert.equal(closes, 0);
  pending.resolve();
  await showing;
  h.ads[0].close({ trackId: "after-show" });
  await h.client.flush();
  assert.equal(closes, 1);
  assert.deepEqual(h.events().map(e => e.payload?.trackId), ["after-show"]);
});

test("a prior close redelivered to the current listener cannot complete the next playback", async (t) => {
  const h = await harness(t);
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  let closes = 0;
  await space.show(placement, { onClose() { closes++; } });
  h.ads[0].close({ trackId: "replayed-track" });
  await space.show(placement, { onClose() { closes++; } });
  h.ads[0].close({ trackId: "replayed-track" });
  assert.equal(closes, 1);
  await assert.rejects(space.show(placement), /busy/);
  h.ads[0].close({ trackId: "new-track" });
  await h.client.flush();
  assert.equal(closes, 2);
  assert.equal(h.events().length, 2);
});

test("closing an active owner retires the host instance even when another client preloaded it", async (t) => {
  const h = await harness(t);
  const other = h.makeClient();
  t.after(() => other.close());
  await other.waitForReady();
  other.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  await h.client.createAdSpace({ adUnitId: "native-unit" }).show(placement);
  h.client.close();
  assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
  await other.createAdSpace({ adUnitId: "native-unit" }).show(placement);
  assert.equal(h.ads.length, 2);
  h.ads[0].closeCallbacks[0]({ trackId: "closed-owner" });
  h.ads[1].close({ trackId: "new-owner" });
  await other.flush();
  assert.deepEqual(h.events().map(e => e.payload?.trackId), ["new-owner"]);
});

test("closing one owner preserves another owner's automatic preparation", async t => {
  const h = await harness(t);
  const other = h.makeClient(); t.after(() => other.close()); await other.waitForReady();
  const pending = deferred();
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    ad.load = () => { h.ads[0].calls.push("load"); return pending.promise; };
    return ad;
  };
  h.client.createAdSpace({ adUnitId: "native-unit" });
  const space = other.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.ads[0]?.calls.includes("load") === true);
  h.client.close();
  assert.equal(h.ads[0].calls.includes("destroy"), false);
  pending.resolve();
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  await space.show(placement);
  assert.equal(h.ads.length, 1);
  h.ads[0].close({ trackId: "remaining-automatic-owner" });
});

test("a missing track ID remains reportable on every playback even if the host reuses its result object", async (t) => {
  const h = await harness(t);
  const result = { isEnded: true };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  for (let i = 0; i < 2; i++) {
    await space.show(placement);
    h.ads[0].close(result);
  }
  await h.client.flush();
  assert.equal(h.events().length, 2);
});

test("a timed-out load releases the slot and permits a later explicit retry", async (t) => {
  const h = await harness(t);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function (options) {
    const ad = create.call(this, options);
    if (h.ads.length === 1) ad.load = () => new Promise<void>(() => {});
    return ad;
  };
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  const pending = assert.rejects(space.show(placement), /load timed out/);
  t.mock.timers.tick(30_000);
  await pending;
  assert.equal(h.ads[0].calls.filter(c => c === "destroy").length, 1);
  await space.show(placement);
  assert.equal(h.ads.length, 2);
  h.ads[1].close({ trackId: "after-timeout" });
});

test("a real close before identity hydration stays queued with its original timestamp until identity/context arrive", async (t) => {
  const h = await harness(t);
  const identity = deferred();
  let now = Date.parse("2026-11-11T05:00:00.000Z");
  const values = new Map();
  const sdk = h.makeClient({
    now: () => now,
    storage: {
      async getItem(key) {
        await identity.promise;
        if (key.endsWith(":user-id")) return "hydrated-real-user";
        return values.get(key);
      },
      setItem: (key, value) => { values.set(key, value); },
      removeItem: key => { values.delete(key); },
    },
  });
  t.after(() => sdk.close());
  const session = sdk.tracker.currentSessionId();
  let closes = 0;
  await sdk.createAdSpace({ adUnitId: "native-unit" }).show(placement, { onClose() { closes++; } });
  h.ads[0].close({ trackId: "before-identity" });
  h.ads[0].closeCallbacks[0]({ trackId: "duplicate-before-identity" });
  assert.equal(closes, 1);
  assert.ok(h.logs.some(line => line.includes("closed queued=true")));
  assert.equal(h.events().length, 0, "no fake user or context may be uploaded");
  now += 20_000;
  identity.resolve();
  await sdk.waitForReady();
  await sdk.tracker.flushUrgent();
  await sdk.tracker.flush();
  assert.equal(h.events().length, 1);
  assert.equal(h.events()[0].userId, "hydrated-real-user");
  assert.equal(h.events()[0].sessionId, session);
  assert.equal(h.events()[0].contextId, "ctx-ad");
  assert.equal(h.events()[0].timestamp, "2026-11-11T05:00:00.000Z");
  assert.equal(h.events()[0].payload.trackId, "before-identity");
});

test("closing the client after a real cold-start close does not discard its buffered exposure", async t => {
  const h = await harness(t);
  const identity = deferred();
  const sdk = h.makeClient({
    storage: {
      async getItem() { await identity.promise; return undefined; },
      setItem() {}, removeItem() {},
    },
  });
  t.after(() => sdk.close());
  await sdk.createAdSpace({ adUnitId: "native-unit" }).show(placement);
  h.ads[0].close({ trackId: "completed-before-close" });
  sdk.close();
  identity.resolve();
  await sdk.waitForReady();
  await sdk.tracker.flushUrgent();
  await sdk.tracker.flush();
  assert.equal(h.events().length, 1);
  assert.equal(h.events()[0].payload.trackId, "completed-before-close");
  assert.ok(h.logs.some(line => line.includes("ad_view identity buffered: count=1")));
  assert.ok(h.logs.some(line => line.includes("ad_view identity released: count=1")));
  assert.ok(h.logs.some(line => line.includes("ad_view upload ack: accepted=1")));
});

test("identity restoration failures report their stage without exposing stored values", async t => {
  const h = await harness(t);
  const sdk = h.makeClient({
    storage: {
      getItem(key) { if (key.endsWith(":user-id")) throw new TypeError("private-storage-detail"); return undefined; },
      setItem() {}, removeItem() {},
    },
  });
  t.after(() => sdk.close());
  assert.equal(await sdk.waitForReady(), false);
  assert.ok(h.logs.some(line => line.includes("initialization failed: stage=identity errorType=TypeError")));
  assert.ok(h.logs.every(line => !line.includes("private-storage-detail")));
  assert.equal(h.events().length, 0);
});

test("each real close prepares the next ad once without replaying or creating another native object", async t => {
  const h = await harness(t);
  const space = h.client.createAdSpace({ adUnitId: "native-unit" });
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  for (let i = 1; i <= 2; i++) {
    const showing = space.show(placement);
    assert.equal(h.ads[0].calls.at(-1), "show"); await showing;
    const result = { isEnded: i === 2, trackId: `automatic-next-${i}` };
    h.ads[0].close(result); h.ads[0].closeCallbacks[i-1](result);
    await waitUntil(() => h.ads[0].calls.filter(c => c === "load").length === i+1);
  }
  await h.client.flush();
  assert.equal(h.ads.length, 1);
  assert.equal(h.ads[0].calls.filter(c => c === "show").length, 2);
  assert.equal(h.ads[0].calls.filter(c => c === "load").length, 3);
  assert.equal(h.events().length, 2);
});

test("closing before scheduled startup preparation never creates a native ad", async t => {
  const h = await harness(t);
  h.client.createAdSpace({ adUnitId: "native-unit" }); h.client.close();
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.ads.length, 0);
});

test("late host injection is discovered for automatic preparation without a click", async t => {
  const h = await harness(t);
  const host = h.host;
  Reflect.deleteProperty(globalThis, "tap");
  h.client.createAdSpace({ adUnitId: "native-unit" });
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.ads.length, 0);
  Object.defineProperty(globalThis, "tap", {configurable:true,value:host});
  await waitUntil(() => h.logs.some(line => line.includes("automatic preload ready")));
  assert.equal(h.ads[0].calls.includes("show"), false);
  assert.equal(h.events().length, 0);
});

test("automatic preparation timeout is logged once and does not retry until a click", async t => {
  const h = await harness(t);
  t.mock.timers.enable({apis:["setTimeout"]});
  const create = h.host.createRewardedVideoAd;
  h.host.createRewardedVideoAd = function(options) {
    const ad = create.call(this, options);
    if (h.ads.length === 1) ad.load = () => new Promise<void>(() => {});
    return ad;
  };
  const space = h.client.createAdSpace({adUnitId:"native-unit"});
  t.mock.timers.tick(0);
  assert.equal(h.ads.length,1);
  t.mock.timers.tick(30_000);
  await Promise.resolve();
  assert.equal(h.logs.filter(line=>line.includes("automatic preload failed")).length,1);
  assert.equal(h.ads[0].calls.filter(c=>c==="destroy").length,1);
  t.mock.timers.tick(60_000);
  assert.equal(h.ads.length,1);
  await space.show(placement);
  assert.equal(h.ads.length,2);
  h.ads[1].close({trackId:"after-automatic-timeout"});
});
