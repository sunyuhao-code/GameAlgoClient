import type { GameAlgoStorage } from "../../rest-api/src/types.ts";
import type { WechatHost } from "./host.ts";

/** Native local storage. Failed I/O is never presented as an empty durable queue. */
export class GameAlgoWechatStorage implements GameAlgoStorage {
  private readonly written = new Map<string, string>();

  private readonly host: WechatHost;

  constructor(host: WechatHost) { this.host = host; }

  getItem(key: string): string | undefined {
    try {
      const value = this.host.getStorageSync(key);
      if (value === "" || value === undefined || value === null) {
        this.written.delete(key);
        return undefined;
      }
      if (typeof value !== "string") throw new Error("Unexpected GameAlgo WeChat storage value");
      // Identity/snapshot restore often writes back the same metadata. The
      // successful native read already proves those bytes are durable.
      this.written.set(key, value);
      return value;
    } catch (error) {
      this.written.delete(key);
      throw error;
    }
  }

  setItem(key: string, value: string): void {
    if (this.written.get(key) === value) return;
    try {
      this.host.setStorageSync(key, value);
      this.written.set(key, value);
    } catch (error) {
      this.written.delete(key);
      throw error;
    }
  }

  removeItem(key: string): void {
    this.written.delete(key);
    this.host.removeStorageSync(key);
  }

  getItemDurably(key: string): string | undefined { return this.getItem(key); }
  setItemDurably(key: string, value: string): void { this.setItem(key, value); }
  removeItemDurably(key: string): void { this.removeItem(key); }
}
