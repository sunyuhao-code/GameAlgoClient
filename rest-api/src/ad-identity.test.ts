import assert from "node:assert/strict";
import test from "node:test";
import { GameAlgoEventTracker } from "./client.ts";
import type { GameEvent, Platform } from "./types.ts";

function harness(platform: Platform = "web", queueLimit = 1000) {
  const uploaded: GameEvent[] = [];
  let now = Date.parse("2026-11-11T05:00:00.000Z");
  const tracker = new GameAlgoEventTracker({
    platform, sdkVersion: "test", isDebug: true, maxBatchSize: Math.min(20, queueLimit), queueLimit,
    flushIntervalMs: 0, now: () => now,
    uploadEvents: async events => { uploaded.push(...structuredClone(events)); return { ok: true, accepted: events.length }; },
  });
  return { tracker, uploaded, setTime(value: number) { now = value; } };
}

test("Web ads wait for identity while ordinary events retain their existing readiness requirement", async t => {
  const h = harness(); t.after(() => h.tracker.close());
  const session = h.tracker.currentSessionId();
  const payload = { trackId: "original" };
  assert.equal(h.tracker.track("custom", {}), false);
  assert.equal(h.tracker.track("ad_view", {}, { userId: "" }), false);
  assert.equal(h.tracker.track("ad_view", {}, { userId: "   " }), false);
  assert.equal(h.tracker.trackAdPlacement(`gap_${"a".repeat(32)}`, 0, payload), true);
  payload.trackId = "changed";
  await h.tracker.flush();
  assert.equal(h.uploaded.length, 0);
  h.setTime(Date.parse("2026-11-11T06:00:00.000Z"));
  h.tracker.identify("restored-user");
  h.tracker.setContextId("current-context");
  await h.tracker.flushUrgent();
  assert.equal(h.uploaded.length, 1);
  assert.equal(h.uploaded[0].userId, "restored-user");
  assert.equal(h.uploaded[0].sessionId, session);
  assert.equal(h.uploaded[0].timestamp, "2026-11-11T05:00:00.000Z");
  assert.equal(h.uploaded[0].payload?.trackId, "original");
  assert.equal(h.uploaded[0].isDebug, true);
});

test("identity buffering is bounded and keeps the latest ads like the existing queue limit", async t => {
  const h = harness("web", 2); t.after(() => h.tracker.close());
  for (let i = 0; i < 3; i++) h.tracker.trackAdPlacement(`gap_${"a".repeat(32)}`, 0, { trackId: String(i) });
  h.tracker.identify("real-user"); h.tracker.setContextId("context");
  await h.tracker.flushUrgent();
  assert.deepEqual(h.uploaded.map(e => e.payload?.trackId), ["1", "2"]);
});

test("a new session cannot claim a buffered ad from the pre-identity session", async t => {
  const h = harness(); t.after(() => h.tracker.close());
  const original = h.tracker.currentSessionId();
  h.tracker.trackAdPlacement(`gap_${"a".repeat(32)}`, 0, { trackId: "old-session" });
  h.tracker.newSession("new-session");
  h.tracker.identify("real-user"); h.tracker.setContextId("new-context");
  await h.tracker.flushUrgent();
  assert.equal(h.uploaded.length, 0);
  h.tracker.bindSessionContext(original, "old-context");
  await h.tracker.flushUrgent();
  assert.equal(h.uploaded.length, 1);
  assert.equal(h.uploaded[0].sessionId, original);
  assert.equal(h.uploaded[0].contextId, "old-context");
});

test("other clients keep their pre-identity return value and invalid ad inputs are still rejected", t => {
  const h = harness("maker"); t.after(() => h.tracker.close());
  assert.equal(h.tracker.trackAdPlacement(`gap_${"a".repeat(32)}`, 0), false);
  assert.equal(h.tracker.trackAdPlacement("not-a-gap", 0), false);
});
