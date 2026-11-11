import type { JsonValue } from "./types.ts";
import { RewardVideoAdPool, validateRewardVideoAdUnit, type RewardVideoHost, type RewardVideoCallback, type RewardVideoPlayback, type NativeRewardVideoAd } from "./reward-video-ad.ts";

export type RewardVideoCloseResult = { isEnded?: boolean; [key: string]: unknown };
export type RewardVideoAdOptions = {
  adUnitId: string;
  onClose?: (result: RewardVideoCloseResult | undefined, ...values: unknown[]) => void | Promise<void>;
  onError?: (...values: unknown[]) => void | Promise<void>;
};
export type RewardAdSpaceOptions = Pick<RewardVideoAdOptions, "adUnitId">;
export type RewardVideoAdCallbacks = Omit<RewardVideoAdOptions, "adUnitId">;
export type RewardAdSpace = { show(adPlacementId: string, callbacks?: RewardVideoAdCallbacks, payload?: Record<string, JsonValue>): Promise<void> };
type ManagerOptions = {
  host: () => RewardVideoHost | undefined;
  logger?: (message: string) => void;
  closeId?: (values: unknown[]) => string | undefined;
  report: (placementId: string, payload: Record<string, JsonValue>, values: unknown[], closeId: string | undefined) => boolean;
};

/** Shared playback state machine; host adapters own revenue and identifier semantics. */
export class RewardVideoManager {
  private readonly options: ManagerOptions;
  private closed = false;
  private readonly rewardVideoAds: RewardVideoAdPool;
  private readonly rewardVideoCleanups = new Set<() => void>();
  private readonly rewardAdSpaces = new Map<string, RewardAdSpace>();
  private rewardVideoSequence = 0;

  constructor(options: ManagerOptions) {
    this.options = options;
    this.rewardVideoAds = new RewardVideoAdPool(options.host, options.logger);
  }

  /** Bind a native ad unit and automatically prepare it without blocking startup. */
  createAdSpace(options: RewardAdSpaceOptions): RewardAdSpace {
    if (this.closed) throw new Error("GameAlgo client is closed");
    validateRewardVideoAdUnit(options);
    const { adUnitId } = options;
    let space = this.rewardAdSpaces.get(adUnitId);
    if (!space) {
      space = Object.freeze({
        show: async (adPlacementId: string, callbacks: RewardVideoAdCallbacks = {}, payload: Record<string, JsonValue> = {}) => {
          if (!callbacks || typeof callbacks !== "object" || Array.isArray(callbacks)) throw new Error("Invalid Host rewarded ad options");
          return this.showRewardVideoAd(adPlacementId, { ...callbacks, adUnitId }, payload);
        },
      });
      this.rewardAdSpaces.set(adUnitId, space);
      this.rewardVideoAds.register(adUnitId);
    }
    return space;
  }

  /** Compatibility shortcut; new integrations use createAdSpace(...).show(). */
  async showRewardVideoAd(
    adPlacementId: string,
    options: RewardVideoAdOptions,
    payload: Record<string, JsonValue> = {},
  ): Promise<void> {
    if (this.closed) throw new Error("GameAlgo client is closed");
    if (typeof adPlacementId !== "string" || !/^gap_[a-f0-9]{32}$/.test(adPlacementId)) {
      throw new Error("Invalid GameAlgo adPlacementId");
    }
    validateRewardVideoAdUnit(options);
    if ((options.onClose !== undefined && typeof options.onClose !== "function")
      || (options.onError !== undefined && typeof options.onError !== "function")) {
      throw new Error("Invalid Host rewarded ad options");
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("Ad payload must be an object");
    const snapshot = JSON.parse(JSON.stringify(payload)) as Record<string, JsonValue>;
    delete snapshot.trackId;
    const { adUnitId, onClose: gameOnClose, onError: gameOnError } = options;
    const requestId = ++this.rewardVideoSequence;
    const log = (message: string): void => {
      try { this.options.logger?.(`[GameAlgoSDK] reward ad requestId=${requestId} ${message}`); } catch { /* Optional diagnostics. */ }
    };
    const invoke = (callback: ((...values: unknown[]) => unknown) | undefined, values: unknown[]): void => {
      try {
        void Promise.resolve(callback?.(...values)).catch(() => log("business callback failed"));
      } catch { log("business callback failed"); }
    };
    let ad: NativeRewardVideoAd | undefined;
    let playback: RewardVideoPlayback | undefined;
    let reported = false;
    let failed = false;
    let showStarted = false;
    let showPending = false;
    let pendingShowError: unknown[] | undefined;
    let listenerVersion = 0;
    const listeners: Array<{ close: RewardVideoCallback; error: RewardVideoCallback }> = [];
    let released = false;
    let cleaning = false;
    const cleanup = (prepareNext = false): void => {
      if (released) {
        if (prepareNext) this.rewardVideoAds.register(adUnitId);
        return;
      }
      released = true;
      cleaning = true;
      this.rewardVideoCleanups.delete(cleanup);
      // Keep the native instance; only this playback's listeners/context end.
      // Hosts without reliable listener removal fall back to retiring the instance.
      let reusable = typeof ad?.offClose === "function" && (!ad.onError || typeof ad.offError === "function");
      for (const listener of listeners) {
        for (const release of [() => ad?.offClose?.(listener.close), () => ad?.offError?.(listener.error)]) {
          try { release(); } catch { reusable = false; log("host cleanup failed"); }
        }
      }
      playback?.finish(reusable, prepareNext);
      cleaning = false;
    };
    const onClose: RewardVideoCallback = (...values) => {
      if (this.closed || cleaning || playback?.cleaning || !showStarted) return;
      if (reported) { log("duplicate close ignored"); return; }
      let trackId: string | undefined;
      try { trackId = this.options.closeId?.(values); } catch { log("ad track ID parsing failed"); }
      if (!playback?.acceptClose(trackId)) { log("stale close ignored"); return; }
      reported = true;
      let queued = false;
      try {
        if (trackId) snapshot.trackId = trackId;
        queued = this.options.report(adPlacementId, snapshot, values, trackId);
      }
      catch { log("ad_view enqueue failed"); }
      log(`closed queued=${queued} hasTrackId=${trackId !== undefined}`);
      cleanup(true);
      invoke(gameOnClose as RewardVideoCallback | undefined, values);
    };
    const onError: RewardVideoCallback = (...values) => {
      if (this.closed || cleaning || playback?.cleaning || reported || failed) return;
      // A host may report the same unsuccessful show via onError and rejection.
      // Delay the business error until that request either recovers or ends.
      if (showPending) {
        pendingShowError ??= values;
        return;
      }
      failed = true;
      log("native onError");
      cleanup();
      invoke(gameOnError, values);
    };
    const listen = (): void => {
      const version = ++listenerVersion;
      const listener = {
        close: (...values: unknown[]) => { if (version === listenerVersion) onClose(...values); },
        error: (...values: unknown[]) => { if (version === listenerVersion) onError(...values); },
      };
      listeners.push(listener);
      ad!.onClose(listener.close);
      if (!reported && !failed) ad!.onError?.(listener.error);
    };
    const finishShowRequest = (): void => {
      showPending = false;
      if (pendingShowError) onError(...pendingShowError);
    };

    try {
      playback = this.rewardVideoAds.begin(adUnitId);
      ad = playback.ad;
      this.rewardVideoCleanups.add(cleanup);
      if (typeof ad?.onClose !== "function" || typeof ad.show !== "function") throw new Error("Incomplete Host rewarded ad API");
      listen();
      if (!reported && !failed && !playback.ready) {
        const loaded = await playback.load();
        if (!loaded.ok && !reported && !failed) onError(...loaded.values);
      }
      if (this.closed) throw new Error("GameAlgo client is closed");
      for (let attempt = 0; attempt < 2 && !reported && !failed; attempt++) {
        playback.consume();
        showStarted = true;
        showPending = true;
        pendingShowError = undefined;
        try {
          await ad.show();
          finishShowRequest();
          break;
        } catch (error) {
          showPending = false;
          if (attempt === 1 || this.closed || reported || failed) {
            finishShowRequest();
            throw error;
          }
          log("show rejected; reloading for one retry");
          // Keep the host lock while recovering, and invalidate callbacks retained
          // by the failed attempt. Force a new load even if onLoad raced rejection.
          showStarted = false;
          listenerVersion++;
          playback.consume();
          const loaded = await playback.load();
          if (!loaded.ok) onError(...loaded.values);
          if (this.closed) throw new Error("GameAlgo client is closed");
          if (!reported && !failed) {
            listen();
            log("reload ready; retrying show");
          }
        }
      }
    } catch (error) {
      failed = true;
      cleanup();
      log("load/show rejected");
      // Preserve the native Promise failure; do not manufacture an onError event.
      throw error;
    }
  }


  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.rewardVideoAds.close();
    for (const cleanup of this.rewardVideoCleanups) cleanup();
    this.rewardAdSpaces.clear();
  }
}
