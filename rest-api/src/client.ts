import type {
  ConfigFileResponse,
  ConfigResponse,
  EventBatchResponse,
  FetchConfigOptions,
  GameAlgoExecutionResult,
  GameAlgoRestClientOptions,
  GameAlgoScriptInput,
  GameAlgoScriptRuntime,
  GameAlgoSnapshot,
  GameAlgoStorage,
  GameEvent,
  JsonValue,
  Platform,
  StartOptions,
} from "./types.ts";

export class GameAlgoApiError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export class GameAlgoRestClient {
  private readonly baseUrl: URL;
  private readonly gameKey: string;
  private readonly sdkVersion: string;
  private readonly appVersion?: string;
  private readonly platform: Platform;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly storage?: GameAlgoStorage;
  private readonly scriptRuntime: GameAlgoScriptRuntime;
  private readonly snapshotCacheKey: string;
  private cachedConfig: { value: ConfigResponse; expiresAt: number; cacheKey: string } | null = null;
  private snapshot: GameAlgoSnapshot = { configFiles: new Map(), updatedAt: 0 };
  private readyPromise: Promise<void> | null = null;
  readonly config: GameAlgoConfigReader;

  constructor(options: GameAlgoRestClientOptions) {
    if (!options.baseUrl) throw new Error("baseUrl is required");
    if (!options.gameKey) throw new Error("gameKey is required");

    this.baseUrl = new URL(options.baseUrl);
    this.gameKey = options.gameKey;
    this.sdkVersion = options.sdkVersion ?? "1.0.0";
    this.appVersion = options.appVersion;
    this.platform = options.platform ?? "rest";
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
    this.storage = options.storage;
    this.scriptRuntime = options.scriptRuntime ?? new FunctionScriptRuntime();
    this.snapshotCacheKey = options.cacheKey ?? `gamealgo:v1:snapshot:${this.baseUrl.origin}:${this.gameKey.slice(0, 16)}`;
    this.config = new GameAlgoConfigReader(() => this.snapshot);
  }

  start(options: StartOptions): Promise<void> {
    this.readyPromise = (async () => {
      await this.loadPersistedSnapshot();
      try {
        await this.refresh({ ...options, forceRefresh: true });
      } catch (error) {
        if (!this.snapshot.config) throw error;
      }
    })();
    return this.readyPromise;
  }

  async waitForReady(timeoutMs = 5000): Promise<boolean> {
    if (!this.readyPromise) return this.snapshot.config !== undefined;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        this.readyPromise,
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(new Error("GameAlgo ready timeout")), timeoutMs);
        }),
      ]);
      return true;
    } catch {
      return false;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  executor(key: string): GameAlgoExperimentExecutor {
    return new GameAlgoExperimentExecutor(key, () => this.snapshot, this.scriptRuntime);
  }

  async fetchConfig(options: FetchConfigOptions): Promise<ConfigResponse> {
    const platform = options.platform ?? this.platform;
    const sdkVersion = options.sdkVersion ?? this.sdkVersion;
    const appVersion = options.appVersion ?? this.appVersion;
    const cacheKey = JSON.stringify({
      userId: options.userId,
      platform,
      sdkVersion,
      appVersion,
      deviceId: options.deviceId,
    });

    if (!options.forceRefresh && this.cachedConfig && this.cachedConfig.cacheKey === cacheKey && this.cachedConfig.expiresAt > this.now()) {
      return this.cachedConfig.value;
    }

    const url = this.url("/v1/config");
    url.searchParams.set("userId", options.userId);
    url.searchParams.set("platform", platform);
    url.searchParams.set("sdkVersion", sdkVersion);
    if (appVersion) url.searchParams.set("appVersion", appVersion);
    if (options.deviceId) url.searchParams.set("deviceId", options.deviceId);

    const config = await this.requestJson<ConfigResponse>(url, { method: "GET" });
    this.cachedConfig = {
      value: config,
      cacheKey,
      expiresAt: this.now() + Math.max(Number(config.ttlSeconds) || 0, 0) * 1000,
    };
    this.snapshot = {
      ...this.snapshot,
      config,
      updatedAt: this.now(),
      userId: options.userId,
    };
    await this.persistSnapshot();
    return config;
  }

  async fetchConfigFile(name: string): Promise<ConfigFileResponse> {
    const safeName = normalizeFileName(name);
    const response = await this.request(this.url(`/v1/config-files/${encodeURIComponent(safeName)}`), { method: "GET" });
    const file = {
      name: safeName,
      content: await response.text(),
      contentType: response.headers.get("content-type") ?? "application/octet-stream",
      etag: response.headers.get("etag") ?? undefined,
    };
    const configFiles = new Map(this.snapshot.configFiles);
    configFiles.set(safeName, file);
    this.snapshot = {
      ...this.snapshot,
      configFiles,
      updatedAt: this.now(),
    };
    await this.persistSnapshot();
    return file;
  }

  async uploadEvents(events: GameEvent[]): Promise<EventBatchResponse> {
    if (!Array.isArray(events) || events.length === 0) {
      throw new Error("events must be a non-empty array");
    }
    if (events.length > 100) {
      throw new Error("Maximum 100 events per batch");
    }

    const normalizedEvents = events.map((event) => ({
      ...event,
      platform: event.platform ?? this.platform,
      sdkVersion: event.sdkVersion ?? this.sdkVersion,
      appVersion: event.appVersion ?? this.appVersion,
      isDebug: Boolean(event.isDebug),
      timestamp: event.timestamp ?? new Date(this.now()).toISOString(),
    }));

    return this.requestJson<EventBatchResponse>(this.url("/v1/events/batch"), {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify({ events: normalizedEvents }),
    });
  }

  clearConfigCache(): void {
    this.cachedConfig = null;
  }

  snapshotValue(): GameAlgoSnapshot {
    return {
      config: this.snapshot.config,
      configFiles: new Map(this.snapshot.configFiles),
      updatedAt: this.snapshot.updatedAt,
    };
  }

  private async refresh(options: StartOptions): Promise<void> {
    const config = await this.fetchConfig(options);
    const preload = options.preloadConfigFiles ?? true;
    if (!preload) return;

    const names = Array.isArray(preload)
      ? preload
      : [
          ...config.configFiles.map((file) => file.name),
          ...config.experiments.flatMap((experiment) => experiment.script?.name ? [experiment.script.name] : []),
        ];
    await Promise.all([...new Set(names)].map((name) => this.fetchConfigFile(name)));
  }

  private async loadPersistedSnapshot(): Promise<void> {
    if (!this.storage) return;
    const raw = await this.storage.getItem(this.snapshotCacheKey);
    if (!raw) return;
    try {
      const parsed = JSON.parse(raw) as {
        config?: ConfigResponse;
        configFiles?: ConfigFileResponse[];
        updatedAt?: number;
        userId?: string;
      };
      this.snapshot = {
        config: parsed.config,
        configFiles: new Map((parsed.configFiles ?? []).map((file) => [file.name, file])),
        updatedAt: Number(parsed.updatedAt || 0),
        userId: parsed.userId,
      };
    } catch {
      await this.storage.removeItem?.(this.snapshotCacheKey);
    }
  }

  private async persistSnapshot(): Promise<void> {
    if (!this.storage) return;
    await this.storage.setItem(this.snapshotCacheKey, JSON.stringify({
      config: this.snapshot.config,
      configFiles: [...this.snapshot.configFiles.values()],
      updatedAt: this.snapshot.updatedAt,
      userId: this.snapshot.userId,
    }));
  }

  private url(path: string): URL {
    return new URL(path, this.baseUrl);
  }

  private async requestJson<T>(url: URL, init: RequestInit): Promise<T> {
    const response = await this.request(url, init);
    return response.json() as Promise<T>;
  }

  private async request(url: URL, init: RequestInit): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set("X-GameAlgo-Key", this.gameKey);

    const response = await this.fetchImpl(url, {
      ...init,
      headers,
    });

    if (!response.ok) {
      throw await apiError(response);
    }

    return response;
  }
}

export class GameAlgoExperimentExecutor {
  private readonly key: string;
  private readonly snapshotProvider: () => GameAlgoSnapshot;
  private readonly scriptRuntime: GameAlgoScriptRuntime;

  constructor(key: string, snapshotProvider: () => GameAlgoSnapshot, scriptRuntime: GameAlgoScriptRuntime) {
    this.key = key;
    this.snapshotProvider = snapshotProvider;
    this.scriptRuntime = scriptRuntime;
  }

  get isReady(): boolean {
    return this.assignment() !== undefined;
  }

  assignment() {
    return this.snapshotProvider().config?.experiments.find((experiment) => experiment.key === this.key);
  }

  variant(defaultValue = "control"): string {
    return this.assignment()?.variant ?? defaultValue;
  }

  config<T extends JsonValue>(defaultValue: T): JsonValue | T {
    return this.assignment()?.config ?? defaultValue;
  }

  value<T extends JsonValue>(path: string, defaultValue: T): JsonValue | T {
    const config = this.assignment()?.config;
    if (config === undefined) return defaultValue;
    return readPath(config, path) ?? defaultValue;
  }

  string(path: string, defaultValue = ""): string {
    const value = this.value(path, defaultValue);
    return typeof value === "string" ? value : defaultValue;
  }

  number(path: string, defaultValue = 0): number {
    const value = this.value(path, defaultValue);
    return typeof value === "number" ? value : defaultValue;
  }

  bool(path: string, defaultValue = false): boolean {
    const value = this.value(path, defaultValue);
    return typeof value === "boolean" ? value : defaultValue;
  }

  async execute(state: JsonValue): Promise<GameAlgoExecutionResult | undefined> {
    const snapshot = this.snapshotProvider();
    const assignment = this.assignment();
    if (!snapshot.config || !assignment) return undefined;

    if (!assignment.script) {
      return {
        payload: assignment.config,
        diagnostics: { mode: "config-only" },
        assignment,
      };
    }

    const scriptFile = snapshot.configFiles.get(assignment.script.name);
    if (!scriptFile) return undefined;

    await verifyScriptHash(scriptFile.content, assignment.script.hash);
    const input: GameAlgoScriptInput = {
      state,
      config: assignment.config,
      meta: {
        gameId: snapshot.config.gameId,
        userId: snapshot.userId ?? "",
        environment: snapshot.config.environment,
        strategy: assignment.key,
        experimentId: assignment.experimentId,
        variant: assignment.variant,
      },
    };
    const output = normalizeJsonValue(await this.scriptRuntime.execute(scriptFile.content, input));
    if (!output || typeof output !== "object" || Array.isArray(output)) {
      return undefined;
    }
    const payload = (output as Record<string, JsonValue>).payload;
    const diagnostics = (output as Record<string, JsonValue>).diagnostics;
    if (payload === undefined) return undefined;
    return {
      payload,
      diagnostics: diagnostics ?? {},
      assignment,
    };
  }
}

export class FunctionScriptRuntime implements GameAlgoScriptRuntime {
  execute(script: string, input: GameAlgoScriptInput): JsonValue {
    const runner = new Function("input", `${script}\n; return execute(input);`);
    return normalizeJsonValue(runner(input));
  }
}

export class GameAlgoConfigReader {
  private readonly snapshotProvider: () => GameAlgoSnapshot;

  constructor(snapshotProvider: () => GameAlgoSnapshot) {
    this.snapshotProvider = snapshotProvider;
  }

  file(name: string): ConfigFileResponse | undefined {
    return this.snapshotProvider().configFiles.get(name);
  }

  jsonFile<T extends JsonValue>(name: string, defaultValue: T): JsonValue | T {
    const file = this.file(name);
    if (!file) return defaultValue;
    try {
      return JSON.parse(file.content) as JsonValue;
    } catch {
      return defaultValue;
    }
  }

  value<T extends JsonValue>(path: string, defaultValue: T, fileName?: string): JsonValue | T {
    const source = this.defaultJsonSource(fileName);
    if (source === undefined) return defaultValue;
    return readPath(source, path) ?? defaultValue;
  }

  string(path: string, defaultValue = "", fileName?: string): string {
    const value = this.value(path, defaultValue, fileName);
    return typeof value === "string" ? value : defaultValue;
  }

  number(path: string, defaultValue = 0, fileName?: string): number {
    const value = this.value(path, defaultValue, fileName);
    return typeof value === "number" ? value : defaultValue;
  }

  bool(path: string, defaultValue = false, fileName?: string): boolean {
    const value = this.value(path, defaultValue, fileName);
    return typeof value === "boolean" ? value : defaultValue;
  }

  private defaultJsonSource(fileName?: string): JsonValue | undefined {
    if (fileName) return this.jsonFile(fileName, undefinedJson);

    const jsonFiles = [...this.snapshotProvider().configFiles.values()].filter((file) => (
      file.contentType.includes("application/json") || file.name.endsWith(".json")
    ));
    if (jsonFiles.length !== 1) return undefined;

    try {
      return JSON.parse(jsonFiles[0].content) as JsonValue;
    } catch {
      return undefined;
    }
  }
}

export function createEvent(input: Omit<GameEvent, "eventId" | "timestamp"> & { eventId?: string; timestamp?: string }): GameEvent {
  return {
    ...input,
    eventId: input.eventId ?? crypto.randomUUID(),
    timestamp: input.timestamp ?? new Date().toISOString(),
  };
}

async function apiError(response: Response): Promise<GameAlgoApiError> {
  const fallback = `GameAlgo API returned ${response.status}`;
  try {
    const payload = await response.json() as { error?: string; message?: string };
    return new GameAlgoApiError(response.status, payload.message ?? payload.error ?? fallback, payload.error);
  } catch {
    return new GameAlgoApiError(response.status, fallback);
  }
}

function normalizeFileName(name: string): string {
  const trimmed = name.trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(trimmed) || trimmed.includes("..")) {
    throw new Error("Invalid config file name");
  }
  return trimmed;
}

async function verifyScriptHash(content: string, expected: string): Promise<void> {
  if (!expected) return;
  const actual = await sha256(content);
  if (!actual) return;
  if (actual !== expected) {
    throw new Error(`Script hash mismatch: expected=${expected} actual=${actual}`);
  }
}

async function sha256(content: string): Promise<string | undefined> {
  if (!globalThis.crypto?.subtle) return undefined;
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  return `sha256:${[...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

function normalizeJsonValue(value: unknown): JsonValue {
  return JSON.parse(JSON.stringify(value)) as JsonValue;
}

const undefinedJson = undefined as unknown as JsonValue;

function readPath(source: JsonValue, path: string): JsonValue | undefined {
  if (!path) return source;
  let current: JsonValue | undefined = source;
  for (const segment of path.split(".")) {
    if (Array.isArray(current)) {
      const index = Number(segment);
      current = Number.isInteger(index) ? current[index] : undefined;
    } else if (current && typeof current === "object") {
      current = (current as Record<string, JsonValue>)[segment];
    } else {
      return undefined;
    }
    if (current === undefined) return undefined;
  }
  return current;
}
