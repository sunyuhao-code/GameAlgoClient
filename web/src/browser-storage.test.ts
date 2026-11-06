import test from "node:test";
import assert from "node:assert/strict";
import { GameAlgoBrowserStorage } from "./browser-storage.ts";
import { IncrementalEventQueue } from "../../rest-api/src/event-queue-store.ts";
import type { GameEvent } from "../../rest-api/src/types.ts";

test("an unread primary cannot be replaced by an unmarked stale fallback queue", async () => {
  const local = { getItem: (key: string) => key === "queue" ? "stale" : null } as Storage;
  const value = new GameAlgoBrowserStorage({ indexedDB: {} as IDBFactory, localStorage: local });
  const adapter = value as unknown as { readIndexedDB(key: string): Promise<unknown> };
  adapter.readIndexedDB = async () => { throw new Error("primary unavailable"); };
  assert.equal(await value.getItem("queue"), "stale", "ordinary caches retain their compatibility fallback");
  await assert.rejects(value.getItemDurably("queue"), /primary unavailable/);
  adapter.readIndexedDB = async () => "latest";
  assert.equal(await value.getItemDurably("queue"), "latest");
});

test("memory fallback cannot commit queue banks or erase old chunks during a persistent-store outage", async () => {
  const primary = new Map<string, string>(), fallback = new Map<string, string>();
  let unavailable = false;
  const local = { getItem: (key: string) => fallback.get(key) ?? null,
    setItem: (key: string, value: string) => { if (unavailable) throw new Error("quota"); fallback.set(key, value); },
    removeItem: (key: string) => { if (unavailable) throw new Error("quota"); fallback.delete(key); } } as Storage;
  function instance() {
    const value = new GameAlgoBrowserStorage({ indexedDB: {} as IDBFactory, localStorage: local });
    const adapter = value as unknown as {
      readIndexedDB(key: string): Promise<unknown>;
      writeIndexedDB(key: string, data: string): Promise<void>;
      deleteIndexedDB(key: string): Promise<void>;
    };
    adapter.readIndexedDB = async key => primary.get(key);
    adapter.writeIndexedDB = async (key, data) => { if (unavailable) throw new Error("blocked"); primary.set(key, data); };
    adapter.deleteIndexedDB = async key => { if (unavailable) throw new Error("blocked"); primary.delete(key); };
    return value;
  }
  const events: GameEvent[] = Array.from({ length: 250 }, (_, id) => ({ eventId: `event-${id}`,
    userId: "user", sessionId: "session", contextId: "", eventType: "level_end", payload: { id } }));
  const queue = new IncrementalEventQueue(instance(), "queue");
  await queue.save(events);
  const rebound = events.map(row => ({ ...row, contextId: "recovered-context" }));
  unavailable = true;
  await assert.rejects(queue.save(rebound), /quota/);
  assert.deepEqual(await new IncrementalEventQueue(instance(), "queue").load(), events);
  await assert.rejects(queue.save([]), /quota/);
  assert.deepEqual(await new IncrementalEventQueue(instance(), "queue").load(), events,
    "a failed directory deletion must leave its referenced chunks intact");
  // Identity/config caches retain their existing in-memory fallback behavior.
  const memory = instance();
  await memory.setItem("memory-only", "value");
  assert.equal(await memory.getItem("memory-only"), "value");
  assert.equal(await memory.getItemDurably("memory-only"), undefined);
  unavailable = false;
  const next = [...rebound, { ...events[0], eventId: "tail" }];
  await queue.save(next);
  assert.deepEqual(await new IncrementalEventQueue(instance(), "queue").load(), next);
});

test("a retained fallback overlay cannot hide a newly confirmed chunk after primary recovery", async () => {
  const primary = new Map<string, string>(), fallback = new Map<string, string>();
  let primaryFails = true, fallbackFails = false, interruptCleanup = false;
  const local = { getItem: (key: string) => fallback.get(key) ?? null,
    setItem: (key: string, value: string) => { if (fallbackFails) throw new Error("quota"); fallback.set(key, value); },
    removeItem: (key: string) => {
      if (interruptCleanup) { interruptCleanup = false; throw new Error("cleanup interrupted"); }
      fallback.delete(key);
    } } as Storage;
  function instance() {
    const value = new GameAlgoBrowserStorage({ indexedDB: {} as IDBFactory, localStorage: local });
    const adapter = value as unknown as {
      readIndexedDB(key: string): Promise<unknown>;
      writeIndexedDB(key: string, data: string): Promise<void>;
    };
    adapter.readIndexedDB = async key => primary.get(key);
    adapter.writeIndexedDB = async (key, data) => { if (primaryFails) throw new Error("blocked"); primary.set(key, data); };
    return value;
  }
  const queue = new IncrementalEventQueue(instance(), "queue");
  const events: GameEvent[] = Array.from({ length: 250 }, (_, id) => ({ eventId: `event-${id}`,
    userId: "user", sessionId: "session", contextId: "", eventType: "level_end", payload: { id } }));
  await queue.save(events);
  primaryFails = false;
  const first = events.map(row => ({ ...row, contextId: "first" }));
  await queue.save(first);
  const second = events.map(row => ({ ...row, contextId: "second" }));
  fallbackFails = true; interruptCleanup = true;
  await assert.rejects(queue.save(second), /quota/);
  assert.deepEqual(await new IncrementalEventQueue(instance(), "queue").load(), first);
  fallbackFails = false;
  await queue.save(second);
  assert.deepEqual(await new IncrementalEventQueue(instance(), "queue").load(), second);
});

test("failed IndexedDB writes and removals remain authoritative after restart", async () => {
  const primary = new Map<string, string>([["queue", "old"]]);
  const fallback = new Map<string, string>();
  let fail = true;
  const local = { getItem: (key: string) => fallback.get(key) ?? null,
    setItem: (key: string, value: string) => { fallback.set(key, value); },
    removeItem: (key: string) => { fallback.delete(key); } } as Storage;
  function instance() {
    const value = new GameAlgoBrowserStorage({ indexedDB: {} as IDBFactory, localStorage: local });
    const adapter = value as unknown as {
      readIndexedDB(key: string): Promise<unknown>;
      writeIndexedDB(key: string, data: string): Promise<void>;
      deleteIndexedDB(key: string): Promise<void>;
    };
    adapter.readIndexedDB = async key => primary.get(key);
    adapter.writeIndexedDB = async (key, data) => { if (fail) throw new Error("blocked"); primary.set(key, data); };
    adapter.deleteIndexedDB = async key => { if (fail) throw new Error("blocked"); primary.delete(key); };
    return value;
  }
  await instance().setItem("queue", "new");
  assert.equal(await instance().getItem("queue"), "new", "stale primary must not hide a committed fallback");
  await instance().removeItem("queue");
  assert.equal(await instance().getItem("queue"), undefined, "failed primary removal must not resurrect an acknowledged queue");
  fail = false;
  await instance().setItem("queue", "latest");
  assert.equal(await instance().getItem("queue"), "latest");
  assert.equal(fallback.size, 0, "successful primary commit retires the fallback overlay");
});
