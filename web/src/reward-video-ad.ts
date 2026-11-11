// TapTap's default rewarded ad is a host singleton, not a GameAlgo placement.
// Share ownership and the playback lock even across WebClient instances.
export type RewardVideoCallback = (...values: unknown[]) => void;
export type TapRewardVideoAd = {
  load?: () => unknown;
  show: () => unknown;
  onLoad?: (callback: RewardVideoCallback) => void;
  offLoad?: (callback: RewardVideoCallback) => void;
  onClose: (callback: RewardVideoCallback) => void;
  offClose?: (callback: RewardVideoCallback) => void;
  onError?: (callback: RewardVideoCallback) => void;
  offError?: (callback: RewardVideoCallback) => void;
  destroy?: () => void;
};
type TapRewardVideoHost = { createRewardedVideoAd: (options: { adUnitId: string }) => TapRewardVideoAd };
type LoadResult = { ok: true } | { ok: false; values: unknown[] };
type LoadOperation = {
  promise: Promise<LoadResult>;
  resolve: (value: LoadResult) => void;
  reject: (error: unknown) => void;
  eventOnly: boolean;
  errorValues?: unknown[];
  timer?: ReturnType<typeof setTimeout>;
};
const hostSlots = new WeakMap<TapRewardVideoHost, RewardVideoSlot>();
const LOAD_TIMEOUT_MS = 30_000;

export type RewardVideoPlayback = {
  ad: TapRewardVideoAd;
  readonly ready: boolean;
  readonly cleaning: boolean;
  load: () => Promise<LoadResult>;
  acceptClose: (trackId: string | undefined) => boolean;
  consume: () => void;
  finish: (reusable: boolean) => void;
};

export function validateRewardVideoAdUnit(options: { adUnitId: string }): void {
  if (!options || typeof options.adUnitId !== "string" || !options.adUnitId.trim()) {
    throw new Error("Invalid TapTap rewarded ad options");
  }
}

export class RewardVideoAdPool {
  readonly slots = new Set<RewardVideoSlot>();
  private closed = false;
  private readonly waiting = new Set<(reason: Error) => void>();

  async preload(options: { adUnitId: string }): Promise<void> {
    validateRewardVideoAdUnit(options);
    const slot = this.acquire(options.adUnitId);
    if (slot.playback || slot.loading?.errorValues) throw new Error("TapTap rewarded ad is busy");
    const result = await this.wait(slot.load(true));
    if (!result.ok) throw new Error("TapTap rewarded ad preload failed", { cause: result.values[0] });
  }

  begin(adUnitId: string): RewardVideoPlayback {
    const slot = this.acquire(adUnitId);
    if (slot.playback || slot.loading?.errorValues) throw new Error("TapTap rewarded ad is busy");
    const playback: RewardVideoPlayback = {
      ad: slot.ad,
      get ready() { return slot.ready; },
      get cleaning() { return slot.cleaning; },
      load: () => this.wait(slot.load(false)),
      acceptClose: (trackId) => slot.acceptClose(trackId),
      consume: () => { slot.ready = false; },
      finish: (reusable) => {
        // Retained callbacks from an old playback cannot release a newer one.
        if (slot.playback?.lease !== playback) return;
        slot.playback = undefined;
        if (!reusable) slot.destroy();
      },
    };
    slot.playback = { owner: this, lease: playback };
    return playback;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const reject of this.waiting) reject(new Error("GameAlgo client is closed"));
    this.waiting.clear();
    for (const slot of [...this.slots]) {
      slot.owners.delete(this);
      this.slots.delete(slot);
      if (slot.playback?.owner === this || slot.owners.size === 0) slot.destroy();
    }
  }

  private wait<T>(promise: Promise<T>): Promise<T> {
    // Remove cancellation listeners after each operation, rather than retaining
    // every completed preload/playback on a never-settled closing Promise.
    return new Promise<T>((resolve, reject) => {
      const cancel = (reason: Error) => reject(reason);
      if (this.closed) cancel(new Error("GameAlgo client is closed"));
      else this.waiting.add(cancel);
      void promise.then((value) => {
        this.waiting.delete(cancel);
        resolve(value);
      }, (error) => {
        this.waiting.delete(cancel);
        reject(error);
      });
    });
  }

  private acquire(adUnitId: string): RewardVideoSlot {
    if (this.closed) throw new Error("GameAlgo client is closed");
    const tap = (globalThis as { tap?: Partial<TapRewardVideoHost> }).tap;
    if (typeof tap?.createRewardedVideoAd !== "function") throw new Error("TapTap rewarded ads are unavailable in this host");
    const host = tap as TapRewardVideoHost;
    let slot = hostSlots.get(host);
    if (slot && slot.adUnitId !== adUnitId) {
      if (slot.playback || slot.loading) throw new Error("TapTap rewarded ad is busy");
      if (!slot.ad.destroy) throw new Error("TapTap host cannot switch rewarded ad units without destroy");
      slot.destroy();
      slot = undefined;
    }
    if (!slot) {
      slot = new RewardVideoSlot(host, adUnitId);
      hostSlots.set(host, slot);
    }
    slot.owners.add(this);
    this.slots.add(slot);
    return slot;
  }
}

class RewardVideoSlot {
  private readonly host: TapRewardVideoHost;
  readonly adUnitId: string;
  readonly owners = new Set<RewardVideoAdPool>();
  readonly ad: TapRewardVideoAd;
  ready = false;
  cleaning = false;
  loading?: LoadOperation;
  playback?: { owner: RewardVideoAdPool; lease: RewardVideoPlayback };
  private disposed = false;
  private readonly reportedTracks = new Set<string>();
  private readonly onLoad: RewardVideoCallback = () => {
    if (this.disposed) return;
    this.ready = true;
    const loading = this.loading;
    if (loading?.eventOnly) this.finishLoad(loading, { ok: true });
  };
  private readonly onError: RewardVideoCallback = (...values) => {
    if (this.disposed) return;
    this.ready = false;
    const loading = this.loading;
    if (loading) {
      loading.errorValues = values;
      if (loading.eventOnly) this.finishLoad(loading, { ok: false, values });
    }
  };

  constructor(host: TapRewardVideoHost, adUnitId: string) {
    this.host = host;
    this.adUnitId = adUnitId;
    this.ad = host.createRewardedVideoAd({ adUnitId });
    try {
      if (typeof this.ad?.onClose !== "function" || typeof this.ad.show !== "function") {
        throw new Error("Incomplete TapTap rewarded ad API");
      }
      this.ad.onLoad?.(this.onLoad);
      this.ad.onError?.(this.onError);
    } catch (error) {
      this.destroy();
      throw error;
    }
  }

  load(requireReady: boolean): Promise<LoadResult> {
    if (this.disposed) return Promise.reject(new Error("TapTap rewarded ad instance was released"));
    if (this.ready) return Promise.resolve({ ok: true });
    if (this.loading) return this.loading.promise;
    const operation: LoadOperation = {
      promise: undefined!, resolve: undefined!, reject: undefined!, eventOnly: false,
    };
    operation.promise = new Promise<LoadResult>((resolve, reject) => {
      operation.resolve = resolve;
      operation.reject = reject;
    });
    this.loading = operation;
    try {
      const result = this.ad.load?.();
      if (result && typeof (result as PromiseLike<unknown>).then === "function") {
        void Promise.resolve(result).then(() => {
          if (this.loading !== operation) return;
          if (operation.errorValues) this.finishLoad(operation, { ok: false, values: operation.errorValues });
          else {
            this.ready = true;
            this.finishLoad(operation, { ok: true });
          }
        }, (error) => this.failLoad(operation, error));
      } else if (operation.errorValues) this.finishLoad(operation, { ok: false, values: operation.errorValues });
      else if (this.ready) this.finishLoad(operation, { ok: true });
      else if (this.ad.onLoad) operation.eventOnly = true;
      else if (requireReady) this.failLoad(operation, new Error("TapTap host cannot confirm rewarded ad preload readiness"));
      else this.finishLoad(operation, { ok: true }); // Legacy hosts may only support show().
      if (this.loading === operation) {
        operation.timer = setTimeout(() => {
          this.failLoad(operation, new Error("TapTap rewarded ad load timed out"));
          this.destroy();
        }, LOAD_TIMEOUT_MS);
      }
    } catch (error) { this.failLoad(operation, error); }
    return operation.promise;
  }

  acceptClose(trackId: string | undefined): boolean {
    const key = trackId?.trim();
    if (key && this.reportedTracks.has(key)) return false;
    if (key) {
      this.reportedTracks.add(key);
      if (this.reportedTracks.size > 64) this.reportedTracks.delete(this.reportedTracks.values().next().value!);
    }
    return true;
  }

  destroy(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.cleaning = true;
    if (hostSlots.get(this.host) === this) hostSlots.delete(this.host);
    if (this.loading) this.failLoad(this.loading, new Error("TapTap rewarded ad instance was released"));
    for (const owner of this.owners) owner.slots.delete(this);
    this.owners.clear();
    for (const release of [() => this.ad?.offLoad?.(this.onLoad), () => this.ad?.offError?.(this.onError), () => this.ad?.destroy?.()]) {
      try { release(); } catch { /* Optional host cleanup cannot block client.close(). */ }
    }
    this.cleaning = false;
  }

  private finishLoad(operation: LoadOperation, result: LoadResult): void {
    if (this.loading !== operation) return;
    clearTimeout(operation.timer);
    this.loading = undefined;
    operation.resolve(result);
  }

  private failLoad(operation: LoadOperation, error: unknown): void {
    if (this.loading !== operation) return;
    clearTimeout(operation.timer);
    this.loading = undefined;
    this.ready = false;
    operation.reject(error);
  }
}
