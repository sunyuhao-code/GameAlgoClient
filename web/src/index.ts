import { GameAlgoRestClient } from "../../rest-api/src/client.ts";
import type {
  ConfigResponse,
  FetchConfigOptions,
  GameAlgoRestClientOptions,
  GameAlgoStorage,
  JsonValue,
  UserAttributionResponse,
} from "../../rest-api/src/types.ts";
import { GameAlgoBrowserStorage, type GameAlgoBrowserStorageOptions } from "./browser-storage.ts";
import { GameAlgoWebScriptRuntime } from "./script-runtime.ts";
import { GameAlgoMatchmakingClient } from "./multiplayer.ts";

export const GAMEALGO_WEB_SDK_VERSION = "2.0.2";
const WEB_KEEPALIVE_BODY_LIMIT_BYTES = 60 * 1024;
const WEB_EVENT_BATCH_BODY_BUDGET_BYTES = 48 * 1024;
const TAPDB_CONTEXT_LINK_EVENT = "gamealgo_context_link";
const RUNTIME_IDENTITY_FIELDS = ["runtimeMiniappId", "runtimeProjectId", "runtimeAppId", "runtimeIdentitySource"] as const;
type TapDbEventOptions = {
  name: string;
  properties: Record<string, string | boolean>;
  success: (result: unknown) => void;
  fail: (result: unknown) => void;
  complete: (result: unknown) => void;
};
type TapLifecycle = {
  onHide?: (callback: () => void) => void;
  onShow?: (callback: () => void) => void;
  offHide?: (callback: () => void) => void;
  offShow?: (callback: () => void) => void;
};
const DEFAULT_WEB_ATTRIBUTION_PARAMETERS = [
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "gclid",
  "gbraid",
  "wbraid",
  "fbclid",
  "ttclid",
  "msclkid",
] as const;

export type GameAlgoWebUrlAttributionOptions = {
  url?: string | URL;
  provider?: string;
  status?: string;
  parameterNames?: readonly string[];
  referrer?: string;
};

export type GameAlgoWebClientOptions = Omit<
  GameAlgoRestClientOptions,
  "platform" | "scriptRuntime" | "scriptRuntimeBinaryPath" | "storage" | "sdkVersion"
> & {
  sdkVersion?: string;
  storage?: GameAlgoStorage;
  browserStorage?: GameAlgoBrowserStorageOptions;
  autoLifecycle?: boolean;
  autoSessionLifecycle?: boolean;
  autoUrlAttribution?: boolean | GameAlgoWebUrlAttributionOptions;
  scriptPrepareTimeoutMs?: number;
  scriptExecutionTimeoutMs?: number;
  multiplayerControllerUrl?: string;
};

/** Browser-native GameAlgo client. The telemetry platform is always `web`. */
export class GameAlgoWebClient extends GameAlgoRestClient {
  private readonly lifecycleTarget?: Pick<Window, "addEventListener" | "removeEventListener">;
  private readonly documentTarget?: Pick<Document, "addEventListener" | "removeEventListener" | "visibilityState">;
  private readonly webScriptRuntime: GameAlgoWebScriptRuntime;
  private readonly deviceOverrides: Record<string, JsonValue>;
  private readonly onVisibilityChange: () => void;
  private readonly onPageHide: () => void;
  private readonly onPageShow: () => void;
  private readonly onTapHide: () => void;
  private readonly onLoad: () => void;
  private readonly onOnline: () => void;
  private readonly autoSessionLifecycle: boolean;
  private endedSessionId?: string;
  private tapLifecycle?: TapLifecycle;
  private tapHideAttached = false;
  private tapShowAttached = false;
  private tapDiscoveryTimer?: ReturnType<typeof setInterval>;
  private closed = false;
  private tapDbContextLinkAttempted = false;
  private tapDbContextLinkProperties?: TapDbEventOptions["properties"];
  private tapDbContextLinkTimer?: ReturnType<typeof setInterval>;
  private readonly tapDbLogger?: (message: string) => void;
  readonly matchmaking: GameAlgoMatchmakingClient;

  constructor(options: GameAlgoWebClientOptions) {
    const storage = options.storage ?? new GameAlgoBrowserStorage(options.browserStorage);
    const browserFetch = options.fetchImpl ?? globalThis.fetch?.bind(globalThis);
    if (!browserFetch) throw new Error("fetch is required");
    const fetchImpl: typeof fetch = (input, init = {}) => {
      const url = typeof input === "string" || input instanceof URL ? String(input) : input.url;
      const isEventBatch = /\/v1\/events\/batch(?:\?|$)/.test(url);
      const keepalive = isEventBatch && requestBodyBytes(init.body) <= WEB_KEEPALIVE_BODY_LIMIT_BYTES;
      return browserFetch(input, isEventBatch ? { ...init, keepalive } : init);
    };
    const scriptRuntime = new GameAlgoWebScriptRuntime({
      prepareTimeoutMs: options.scriptPrepareTimeoutMs,
      executionTimeoutMs: options.scriptExecutionTimeoutMs,
    });

    super({
      ...options,
      platform: "web",
      sdkVersion: options.sdkVersion ?? GAMEALGO_WEB_SDK_VERSION,
      storage,
      fetchImpl,
      scriptRuntime,
      eventFlushIntervalMs: options.eventFlushIntervalMs ?? 5_000,
      eventMaxBatchSize: Math.min(options.eventMaxBatchSize ?? 20, 20),
      eventMaxBatchBytes: Math.min(
        options.eventMaxBatchBytes ?? WEB_EVENT_BATCH_BODY_BUDGET_BYTES,
        WEB_EVENT_BATCH_BODY_BUDGET_BYTES,
      ),
      eventPersistOnEnqueue: options.eventPersistOnEnqueue ?? true,
      logger: options.logger ?? false,
      device: withoutRuntimeIdentity(options.device),
    });

    this.webScriptRuntime = scriptRuntime;
    this.tapDbLogger = typeof options.logger === "function" ? options.logger : undefined;
    this.deviceOverrides = withoutRuntimeIdentity(options.device);
    this.matchmaking = new GameAlgoMatchmakingClient({
      apiBaseUrl: options.baseUrl,
      gameKey: options.gameKey,
      controllerUrl: options.multiplayerControllerUrl,
      fetchImpl,
      identity: async (userId, sessionId) => ({
        userId: (await this.userIdentity(userId)).userId,
        sessionId: sessionId?.trim() || this.tracker.currentSessionId(),
      }),
    });
    this.lifecycleTarget = typeof window === "undefined" ? undefined : window;
    this.documentTarget = typeof document === "undefined" ? undefined : document;
    this.tracker.setSessionDurationVisibility(() => this.documentTarget?.visibilityState !== "hidden");
    this.autoSessionLifecycle = options.autoSessionLifecycle !== false;
    this.onVisibilityChange = () => {
      this.attachTapLifecycle();
      if (this.documentTarget?.visibilityState === "hidden") {
        this.endSessionAndFlush("visibility_hidden");
      } else if (this.documentTarget?.visibilityState === "visible") {
        this.resumeSession();
      }
    };
    this.onPageHide = () => this.endSessionAndFlush("pagehide");
    this.onPageShow = () => {
      this.attachTapLifecycle();
      if (!this.documentTarget || this.documentTarget.visibilityState === "visible") this.resumeSession();
    };
    this.onTapHide = () => this.endSessionAndFlush("taptap_hide");
    this.onLoad = () => { this.attachTapLifecycle(); };
    this.onOnline = () => this.flushInBackground();
    if (options.autoLifecycle !== false) this.attachLifecycle();
    if (options.autoUrlAttribution) {
      const attributionOptions = options.autoUrlAttribution === true ? {} : options.autoUrlAttribution;
      void this.waitForReady().then((ready) => {
        if (ready) return this.syncUrlAttribution(attributionOptions);
        return undefined;
      }).catch(() => undefined);
    }
  }

  static init(options: GameAlgoWebClientOptions): GameAlgoWebClient {
    return new GameAlgoWebClient(options);
  }

  override fetchConfig(options: FetchConfigOptions = {}): Promise<ConfigResponse> {
    return super.fetchConfig({ ...options, device: withoutRuntimeIdentity(options.device) });
  }

  protected override defaultDeviceContext(): Record<string, JsonValue> {
    const context = super.defaultDeviceContext();
    // Node/browser shims do not identify the OS of an H5 host.
    delete context.os;
    return {
      ...context,
      runtime: "h5",
      ...browserDeviceContext(),
      ...this.deviceOverrides,
      ...tapRuntimeIdentity(),
    };
  }

  protected override onConfigReady(config: ConfigResponse, identity: { userId: string; sessionId: string; isDebug: boolean }): void {
    if (this.closed || this.tapDbContextLinkAttempted || identity.sessionId !== this.tracker.currentSessionId()
      || typeof config.contextId !== "string" || !config.contextId.trim() || !identity.userId.trim()) return;
    this.tapDbContextLinkProperties ??= {
      gamealgo_context_id: config.contextId,
      gamealgo_device_id: identity.userId,
      gamealgo_is_debug: identity.isDebug,
    };
    this.reportTapDbContextLink();
    if (!this.closed && !this.tapDbContextLinkAttempted && !this.tapDbContextLinkTimer) {
      let checks = 0;
      this.tapDbContextLinkTimer = setInterval(() => {
        this.reportTapDbContextLink();
        if (this.closed || this.tapDbContextLinkAttempted || ++checks >= 20) this.stopTapDbContextLinkDiscovery();
      }, 500);
      this.tapDbContextLinkTimer.unref?.();
    }
  }

  private stopTapDbContextLinkDiscovery(): void {
    if (this.tapDbContextLinkTimer) clearInterval(this.tapDbContextLinkTimer);
    this.tapDbContextLinkTimer = undefined;
  }

  private reportTapDbContextLink(): void {
    const properties = this.tapDbContextLinkProperties;
    if (this.closed || this.tapDbContextLinkAttempted || !properties) return;
    let tap: { logEvent?: (options: TapDbEventOptions) => unknown } | undefined;
    let logEvent: ((options: TapDbEventOptions) => unknown) | undefined;
    try {
      tap = (globalThis as { tap?: typeof tap }).tap;
      logEvent = tap?.logEvent;
    } catch { return; /* The bridge may not be ready yet. */ }
    if (typeof logEvent !== "function") return;
    // One best-effort host call per client initialization, including rejected calls.
    // Set the guard before entering the bridge: callbacks may run synchronously.
    this.tapDbContextLinkAttempted = true;
    this.tapDbContextLinkProperties = undefined;
    this.stopTapDbContextLinkDiscovery();
    let settled = false;
    const finish = (accepted: boolean) => {
      if (settled || this.closed) return;
      settled = true;
      if (!accepted) {
        try { this.tapDbLogger?.("[GameAlgoSDK] TapDB context link failed"); } catch { /* Logging must not break initialization. */ }
      }
    };
    const onResult = (result: unknown) => {
      try { finish(!!result && typeof result === "object" && "errno" in result && result.errno === 0); }
      catch { finish(false); }
    };
    try {
      // H5 uses one options object. Maker's LogEvent(name, properties) signature
      // is not supported here and can silently drop the event in the H5 bridge.
      const result = logEvent.call(tap, {
        name: TAPDB_CONTEXT_LINK_EVENT,
        properties,
        success: onResult,
        fail: () => finish(false),
        complete: onResult,
      });
      // The tested native bridge returns undefined; only its callbacks confirm
      // acceptance. Tolerate promise-based hosts without waiting for delivery.
      void Promise.resolve(result).then((value) => {
        if (value === false) finish(false);
      }, () => finish(false));
    } catch {
      finish(false);
    }
  }

  async flush(): Promise<void> {
    await this.tracker.flushUrgent();
    await this.tracker.flush();
  }

  /** @deprecated Hides now report a session-end snapshot during ads as well.
   * Retained for compatibility with games that already report their ad state. */
  setAdShowing(_showing: boolean): void {}

  /** Capture allow-listed campaign parameters without sending the full URL. */
  async syncUrlAttribution(options: GameAlgoWebUrlAttributionOptions = {}): Promise<UserAttributionResponse> {
    const attribution = webUrlAttribution(options);
    return await this.setAttribution({
      provider: cleanText(options.provider) ?? "web",
      status: cleanText(options.status) ?? (Object.keys(attribution).length > 0 ? "attributed" : "organic"),
      attribution,
      attributedAt: new Date().toISOString(),
    });
  }

  close(): void {
    this.closed = true;
    this.stopTapDbContextLinkDiscovery();
    this.tapDbContextLinkProperties = undefined;
    this.documentTarget?.removeEventListener("visibilitychange", this.onVisibilityChange);
    this.lifecycleTarget?.removeEventListener("pagehide", this.onPageHide);
    this.lifecycleTarget?.removeEventListener("pageshow", this.onPageShow);
    this.lifecycleTarget?.removeEventListener("online", this.onOnline);
    this.lifecycleTarget?.removeEventListener("load", this.onLoad);
    if (this.tapDiscoveryTimer) clearInterval(this.tapDiscoveryTimer);
    // Some hosts provide onHide/onShow without the matching off methods.
    // Closed guards also make retained callbacks inert in those hosts.
    try { if (this.tapHideAttached) this.tapLifecycle?.offHide?.(this.onTapHide); } catch { /* Host API is optional. */ }
    try { if (this.tapShowAttached) this.tapLifecycle?.offShow?.(this.onPageShow); } catch { /* Host API is optional. */ }
    this.webScriptRuntime.close();
    this.tracker.close();
  }

  private attachLifecycle(): void {
    this.documentTarget?.addEventListener("visibilitychange", this.onVisibilityChange);
    this.lifecycleTarget?.addEventListener("pagehide", this.onPageHide);
    this.lifecycleTarget?.addEventListener("pageshow", this.onPageShow);
    this.lifecycleTarget?.addEventListener("online", this.onOnline);
    this.lifecycleTarget?.addEventListener("load", this.onLoad);
    if (!this.attachTapLifecycle() && this.lifecycleTarget) {
      // Tap can be injected after the game's script. Discovery is bounded and
      // page/load events also retry attachment after this initial window.
      let attempts = 0;
      this.tapDiscoveryTimer = setInterval(() => {
        if (this.attachTapLifecycle() || ++attempts >= 20) {
          clearInterval(this.tapDiscoveryTimer);
          this.tapDiscoveryTimer = undefined;
        }
      }, 500);
      this.tapDiscoveryTimer.unref?.();
    }
  }

  private attachTapLifecycle(): boolean {
    if (this.closed) return false;
    const tap = this.tapLifecycle ?? (globalThis as { tap?: TapLifecycle }).tap;
    if (!tap) return false;
    if (!this.tapHideAttached && typeof tap.onHide === "function") {
      this.tapLifecycle = tap;
      this.tapHideAttached = true;
      try {
        tap.onHide(this.onTapHide);
      } catch { this.tapHideAttached = false; /* DOM listeners remain available. */ }
    }
    if (!this.tapShowAttached && typeof tap.onShow === "function") {
      this.tapLifecycle = tap;
      this.tapShowAttached = true;
      try {
        tap.onShow(this.onPageShow);
      } catch { this.tapShowAttached = false; /* DOM listeners remain available. */ }
    }
    return this.tapHideAttached && this.tapShowAttached;
  }

  private flushInBackground(): void {
    if (this.closed) return;
    void this.tracker.flushUrgent().catch(() => undefined);
    void this.tracker.flush().catch(() => undefined);
  }

  private endSessionAndFlush(reason: string): void {
    if (this.closed) return;
    this.tracker.observeSessionDurationVisibility();
    const session = this.tracker.currentSessionId();
    if (this.autoSessionLifecycle && this.endedSessionId !== session) {
      if (this.tracker.trackSessionEndSnapshot({ reason })) this.endedSessionId = session;
    }
    this.flushInBackground();
  }

  private resumeSession(): void {
    if (this.closed) return;
    this.tracker.observeSessionDurationVisibility();
    const hadEnd = this.endedSessionId !== undefined;
    this.endedSessionId = undefined;
    if (!hadEnd) return;
    // Returning to the page keeps the same session and duration origin.
    // Only initialization or an explicit newSession call changes ownership.
    void this.refresh({ forceRefresh: true }).catch(() => undefined);
  }
}

export function initGameAlgoWeb(options: GameAlgoWebClientOptions): GameAlgoWebClient {
  return GameAlgoWebClient.init(options);
}

/** Extract an original TapTap ad track ID from an onClose callback result. */
export function extractAdTrackId(result: unknown): string | undefined {
  if (!result || typeof result !== "object" || Array.isArray(result)) return undefined;
  const callback = result as Record<string, unknown>;
  for (const value of [callback, callback.extra, callback.msg, callback.message]) {
    let data = value;
    if (typeof data === "string") {
      try { data = JSON.parse(data); } catch { continue; }
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) continue;
    const fields = data as Record<string, unknown>;
    for (const id of [fields.trackId, fields.track_id]) {
      if (typeof id === "string" && id.trim()) return id;
    }
  }
  return undefined;
}

function browserDeviceContext(): Record<string, JsonValue> {
  const context: Record<string, JsonValue> = {};
  const os = browserOperatingSystem();
  if (os) context.os = os;
  Object.assign(context, tapDeviceContext());
  if (typeof window === "undefined") return context;
  return {
    ...context,
    viewportWidth: Math.max(0, Math.round(window.innerWidth || 0)),
    viewportHeight: Math.max(0, Math.round(window.innerHeight || 0)),
    devicePixelRatio: Number.isFinite(window.devicePixelRatio) ? window.devicePixelRatio : 1,
    touchPoints: typeof navigator === "undefined" ? 0 : navigator.maxTouchPoints || 0,
    standalone: typeof matchMedia === "function" ? matchMedia("(display-mode: standalone)").matches : false,
  };
}

function normalizeOperatingSystem(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const name = value.trim().toLowerCase().replace(/[\s_-]+/g, "");
  const names: Record<string, string> = {
    ios: "ios", ipados: "ios", iphoneos: "ios", android: "android",
    mac: "macos", macos: "macos", macosx: "macos", darwin: "macos",
    windows: "windows", windowsnt: "windows", win32: "windows", win64: "windows",
    linux: "linux", harmonyos: "harmonyos", openharmony: "harmonyos", ohos: "harmonyos",
  };
  return Object.prototype.hasOwnProperty.call(names, name) ? names[name] : undefined;
}

function browserOperatingSystem(): string | undefined {
  if (typeof navigator === "undefined") return undefined;
  const ua = navigator.userAgent || "";
  const platform = navigator.platform || "";
  if (/HarmonyOS|OpenHarmony/i.test(ua)) return "harmonyos";
  if (/Android/i.test(ua)) return "android";
  if (/iPhone|iPad|iPod/i.test(ua) || (/Mac/i.test(platform) && navigator.maxTouchPoints > 1)) return "ios";
  if (/Windows/i.test(ua)) return "windows";
  if (/Macintosh|Mac OS X/i.test(ua)) return "macos";
  if (/Linux/i.test(ua) || /^Linux/i.test(platform)) return "linux";
  return normalizeOperatingSystem(platform);
}

function withoutRuntimeIdentity(device?: Record<string, JsonValue>): Record<string, JsonValue> {
  const result = { ...device };
  for (const key of RUNTIME_IDENTITY_FIELDS) delete result[key];
  return result;
}

function runtimeMiniappId(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text.length <= 128 && /^tapmc[a-z0-9]+$/.test(text) ? text : undefined;
}

function tapRuntimeIdentity(): Record<string, JsonValue> {
  try {
    const tap = (globalThis as { tap?: { getAccountInfoSync?: () => unknown } }).tap;
    if (typeof tap?.getAccountInfoSync !== "function") return {};
    const value = tap.getAccountInfoSync();
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    if (typeof (value as { then?: unknown }).then === "function") {
      void Promise.resolve(value).catch(() => undefined);
      return {};
    }
    const miniProgram = (value as { miniProgram?: unknown }).miniProgram;
    if (!miniProgram || typeof miniProgram !== "object" || Array.isArray(miniProgram)) return {};
    const miniappId = runtimeMiniappId((miniProgram as { appId?: unknown }).appId);
    // Do not use host.appId (the TapTap container), plugin IDs, URLs or game options.
    return miniappId ? { runtimeMiniappId: miniappId } : {};
  } catch {
    return {};
  }
}

function tapDeviceContext(): Record<string, JsonValue> {
  try {
    const tap = (globalThis as { tap?: { getDeviceInfo?: () => unknown } }).tap;
    if (typeof tap?.getDeviceInfo !== "function") return {};
    const value = tap.getDeviceInfo();
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    const info = value as Record<string, unknown>;
    if (typeof info.then === "function") {
      void Promise.resolve(value).catch(() => undefined);
      return {};
    }
    const system = typeof info.system === "string" ? info.system.trim() : "";
    const systemName = system.match(/^(iOS|iPadOS|iPhone OS|Android|Windows(?: NT)?|macOS|Mac OS X|HarmonyOS|OpenHarmony|Linux)\b/i)?.[1];
    const os = normalizeOperatingSystem(info.platform) ?? normalizeOperatingSystem(systemName);
    if (!os) return {};
    const context: Record<string, JsonValue> = { os };
    // TapTap iOS returns "26.5"; some hosts include the OS name. UA versions
    // may be frozen for compatibility and are deliberately not used here.
    const version = systemName ? system.slice(systemName.length).trim() : system;
    if ((!systemName || normalizeOperatingSystem(systemName) === os) && /^\d+(?:[._]\d+){0,5}$/.test(version)) {
      context.osVersion = version.replace(/_/g, ".");
    }
    return context;
  } catch {
    return {};
  }
}

function webUrlAttribution(options: GameAlgoWebUrlAttributionOptions): Record<string, JsonValue> {
  const rawUrl = options.url ?? (typeof location === "undefined" ? undefined : location.href);
  if (!rawUrl) return {};
  let url: URL;
  try {
    url = rawUrl instanceof URL ? rawUrl : new URL(rawUrl);
  } catch {
    return {};
  }
  const names = (options.parameterNames ?? DEFAULT_WEB_ATTRIBUTION_PARAMETERS)
    .map((name) => name.trim())
    .filter((name, index, values) => /^[A-Za-z0-9_.-]{1,64}$/.test(name) && values.indexOf(name) === index)
    .slice(0, 32);
  const attribution: Record<string, JsonValue> = {};
  for (const name of names) {
    const value = cleanText(url.searchParams.get(name));
    if (value) attribution[name] = value.slice(0, 512);
  }
  const referrer = cleanText(options.referrer ?? (typeof document === "undefined" ? undefined : document.referrer));
  if (referrer) {
    try {
      attribution.referrerHost = new URL(referrer).host.slice(0, 255);
    } catch {
      // Do not upload malformed or full referrer values.
    }
  }
  return attribution;
}

function cleanText(value: string | null | undefined): string | undefined {
  const cleaned = value?.trim();
  return cleaned || undefined;
}

function requestBodyBytes(body: BodyInit | null | undefined): number {
  return typeof body === "string" ? new TextEncoder().encode(body).byteLength : Number.POSITIVE_INFINITY;
}

export { GameAlgoBrowserStorage } from "./browser-storage.ts";
export { GameAlgoWebScriptRuntime } from "./script-runtime.ts";
export { defineMultiplayerProtocol } from "./multiplayer-protocol.ts";
export {
  connectRoom,
  GameAlgoMatchmakingClient,
  GameAlgoMultiplayerError,
  LobbyHandle,
  MatchHandle,
  MultiplayerInputQueue,
  MultiplayerRoom,
} from "./multiplayer.ts";
export type { GameAlgoBrowserStorageOptions } from "./browser-storage.ts";
export type { GameAlgoWebScriptRuntimeOptions } from "./script-runtime.ts";
export type { MultiplayerFieldSchema, MultiplayerPrimitive, MultiplayerProtocol, MultiplayerProtocolDefinition, MultiplayerStructSchema } from "./multiplayer-protocol.ts";
export type {
  ConnectRoomOptions,
  CreateLobbyOptions,
  GameAlgoMatchmakingClientOptions,
  InputQueueOptions,
  JoinLobbyOptions,
  LobbyListOptions,
  LobbyMetadata,
  LobbyPage,
  LobbySnapshot,
  LobbySummary,
  MatchedRoom,
  MatchJoinOptions,
  MultiplayerErrorPhase,
  MultiplayerRoomState,
  MultiplayerRoomMember,
  MultiplayerSocketFactory,
} from "./multiplayer.ts";
export type {
  ConfigResponse,
  EventBatchResponse,
  EventPayload,
  FetchConfigOptions,
  GameAlgoExecutionResult,
  GameAlgoStorage,
  GameAlgoUserIdentity,
  JsonValue,
  TrackEventOptions,
  UserAttributionResponse,
} from "../../rest-api/src/types.ts";
