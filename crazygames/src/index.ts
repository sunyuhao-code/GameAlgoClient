import { GameAlgoRestClient } from "../../rest-api/src/core-client.ts";
import type { ConfigResponse, FetchConfigOptions, GameAlgoRestClientOptions, JsonValue } from "../../rest-api/src/types.ts";
import { CrazyGamesAds, type GamePropelCrazyGamesAdSpace } from "./ads.ts";
import { getCrazyGamesHost, type CrazyGamesHost, type CrazyGamesAdType } from "./host.ts";
import { GamePropelCrazyGamesStorage, type GamePropelCrazyGamesStorageOptions } from "./storage.ts";
import { CrazyGamesTransport } from "./transport.ts";

export const GAMEPROPEL_CRAZYGAMES_SDK_VERSION = "1.0.0";
export const GAMEPROPEL_CRAZYGAMES_CAPABILITIES = Object.freeze({
  config: true, parameterExperiments: true, remoteScripts: false, multiplayer: false,
  rewardedAds: true, midgameAds: true, impressionRevenue: false,
});

export type GamePropelCrazyGamesClientOptions = Omit<GameAlgoRestClientOptions,
  "platform" | "sdkVersion" | "fetchImpl" | "scriptRuntime" | "scriptRuntimeBinaryPath" | "eventPersistOnEnqueue"> & {
  crazyGames?: CrazyGamesHost;
  fetchImpl?: typeof fetch;
  browserStorage?: GamePropelCrazyGamesStorageOptions;
  hostInitTimeoutMs?: number;
  requestTimeoutMs?: number;
  adTimeoutMs?: number;
  autoLifecycle?: boolean;
  autoSessionLifecycle?: boolean;
};
type RefreshOptions = FetchConfigOptions & { preloadConfigFiles?: boolean | string[] };

/** Independent HTML5 v3 adapter. Initialization awaits the official portal SDK. */
export class GamePropelCrazyGamesClient extends GameAlgoRestClient {
  private readonly host: CrazyGamesHost;
  private readonly transport: CrazyGamesTransport;
  private readonly ads: CrazyGamesAds;
  private readonly win = typeof window === "undefined" ? undefined : window;
  private readonly doc = typeof document === "undefined" ? undefined : document;
  private readonly releases: Array<() => void> = [];
  private readonly autoSessionLifecycle: boolean;
  private readonly preload: boolean | string[];
  private readonly deviceOverrides: Record<string, JsonValue>;
  private closed = false;
  private endedSessionId?: string;
  private readonly onVisibility = () => {
    if (this.doc?.visibilityState === "hidden") this.endSession("visibility_hidden");
    else if (this.doc?.visibilityState === "visible") this.resume();
  };
  private readonly onPageHide = () => this.endSession("pagehide");
  private readonly onPageShow = () => { if (this.doc?.visibilityState !== "hidden") this.resume(); };
  private readonly onOnline = () => this.flushInBackground();

  static async init(options: GamePropelCrazyGamesClientOptions): Promise<GamePropelCrazyGamesClient> {
    const host = getCrazyGamesHost(options.crazyGames);
    if (options.adTimeoutMs !== undefined && (!Number.isFinite(options.adTimeoutMs) || options.adTimeoutMs <= 0)) throw new Error("adTimeoutMs must be positive");
    const timeoutMs = options.hostInitTimeoutMs ?? 10_000;
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("hostInitTimeoutMs must be positive");
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([host.init(), new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("CrazyGames initialization timed out")), timeoutMs);
      })]);
    } finally { if (timer) clearTimeout(timer); }
    if (host.environment !== "crazygames" && host.environment !== "local") throw new Error("CrazyGames SDK is disabled on this domain");
    return new GamePropelCrazyGamesClient(options, host);
  }

  private constructor(options: GamePropelCrazyGamesClientOptions, host: CrazyGamesHost) {
    const fetchImpl = options.fetchImpl ?? globalThis.fetch?.bind(globalThis);
    if (!fetchImpl) throw new Error("Browser fetch is required");
    const transport = new CrazyGamesTransport(fetchImpl, options.requestTimeoutMs);
    super({ ...options, platform: "crazygames", sdkVersion: GAMEPROPEL_CRAZYGAMES_SDK_VERSION,
      storage: options.storage ?? new GamePropelCrazyGamesStorage(options.browserStorage), fetchImpl: transport.fetch,
      scriptRuntime: { execute() { throw new Error("CrazyGames SDK 1.x supports parameter experiments; remote scripts are unavailable"); } },
      isDebug: host.environment === "local" ? true : options.isDebug,
      eventFlushIntervalMs: options.eventFlushIntervalMs ?? 5_000,
      eventMaxBatchSize: Math.min(options.eventMaxBatchSize ?? 20, 20),
      eventMaxBatchBytes: Math.min(options.eventMaxBatchBytes ?? 48 * 1024, 48 * 1024),
      eventQueueLimit: options.eventQueueLimit ?? 500, eventPersistOnEnqueue: true,
      logger: options.logger ?? false, device: sanitizeDevice(options.device),
    });
    this.host = host;
    this.deviceOverrides = sanitizeDevice(options.device);
    this.transport = transport;
    this.autoSessionLifecycle = options.autoSessionLifecycle !== false;
    this.preload = options.preloadConfigFiles ?? true;
    this.tracker.setSessionDurationVisibility(() => this.doc?.visibilityState !== "hidden");
    this.ads = new CrazyGamesAds(host, (id, payload) => { this.tracker.trackAdPlacement(id, 0, "crazygames", payload); },
      typeof options.logger === "function" ? options.logger : undefined, options.adTimeoutMs);
    if (options.autoLifecycle !== false) {
      this.listen(this.doc, "visibilitychange", this.onVisibility);
      this.listen(this.win, "pagehide", this.onPageHide);
      this.listen(this.win, "pageshow", this.onPageShow);
      this.listen(this.win, "online", this.onOnline);
    }
  }

  createAdSpace(options: { adType: CrazyGamesAdType }): GamePropelCrazyGamesAdSpace { return this.ads.createAdSpace(options); }
  getForegroundTimeMs(): number { return this.tracker.getForegroundTimeMs(); }
  async flush(): Promise<void> { await this.tracker.flushUrgent(); await this.tracker.flush(); }

  override fetchConfig(options: FetchConfigOptions = {}): Promise<ConfigResponse> {
    if (this.closed) return Promise.reject(new Error("GamePropel client is closed"));
    return super.fetchConfig({ ...options, platform: "crazygames", sdkVersion: GAMEPROPEL_CRAZYGAMES_SDK_VERSION,
      isDebug: this.host.environment === "local" ? true : options.isDebug, device: sanitizeDevice(options.device) });
  }

  override async refresh(options: RefreshOptions = {}): Promise<void> {
    const config = await this.fetchConfig(options);
    if (this.closed) return;
    const preload = options.preloadConfigFiles ?? this.preload;
    if (preload === false) return;
    const jsonFiles = config.configFiles.filter(file => file.name.endsWith(".json") || file.contentType?.includes("application/json"));
    const names = jsonFiles.filter(file => !Array.isArray(preload) || preload.includes(file.name)).map(file => file.name);
    await Promise.all([...new Set(names)].map(name => this.fetchConfigFile(name)));
  }

  protected override defaultDeviceContext(): Record<string, JsonValue> {
    const context: Record<string, JsonValue> = { ...this.deviceOverrides, runtime: "crazygames", remoteScripts: false, crazyGamesEnvironment: this.host.environment };
    try {
      const info = this.host.user?.systemInfo;
      const fields = { locale: info?.locale, countryCode: info?.countryCode, deviceType: info?.device?.type,
        osVersion: info?.os?.version, browser: info?.browser?.name, browserVersion: info?.browser?.version,
        applicationType: info?.applicationType };
      for (const [key, value] of Object.entries(fields)) if (typeof value === "string" && value.trim()) context[key] = value.trim().slice(0, 128);
      const name = info?.os?.name?.toLowerCase();
      const os = name && ({ ios: "ios", android: "android", windows: "windows", "mac os": "macos", macos: "macos", linux: "linux", "chromium os": "chromeos", "chrome os": "chromeos" } as Record<string, string>)[name];
      if (os) context.os = os;
    } catch { /* Optional metadata never blocks collection. */ }
    return context;
  }

  protected override onConfigReady(): void { if (this.doc?.visibilityState === "hidden") this.endSession("visibility_hidden"); }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const release of this.releases.splice(0)) release();
    this.ads.close(); this.tracker.close(); this.transport.close();
  }

  private listen(target: EventTarget | undefined, event: string, listener: () => void): void {
    target?.addEventListener(event, listener);
    this.releases.push(() => target?.removeEventListener(event, listener));
  }
  private endSession(reason: string): void {
    if (this.closed) return;
    this.tracker.observeSessionDurationVisibility();
    const session = this.tracker.currentSessionId();
    if (this.autoSessionLifecycle && this.endedSessionId !== session && this.tracker.trackSessionEndSnapshot({ reason })) this.endedSessionId = session;
    this.flushInBackground();
  }
  private resume(): void {
    if (this.closed) return;
    this.tracker.observeSessionDurationVisibility();
    const hadEnd = this.endedSessionId !== undefined;
    this.endedSessionId = undefined;
    this.flushInBackground();
    if (hadEnd) void this.refresh({ forceRefresh: true }).catch(() => undefined);
  }
  private flushInBackground(): void {
    if (this.closed) return;
    void this.tracker.flushUrgent().catch(() => undefined);
    void this.tracker.flush().catch(() => undefined);
  }
}

function sanitizeDevice(value?: Record<string, JsonValue>): Record<string, JsonValue> {
  const device = { ...value };
  for (const key of ["runtime", "remoteScripts", "runtimeMiniappId", "runtimeProjectId", "runtimeAppId", "runtimeIdentitySource", "wechatAppId", "crazyGamesEnvironment",
    "os", "osVersion", "locale", "countryCode", "deviceType", "browser", "browserVersion", "applicationType"]) delete device[key];
  return device;
}
export function initGamePropelCrazyGames(options: GamePropelCrazyGamesClientOptions): Promise<GamePropelCrazyGamesClient> { return GamePropelCrazyGamesClient.init(options); }
export { GamePropelCrazyGamesStorage } from "./storage.ts";
export type { GamePropelCrazyGamesStorageOptions } from "./storage.ts";
export type { GamePropelCrazyGamesAdSpace, GamePropelCrazyGamesAdCallbacks } from "./ads.ts";
export type { CrazyGamesHost, CrazyGamesAdType, CrazyGamesAdError } from "./host.ts";
export type { ConfigResponse, EventPayload, EventBatchResponse, JsonValue, TrackEventOptions, GameAlgoStorage } from "../../rest-api/src/types.ts";
