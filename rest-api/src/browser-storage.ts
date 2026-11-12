import type { GameAlgoStorage } from "./types.ts";

export type GameAlgoBrowserStorageOptions = {
  databaseName?: string;
  storeName?: string;
  indexedDB?: IDBFactory | null;
  /** null disables localStorage fallback, e.g. when a portal syncs it as a cloud save. */
  localStorage?: Storage | null;
  /** Optional diagnostics omit keys and stored values. */
  logger?: ((message: string) => void) | false;
};

/**
 * Browser storage with IndexedDB as the durable primary and localStorage as a
 * compatibility fallback. Raw Game Keys are never written by the SDK.
 */
export class GameAlgoBrowserStorage implements GameAlgoStorage {
  private readonly databaseName: string;
  private readonly storeName: string;
  private readonly indexedDB?: IDBFactory | null;
  private readonly localStorage?: Storage;
  private readonly memory = new Map<string, string>();
  private databasePromise?: Promise<IDBDatabase>;
  private readonly logger?: (message: string) => void;
  private operationSequence = 0;

  constructor(options: GameAlgoBrowserStorageOptions = {}) {
    this.databaseName = options.databaseName ?? "gamealgo-sdk";
    this.storeName = options.storeName ?? "kv";
    this.indexedDB = options.indexedDB === null ? undefined : (options.indexedDB ?? safeIndexedDB());
    this.localStorage = options.localStorage === null ? undefined : (options.localStorage ?? safeLocalStorage());
    this.logger = typeof options.logger === "function" ? options.logger : undefined;
    try { this.logger?.(`[GameAlgoSDK] storage capabilities indexedDB=${Boolean(this.indexedDB)} localStorage=${Boolean(this.localStorage)}`); } catch { /* Optional diagnostics. */ }
  }

  async getItem(key: string): Promise<string | undefined> {
    return this.observe(`read ${storageCategory(key)}`, () => this.readItem(key, false));
  }

  /** @internal Queue commits cannot treat an in-memory fallback as durable. */
  async getItemDurably(key: string): Promise<string | undefined> {
    return this.observe(`read-durable ${storageCategory(key)}`, () => this.readItem(key, true));
  }

  private async readItem(key: string, durable: boolean): Promise<string | undefined> {
    let readError: unknown;
    try {
      const overlay = this.localStorage?.getItem(`gamealgo:fallback:${key}`);
      if (overlay === "deleted") return undefined;
      if (overlay === "value") return this.localStorage?.getItem(key) ?? (durable ? undefined : this.memory.get(key));
    } catch (error) {
      if (durable) throw error;
      readError = error;
    }
    if (this.indexedDB) {
      try {
        const value = await this.readIndexedDB(key);
        if (typeof value === "string") return value;
      } catch (error) {
        // Without an authoritative fallback marker, an unread primary may
        // contain a newer queue than the legacy localStorage value.
        if (durable) throw error;
        readError = error;
        // Fall through to the compatibility stores.
      }
    }
    try {
      const value = this.localStorage?.getItem(key);
      if (value !== null && value !== undefined) return value;
    } catch (error) {
      readError = error;
      // Storage can be disabled in private or embedded browsing contexts.
    }
    if (durable && readError) throw readError;
    return durable ? undefined : this.memory.get(key);
  }

  async setItem(key: string, value: string): Promise<void> {
    return this.observe(`write ${storageCategory(key)}`, () => this.writeItem(key, value, false));
  }

  /** @internal Retain dirty chunks when both persistent stores are unavailable. */
  async setItemDurably(key: string, value: string): Promise<void> {
    return this.observe(`write-durable ${storageCategory(key)}`, () => this.writeItem(key, value, true));
  }

  private async writeItem(key: string, value: string, durable: boolean): Promise<void> {
    if (durable) this.localStorage?.getItem(`gamealgo:fallback:${key}`);
    this.memory.set(key, value);
    if (this.indexedDB) {
      try {
        await this.writeIndexedDB(key, value);
        try {
          this.localStorage?.removeItem(`gamealgo:fallback:${key}`);
          this.localStorage?.removeItem(key);
        } catch (error) {
          // A retained fallback marker can still hide this primary value.
          if (durable) throw error;
        }
        return;
      } catch {
        // Fall through to localStorage.
      }
    }
    try {
      if (!this.localStorage) throw new Error("Persistent browser storage is unavailable");
      this.localStorage?.setItem(key, value);
      // A failed transaction can leave an older primary value behind. Record
      // that the fallback is authoritative, including after a page restart.
      this.localStorage?.setItem(`gamealgo:fallback:${key}`, "value");
    } catch (error) {
      if (durable) throw error;
      // Memory remains available for the current page lifecycle.
    }
  }

  async removeItem(key: string): Promise<void> {
    return this.observe(`delete ${storageCategory(key)}`, () => this.deleteItem(key, false));
  }

  /** @internal Do not clean up chunks before their directory removal commits. */
  async removeItemDurably(key: string): Promise<void> {
    return this.observe(`delete-durable ${storageCategory(key)}`, () => this.deleteItem(key, true));
  }

  private async deleteItem(key: string, durable: boolean): Promise<void> {
    this.memory.delete(key);
    let primaryRemoved = false;
    if (this.indexedDB) {
      try {
        await this.deleteIndexedDB(key);
        primaryRemoved = true;
      } catch {
        // Continue clearing fallback storage.
      }
    }
    try {
      if (!this.localStorage) {
        if (primaryRemoved) return;
        throw new Error("Persistent browser storage is unavailable");
      }
      this.localStorage?.removeItem(key);
      if (primaryRemoved) this.localStorage?.removeItem(`gamealgo:fallback:${key}`);
      else this.localStorage?.setItem(`gamealgo:fallback:${key}`, "deleted");
    } catch (error) {
      if (durable) throw error;
      // Nothing else to clear.
    }
  }

  private database(): Promise<IDBDatabase> {
    if (!this.indexedDB) return Promise.reject(new Error("IndexedDB is unavailable"));
    if (!this.databasePromise) {
      this.databasePromise = this.observe("indexeddb.open", () => new Promise<IDBDatabase>((resolve, reject) => {
        const request = this.indexedDB!.open(this.databaseName, 1);
        request.onupgradeneeded = () => {
          const database = request.result;
          if (!database.objectStoreNames.contains(this.storeName)) database.createObjectStore(this.storeName);
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("Unable to open IndexedDB"));
        request.onblocked = () => reject(new Error("IndexedDB upgrade is blocked"));
      }));
    }
    return this.databasePromise;
  }

  private async readIndexedDB(key: string): Promise<unknown> {
    const database = await this.database();
    return this.observe(`indexeddb.read ${storageCategory(key)}`, () => idbRequest(database.transaction(this.storeName, "readonly").objectStore(this.storeName).get(key)));
  }

  private async writeIndexedDB(key: string, value: string): Promise<void> {
    const database = await this.database();
    await this.observe(`indexeddb.write ${storageCategory(key)}`, async () => {
      const transaction = database.transaction(this.storeName, "readwrite");
      transaction.objectStore(this.storeName).put(value, key);
      await idbTransaction(transaction);
    });
  }

  private async deleteIndexedDB(key: string): Promise<void> {
    const database = await this.database();
    await this.observe(`indexeddb.delete ${storageCategory(key)}`, async () => {
      const transaction = database.transaction(this.storeName, "readwrite");
      transaction.objectStore(this.storeName).delete(key);
      await idbTransaction(transaction);
    });
  }

  private async observe<T>(stage: string, operation: () => T | Promise<T>): Promise<T> {
    if (!this.logger) return operation();
    const sequence = ++this.operationSequence;
    const startedAt = Date.now();
    const log = (status: string) => {
      try { this.logger?.(`[GameAlgoSDK] storage op=${sequence} ${stage} ${status} elapsedMs=${Math.max(0, Date.now() - startedAt)}`); } catch { /* Diagnostics cannot alter storage. */ }
    };
    log("started");
    const slowTimer = setTimeout(() => log("pending"), 3000);
    slowTimer.unref?.();
    try {
      const result = await operation();
      log(`complete resultType=${typeof result}`);
      return result;
    } catch (error) {
      log(`failed errorType=${error instanceof Error ? error.name : typeof error}`);
      throw error;
    } finally {
      clearTimeout(slowTimer);
    }
  }
}

function storageCategory(key: string): string {
  if (key.startsWith("gamealgo:v1:identity:")) {
    if (key.endsWith(":user-id")) return "identity.userId";
    if (key.endsWith(":created-at")) return "identity.createdAt";
    if (key.endsWith(":created-local-at")) return "identity.createdLocalAt";
    return "identity";
  }
  if (key.startsWith("gamealgo_user_")) return "identity.legacy";
  if (key.startsWith("gamealgo:v1:event-queue:")) return "event-queue";
  if (key.startsWith("gamealgo:v1:snapshot:")) return "snapshot";
  return "cache";
}

function safeLocalStorage(): Storage | undefined {
  if (typeof window === "undefined") return undefined;
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

function idbRequest(request: IDBRequest): Promise<unknown> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });
}

function idbTransaction(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("IndexedDB transaction failed"));
    transaction.onabort = () => reject(transaction.error ?? new Error("IndexedDB transaction was aborted"));
  });
}

function safeIndexedDB(): IDBFactory | undefined {
  try { return globalThis.indexedDB; } catch { return undefined; }
}
