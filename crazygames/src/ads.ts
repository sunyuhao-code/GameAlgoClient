import type { JsonValue } from "../../rest-api/src/types.ts";
import type { CrazyGamesHost, CrazyGamesAdType, CrazyGamesAdError } from "./host.ts";

export type GamePropelCrazyGamesAdCallbacks = {
  onStarted?: () => void | Promise<void>;
  /** For rewarded ads, grant the reward here, after the native adFinished. */
  onFinished?: () => void | Promise<void>;
  onError?: (error: CrazyGamesAdError) => void | Promise<void>;
};
export type GamePropelCrazyGamesAdSpace = {
  show(adPlacementId: string, callbacks?: GamePropelCrazyGamesAdCallbacks, payload?: Record<string, JsonValue>): Promise<void>;
};
const activeSlots = new WeakSet<CrazyGamesHost["ad"]>();

/** CrazyGames exposes one video slot shared by rewarded and midgame ads. */
export class CrazyGamesAds {
  private closed = false;
  private cancel?: () => void;
  private readonly host: CrazyGamesHost;
  private readonly report: (id: string, payload: Record<string, JsonValue>) => void;
  private readonly logger?: (message: string) => void;
  private readonly timeoutMs: number;
  constructor(host: CrazyGamesHost,
    report: (id: string, payload: Record<string, JsonValue>) => void,
    logger?: (message: string) => void,
    timeoutMs = 180_000) {
    this.host = host; this.report = report; this.logger = logger; this.timeoutMs = timeoutMs;
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("adTimeoutMs must be positive");
  }

  createAdSpace({ adType }: { adType: CrazyGamesAdType }): GamePropelCrazyGamesAdSpace {
    if (this.closed) throw new Error("GamePropel client is closed");
    if (adType !== "rewarded" && adType !== "midgame") throw new Error("Invalid CrazyGames ad type");
    return Object.freeze({ show: (id: string, callbacks: GamePropelCrazyGamesAdCallbacks = {}, payload: Record<string, JsonValue> = {}) =>
      this.show(adType, id, callbacks, payload) });
  }

  private async show(adType: CrazyGamesAdType, id: string, callbacks: GamePropelCrazyGamesAdCallbacks, payload: Record<string, JsonValue>): Promise<void> {
    if (this.closed) throw new Error("GamePropel client is closed");
    if (!/^gap_[a-f0-9]{32}$/.test(id)) throw new Error("Invalid GamePropel adPlacementId");
    if (!callbacks || typeof callbacks !== "object" || Array.isArray(callbacks) || [callbacks.onStarted, callbacks.onFinished, callbacks.onError].some(value => value !== undefined && typeof value !== "function")) {
      throw new Error("Invalid CrazyGames ad callbacks");
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("Ad payload must be an object");
    const nativeAd = this.host.ad;
    if (activeSlots.has(nativeAd)) throw new Error("A CrazyGames video ad is already pending");
    const snapshot = JSON.parse(JSON.stringify(payload)) as Record<string, JsonValue>;
    delete snapshot.trackId;
    snapshot.hostAdType = adType;
    snapshot.revenueStatus = "unavailable";
    snapshot.hostEnvironment = this.host.environment;
    activeSlots.add(nativeAd);
    return new Promise<void>((resolve, reject) => {
      let settled = false, started = false;
      const log = () => { try { this.logger?.("[GamePropelSDK] ad callback failed"); } catch { /* Optional diagnostics. */ } };
      const invoke = (callback: (() => unknown) | undefined) => {
        try { void Promise.resolve(callback?.()).catch(log); } catch { log(); }
      };
      const cleanup = () => { settled = true; clearTimeout(timer); activeSlots.delete(nativeAd); this.cancel = undefined; };
      const fail = (error: CrazyGamesAdError) => {
        if (settled) return;
        cleanup();
        invoke(callbacks.onError ? () => callbacks.onError!(error) : undefined);
        reject(Object.assign(new Error(error.message), { code: error.code }));
      };
      const timer = setTimeout(() => fail({ code: "timeout", message: "CrazyGames ad callbacks timed out" }), this.timeoutMs);
      timer.unref?.();
      this.cancel = () => { if (!settled) { cleanup(); reject(new Error("GamePropel client is closed")); } };
      try {
        const result = nativeAd.requestAd(adType, {
          adStarted: () => {
            if (settled || started) return;
            started = true;
            try { this.report(id, snapshot); } catch { log(); }
            invoke(callbacks.onStarted);
          },
          adFinished: () => {
            if (settled) return;
            cleanup();
            invoke(callbacks.onFinished);
            resolve();
          },
          adError: error => fail(normalizeError(error)),
        });
        void Promise.resolve(result).catch(error => fail(normalizeError(error)));
      } catch (error) { fail(normalizeError(error)); }
    });
  }

  close(): void { this.closed = true; this.cancel?.(); }
}

function normalizeError(error: unknown): CrazyGamesAdError {
  const value = error as { code?: unknown; message?: unknown } | undefined;
  return { code: typeof value?.code === "string" ? value.code : "other",
    message: typeof value?.message === "string" ? value.message : "CrazyGames ad failed" };
}
