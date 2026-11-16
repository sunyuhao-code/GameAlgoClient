import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { GameAlgoWebClient, type GameAlgoStorage } from "./index.ts";
import { GameAlgoRestClient } from "../../rest-api/src/core-client.ts";
import { TapTapTelemetryRouter, tapDbEnvelope, type TapDbProperties } from "./telemetry-routing.ts";

const turn = async () => { for (let i = 0; i < 3; i++) await new Promise(resolve => setImmediate(resolve)); };
type NativeCall = { name: string; properties: TapDbProperties };
function decode(call: NativeCall): any {
  return JSON.parse(Array.from({ length: Number(call.properties.gamealgo_part_count) }, (_, i) => call.properties[`gamealgo_part_${i}`]).join(""));
}
function fixture(t: TestContext, flags: Record<string, unknown> = {}, isDebug = false) {
  const calls: NativeCall[] = [], requests: Array<{ path: string; body: any }> = [];
  const values = new Map<string, string>();
  const storage: GameAlgoStorage = { getItem: key => values.get(key), setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } };
  const original = Object.getOwnPropertyDescriptor(globalThis, "tap");
  const control = { flags, failBatch: false, throwTapdb: false, holdTapdb: false, batchReply: undefined as Record<string, unknown> | undefined, config: undefined as undefined | (() => Promise<Response>) };
  const host = { logEvent(options: NativeCall & { success: (result: unknown) => void }) {
    assert.equal(this, host); calls.push(options);
    if (control.throwTapdb) throw new Error("native failure");
    if (control.holdTapdb) return;
    options.success({ errno: 0 });
  } };
  Object.defineProperty(globalThis, "tap", { configurable: true, value: host });
  const response = (extra: Record<string, unknown> = {}) => Response.json({ contextId: "ctx-routing", gameId: "routing-fixture", environment: "test", configVersion: "1", ttlSeconds: 60, serverTime: new Date().toISOString(), configFiles: [], experiments: [], ...extra });
  const client = new GameAlgoWebClient({ baseUrl: "https://routing.test/algo_sdk", gameKey: "ga_live_routing_fixture",
    storage, isDebug, autoLifecycle: false, preloadConfigFiles: false, eventFlushIntervalMs: 0,
    fetchImpl: async (input, init) => {
      const path = new URL(String(input)).pathname.replace("/algo_sdk", ""), body = JSON.parse(String(init?.body ?? "{}"));
      requests.push({ path, body });
      if (path === "/v1/config") return control.config ? control.config() : response(control.flags);
      if (control.failBatch && path === "/v1/events/batch") throw new Error("offline");
      if (path === "/v1/events/batch" && control.batchReply) return Response.json(control.batchReply);
      return Response.json({ ok: true, accepted: body.events?.length ?? 1, attributionHash: body.attributionHash, identifierHash: body.identifierHash });
    },
  });
  t.after(() => { client.close(); if (original) Object.defineProperty(globalThis, "tap", original); else Reflect.deleteProperty(globalThis, "tap"); });
  return { client, calls, requests, storage, control, response, values };
}

test("all four reporting combinations route every event type without changing its original envelope", async t => {
  for (const gamealgo of [false, true]) for (const tapdb of [false, true]) await t.test(`${gamealgo}/${tapdb}`, async t => {
    const f = fixture(t, { gamealgoStandardReportingEnabled: gamealgo, gamealgoCustomReportingEnabled: gamealgo, tapdbStandardReportingEnabled: tapdb, tapdbCustomReportingEnabled: tapdb });
    assert.equal(await f.client.waitForReady(), true);
    const types = ["level_start", "level_end", "session_end", "ad_view", "purchase", "milestone", "_custom", "experiment_exposure"];
    for (const type of types) assert.equal(f.client.tracker.track(type, { text: "长参数🙂".repeat(150), flag: false, empty: null }), true);
    const result = await f.client.tracker.flush(); await f.client.flush(); await turn();
    const batches = f.requests.filter(r => r.path === "/v1/events/batch");
    assert.equal(batches.length > 0, gamealgo);
    assert.equal(f.calls.length, tapdb ? types.length : 0);
    if (tapdb) {
      const events = f.calls.map(c => decode(c).event);
      assert.deepEqual(new Set(events.map(e => e.eventType)), new Set(types));
      for (const [index, event] of events.entries()) {
        assert.equal(event.contextId, "ctx-routing"); assert.ok(event.eventId); assert.ok(event.timestamp);
        assert.equal(event.payload.text, "长参数🙂".repeat(150));
        for (const value of Object.values(f.calls[index].properties)) if (typeof value === "string") assert.ok(Buffer.byteLength(value) <= 240);
        assert.ok(!JSON.stringify(f.calls[index]).includes("ga_live_routing_fixture"));
      }
      if (gamealgo) assert.deepEqual(new Set(events.map(e => e.eventId)), new Set(batches.flatMap(r => r.body.events).map((e: any) => e.eventId)));
    }
    if (!gamealgo) for (const r of result) { assert.equal(r.accepted, 0); assert.ok(r.skipped); }
    const calls = f.calls.length, uploads = batches.length;
    await f.client.flush();
    assert.equal(f.calls.length, calls);
    assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, uploads);
  });
});

test("old or malformed controls keep direct delivery; an explicit TapDB disable also vetoes identity linking", async t => {
  for (const flags of [{}, { gamealgoStandardReportingEnabled: "false", gamealgoCustomReportingEnabled: "false", tapdbStandardReportingEnabled: "true", tapdbCustomReportingEnabled: "true" }, { tapdbContextLinkEnabled: true, tapdbStandardReportingEnabled: false, tapdbCustomReportingEnabled: false }]) await t.test(JSON.stringify(flags), async t => {
    const f = fixture(t, flags); await f.client.waitForReady();
    f.client.tracker.trackLevelStart(); await f.client.flush();
    assert.equal(f.calls.length, 0); assert.ok(f.requests.some(r => r.path === "/v1/events/batch"));
  });
});

test("TapDB handoff is once across direct HTTP retries and rejection does not block direct delivery", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: true, gamealgoCustomReportingEnabled: true, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true }); await f.client.waitForReady();
  f.control.failBatch = true; f.control.throwTapdb = true;
  f.client.tracker.trackLevelStart(); await assert.rejects(f.client.flush(), /offline/);
  assert.equal(f.calls.length, 1);
  f.control.failBatch = false; await f.client.flush();
  assert.equal(f.calls.length, 1); assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 2);
});

test("TapDB-only failures retain durable events, retry with the same ID, and do not silently fall back to direct HTTP", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true }); await f.client.waitForReady();
  f.control.throwTapdb = true;
  f.client.tracker.trackLevelEnd({ result: "done" });
  await assert.rejects(f.client.flush(), /handoff failed/); await turn();
  assert.ok([...f.values.values()].some(value => value.includes("level_end")));
  const first = decode(f.calls[0]).event;
  f.control.throwTapdb = false; await f.client.flush();
  assert.equal(f.calls.length, 2); assert.equal(decode(f.calls[1]).event.eventId, first.eventId);
  assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 0);
  await f.client.flush(); assert.equal(f.calls.length, 2);
});

test("a pending TapDB callback cannot hold the direct channel, and closing cancels pending handoffs", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: true, gamealgoCustomReportingEnabled: true, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true }); await f.client.waitForReady();
  f.control.holdTapdb = true;
  f.client.tracker.trackLevelStart(); await f.client.flush();
  assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 1);
  f.client.close(); await turn();
});

test("a TapDB-only callback timeout preserves the queue for the next bounded retry", async t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture(t, { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true }); await f.client.waitForReady();
  f.control.holdTapdb = true;
  f.client.tracker.trackLevelStart();
  const flush = f.client.flush(); const checked = assert.rejects(flush, /handoff failed/);
  await turn(); t.mock.timers.tick(15000); await checked;
  f.control.holdTapdb = false; await f.client.flush(); assert.equal(f.calls.length, 2);
});

test("a recovered direct batch uses the new TapDB-only policy while retaining the original context and timestamp", async t => {
  const f = fixture(t); await f.client.waitForReady();
  f.control.failBatch = true; f.client.tracker.trackLevelEnd({ result: "done" });
  await assert.rejects(f.client.flush(), /offline/); await turn();
  const original = f.requests.find(r => r.path === "/v1/events/batch")!.body.events[0];
  f.client.close();
  const next = new GameAlgoWebClient({ baseUrl: "https://routing.test/algo_sdk", gameKey: "ga_live_routing_fixture", storage: f.storage,
    autoLifecycle: false, preloadConfigFiles: false, eventFlushIntervalMs: 0,
    fetchImpl: async input => {
      assert.ok(String(input).endsWith("/v1/config"), "disabled direct channel must not replay restored events");
      return f.response({ gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true });
    } });
  t.after(() => next.close()); await next.waitForReady(); await next.flush();
  assert.equal(f.calls.length, 1);
  const restored = decode(f.calls[0]).event;
  for (const key of ["eventId", "contextId", "sessionId", "timestamp"]) assert.equal(restored[key], original[key]);
});

test("cached snapshots cannot authorize TapDB after reopening without a fresh server response", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: true, gamealgoCustomReportingEnabled: true, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true }); await f.client.waitForReady(); f.client.close();
  const next = new GameAlgoWebClient({ baseUrl: "https://routing.test/algo_sdk", gameKey: "ga_live_routing_fixture", storage: f.storage,
    autoLifecycle: false, preloadConfigFiles: false, eventFlushIntervalMs: 0,
    fetchImpl: async input => {
      if (String(input).endsWith("/v1/config")) throw new Error("offline config");
      return Response.json({ ok: true, accepted: 1 });
    } });
  t.after(() => next.close()); await next.waitForReady(); next.tracker.trackLevelStart(); await next.flush();
  assert.equal(f.calls.length, 0);
});

test("attribution, identifiers and quota diagnostics obey both controls without caching a local receipt as a server ACK", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true,
    eventQuota: { mode: "enforce", policyVersion: 1, ordinaryEventLimit: 0, quotaDate: "2026-11-16", resetAt: "2026-11-17T00:00:00Z", exemptEventTypes: [] } }, true);
  await f.client.waitForReady();
  const input = { provider: "fixture", attribution: { campaign: "routing-test" }, attributedAt: "2026-11-16T00:00:00Z" };
  const attribution = await f.client.setAttribution(input);
  assert.equal(attribution.accepted, 0); assert.equal(attribution.skipped, 1);
  const identifier = await f.client.setIdfa("12345678-1234-1234-1234-123456789abc");
  assert.equal(identifier.accepted, 0); assert.equal(identifier.skipped, 1);
  assert.equal(f.client.tracker.trackLevelStart(), false); await turn();
  assert.deepEqual(new Set(f.calls.map(c => decode(c).path)), new Set(["/v1/attribution", "/v1/context-identifiers", "/v1/diagnostics/sdk"]));
  assert.ok(f.calls.every(c => c.properties.gamealgo_is_debug === true));
  assert.equal(f.requests.filter(r => r.path !== "/v1/config").length, 0);
  f.control.flags = { gamealgoStandardReportingEnabled: true, gamealgoCustomReportingEnabled: true, tapdbStandardReportingEnabled: false, tapdbCustomReportingEnabled: false };
  await f.client.fetchConfig({ forceRefresh: true }); await f.client.setAttribution(input);
  assert.equal(f.requests.filter(r => r.path === "/v1/attribution").length, 1, "a previous TapDB-only receipt must not suppress direct reporting after re-enable");
  const previousTapdb = f.calls.filter(c => decode(c).path === "/v1/attribution").length;
  f.control.flags = { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true };
  await f.client.fetchConfig({ forceRefresh: true });
  await f.client.setAttribution({ ...input, attribution: { campaign: "second" } });
  assert.equal(f.calls.filter(c => decode(c).path === "/v1/attribution").length, previousTapdb + 1);
});

test("a fresh disable is installed before pending urgent events bind to their first context", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true });
  f.client.tracker.trackAdPlacement("gap_0123456789abcdef0123456789abcdef", 0, "taptap", { trackId: "native-original" });
  await f.client.waitForReady(); await f.client.flush(); await turn();
  assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 0);
  assert.equal(f.calls.filter(c => decode(c).event?.eventType === "ad_view").length, 1);
});

test("enabling TapDB mirrors attribution even when the direct channel previously acknowledged its hash", async t => {
  const f = fixture(t); await f.client.waitForReady();
  const input = { provider: "fixture", attribution: { campaign: "already-direct" }, attributedAt: "2026-11-16T00:00:00Z" };
  await f.client.setAttribution(input); assert.equal(f.calls.length, 0);
  f.control.flags = { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true };
  await f.client.fetchConfig({ forceRefresh: true }); await f.client.setAttribution(input);
  assert.equal(f.calls.length, 1); assert.equal(decode(f.calls[0]).path, "/v1/attribution");
});

test("a server disable takes effect even while snapshot storage is stalled, and cached configs do not enable TapDB", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: true, gamealgoCustomReportingEnabled: true, tapdbStandardReportingEnabled: true, tapdbCustomReportingEnabled: true }); await f.client.waitForReady();
  const saved = f.storage.setItem;
  let release: (() => void) | undefined;
  f.storage.setItem = (key, value) => key.includes(":snapshot:") ? new Promise<void>(resolve => { release = resolve; }) : saved(key, value);
  f.control.flags = { gamealgoStandardReportingEnabled: false, gamealgoCustomReportingEnabled: false, tapdbStandardReportingEnabled: false, tapdbCustomReportingEnabled: false };
  const pending = f.client.fetchConfig({ forceRefresh: true }); await turn();
  f.client.tracker.trackLevelStart(); await f.client.flush();
  assert.equal(f.calls.length, 0); assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 0);
  release?.(); await pending;
  const router = new TapTapTelemetryRouter(async () => { throw new Error("not allowed without fresh config"); });
  assert.equal(await router.forward("/v1/events/batch", { events: [{ eventId: "old" }] }), 0);
});

test("envelope chunks preserve arbitrary Unicode and nulls; shared non-TapTap clients keep their original HTTP path", async t => {
  const original = { schemaVersion: 1, event: { payload: { text: "🙂中a".repeat(2000), value: null, nested: '{"a":true}' } } };
  assert.deepEqual(decode({ name: "fixture", properties: tapDbEnvelope(original, {}) }), original);
  const f = fixture(t);
  const base = new GameAlgoRestClient({ baseUrl: "https://other.test", gameKey: "fixture", platform: "wechat", autoStart: false,
    fetchImpl: async () => Response.json({ ok: true, accepted: 1 }) } as never);
  t.after(() => base.tracker.close());
  await base.uploadEvents([{ contextId: "ctx", userId: "user", sessionId: "session", eventType: "level_start" }]);
  assert.equal(f.calls.length, 0);
});

test("four independent gates split mixed batches in all 16 combinations", async t => {
  for (let mask = 0; mask < 16; mask++) await t.test(String(mask), async t => {
    const flags = { gamealgoStandardReportingEnabled: Boolean(mask & 1), gamealgoCustomReportingEnabled: Boolean(mask & 2),
      tapdbStandardReportingEnabled: Boolean(mask & 4), tapdbCustomReportingEnabled: Boolean(mask & 8) };
    const f = fixture(t, flags); await f.client.waitForReady();
    const types = ["level_end", "experiment_exposure", "experiment_execution", "_business", "raw_business"];
    const events = types.map((eventType, index) => ({ eventId: `category-${mask}-${index}`, eventType,
      contextId: "ctx-routing", userId: "user", sessionId: "session", timestamp: "2026-11-16T01:00:00Z", payload: { index } }));
    const result = await f.client.uploadEvents(events);
    const nativeTypes = types.filter((_, index) => index < 3 ? flags.gamealgoStandardReportingEnabled : flags.gamealgoCustomReportingEnabled);
    const tapTypes = types.filter((_, index) => index < 3 ? flags.tapdbStandardReportingEnabled : flags.tapdbCustomReportingEnabled);
    assert.deepEqual(f.requests.filter(r => r.path === "/v1/events/batch").flatMap(r => r.body.events.map((e: any) => e.eventType)), nativeTypes);
    assert.deepEqual(f.calls.map(call => decode(call).event.eventType), tapTypes);
    assert.equal(result.accepted, nativeTypes.length);
    assert.equal(result.skipped ?? 0, types.length - nativeTypes.length);
    for (const call of f.calls) assert.deepEqual(decode(call).event.payload, { index: types.indexOf(decode(call).event.eventType) });
  });
});

test("custom-only TapDB cannot send attribution, identifiers, diagnostics or legacy identity links", async t => {
  const f = fixture(t, { gamealgoStandardReportingEnabled: false, tapdbStandardReportingEnabled: false,
    tapdbCustomReportingEnabled: true, tapdbContextLinkEnabled: true,
    eventQuota: { mode: "enforce", policyVersion: 1, ordinaryEventLimit: 0, quotaDate: "2026-11-16", resetAt: "2026-11-17T00:00:00Z", exemptEventTypes: [] } });
  await f.client.waitForReady();
  const input = { provider: "fixture", attribution: { campaign: "category" } };
  assert.equal((await f.client.setAttribution(input)).skipped, 1);
  assert.equal((await f.client.setIdfa("12345678-1234-1234-1234-123456789abc")).skipped, 1);
  assert.equal(f.client.tracker.trackLevelStart(), false); await turn();
  assert.equal(f.calls.length, 0);
  assert.ok(f.requests.every(request => request.path === "/v1/config"));
  f.control.flags = { gamealgoStandardReportingEnabled: true };
  await f.client.fetchConfig({ forceRefresh: true }); await f.client.setAttribution(input);
  assert.equal(f.requests.filter(request => request.path === "/v1/attribution").length, 1);
});

test("mixed-batch TapDB failures keep durable rows without replaying the HTTP-acknowledged subset", async t => {
  const f = fixture(t, { gamealgoCustomReportingEnabled: false, tapdbCustomReportingEnabled: true });
  await f.client.waitForReady(); f.control.throwTapdb = true;
  f.client.tracker.trackLevelStart(); f.client.tracker.trackEvent("business", { value: 42 });
  await assert.rejects(f.client.flush(), /handoff failed/); await turn();
  assert.ok([...f.values.values()].some(value => value.includes("_business")));
  const first = decode(f.calls[0]).event;
  assert.deepEqual(f.requests.filter(r => r.path === "/v1/events/batch").flatMap(r => r.body.events.map((e: any) => e.eventType)), ["level_start"]);
  f.control.throwTapdb = false; await f.client.flush();
  assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 1);
  assert.equal(f.calls.length, 2);
  assert.equal(decode(f.calls[1]).event.eventId, first.eventId);
  assert.equal(decode(f.calls[1]).event.timestamp, first.timestamp);
  await f.client.flush(); assert.equal(f.calls.length, 2);
});

test("a successful TapDB subset is not repeated when the mixed batch's HTTP subset retries", async t => {
  const f = fixture(t, { gamealgoCustomReportingEnabled: false, tapdbCustomReportingEnabled: true });
  await f.client.waitForReady(); f.control.failBatch = true;
  f.client.tracker.trackLevelStart(); f.client.tracker.trackEvent("business");
  await assert.rejects(f.client.flush(), /offline/);
  f.control.failBatch = false; await f.client.flush();
  assert.equal(f.calls.length, 1);
  assert.equal(f.requests.filter(r => r.path === "/v1/events/batch").length, 2);
});


test("mixed batches retain native rows on invalid acknowledgements and restore original rejection indices", async t => {
  const f = fixture(t, { gamealgoCustomReportingEnabled: false, tapdbCustomReportingEnabled: true });
  await f.client.waitForReady();
  f.client.tracker.trackEvent("business"); f.client.tracker.trackLevelStart();
  for (const reply of [{}, { accepted: 0, rejected: [] }, { accepted: 0, rejected: [null] }, { ok: false, accepted: 1 }]) {
    f.control.batchReply = reply;
    await assert.rejects(f.client.flush(), /invalid telemetry batch acknowledgement/);
  }
  f.control.batchReply = { ok: true, accepted: 0, rejected: [{ index: 0, reason: "fixture rejection" }] };
  const receipts = await f.client.tracker.flush();
  assert.equal(receipts[0].accepted, 0); assert.equal(receipts[0].skipped, 1);
  assert.equal(receipts[0].rejected?.[0].index, 1);
  assert.equal(f.calls.length, 1, "an accepted TapDB subset is not retried for invalid HTTP acknowledgements");
});
