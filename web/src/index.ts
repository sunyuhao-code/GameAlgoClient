import { GameAlgoRestClient } from "../../rest-api/src/client.ts";
import type {
  GameAlgoRestClientOptions,
  GameAlgoStorage,
  JsonValue,
  UserAttributionResponse,
} from "../../rest-api/src/types.ts";
import { GameAlgoBrowserStorage, type GameAlgoBrowserStorageOptions } from "./browser-storage.ts";
import { GameAlgoWebScriptRuntime } from "./script-runtime.ts";
import { GameAlgoMatchmakingClient } from "./multiplayer.ts";

export const GAMEALGO_WEB_SDK_VERSION = "1.0.21";
const WEB_KEEPALIVE_BODY_LIMIT_BYTES = 60 * 1024;
const WEB_EVENT_BATCH_BODY_BUDGET_BYTES = 48 * 1024;
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
      device: {
        runtime: "h5",
        ...browserDeviceContext(),
        ...(options.device ?? {}),
      },
    });

    this.webScriptRuntime = scriptRuntime;
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
    const session = this.tracker.currentSessionId();
    if (this.autoSessionLifecycle && this.endedSessionId !== session) {
      if (this.tracker.trackSessionEndSnapshot({ reason })) this.endedSessionId = session;
    }
    this.flushInBackground();
  }

  private resumeSession(): void {
    if (this.closed) return;
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

function browserDeviceContext(): Record<string, JsonValue> {
  if (typeof window === "undefined") return {};
  return {
    viewportWidth: Math.max(0, Math.round(window.innerWidth || 0)),
    viewportHeight: Math.max(0, Math.round(window.innerHeight || 0)),
    devicePixelRatio: Number.isFinite(window.devicePixelRatio) ? window.devicePixelRatio : 1,
    touchPoints: typeof navigator === "undefined" ? 0 : navigator.maxTouchPoints || 0,
    standalone: typeof matchMedia === "function" ? matchMedia("(display-mode: standalone)").matches : false,
  };
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
