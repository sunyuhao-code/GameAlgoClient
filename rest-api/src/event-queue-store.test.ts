import test from "node:test";
import assert from "node:assert/strict";
import { IncrementalEventQueue } from "./event-queue-store.ts";
import { GameAlgoEventTracker } from "./client.ts";
import type { GameEvent } from "./types.ts";

const event = (id: number): GameEvent => ({ eventId: `event-${id}`, contextId: "ctx", userId: "user",
  sessionId: "session", eventType: "level_end", timestamp: "2026-11-06T00:00:00Z", payload: { level: id } });

function storage() {
  const values = new Map<string, string>();
  let writes = 0, removes = 0, failDirectory = false;
  return { values, writes: () => writes, removes: () => removes, fail: (value: boolean) => { failDirectory = value; },
    getItem: (key: string) => values.get(key),
    setItem: (key: string, value: string) => {
      if (failDirectory && key === "queue") throw new Error("interrupted directory commit");
      values.set(key, value); writes++;
    }, removeItem: (key: string) => { values.delete(key); removes++; } };
}

test("event chunks only write changed blocks and unchanged queues do no work", async () => {
  const store = storage(), queue = new IncrementalEventQueue(store, "queue");
  await queue.load();
  const events = Array.from({ length: 250 }, (_, id) => event(id));
  await queue.save(events);
  assert.equal(store.writes(), 4);
  await queue.save(events);
  assert.equal(store.writes(), 4);
  events.push(event(250));
  await queue.save(events);
  assert.equal(store.writes(), 6, "only the tail and small directory change");
  const next = events.slice(100);
  next[0] = { ...next[0], contextId: "recovered-context" };
  await queue.save(next);
  const restored = await new IncrementalEventQueue(store, "queue").load();
  assert.deepEqual(restored, next);
  await queue.save([]);
  assert.equal(store.values.size, 0, "ACK cleanup removes directory and both banks");
  const removed = store.removes();
  await queue.save([]);
  assert.equal(store.removes(), removed, "an already empty queue does no storage work");
});

test("a failed root read does not erase or overwrite an unread durable queue", async () => {
  const store = storage();
  store.values.set("queue", JSON.stringify(event(1)));
  const tracker = new GameAlgoEventTracker({ platform: "web", sdkVersion: "test", isDebug: true,
    now: () => 1000, queueLimit: 1000, maxBatchSize: 100,
    flushIntervalMs: 0, persistOnEnqueue: true, storage: { ...store,
      getItem: (key: string) => { if (key === "queue") throw new Error("storage unavailable"); return store.getItem(key); } },
    persistenceKey: "queue", uploadEvents: async () => { throw new Error("offline"); } });
  await tracker.waitForRestore();
  tracker.identify("user", "session");
  tracker.setContextId("ctx");
  tracker.trackLevelEnd({ level: 2 });
  await assert.rejects(tracker.flush(), /offline/);
  assert.equal(store.writes(), 0);
  assert.equal(store.removes(), 0);
  assert.equal(store.values.get("queue"), JSON.stringify(event(1)));
  tracker.close();
});

test("unread disk data is retained while new events upload, then restored when storage recovers", async () => {
  const store = storage();
  store.values.set("queue", JSON.stringify(event(1)));
  let unavailable = true;
  const sent: string[][] = [];
  const tracker = new GameAlgoEventTracker({ platform: "web", sdkVersion: "test", isDebug: true,
    now: () => 1000, queueLimit: 1000, maxBatchSize: 100, flushIntervalMs: 0, persistOnEnqueue: true,
    storage: { ...store, getItem: key => {
      if (unavailable && key === "queue") throw new Error("storage unavailable");
      return store.getItem(key);
    } }, persistenceKey: "queue", uploadEvents: async events => {
      sent.push(events.map(row => row.eventId!)); return { ok: true, accepted: events.length };
    } });
  await tracker.waitForRestore();
  tracker.identify("user", "session"); tracker.setContextId("ctx");
  tracker.trackLevelEnd({ level: 2 });
  await tracker.flush();
  assert.equal(sent.length, 1, "persistent-storage failure must not block new HTTP uploads");
  assert.equal(store.writes(), 0);
  assert.equal(store.values.get("queue"), JSON.stringify(event(1)));
  unavailable = false;
  await tracker.flush();
  assert.deepEqual(sent[1], ["event-1"], "old disk events resume independently after storage recovers");
  assert.equal(sent.flat().length, new Set(sent.flat()).size, "storage errors must not requeue an HTTP-acknowledged batch");
  assert.equal(store.values.size, 0);
  tracker.close();
});

test("failed directory commits preserve the previous durable queue and can retry", async () => {
  const store = storage(), queue = new IncrementalEventQueue(store, "queue");
  const events = [event(1)];
  await queue.save(events);
  events.push(event(2));
  store.fail(true);
  await assert.rejects(queue.save(events), /interrupted/);
  assert.deepEqual(await new IncrementalEventQueue(store, "queue").load(), [event(1)]);
  store.fail(false);
  await queue.save(events);
  assert.deepEqual(await new IncrementalEventQueue(store, "queue").load(), events);
});

test("an uncertain directory commit reloads active banks before another failed retry", async () => {
  const store = storage();
  let failRootAfterCommit = false, failChunkAfterCommit = false;
  const uncertain = { ...store, setItem: (key: string, value: string) => {
    store.setItem(key, value);
    if (failRootAfterCommit && key === "queue") { failRootAfterCommit = false; throw new Error("root response interrupted"); }
    if (failChunkAfterCommit && key !== "queue") { failChunkAfterCommit = false; throw new Error("chunk response interrupted"); }
  } };
  const queue = new IncrementalEventQueue(uncertain, "queue");
  const events = Array.from({ length: 250 }, (_, id) => event(id));
  await queue.save(events);
  const rebound = events.map(row => ({ ...row, contextId: "first-binding" }));
  failRootAfterCommit = true;
  await assert.rejects(queue.save(rebound), /root response/);
  assert.deepEqual(await new IncrementalEventQueue(store, "queue").load(), rebound);
  failChunkAfterCommit = true;
  await assert.rejects(queue.save(events), /chunk response/);
  assert.deepEqual(await new IncrementalEventQueue(store, "queue").load(), rebound,
    "retry must not overwrite banks referenced by the committed directory");
  await queue.save(events);
  assert.deepEqual(await new IncrementalEventQueue(store, "queue").load(), events);
});

test("legacy JSONL migrates without changing event ownership or IDs", async () => {
  const store = storage();
  const events = Array.from({ length: 220 }, (_, id) => event(id));
  store.values.set("queue", events.map(value => JSON.stringify(value)).join("\n"));
  const queue = new IncrementalEventQueue(store, "queue");
  assert.deepEqual(await queue.load(), events);
  await queue.save(events);
  assert.deepEqual(await new IncrementalEventQueue(store, "queue").load(), events);
});

test("unread chunks are reserved rather than overwritten by new events", async () => {
  const store = storage(), queue = new IncrementalEventQueue(store, "queue");
  await queue.save([event(1)]);
  const directory = JSON.parse(store.values.get("queue")!);
  const key = directory.chunks[0].key;
  const saved = store.values.get(key)!;
  store.values.delete(key);
  const recovery = new IncrementalEventQueue(store, "queue");
  assert.deepEqual(await recovery.load(), []);
  await recovery.save([event(2)]);
  store.values.set(key, saved);
  assert.deepEqual((await new IncrementalEventQueue(store, "queue").load()).map(row => row.eventId).sort(), ["event-1", "event-2"]);
});

test("a burst coalesces enqueue persistence instead of serializing every snapshot", async () => {
  const store = storage();
  const tracker = new GameAlgoEventTracker({ platform: "web", sdkVersion: "test", isDebug: true,
    queueLimit: 1000, maxBatchSize: 100, flushIntervalMs: 0, persistOnEnqueue: true,
    now: () => 1000, storage: store, persistenceKey: "queue",
    uploadEvents: async () => ({ ok: true, accepted: 0 }) });
  tracker.identify("user", "session");
  for (let index = 0; index < 500; index++) assert.equal(tracker.trackLevelEnd({ level: index }), true);
  await tracker.flush();
  assert.ok(store.writes() <= 7, "500 events need five chunks and a directory");
  assert.equal((await new IncrementalEventQueue(store, "queue").load()).length, 500);
  tracker.close();
});
