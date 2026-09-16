import type { GameAlgoStorage } from "../../rest-api/src/types.ts";

export type GameAlgoBrowserStorageOptions = {
  databaseName?: string;
  storeName?: string;
  indexedDB?: IDBFactory;
  localStorage?: Storage;
};

/**
 * Browser storage with IndexedDB as the durable primary and localStorage as a
 * compatibility fallback. Raw Game Keys are never written by the SDK.
 */
export class GameAlgoBrowserStorage implements GameAlgoStorage {
  private readonly databaseName: string;
  private readonly storeName: string;
  private readonly indexedDB?: IDBFactory;
  private readonly localStorage?: Storage;
  private readonly memory = new Map<string, string>();
  private databasePromise?: Promise<IDBDatabase>;

  constructor(options: GameAlgoBrowserStorageOptions = {}) {
    this.databaseName = options.databaseName ?? "gamealgo-sdk";
    this.storeName = options.storeName ?? "kv";
    this.indexedDB = options.indexedDB ?? globalThis.indexedDB;
    this.localStorage = options.localStorage ?? safeLocalStorage();
  }

  async getItem(key: string): Promise<string | undefined> {
    if (this.indexedDB) {
      try {
        const value = await this.readIndexedDB(key);
        if (typeof value === "string") return value;
      } catch {
        // Fall through to the compatibility stores.
      }
    }
    try {
      const value = this.localStorage?.getItem(key);
      if (value !== null && value !== undefined) return value;
    } catch {
      // Storage can be disabled in private or embedded browsing contexts.
    }
    return this.memory.get(key);
  }

  async setItem(key: string, value: string): Promise<void> {
    this.memory.set(key, value);
    if (this.indexedDB) {
      try {
        await this.writeIndexedDB(key, value);
        return;
      } catch {
        // Fall through to localStorage.
      }
    }
    try {
      this.localStorage?.setItem(key, value);
    } catch {
      // Memory remains available for the current page lifecycle.
    }
  }

  async removeItem(key: string): Promise<void> {
    this.memory.delete(key);
    if (this.indexedDB) {
      try {
        await this.deleteIndexedDB(key);
      } catch {
        // Continue clearing fallback storage.
      }
    }
    try {
      this.localStorage?.removeItem(key);
    } catch {
      // Nothing else to clear.
    }
  }

  private database(): Promise<IDBDatabase> {
    if (!this.indexedDB) return Promise.reject(new Error("IndexedDB is unavailable"));
    if (!this.databasePromise) {
      this.databasePromise = new Promise((resolve, reject) => {
        const request = this.indexedDB!.open(this.databaseName, 1);
        request.onupgradeneeded = () => {
          const database = request.result;
          if (!database.objectStoreNames.contains(this.storeName)) database.createObjectStore(this.storeName);
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("Unable to open IndexedDB"));
        request.onblocked = () => reject(new Error("IndexedDB upgrade is blocked"));
      });
    }
    return this.databasePromise;
  }

  private async readIndexedDB(key: string): Promise<unknown> {
    const database = await this.database();
    return await idbRequest(database.transaction(this.storeName, "readonly").objectStore(this.storeName).get(key));
  }

  private async writeIndexedDB(key: string, value: string): Promise<void> {
    const database = await this.database();
    const transaction = database.transaction(this.storeName, "readwrite");
    transaction.objectStore(this.storeName).put(value, key);
    await idbTransaction(transaction);
  }

  private async deleteIndexedDB(key: string): Promise<void> {
    const database = await this.database();
    const transaction = database.transaction(this.storeName, "readwrite");
    transaction.objectStore(this.storeName).delete(key);
    await idbTransaction(transaction);
  }
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
