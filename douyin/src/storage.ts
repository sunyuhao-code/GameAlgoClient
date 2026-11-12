import type { GameAlgoStorage } from "../../rest-api/src/types.ts";
import type { DouyinHost } from "./host.ts";

/** Native storage; only a documented missing-key error means an empty value. */
export class GamePropelDouyinStorage implements GameAlgoStorage {
  private readonly written = new Map<string, string>();
  private readonly host: DouyinHost;
  constructor(host: DouyinHost) { this.host = host; }
  getItem(key: string): string | undefined {
    try {
      const value = this.host.getStorageSync(key);
      if (value === "" || value === undefined || value === null) { this.written.delete(key); return undefined; }
      if (typeof value !== "string") throw new Error("Unexpected GamePropel Douyin storage value");
      this.written.set(key, value);
      return value;
    } catch (error) {
      this.written.delete(key);
      if (missingKey(error, "getStorageSync")) return undefined;
      throw error;
    }
  }
  setItem(key: string, value: string): void {
    if (this.written.get(key) === value) return;
    try { this.host.setStorageSync(key, value); this.written.set(key, value); }
    catch (error) { this.written.delete(key); throw error; }
  }
  removeItem(key: string): void {
    this.written.delete(key);
    try { this.host.removeStorageSync(key); }
    catch (error) { if (!missingKey(error, "removeStorageSync")) throw error; }
  }
  getItemDurably(key: string): string | undefined { return this.getItem(key); }
  setItemDurably(key: string, value: string): void { this.setItem(key, value); }
  removeItemDurably(key: string): void { this.removeItem(key); }
}

function missingKey(error: unknown, method: "getStorageSync" | "removeStorageSync"): boolean {
  const value = error as { errMsg?: unknown; message?: unknown } | undefined;
  const message = value?.errMsg ?? value?.message;
  if (typeof message !== "string") return false;
  const detail = message.startsWith(method + ":fail") ? message.slice(method.length + 5).trim() : message;
  return /^data not found(?:\b|,)/i.test(detail);
}
