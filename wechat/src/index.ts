import { GameAlgoRestClient } from "../../rest-api/src/core-client.ts";
import { RewardVideoManager, type RewardAdSpace, type RewardAdSpaceOptions } from "../../rest-api/src/reward-video-manager.ts";
import type { ConfigResponse, FetchConfigOptions, GameAlgoRestClientOptions, GameAlgoUserIdentity, JsonValue } from "../../rest-api/src/types.ts";
import { getWechatHost, type WechatHost, type WechatNetworkStatus } from "./host.ts";
import { GameAlgoWechatStorage } from "./storage.ts";
import { GameAlgoWechatTransport } from "./transport.ts";
import { isNewWechatIdentity } from "./identity.ts";

export const GAMEALGO_WECHAT_SDK_VERSION = "1.1.3";
export const GAMEALGO_WECHAT_CAPABILITIES = Object.freeze({ config: true, parameterExperiments: true, remoteScripts: false, multiplayer: false });

export type GameAlgoWechatClientOptions = Omit<GameAlgoRestClientOptions,
  "platform" | "fetchImpl" | "scriptRuntime" | "scriptRuntimeBinaryPath" | "storage" | "sdkVersion" | "eventPersistOnEnqueue"> & {
  /** Normally omitted; lets engine bridges supply their own wx namespace. */
  wx?: WechatHost;
  requestTimeoutMs?: number;
  autoLifecycle?: boolean;
  autoSessionLifecycle?: boolean;
  /** Maximum wait for a first-install wx.login code; failure keeps the anonymous ID. */
  wechatLoginTimeoutMs?: number;
};
type RefreshOptions = FetchConfigOptions & { preloadConfigFiles?: boolean | string[] };

/** Native WeChat minigame host adapter, independent of the TapTap/browser SDK. */
export class GameAlgoWechatClient extends GameAlgoRestClient {
  private readonly host: WechatHost;
  private readonly transport: GameAlgoWechatTransport;
  private readonly deviceOverrides: Record<string, JsonValue>;
  private readonly defaultPreload: boolean | string[];
  private readonly autoSessionLifecycle: boolean;
  private readonly ads: RewardVideoManager;
  private readonly releases: Array<() => void> = [];
  private background = false;
  private closed = false;
  private endedSessionId?: string;
  private initialIdentityPending: boolean;
  private initialConfig?: Promise<ConfigResponse>;
  private initialCandidateId?: string;
  private initialLoginCodeSent = false;
  private cancelLogin?: () => void;
  private readonly wechatLoginTimeoutMs: number;

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
    // Foreground restoration keeps the current session, context and config.
    // Only retry config if startup has not yet obtained a valid snapshot.
    if (wasHidden && !this.snapshotValue().config) void this.refresh({ forceRefresh: true }).catch(() => undefined);
  };
  private readonly onNetwork = (result: WechatNetworkStatus): void => {
    if (!this.closed && result.isConnected) this.flushInBackground();
  };

  constructor(options: GameAlgoWechatClientOptions) {
    const host = getWechatHost(options.wx);
    const storage = new GameAlgoWechatStorage(host);
    const transport = new GameAlgoWechatTransport(host, options.requestTimeoutMs);
    const initialIdentityPending = isNewWechatIdentity(storage, options.baseUrl, options.gameKey, options.userId);
    const loginTimeout = options.wechatLoginTimeoutMs ?? 3000;
    if (!Number.isFinite(loginTimeout) || loginTimeout < 1 || loginTimeout > 30_000) throw new Error("Invalid wechatLoginTimeoutMs");
    super({
      ...options,
      platform: "wechat",
      sdkVersion: GAMEALGO_WECHAT_SDK_VERSION,
      storage,
      fetchImpl: transport.fetch,
      scriptRuntime: { execute() { throw new Error(`WeChat SDK ${GAMEALGO_WECHAT_SDK_VERSION} does not support remote scripts; use parameter experiments or local defaults`); } },
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
    this.initialIdentityPending = initialIdentityPending;
    this.wechatLoginTimeoutMs = loginTimeout;
    this.deviceOverrides = sanitizeDevice(options.device);
    this.defaultPreload = options.preloadConfigFiles ?? true;
    this.autoSessionLifecycle = options.autoSessionLifecycle !== false;
    this.tracker.setSessionDurationVisibility(() => !this.background);
    this.ads = new RewardVideoManager({
      host: () => typeof host.createRewardedVideoAd === "function" ? host as Required<Pick<WechatHost, "createRewardedVideoAd">> : undefined,
      logger: message => { try { if (typeof options.logger === "function") options.logger(message); } catch { /* Optional diagnostics. */ } },
      report: (id, payload) => {
        // WeChat's documented close callback does not provide per-impression revenue.
        // Zero is an explicitly marked placeholder, never settled ad income.
        delete payload.trackId;
        return this.tracker.trackAdPlacement(id, 0, "wechat", { ...payload, revenueStatus: "unavailable" });
      },
    });
    if (options.autoLifecycle !== false) {
      this.subscribe(() => host.onHide?.(this.onHide), () => host.offHide?.(this.onHide));
      this.subscribe(() => host.onShow?.(this.onShow), () => host.offShow?.(this.onShow));
      this.subscribe(() => host.onNetworkStatusChange?.(this.onNetwork), () => host.offNetworkStatusChange?.(this.onNetwork));
    }
  }

  static init(options: GameAlgoWechatClientOptions): GameAlgoWechatClient {
    return new GameAlgoWechatClient(options);
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
    if (this.initialIdentityPending) {
      // Initialization and an immediate caller refresh share one single-use code.
      return this.initialConfig ??= this.fetchInitialConfig(options);
    }
    return super.fetchConfig({ ...options, wechatLoginCode: undefined, platform: "wechat", device: sanitizeDevice(options.device) });
  }

  private async fetchInitialConfig(options: FetchConfigOptions): Promise<ConfigResponse> {
    try {
      this.initialCandidateId = (await this.userIdentity(options.userId)).userId;
      const wechatLoginCode = await this.firstLoginCode();
      if (this.closed) throw new Error("GameAlgo client is closed");
      this.initialLoginCodeSent = Boolean(wechatLoginCode);
      return await super.fetchConfig({ ...options, wechatLoginCode, platform: "wechat", device: sanitizeDevice(options.device) });
    } finally {
      // Once the first decision falls back, future config fetches never upgrade
      // that local player, even after the developer configures AppSecret.
      this.initialIdentityPending = false;
    }
  }

  private firstLoginCode(): Promise<string | undefined> {
    if (typeof this.host.login !== "function") return Promise.resolve(undefined);
    return new Promise(resolve => {
      let settled = false;
      const finish = (code?: string): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.cancelLogin = undefined;
        resolve(code);
      };
      const timer = setTimeout(() => finish(), this.wechatLoginTimeoutMs);
      this.cancelLogin = () => finish();
      try {
        this.host.login!({ timeout: this.wechatLoginTimeoutMs,
          success: result => finish(typeof result.code === "string" && result.code.trim().length <= 512 ? result.code.trim() || undefined : undefined),
          fail: () => finish(),
        });
      } catch { finish(); }
    });
  }

  protected override async resolveConfigIdentity(config: ConfigResponse, identity: GameAlgoUserIdentity): Promise<GameAlgoUserIdentity> {
    if (!this.initialIdentityPending || identity.userId !== this.initialCandidateId || !config.userIdentity) return identity;
    const resolved = config.userIdentity;
    if (!resolved || typeof resolved.userId !== "string" || !resolved.userId.trim() || resolved.userId.length > 256
      || (resolved.source !== "anonymous" && resolved.source !== "wechat_openid")
      || (resolved.source === "anonymous" && resolved.userId !== identity.userId)
      || (resolved.source === "wechat_openid" && !this.initialLoginCodeSent)) {
      throw new Error("Invalid WeChat initial identity response");
    }
    if (this.closed) throw new Error("GameAlgo client is closed");
    if (resolved.userId === identity.userId) return identity;
    if ((resolved.userCreatedAt && !Number.isFinite(Date.parse(resolved.userCreatedAt)))
      || (resolved.userCreatedLocalAt && !Number.isFinite(Date.parse(resolved.userCreatedLocalAt)))) throw new Error("Invalid WeChat identity creation time");
    const next = { userId: resolved.userId, userCreatedAt: resolved.userCreatedAt ?? identity.userCreatedAt,
      userCreatedLocalAt: resolved.userCreatedLocalAt ?? identity.userCreatedLocalAt };
    await this.tracker.resolveInitialUserId(identity.userId, next.userId, next.userCreatedAt);
    await this.persistResolvedIdentity(next);
    return next;
  }

  override async refresh(options: RefreshOptions = {}): Promise<void> {
    const config = await this.fetchConfig(options);
    if (this.closed) return;
    const preload = options.preloadConfigFiles ?? this.defaultPreload;
    if (preload === false) return;
    // Never download or execute a remote JS file in the first WeChat release.
    const jsonFiles = config.configFiles.filter(file =>
      (file.name.endsWith(".json") || file.contentType?.includes("application/json"))
      && (!Array.isArray(preload) || preload.includes(file.name)));
    const hashes = new Map(jsonFiles.map(file => [file.name, file.hash]));
    const names = [...new Set(jsonFiles.map(file => file.name))];
    if (names.length > 0) {
      await Promise.all(names.map(name => this.fetchConfigFile(name, { expectedHash: hashes.get(name), persist: false })));
      await this.persistSnapshot();
    }
  }

  protected override defaultDeviceContext(): Record<string, JsonValue> {
    const context: Record<string, JsonValue> = { ...this.deviceOverrides, runtime: "wechat", remoteScripts: false };
    try {
      const info = this.host?.getDeviceInfo?.();
      if (info) {
        const os = normalizeOs(info.platform);
        if (os) context.os = os;
        const version = typeof info.system === "string" ? info.system.trim().replace(/^(?:iOS|Android|Windows|macOS|Mac OS X|HarmonyOS)\s*/i, "") : "";
        if (version) context.osVersion = version.slice(0, 128);
        if (info.brand) context.brand = info.brand.slice(0, 128);
        if (info.model) context.model = info.model.slice(0, 256);
      }
    } catch { /* Device metadata must not block configuration. */ }
    try {
      const info = this.host?.getAppBaseInfo?.();
      if (info?.version) context.wechatVersion = info.version;
      if (info?.SDKVersion) context.wechatBaseLibraryVersion = info.SDKVersion;
      if (info?.language) context.locale = info.language;
    } catch { /* Optional host metadata. */ }
    try {
      const app = this.host?.getAccountInfoSync?.().miniProgram;
      if (typeof app?.appId === "string" && /^wx[0-9a-f]{16}$/i.test(app.appId)) context.wechatAppId = app.appId;
    } catch { /* No guessed app identity. */ }
    return context;
  }

  protected override onConfigReady(_config: ConfigResponse): void {
    if (this.background) this.endSessionSnapshot();
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.cancelLogin?.();
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
    if (this.tracker.trackSessionEndSnapshot({ reason: "wechat_hide" })) this.endedSessionId = session;
  }

  private flushInBackground(): void {
    void this.tracker.flushUrgent().catch(() => undefined);
    void this.tracker.flush().catch(() => undefined);
  }
}

export function initGameAlgoWechat(options: GameAlgoWechatClientOptions): GameAlgoWechatClient { return GameAlgoWechatClient.init(options); }

function normalizeOs(value?: string): string | undefined {
  const os = value?.trim().toLowerCase();
  if (os === "mac") return "macos";
  return ["ios", "android", "windows", "macos", "linux", "harmonyos"].includes(os ?? "") ? os : undefined;
}

function sanitizeDevice(value?: Record<string, JsonValue>): Record<string, JsonValue> {
  const result = { ...value };
  for (const key of ["runtime", "remoteScripts", "wechatAppId", "runtimeMiniappId", "runtimeAppId", "runtimeProjectId", "runtimeIdentitySource"]) delete result[key];
  return result;
}

export { GameAlgoWechatStorage } from "./storage.ts";
export { GameAlgoWechatTransport } from "./transport.ts";
export type { WechatHost } from "./host.ts";
export type { RewardAdSpace as GameAlgoWechatRewardAdSpace, RewardAdSpaceOptions as GameAlgoWechatRewardAdSpaceOptions, RewardVideoAdCallbacks as GameAlgoWechatRewardVideoAdCallbacks, RewardVideoCloseResult as GameAlgoWechatRewardVideoCloseResult } from "../../rest-api/src/reward-video-manager.ts";
export type { ConfigResponse, EventPayload, EventBatchResponse, JsonValue, TrackEventOptions, GameAlgoExecutionResult, GameAlgoUserIdentity } from "../../rest-api/src/types.ts";

/** Brand aliases use the same implementation, identity and durable queue. */
export { GameAlgoWechatClient as GamePropelWechatClient };
export { GameAlgoWechatStorage as GamePropelWechatStorage } from "./storage.ts";
export { GameAlgoWechatTransport as GamePropelWechatTransport } from "./transport.ts";
export type GamePropelWechatClientOptions = GameAlgoWechatClientOptions;
export const initGamePropelWechat = initGameAlgoWechat;
export const GAMEPROPEL_WECHAT_SDK_VERSION = GAMEALGO_WECHAT_SDK_VERSION;
export const GAMEPROPEL_WECHAT_CAPABILITIES = GAMEALGO_WECHAT_CAPABILITIES;
