import type { GameAlgoStorage, GameEvent } from "./types.ts";
import { sha256HexSync } from "./sha256.ts";

type Row = { sequence: number; event: string };
type Ref = { key: string; revision: number };
type Chunk = { rows?: Map<string, Row>; ref?: Ref; bank: number };
type DurableStorage = GameAlgoStorage & {
  getItemDurably?: GameAlgoStorage["getItem"];
  setItemDurably?: GameAlgoStorage["setItem"];
  removeItemDurably?: GameAlgoStorage["removeItem"];
};
const FORMAT = "gamealgo-event-chunks-v2";

/** Copy-on-write event chunks; the small directory is committed last. */
export class IncrementalEventQueue {
  private readonly prefix: string;
  private chunks: Chunk[] = [];
  private locations = new Map<string, number>();
  private contexts = new Map<string, string>();
  private dirty = new Set<number>();
  private revision = 0;
  private sequence = 0;
  private reloadAfterFailure = false;
  private readonly storage: GameAlgoStorage;
  private readonly key: string;

  constructor(storage: GameAlgoStorage, key: string) {
    const durable = storage as DurableStorage;
    this.storage = durable.setItemDurably ? {
      getItem: key => (durable.getItemDurably ?? storage.getItem).call(storage, key),
      setItem: (key, value) => durable.setItemDurably!.call(storage, key, value),
      removeItem: key => (durable.removeItemDurably ?? storage.removeItem)?.call(storage, key),
    } : storage;
    this.key = key;
    this.prefix = `gamealgo:queue-chunk:${sha256HexSync(key)}`;
  }

  reset(): void {
    this.chunks = []; this.locations.clear(); this.contexts.clear(); this.dirty.clear();
    this.revision = 0; this.sequence = 0;
    this.reloadAfterFailure = false;
  }

  async load(stored?: string): Promise<GameEvent[]> {
    const raw = stored ?? await this.storage.getItem(this.key);
    if (!raw) return [];
    let directory: { format?: string; revision?: number; chunks?: Ref[] } | undefined;
    try { directory = JSON.parse(raw); } catch { /* Former JSONL queue. */ }
    if (directory?.format !== FORMAT) {
      const events = raw.split("\n").filter(Boolean).map(line => JSON.parse(line) as GameEvent)
        .filter(event => event.eventId && event.userId && event.sessionId && event.eventType);
      for (const event of events) this.upsert(event);
      return events;
    }
    this.revision = directory.revision ?? 0;
    const ordered: Array<{ sequence: number; event: GameEvent }> = [];
    for (const ref of directory.chunks ?? []) {
      const index = this.chunks.length;
      const chunk: Chunk = { ref, bank: Number(ref.key.slice(-1)) };
      this.chunks.push(chunk);
      try {
        const value = JSON.parse(await this.storage.getItem(ref.key) ?? "null");
        if (value?.revision !== ref.revision || !Array.isArray(value.rows)) continue;
        const rows = new Map<string, Row>();
        const parsed = (value.rows as Row[]).map(row => {
          const event = JSON.parse(row.event) as GameEvent;
          if (!event.eventId || !event.sessionId) throw new Error("invalid stored event");
          return { row, event, id: event.eventId };
        });
        for (const { row, event, id } of parsed) {
          rows.set(id, row);
          ordered.push({ sequence: row.sequence, event });
          this.locations.set(id, index);
          this.contexts.set(id, event.contextId);
          this.sequence = Math.max(this.sequence, row.sequence);
        }
        chunk.rows = rows;
      } catch { /* Reserve unread chunks instead of overwriting them. */ }
    }
    return ordered.sort((a, b) => a.sequence - b.sequence).map(row => row.event);
  }

  private upsert(event: GameEvent): void {
    const id = event.eventId!;
    const previous = this.locations.get(id);
    if (previous !== undefined && this.contexts.get(id) === event.contextId) return;
    let index = previous;
    if (index === undefined) {
      index = this.chunks.findIndex(chunk => chunk.rows !== undefined && chunk.rows.size < 100);
      if (index < 0) { index = this.chunks.length; this.chunks.push({ rows: new Map(), bank: 1 }); }
    }
    const rows = this.chunks[index].rows!;
    rows.set(id, { sequence: rows.get(id)?.sequence ?? ++this.sequence, event: JSON.stringify(event) });
    this.locations.set(id, index);
    this.contexts.set(id, event.contextId);
    this.dirty.add(index);
  }

  async save(events: GameEvent[]): Promise<boolean> {
    try {
      if (this.reloadAfterFailure) { this.reset(); await this.load(); }
      return await this.saveCurrent(events);
    } catch (error) {
      // A failed call may have committed before its response was interrupted.
      // Re-read the active banks before retrying instead of overwriting them.
      this.reloadAfterFailure = true;
      throw error;
    }
  }

  private async saveCurrent(events: GameEvent[]): Promise<boolean> {
    const retained = new Set(events.map(event => event.eventId!));
    for (const [id, index] of this.locations) {
      if (retained.has(id)) continue;
      this.chunks[index].rows!.delete(id);
      this.locations.delete(id);
      this.contexts.delete(id);
      this.dirty.add(index);
    }
    for (const event of events) this.upsert(event);
    if (this.chunks.length === 0) return false;
    if (this.locations.size === 0 && this.chunks.every(chunk => chunk.rows !== undefined)) {
      if (this.storage.removeItem) await this.storage.removeItem(this.key);
      else await this.storage.setItem(this.key, "");
      for (let index = 0; index < this.chunks.length; index++) {
        for (const bank of [0, 1]) {
          await this.storage.removeItem?.(`${this.prefix}:${index}:${bank}`);
        }
      }
      this.chunks = [];
      this.dirty.clear();
      return false;
    }
    if (this.dirty.size === 0) return true;
    const revision = ++this.revision;
    const refs = this.chunks.map(chunk => chunk.ref!);
    for (const index of this.dirty) {
      const chunk = this.chunks[index];
      const key = `${this.prefix}:${index}:${1 - chunk.bank}`;
      await this.storage.setItem(key, JSON.stringify({ revision, rows: [...chunk.rows!.values()] }));
      refs[index] = { key, revision };
    }
    await this.storage.setItem(this.key, JSON.stringify({ format: FORMAT, revision, chunks: refs }));
    for (const index of this.dirty) {
      this.chunks[index].ref = refs[index];
      this.chunks[index].bank = Number(refs[index].key.slice(-1));
    }
    this.dirty.clear();
    return true;
  }
}
