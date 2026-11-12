import type { JsonValue } from "../../rest-api/src/types.ts";
import { validateRewardVideoAdUnit, type NativeRewardVideoAd } from "../../rest-api/src/reward-video-ad.ts";
import type { RewardAdSpace, RewardAdSpaceOptions, RewardVideoAdCallbacks } from "../../rest-api/src/reward-video-manager.ts";
import type { DouyinHost } from "./host.ts";

type Slot = { host: DouyinHost; unit: string; ad: NativeRewardVideoAd; owners: Set<DouyinRewardAds>; cancel?: () => void; activeOwner?: DouyinRewardAds };
const slots = new WeakMap<DouyinHost, Slot>();

/** Direct show is deliberate: a failed preload must not suppress native share fallback. */
export class DouyinRewardAds {
  private closed = false;
  private readonly owned = new Set<Slot>();
  private readonly host: DouyinHost;
  private readonly report: (id: string, payload: Record<string, JsonValue>, values: unknown[]) => boolean;
  private readonly timeoutMs: number;
  constructor(host: DouyinHost, report: (id: string, payload: Record<string, JsonValue>, values: unknown[]) => boolean, timeoutMs = 180_000) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("Invalid adTimeoutMs");
    this.host = host; this.report = report; this.timeoutMs = timeoutMs;
  }

  createAdSpace(options: RewardAdSpaceOptions): RewardAdSpace {
    if (this.closed) throw new Error("GamePropel client is closed");
    validateRewardVideoAdUnit(options);
    if ((options as { multiton?: unknown }).multiton) throw new Error("Douyin 1.0 supports single rewarded ads; multiton is unavailable");
    return Object.freeze({ show: (id: string, callbacks: RewardVideoAdCallbacks = {}, payload: Record<string, JsonValue> = {}) =>
      this.show(options.adUnitId, id, callbacks, payload) });
  }

  private async show(unit: string, id: string, callbacks: RewardVideoAdCallbacks, payload: Record<string, JsonValue>): Promise<void> {
    if (this.closed) throw new Error("GamePropel client is closed");
    if (!/^gap_[a-f0-9]{32}$/.test(id)) throw new Error("Invalid GamePropel adPlacementId");
    if (!callbacks || typeof callbacks !== "object" || Array.isArray(callbacks)
      || [callbacks.onClose, callbacks.onError].some(value => value !== undefined && typeof value !== "function")) throw new Error("Invalid Douyin ad callbacks");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("Ad payload must be an object");
    const snapshot = JSON.parse(JSON.stringify(payload)) as Record<string, JsonValue>;
    delete snapshot.trackId;
    const slot = this.acquire(unit);
    if (slot.cancel) throw new Error("Douyin rewarded ad is busy");
    let active = true, errorNotified = false, fallbackPending = false;
    let ready!: () => void, rejectPending!: (error: unknown) => void;
    const requestFinished = new Promise<void>((resolve, reject) => { ready = resolve; rejectPending = reject; });
    const invoke = (callback: ((...values: unknown[]) => unknown) | undefined, values: unknown[]) => {
      try { void Promise.resolve(callback?.(...values)).catch(() => undefined); } catch { /* Business errors cannot block telemetry. */ }
    };
    const cleanup = (reason?: unknown) => {
      if (!active) return;
      active = false; clearTimeout(timer); slot.cancel = undefined; slot.activeOwner = undefined;
      if (reason) rejectPending(reason);
      try { slot.ad.offClose?.(onClose); } catch { /* Active guard also protects retained callbacks. */ }
      try { slot.ad.offError?.(onError); } catch { /* Optional old-host cleanup. */ }
    };
    const onClose = (...values: unknown[]) => {
      if (!active || this.closed) return;
      try { this.report(id, snapshot, values); } catch { /* A report failure never withholds rewards. */ }
      cleanup(); ready(); invoke(callbacks.onClose as ((...values: unknown[]) => unknown) | undefined, values);
    };
    const onError = (...values: unknown[]) => {
      if (!active || this.closed) return;
      const value = values[0] as { errCode?: unknown; errNo?: unknown; code?: unknown } | undefined;
      const fallbackPossible = Number(value?.errCode ?? value?.errNo ?? value?.code) === 1004;
      fallbackPending ||= fallbackPossible;
      // An unfilled ad may continue as native sharing and deliver onClose later.
      if (!fallbackPending) cleanup(values[0] ?? new Error("Douyin ad failed"));
      if (!errorNotified) { errorNotified = true; invoke(callbacks.onError, values); }
    };
    const timer = setTimeout(() => { if (active) { cleanup(new Error("Douyin ad callbacks timed out")); if (!errorNotified) invoke(callbacks.onError, [{ errCode: "timeout", errMsg: "Douyin ad close callback timed out" }]); } }, this.timeoutMs);
    timer.unref?.();
    slot.cancel = () => cleanup(new Error("GamePropel client is closed")); slot.activeOwner = this;
    try {
      slot.ad.onClose(onClose); slot.ad.onError?.(onError);
      // Promise fulfillment alone is not an impression and must not grant rewards.
      await Promise.race([Promise.resolve(slot.ad.show()), requestFinished]);
    } catch (error) {
      onError(error);
      throw error;
    }
  }

  private acquire(unit: string): Slot {
    let slot = slots.get(this.host);
    if (slot && slot.unit !== unit) {
      if (slot.cancel) throw new Error("Douyin rewarded ad is busy");
      if (!slot.ad.destroy) throw new Error("Douyin cannot switch ad units without destroy");
      this.destroy(slot); slot = undefined;
    }
    if (!slot) {
      if (!this.host.createRewardedVideoAd) throw new Error("Douyin rewarded ads are unavailable");
      const ad = this.host.createRewardedVideoAd({ adUnitId: unit });
      if (typeof ad?.show !== "function" || typeof ad.onClose !== "function" || typeof ad.onError !== "function"
        || typeof ad.offClose !== "function" || typeof ad.offError !== "function") {
        try { ad?.destroy?.(); } catch { /* Incomplete native API. */ }
        throw new Error("Incomplete Douyin rewarded ad API");
      }
      slot = { host: this.host, unit, ad, owners: new Set() }; slots.set(this.host, slot);
    }
    slot.owners.add(this); this.owned.add(slot); return slot;
  }
  private destroy(slot: Slot): void {
    slot.cancel?.();
    if (slots.get(slot.host) === slot) slots.delete(slot.host);
    for (const owner of slot.owners) owner.owned.delete(slot);
    slot.owners.clear();
    try { slot.ad.destroy?.(); } catch { /* Closed callbacks are inactive. */ }
  }
  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const slot of [...this.owned]) {
      slot.owners.delete(this); this.owned.delete(slot);
      if (slot.owners.size === 0 || slot.activeOwner === this) this.destroy(slot);
    }
  }
}
