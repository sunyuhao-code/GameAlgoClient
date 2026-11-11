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
  finish: (reusable: boolean, prepareNext?: boolean) => void;
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
  private readonly preparationTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private readonly logger?: (message: string) => void;

  constructor(logger?: (message: string) => void) {
    this.logger = logger;
  }

  register(adUnitId: string): void {
    if (this.closed || this.preparationTimers.has(adUnitId)) return;
    const discoveryDeadline = Date.now() + 10_000;
    const prepare = () => {
      this.preparationTimers.delete(adUnitId);
      if (this.closed) return;
      const tap = (globalThis as { tap?: Partial<TapRewardVideoHost> }).tap;
      if (typeof tap?.createRewardedVideoAd !== "function") {
        if (Date.now() < discoveryDeadline) schedule(250);
        return;
      }
      // TapTap has one native slot. Background work never switches an idle
      // unit away from another handle or interrupts its loading/playback.
      const current = hostSlots.get(tap as TapRewardVideoHost);
      if (current && current.adUnitId !== adUnitId) return;
      try { this.acquire(adUnitId).prepare(); }
      catch { this.log("automatic preload failed"); }
    };
    const schedule = (delayMs: number) => {
      const timer = setTimeout(prepare, delayMs);
      timer.unref?.();
      this.preparationTimers.set(adUnitId, timer);
    };
    schedule(0);
  }

  log(message: string): void {
    try { this.logger?.(`[GameAlgoSDK] reward ad ${message}`); } catch { /* Optional diagnostics. */ }
  }

  begin(adUnitId: string): RewardVideoPlayback {
    const slot = this.acquire(adUnitId);
    if (slot.playback) throw new Error("TapTap rewarded ad is busy");
    const playback: RewardVideoPlayback = {
      ad: slot.ad,
      get ready() { return slot.ready; },
      get cleaning() { return slot.cleaning; },
      load: () => this.wait(slot.load(false)),
      acceptClose: (trackId) => slot.acceptClose(trackId),
      consume: () => { slot.ready = false; },
      finish: (reusable, prepareNext = false) => {
        // Retained callbacks from an old playback cannot release a newer one.
        if (slot.playback?.lease !== playback) return;
        slot.playback = undefined;
        if (!reusable) {
          const owners = [...slot.owners];
          slot.destroy();
          if (prepareNext) for (const owner of owners) owner.register(adUnitId);
        } else if (prepareNext) slot.prepare();
      },
    };
    slot.playback = { owner: this, lease: playback };
    return playback;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const timer of this.preparationTimers.values()) clearTimeout(timer);
    this.preparationTimers.clear();
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
  private preparationTimer?: ReturnType<typeof setTimeout>;
  private readonly reportedTracks = new Set<string>();
  private readonly onLoad: RewardVideoCallback = () => {
    if (this.disposed) return;
    this.ready = true;
    const loading = this.loading;
    if (loading) this.finishLoad(loading, { ok: true });
  };
  private readonly onError: RewardVideoCallback = (...values) => {
    if (this.disposed) return;
    this.ready = false;
    const loading = this.loading;
    if (loading) {
      this.finishLoad(loading, { ok: false, values });
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

  prepare(): void {
    if (this.disposed || this.playback || this.ready || this.loading || this.preparationTimer) return;
    // Let the host's own post-close onLoad notification run first. Reuse a
    // ready/in-flight slot instead of loading again or scheduling autoplay.
    this.preparationTimer = setTimeout(() => {
      this.preparationTimer = undefined;
      if (this.disposed || this.owners.size === 0 || this.playback || this.ready || this.loading) return;
      for (const owner of this.owners) owner.log("automatic preload started");
      void this.load(true).then(result => {
        if (this.disposed) return;
        for (const owner of this.owners) owner.log(result.ok ? "automatic preload ready" : "automatic preload failed");
      }).catch(() => {
        if (this.disposed) return;
        for (const owner of this.owners) owner.log("automatic preload failed");
      });
    }, 0);
    this.preparationTimer.unref?.();
  }

  load(requireReady: boolean): Promise<LoadResult> {
    if (this.disposed) return Promise.reject(new Error("TapTap rewarded ad instance was released"));
    if (this.ready) return Promise.resolve({ ok: true });
    if (this.loading) return this.loading.promise;
    const operation: LoadOperation = {
      promise: undefined!, resolve: undefined!, reject: undefined!,
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
          this.ready = true;
          this.finishLoad(operation, { ok: true });
        }, (error) => this.failLoad(operation, error));
      } else if (this.ready) this.finishLoad(operation, { ok: true });
      else if (!this.ad.onLoad) {
        if (requireReady) this.failLoad(operation, new Error("TapTap host cannot confirm rewarded ad preload readiness"));
        else this.finishLoad(operation, { ok: true }); // Legacy hosts may only support show().
      }
      if (this.loading === operation) {
        operation.timer = setTimeout(() => {
          if (requireReady) for (const owner of this.owners) owner.log("automatic preload failed");
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
    clearTimeout(this.preparationTimer);
    this.preparationTimer = undefined;
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
