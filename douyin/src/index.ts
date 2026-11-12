import { GameAlgoRestClient } from "../../rest-api/src/core-client.ts";
import type { RewardAdSpace, RewardAdSpaceOptions } from "../../rest-api/src/reward-video-manager.ts";
import { DouyinRewardAds } from "./ads.ts";
import type { ConfigResponse, FetchConfigOptions, GameAlgoRestClientOptions, JsonValue } from "../../rest-api/src/types.ts";
import { getDouyinHost, type DouyinHost, type DouyinNetworkStatus } from "./host.ts";
import { GamePropelDouyinStorage } from "./storage.ts";
import { GamePropelDouyinTransport } from "./transport.ts";

export const GAMEPROPEL_DOUYIN_SDK_VERSION = "1.0.0-rc.0";
export const GAMEPROPEL_DOUYIN_CAPABILITIES = Object.freeze({ config: true, parameterExperiments: true, remoteScripts: false, multiplayer: false, rewardedAds: true, interstitialAds: false, impressionRevenue: false });

export type GamePropelDouyinClientOptions = Omit<GameAlgoRestClientOptions,
  "platform" | "fetchImpl" | "scriptRuntime" | "scriptRuntimeBinaryPath" | "storage" | "sdkVersion" | "eventPersistOnEnqueue"> & {
  /** Normally omitted; lets engine bridges supply their own tt namespace. */
  tt?: DouyinHost;
  requestTimeoutMs?: number;
  autoLifecycle?: boolean;
  autoSessionLifecycle?: boolean;
  adTimeoutMs?: number;
};
type RefreshOptions = FetchConfigOptions & { preloadConfigFiles?: boolean | string[] };

/** Native tt minigame adapter, independent of browser/TapTap/WeChat transports. */
export class GamePropelDouyinClient extends GameAlgoRestClient {
  private readonly host: DouyinHost;
  private readonly transport: GamePropelDouyinTransport;
  private readonly deviceOverrides: Record<string, JsonValue>;
  private readonly defaultPreload: boolean | string[];
  private readonly autoSessionLifecycle: boolean;
  private readonly ads: DouyinRewardAds;
  private readonly releases: Array<() => void> = [];
  private background = false;
  private closed = false;
  private endedSessionId?: string;

  private readonly onHide = (): void => {
    if (this.closed) return;
    this.background = true;
    this.tracker.observeSessionDurationVisibility();
    this.endSessionSnapshot();
    this.flushInBackground();
  };
  private readonly onShow = (): void => {
    if (this.closed) return;
    const wasHidden = this.background;
    this.background = false;
    this.endedSessionId = undefined;
    this.tracker.observeSessionDurationVisibility();
    this.flushInBackground();
    // Session ownership changes only on initialization or explicit newSession.
    if (wasHidden) void this.refresh({ forceRefresh: true }).catch(() => undefined);
  };
  private readonly onNetwork = (result: DouyinNetworkStatus): void => {
    if (!this.closed && result.isConnected) this.flushInBackground();
  };

  constructor(options: GamePropelDouyinClientOptions) {
    const host = getDouyinHost(options.tt);
    if (options.adTimeoutMs !== undefined && (!Number.isFinite(options.adTimeoutMs) || options.adTimeoutMs <= 0)) throw new Error("Invalid adTimeoutMs");
    const storage = new GamePropelDouyinStorage(host);
    const transport = new GamePropelDouyinTransport(host, options.requestTimeoutMs);
    super({
      ...options,
      platform: "douyin",
      sdkVersion: GAMEPROPEL_DOUYIN_SDK_VERSION,
      storage,
      fetchImpl: transport.fetch,
      scriptRuntime: { execute() { throw new Error(`Douyin SDK ${GAMEPROPEL_DOUYIN_SDK_VERSION} does not support remote scripts; use parameter experiments or local defaults`); } },
      eventFlushIntervalMs: options.eventFlushIntervalMs ?? 5_000,
      eventMaxBatchSize: Math.min(options.eventMaxBatchSize ?? 20, 20),
      eventMaxBatchBytes: Math.min(options.eventMaxBatchBytes ?? 48 * 1024, 48 * 1024),
      eventQueueLimit: options.eventQueueLimit ?? 500,
      eventPersistOnEnqueue: true,
      logger: options.logger ?? false,
      device: sanitizeDevice(options.device),
    });
    this.host = host;
    this.transport = transport;
    this.deviceOverrides = sanitizeDevice(options.device);
    this.defaultPreload = options.preloadConfigFiles ?? true;
    this.autoSessionLifecycle = options.autoSessionLifecycle !== false;
    this.tracker.setSessionDurationVisibility(() => !this.background);
    this.ads = new DouyinRewardAds(host, (id, payload, values) => {
        // Official fallback sharing uses the same onClose callback as a video.
        // Preserve the reward result without asserting an actual impression.
        delete payload.trackId;
        const result = values[0] as { isEnded?: unknown; count?: unknown } | undefined;
        const close = { ...payload, revenueStatus: "unavailable", impressionVerified: false, completionSource: "video_or_share",
          ...(typeof result?.isEnded === "boolean" ? { isEnded: result.isEnded } : {}),
          ...(typeof result?.count === "number" && Number.isFinite(result.count) ? { count: result.count } : {}) };
        const queued = this.tracker.trackAdPlacement(id, 0, "douyin", close);
        void this.flush().catch(() => undefined);
        return queued;
      }, options.adTimeoutMs);
    if (options.autoLifecycle !== false) {
      this.subscribe(() => host.onHide?.(this.onHide), () => host.offHide?.(this.onHide));
      this.subscribe(() => host.onShow?.(this.onShow), () => host.offShow?.(this.onShow));
      this.subscribe(() => host.onNetworkStatusChange?.(this.onNetwork), () => host.offNetworkStatusChange?.(this.onNetwork));
    }
  }

  static init(options: GamePropelDouyinClientOptions): GamePropelDouyinClient {
    return new GamePropelDouyinClient(options);
  }

  createAdSpace(options: RewardAdSpaceOptions): RewardAdSpace { return this.ads.createAdSpace(options); }

  async flush(): Promise<void> {
    await this.tracker.flushUrgent();
    await this.tracker.flush();
  }

  /** Pure memory read; explicit session rotation does not reset this lifetime clock. */
  getForegroundTimeMs(): number { return this.tracker.getForegroundTimeMs(); }

  override fetchConfig(options: FetchConfigOptions = {}): Promise<ConfigResponse> {
    if (this.closed) return Promise.reject(new Error("GameAlgo client is closed"));
    return super.fetchConfig({ ...options, platform: "douyin", sdkVersion: GAMEPROPEL_DOUYIN_SDK_VERSION, device: sanitizeDevice(options.device) });
  }

  override async refresh(options: RefreshOptions = {}): Promise<void> {
    const config = await this.fetchConfig(options);
    if (this.closed) return;
    const preload = options.preloadConfigFiles ?? this.defaultPreload;
    if (preload === false) return;
    // Never download or execute a remote JS file in the first Douyin release.
    const files = config.configFiles.filter(file =>
      (file.name.endsWith(".json") || file.contentType?.includes("application/json"))
      && (!Array.isArray(preload) || preload.includes(file.name))).map(file => file.name);
    await Promise.all([...new Set(files)].map(name => this.fetchConfigFile(name)));
  }

  protected override defaultDeviceContext(): Record<string, JsonValue> {
    const context: Record<string, JsonValue> = { ...this.deviceOverrides, runtime: "douyin", remoteScripts: false };
    try {
      const info = this.host?.getSystemInfoSync?.();
      if (info) {
        const os = normalizeOs(info.platform);
        if (os) context.os = os;
        const version = typeof info.system === "string" ? info.system.trim().replace(/^(?:iOS|Android|HarmonyOS|OpenHarmony|Windows|macOS)\s*/i, "") : "";
        if (version) context.osVersion = version.slice(0, 128);
        for (const [key, value] of Object.entries({ brand: info.brand, model: info.model,
          douyinHostName: info.appName, douyinHostVersion: info.version, douyinBaseLibraryVersion: info.SDKVersion })) {
          if (typeof value === "string" && value.trim()) context[key] = value.trim().slice(0, 128);
        }
      }
    } catch { /* Optional system metadata. */ }
    try {
      const app = this.host?.getEnvInfoSync?.().microapp;
      // microapp.appId identifies this game; never use the host App or a guessed URL.
      if (typeof app?.appId === "string" && app.appId.trim()) context.douyinAppId = app.appId.trim().slice(0, 128);
      if (typeof app?.envType === "string") context.douyinEnvironment = app.envType;
      if (typeof app?.mpVersion === "string") context.douyinGameVersion = app.mpVersion;
    } catch { /* Old base libraries may not provide environment metadata. */ }
    return context;
  }

  protected override onConfigReady(_config: ConfigResponse): void {
    if (this.background) this.endSessionSnapshot();
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.ads.close();
    for (const release of this.releases.splice(0)) { try { release(); } catch { /* Closed guards suppress retained host callbacks. */ } }
    this.tracker.close();
    this.transport.close();
  }

  private subscribe(attach: () => void, release: () => void): void {
    try { attach(); this.releases.push(release); } catch { /* A missing optional host signal is not fatal. */ }
  }

  private endSessionSnapshot(): void {
    if (!this.autoSessionLifecycle || this.closed) return;
    const session = this.tracker.currentSessionId();
    if (this.endedSessionId === session) return;
    if (this.tracker.trackSessionEndSnapshot({ reason: "douyin_hide" })) this.endedSessionId = session;
  }

  private flushInBackground(): void {
    void this.tracker.flushUrgent().catch(() => undefined);
    void this.tracker.flush().catch(() => undefined);
  }
}

export function initGamePropelDouyin(options: GamePropelDouyinClientOptions): GamePropelDouyinClient { return GamePropelDouyinClient.init(options); }

function normalizeOs(value?: string): string | undefined {
  const os = value?.trim().toLowerCase();
  if (os === "mac") return "macos";
  if (os === "openharmony") return "harmonyos";
  return ["ios", "android", "windows", "macos", "linux", "harmonyos"].includes(os ?? "") ? os : undefined;
}

function sanitizeDevice(value?: Record<string, JsonValue>): Record<string, JsonValue> {
  const result = { ...value };
  for (const key of ["runtime", "remoteScripts", "douyinAppId", "douyinEnvironment", "douyinGameVersion", "runtimeMiniappId", "runtimeAppId", "runtimeProjectId", "runtimeIdentitySource"]) delete result[key];
  return result;
}

export { GamePropelDouyinStorage } from "./storage.ts";
export { GamePropelDouyinTransport } from "./transport.ts";
export type { DouyinHost } from "./host.ts";
export type { RewardAdSpace as GamePropelDouyinRewardAdSpace, RewardAdSpaceOptions as GamePropelDouyinRewardAdSpaceOptions, RewardVideoAdCallbacks as GamePropelDouyinRewardVideoAdCallbacks, RewardVideoCloseResult as GamePropelDouyinRewardVideoCloseResult } from "../../rest-api/src/reward-video-manager.ts";
export type { ConfigResponse, EventPayload, EventBatchResponse, JsonValue, TrackEventOptions, GameAlgoExecutionResult, GameAlgoUserIdentity } from "../../rest-api/src/types.ts";

