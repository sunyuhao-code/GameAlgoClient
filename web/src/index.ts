import { GameAlgoRestClient } from "../../rest-api/src/client.ts";
import type {
  GameAlgoRestClientOptions,
  GameAlgoScriptInput,
  GameAlgoScriptRuntime,
  GameAlgoStorage,
  JsonValue,
} from "../../rest-api/src/types.ts";
import { GameAlgoBrowserStorage, type GameAlgoBrowserStorageOptions } from "./browser-storage.ts";

export const GAMEALGO_WEB_SDK_VERSION = "0.1.0";
const WEB_KEEPALIVE_BODY_LIMIT_BYTES = 60 * 1024;
const WEB_EVENT_BATCH_BODY_BUDGET_BYTES = 48 * 1024;

export type GameAlgoWebClientOptions = Omit<
  GameAlgoRestClientOptions,
  "platform" | "scriptRuntime" | "scriptRuntimeBinaryPath" | "storage" | "sdkVersion"
> & {
  sdkVersion?: string;
  storage?: GameAlgoStorage;
  browserStorage?: GameAlgoBrowserStorageOptions;
  autoLifecycle?: boolean;
};

/** Browser-native GameAlgo client. The telemetry platform is always `web`. */
export class GameAlgoWebClient extends GameAlgoRestClient {
  private readonly lifecycleTarget?: Pick<Window, "addEventListener" | "removeEventListener">;
  private readonly documentTarget?: Pick<Document, "addEventListener" | "removeEventListener" | "visibilityState">;
  private readonly onVisibilityChange: () => void;
  private readonly onPageHide: () => void;
  private readonly onOnline: () => void;

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

    super({
      ...options,
      platform: "web",
      sdkVersion: options.sdkVersion ?? GAMEALGO_WEB_SDK_VERSION,
      storage,
      fetchImpl,
      scriptRuntime: new UnsupportedBrowserScriptRuntime(),
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

    this.lifecycleTarget = typeof window === "undefined" ? undefined : window;
    this.documentTarget = typeof document === "undefined" ? undefined : document;
    this.onVisibilityChange = () => {
      if (this.documentTarget?.visibilityState === "hidden") this.flushInBackground();
    };
    this.onPageHide = () => this.flushInBackground();
    this.onOnline = () => this.flushInBackground();
    if (options.autoLifecycle !== false) this.attachLifecycle();
  }

  static init(options: GameAlgoWebClientOptions): GameAlgoWebClient {
    return new GameAlgoWebClient(options);
  }

  async flush(): Promise<void> {
    await this.tracker.flush();
  }

  close(): void {
    this.documentTarget?.removeEventListener("visibilitychange", this.onVisibilityChange);
    this.lifecycleTarget?.removeEventListener("pagehide", this.onPageHide);
    this.lifecycleTarget?.removeEventListener("online", this.onOnline);
    this.tracker.close();
  }

  private attachLifecycle(): void {
    this.documentTarget?.addEventListener("visibilitychange", this.onVisibilityChange);
    this.lifecycleTarget?.addEventListener("pagehide", this.onPageHide);
    this.lifecycleTarget?.addEventListener("online", this.onOnline);
  }

  private flushInBackground(): void {
    void this.tracker.flush().catch(() => undefined);
  }
}

export function initGameAlgoWeb(options: GameAlgoWebClientOptions): GameAlgoWebClient {
  return GameAlgoWebClient.init(options);
}

class UnsupportedBrowserScriptRuntime implements GameAlgoScriptRuntime {
  prepare(): void {
    // Script metadata may still be cached; execution deliberately remains off.
  }

  execute(_script: string, _input: GameAlgoScriptInput): JsonValue {
    throw new Error("Remote script execution is not supported by the H5 SDK yet; use config-only strategies");
  }
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

function requestBodyBytes(body: BodyInit | null | undefined): number {
  return typeof body === "string" ? new TextEncoder().encode(body).byteLength : Number.POSITIVE_INFINITY;
}

export { GameAlgoBrowserStorage } from "./browser-storage.ts";
export type { GameAlgoBrowserStorageOptions } from "./browser-storage.ts";
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
} from "../../rest-api/src/types.ts";
