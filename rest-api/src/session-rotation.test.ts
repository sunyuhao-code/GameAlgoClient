import test from "node:test";
import assert from "node:assert/strict";
import { GameAlgoEventTracker, GameAlgoRestClient } from "./client.ts";
import type { GameEvent, Platform } from "./types.ts";

function harness(platform: Platform = "maker") {
  let now = 1000;
  let offline = false;
  const values = new Map<string, string>();
  const uploaded: GameEvent[] = [];
  const attempts: GameEvent[] = [];
  const tracker = new GameAlgoEventTracker({
    platform, sdkVersion: "test", isDebug: true, maxBatchSize: 100, queueLimit: 1000,
    flushIntervalMs: 0, now: () => now, persistenceKey: "events",
    storage: { getItem: key => values.get(key), setItem: (key, value) => { values.set(key, value); },
      removeItem: key => { values.delete(key); } },
    uploadEvents: async events => {
      attempts.push(...structuredClone(events));
      if (offline) throw new Error("offline");
      uploaded.push(...structuredClone(events));
      return { ok: true, accepted: events.length };
    },
  });
  tracker.identify("old-user", "old", undefined, "old-account");
  return { tracker, values, uploaded, attempts, setTime: (value: number) => { now = value; },
    setOffline: (value: boolean) => { offline = value; } };
}

for (const platform of ["maker", "web", "android", "ios"] as const) {
  test(`${platform} explicit rotation closes and flushes the old session with its original ownership`, async () => {
    const h = harness(platform);
    h.tracker.setContextId("old-context");
    h.setTime(4500);
    h.tracker.newSession("new");
    assert.equal(h.tracker.currentSessionId(), "new");
    await h.tracker.flushUrgent();
    await h.tracker.flush();
    assert.equal(h.uploaded.length, 1);
    const end = h.uploaded[0];
    assert.equal(end.sessionId, "old");
    assert.equal(end.contextId, "old-context");
    assert.equal(end.userId, "old-user");
    assert.equal(end.accountUserId, "old-account");
    assert.equal(end.isDebug, true);
    assert.equal(end.timestamp, new Date(4500).toISOString());
    assert.deepEqual(end.payload, { reason: "new_session", sessionDurationMs: 3500 });
    h.tracker.close();
  });
}

test("rotation keeps unbound old events and ends, and binding the new context cannot claim them", async () => {
  const h = harness();
  h.tracker.trackLevelStart();
  h.setTime(3000);
  h.tracker.newSession("new");
  h.tracker.setContextId("new-context");
  h.tracker.trackLevelStart();
  await h.tracker.flush();
  assert.equal(h.uploaded.length, 1);
  assert.equal(h.uploaded[0].sessionId, "new");
  const pending = h.values.get("events")!.split("\n").map(line => JSON.parse(line));
  assert.equal(pending.length, 2);
  assert.ok(pending.every(event => event.sessionId === "old" && event.contextId === ""));
  h.tracker.bindSessionContext("old", "old-context");
  await h.tracker.flush();
  const old = h.uploaded.filter(event => event.sessionId === "old");
  assert.deepEqual(old.map(event => event.eventType), ["level_start", "session_end"]);
  assert.ok(old.every(event => event.contextId === "old-context"));
  assert.deepEqual(old[1].payload, { reason: "new_session", sessionDurationMs: 2000 });
  h.tracker.close();
});

test("manual endings and same-ID rotations do not duplicate ends or extend an already-ended duration", async () => {
  const h = harness();
  h.tracker.setContextId("old-context");
  h.setTime(2000);
  h.tracker.newSession("old");
  assert.equal(h.attempts.length, 0);
  h.setTime(4000);
  assert.equal(h.tracker.trackSessionEnd({ reason: "manual" }), true);
  h.setTime(100_000);
  h.tracker.newSession("new");
  await h.tracker.flush();
  assert.equal(h.uploaded.length, 1);
  assert.deepEqual(h.uploaded[0].payload, { reason: "manual", sessionDurationMs: 3000 });
  h.tracker.close();
});

test("rotation persists an unacknowledged end immediately and retries the identical event after a network failure", async () => {
  const h = harness();
  h.setOffline(true);
  h.tracker.setContextId("old-context");
  h.tracker.newSession("new");
  await assert.rejects(h.tracker.flush(), /offline/);
  assert.equal(h.tracker.currentSessionId(), "new");
  const pending = JSON.parse(h.values.get("events")!);
  assert.equal(pending.eventType, "session_end");
  assert.equal(pending.contextId, "old-context");
  h.setOffline(false);
  await h.tracker.flush();
  assert.deepEqual(h.uploaded, [pending]);
  assert.equal(h.values.has("events"), false);
  h.tracker.close();
});

test("rotation snapshots the old end together with an ordinary batch already in flight", async () => {
  let release!: () => void;
  let started!: () => void;
  const ready = new Promise<void>(resolve => { started = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const values = new Map<string, string>();
  const uploaded: GameEvent[] = [];
  const tracker = new GameAlgoEventTracker({
    platform: "maker", sdkVersion: "test", isDebug: false, maxBatchSize: 100, queueLimit: 1000,
    flushIntervalMs: 0, now: () => 1000, persistenceKey: "events",
    storage: { getItem: key => values.get(key), setItem: (key, value) => { values.set(key, value); },
      removeItem: key => { values.delete(key); } },
    uploadEvents: async events => {
      if (events[0].eventType === "level_start") { started(); await held; }
      uploaded.push(...events);
      return { ok: true, accepted: events.length };
    },
  });
  tracker.identify("u", "old");
  tracker.setContextId("old-context");
  tracker.trackLevelStart();
  const flushing = tracker.flush();
  await ready;
  tracker.newSession("new");
  // Persistence is serialized, so give the queued storage write a turn.
  await new Promise(resolve => setImmediate(resolve));
  const pending = values.get("events")!.split("\n").map(line => JSON.parse(line));
  assert.deepEqual(pending.map(event => event.eventType), ["level_start", "session_end"]);
  release();
  await flushing;
  assert.deepEqual(uploaded.map(event => event.eventType), ["level_start", "session_end"]);
  tracker.close();
});

test("a late config response binds only its old session and cannot replace the new snapshot", async () => {
  let release!: () => void;
  let started!: () => void;
  const ready = new Promise<void>(resolve => { started = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const events: GameEvent[] = [];
  const client = new GameAlgoRestClient({
    gameKey: "ga_live_session_rotation_test", baseUrl: "https://gamealgo.test", userId: "user",
    autoStart: false, eventFlushIntervalMs: 0, logger: false,
    fetchImpl: async (input, init) => {
      const request = new Request(input, init);
      const body = await request.json() as { sessionId: string; events: GameEvent[] };
      if (request.url.endsWith("/v1/events/batch")) {
        events.push(...body.events);
        return Response.json({ ok: true, accepted: body.events.length });
      }
      if (body.sessionId === "old") { started(); await held; }
      return Response.json({ contextId: `ctx-${body.sessionId}`, gameId: "fixture", environment: "live",
        configVersion: body.sessionId, ttlSeconds: 60, serverTime: new Date().toISOString(), experiments: [], configFiles: [] });
    },
  });
  client.tracker.identify("user", "old");
  const oldRequest = client.fetchConfig();
  await ready;
  client.tracker.newSession("new");
  await client.fetchConfig();
  release();
  await oldRequest;
  await client.tracker.flush();
  assert.equal(client.snapshotValue().config?.contextId, "ctx-new");
  assert.equal(events.length, 1);
  assert.equal(events[0].sessionId, "old");
  assert.equal(events[0].contextId, "ctx-old");
  client.tracker.close();
});
