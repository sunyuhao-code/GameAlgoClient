import type {
  ConfigFileResponse,
  ConfigResponse,
  EventBatchResponse,
  EventPayload,
  EventPayloadValue,
  ExperimentAssignment,
  FetchConfigOptions,
  GameAlgoExecutionResult,
  GameAlgoLogger,
  GameAlgoRestClientOptions,
  GameAlgoScriptInput,
  GameAlgoScriptRuntime,
  GameAlgoSnapshot,
  GameAlgoStorage,
  GameAlgoUserIdentity,
  GameEvent,
  JsonValue,
  Platform,
  TrackEventOptions,
} from "./types.ts";

type RefreshOptions = FetchConfigOptions & {
  preloadConfigFiles?: boolean | string[];
};

type InternalClientOptions = GameAlgoRestClientOptions & {
  autoStart?: boolean;
};

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
  private readonly timezone: string;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly storage?: GameAlgoStorage;
  private readonly scriptRuntime: GameAlgoScriptRuntime;
  private readonly logger?: (message: string) => void;
  private readonly snapshotCacheKey: string;
  private readonly userIdKey = "gamealgo_user_id";
  private readonly userCreatedAtKey = "gamealgo_user_created_at";
  private cachedConfig: { value: ConfigResponse; expiresAt: number; cacheKey: string } | null = null;
  private snapshot: GameAlgoSnapshot = { configFiles: new Map(), updatedAt: 0 };
  private currentIdentity: GameAlgoUserIdentity | null = null;
  private readyPromise: Promise<void> | null = null;
  private didLogUserId = false;
  readonly config: GameAlgoConfigReader;
  readonly tracker: GameAlgoEventTracker;

  constructor(options: GameAlgoRestClientOptions) {
    if (!options.baseUrl) throw new Error("baseUrl is required");
    if (!options.gameKey) throw new Error("gameKey is required");

    this.baseUrl = new URL(options.baseUrl);
    this.gameKey = options.gameKey;
    this.sdkVersion = options.sdkVersion ?? "1.0.0";
    this.appVersion = options.appVersion;
    this.platform = options.platform ?? "rest";
    this.timezone = clean(options.timezone) ?? defaultTimezone();
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
    this.storage = options.storage;
    this.scriptRuntime = options.scriptRuntime ?? new FunctionScriptRuntime();
    this.logger = resolveLogger(options.logger);
    this.snapshotCacheKey = options.cacheKey ?? `gamealgo:v1:snapshot:${this.baseUrl.origin}:${this.gameKey.slice(0, 16)}`;
    this.config = new GameAlgoConfigReader(() => this.snapshot);
    this.tracker = new GameAlgoEventTracker({
      uploadEvents: (events) => this.uploadEvents(events),
      platform: this.platform,
      sdkVersion: this.sdkVersion,
      appVersion: this.appVersion,
      timezone: this.timezone,
      isDebug: options.isDebug ?? false,
      flushIntervalMs: options.eventFlushIntervalMs ?? 30000,
      maxBatchSize: options.eventMaxBatchSize ?? 100,
      queueLimit: options.eventQueueLimit ?? 1000,
      now: this.now,
    });
    const internalOptions = options as InternalClientOptions;
    if (internalOptions.autoStart !== false) {
      this.readyPromise = this.initialize(options);
    }
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
    return new GameAlgoExperimentExecutor(key, () => this.snapshot, this.scriptRuntime, this.logger);
  }

  async userIdentity(explicitUserId?: string): Promise<GameAlgoUserIdentity> {
    const cleanExplicit = clean(explicitUserId);

    if (cleanExplicit) {
      if (this.currentIdentity?.userId === cleanExplicit) return this.currentIdentity;
      const existing = clean(await this.storage?.getItem(this.userIdKey));
      const existingCreatedAt = clean(await this.storage?.getItem(this.userCreatedAtKey));
      this.currentIdentity = {
        userId: cleanExplicit,
        userCreatedAt: existing === cleanExplicit && existingCreatedAt ? existingCreatedAt : new Date(this.now()).toISOString(),
      };
      await this.storage?.setItem(this.userIdKey, this.currentIdentity.userId);
      await this.storage?.setItem(this.userCreatedAtKey, this.currentIdentity.userCreatedAt);
      return this.currentIdentity;
    }
    if (this.currentIdentity) return this.currentIdentity;

    const existing = clean(await this.storage?.getItem(this.userIdKey));
    if (existing) {
      const existingCreatedAt = clean(await this.storage?.getItem(this.userCreatedAtKey)) ?? new Date(this.now()).toISOString();
      this.currentIdentity = {
        userId: existing,
        userCreatedAt: existingCreatedAt,
      };
      await this.storage?.setItem(this.userCreatedAtKey, existingCreatedAt);
      return this.currentIdentity;
    }

    this.currentIdentity = {
      userId: randomId(),
      userCreatedAt: new Date(this.now()).toISOString(),
    };
    await this.storage?.setItem(this.userIdKey, this.currentIdentity.userId);
    await this.storage?.setItem(this.userCreatedAtKey, this.currentIdentity.userCreatedAt);
    return this.currentIdentity;
  }

  async fetchConfig(options: FetchConfigOptions = {}): Promise<ConfigResponse> {
    const identity = await this.userIdentity(options.userId);
    const userCreatedAt = clean(options.userCreatedAt) ?? identity.userCreatedAt;
    this.logUserId(identity.userId);
    this.tracker.identify(identity.userId, options.sessionId, userCreatedAt);
    const platform = options.platform ?? this.platform;
    const sdkVersion = options.sdkVersion ?? this.sdkVersion;
    const appVersion = options.appVersion ?? this.appVersion;
    const sessionId = clean(options.sessionId) ?? this.tracker.currentSessionId();
    const device = {
      ...defaultDeviceContext(),
      ...(options.device ?? {}),
      ...(options.deviceId ? { deviceId: options.deviceId } : {}),
    };
    const cacheKey = JSON.stringify({
      userId: identity.userId,
      userCreatedAt,
      sessionId,
      platform,
      sdkVersion,
      appVersion,
      deviceId: options.deviceId,
      timezone: options.timezone ?? this.timezone,
      device,
    });

    if (!options.forceRefresh && this.cachedConfig && this.cachedConfig.cacheKey === cacheKey && this.cachedConfig.expiresAt > this.now()) {
      this.log(`config cache hit: ${this.cachedConfig.value.configVersion}`);
      return this.cachedConfig.value;
    }

    this.log(`fetching config: userId=${identity.userId}, platform=${platform}`);

    try {
      const config = await this.requestJson<ConfigResponse>(this.url("/v1/config"), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          userId: identity.userId,
          userCreatedAt,
          sessionId,
          platform,
          sdkVersion,
          appVersion,
          timezone: options.timezone ?? this.timezone,
          device,
        }),
      });
      this.cachedConfig = {
        value: config,
        cacheKey,
        expiresAt: this.now() + Math.max(Number(config.ttlSeconds) || 0, 0) * 1000,
      };
      this.tracker.setContextId(config.contextId);
      this.tracker.setAssignments(config.experiments);
      this.snapshot = {
        ...this.snapshot,
        config,
        updatedAt: this.now(),
        userId: identity.userId,
      };
      await this.persistSnapshot();
      this.log(`config fetched: version=${config.configVersion}, experiments=${config.experiments.length}, configFiles=${config.configFiles.length}, ttl=${config.ttlSeconds}s`);
      this.logAssignments(config.experiments, "config ready");
      return config;
    } catch (error) {
      if (this.cachedConfig?.cacheKey === cacheKey) {
        this.log(`config fetch failed, using cached config: ${errorMessage(error)}`);
        return this.cachedConfig.value;
      }
      this.log(`config fetch failed: ${errorMessage(error)}`);
      throw error;
    }
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
    this.log(`config file loaded: ${file.name} (${file.contentType})`);
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
      eventId: event.eventId ?? randomId(),
      isDebug: Boolean(event.isDebug),
      timestamp: event.timestamp ?? new Date(this.now()).toISOString(),
      payload: normalizePayload(event.payload ?? {}),
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

  private async initialize(options: RefreshOptions): Promise<void> {
    const identity = await this.userIdentity(options.userId);
    const userCreatedAt = clean(options.userCreatedAt) ?? identity.userCreatedAt;
    this.logUserId(identity.userId);
    this.tracker.identify(identity.userId, options.sessionId, userCreatedAt);
    this.tracker.markSessionStarted();
    await this.loadPersistedSnapshot();
    try {
      await this.refresh({ ...options, userId: identity.userId, userCreatedAt, forceRefresh: true });
    } catch (error) {
      if (!this.snapshot.config) {
        this.log(`config fetch failed: ${errorMessage(error)}`);
        throw error;
      }
      this.log(`config fetch failed, using cached snapshot: ${errorMessage(error)}`);
    }
  }

  private async refresh(options: RefreshOptions): Promise<void> {
    const config = await this.fetchConfig(options);
    const preload = options.preloadConfigFiles ?? true;
    if (!preload) {
      this.log("config file preload skipped");
      return;
    }

    const names = Array.isArray(preload)
      ? preload
      : [
          ...config.configFiles.map((file) => file.name),
          ...config.experiments.flatMap((experiment) => experiment.script?.name ? [experiment.script.name] : []),
        ];
    const preloadNames = [...new Set(names)];
    if (preloadNames.length === 0) {
      this.log("no config files to preload");
    } else {
      this.log(`preloading config files: ${preloadNames.sort().join(", ")}`);
    }
    await Promise.all(preloadNames.map((name) => this.fetchConfigFile(name)));
    for (const experiment of config.experiments) {
      const scriptName = experiment.script?.name;
      if (scriptName && this.snapshot.configFiles.has(scriptName)) {
        this.log(`script loaded: ${experiment.key} -> ${scriptName}`);
      }
    }
    if (preloadNames.length > 0) {
      this.log("all config files loaded");
    }
    this.tracker.setAssignments(config.experiments);
    this.logAssignments(config.experiments, "experiment");
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
      this.log("cached snapshot loaded");
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

  private logUserId(userId: string): void {
    if (this.didLogUserId) return;
    this.didLogUserId = true;
    this.log(`userId: ${userId}`);
  }

  private logAssignments(assignments: ExperimentAssignment[], prefix: string): void {
    for (const assignment of assignments) {
      this.log(`${prefix}: ${assignment.key} -> ${assignment.variant}`);
    }
  }

  private log(message: string): void {
    this.logger?.(`[GameAlgoSDK] ${message}`);
  }
}

export class GameAlgoEventTracker {
  private readonly uploadEvents: (events: GameEvent[]) => Promise<EventBatchResponse>;
  private readonly platform: Platform;
  private readonly sdkVersion: string;
  private readonly appVersion?: string;
  private readonly maxBatchSize: number;
  private readonly queueLimit: number;
  private readonly flushIntervalMs: number;
  private readonly now: () => number;

  private userId?: string;
  private sessionId = randomId();
  private contextId?: string;
  private timezone?: string;
  private userCreatedAt?: string;
  private isDebug: boolean;
  private currentExperiments: Record<string, string> = {};
  private queue: GameEvent[] = [];
  private retryBatch: GameEvent[] = [];
  private flushTimer?: ReturnType<typeof setInterval>;
  private flushing = false;
  private sessionStartMs?: number;

  constructor(options: {
    uploadEvents: (events: GameEvent[]) => Promise<EventBatchResponse>;
    platform: Platform;
    sdkVersion: string;
    appVersion?: string;
    timezone?: string;
    isDebug: boolean;
    flushIntervalMs: number;
    maxBatchSize: number;
    queueLimit: number;
    now: () => number;
  }) {
    this.uploadEvents = options.uploadEvents;
    this.platform = options.platform;
    this.sdkVersion = options.sdkVersion;
    this.appVersion = options.appVersion;
    this.timezone = clean(options.timezone) ?? defaultTimezone();
    this.isDebug = options.isDebug;
    this.flushIntervalMs = options.flushIntervalMs;
    this.maxBatchSize = Math.max(1, Math.min(options.maxBatchSize, 100));
    this.queueLimit = Math.max(options.queueLimit, this.maxBatchSize);
    this.now = options.now;
  }

  identify(userId: string, sessionId?: string, userCreatedAt?: string): void {
    if (clean(userId)) this.userId = userId;
    if (clean(sessionId)) this.sessionId = sessionId!;
    if (clean(userCreatedAt)) this.userCreatedAt = userCreatedAt;
  }

  newSession(sessionId = randomId()): void {
    this.sessionId = sessionId;
    this.contextId = undefined;
    this.sessionStartMs = this.now();
  }

  currentSessionId(): string {
    return this.sessionId;
  }

  setContextId(contextId: string): void {
    this.contextId = clean(contextId);
  }

  setDebug(isDebug: boolean): void {
    this.isDebug = isDebug;
  }

  setTimezone(timezone?: string): void {
    this.timezone = clean(timezone) ?? defaultTimezone();
  }

  setAssignments(assignments: ExperimentAssignment[]): void {
    this.currentExperiments = {};
    for (const assignment of assignments) {
      this.currentExperiments[assignment.key] = assignment.variant;
    }
  }

  markSessionStarted(): void {
    this.sessionStartMs = this.now();
  }

  track(eventType: string, payload: JsonValue = {}, options: TrackEventOptions = {}): boolean {
    const userId = clean(options.userId ?? this.userId);
    if (!userId) return false;
    const contextId = clean(options.contextId ?? this.contextId);

    this.enqueue({
      eventId: randomId(),
      contextId: contextId ?? "",
      userId,
      sessionId: clean(options.sessionId) ?? this.sessionId,
      eventType,
      isDebug: options.isDebug ?? this.isDebug,
      timestamp: options.timestamp ?? new Date(this.now()).toISOString(),
      payload: normalizePayload(payload),
    });
    return true;
  }

  trackEvent(type: string, payload: JsonValue = {}, options: TrackEventOptions = {}): boolean {
    return this.track(type.startsWith("_") ? type : `_${type}`, payload, options);
  }

  trackSessionStart(payload: JsonValue = {}): boolean {
    void payload;
    this.markSessionStarted();
    return true;
  }

  trackSessionEnd(payload: JsonValue = {}): boolean {
    const merged = objectPayload(payload);
    if (this.sessionStartMs !== undefined) {
      merged.sessionDurationMs = this.now() - this.sessionStartMs;
    }
    return this.track("session_end", merged);
  }

  trackLevelStart(payload: JsonValue = {}): boolean {
    return this.track("level_start", payload);
  }

  trackLevelEnd(payload: JsonValue = {}): boolean {
    return this.track("level_end", payload);
  }

  trackAd(placement: string, adType: string, revenue: number, currency: string, payload?: JsonValue): boolean;
  trackAd(placement: string, adType: string, revenue: number, currency: string, network?: string, payload?: JsonValue): boolean;
  trackAd(
    placement: string,
    adType: string,
    revenue: number,
    currency: string,
    networkOrPayload?: string | JsonValue,
    payload: JsonValue = {},
  ): boolean {
    const network = typeof networkOrPayload === "string" ? networkOrPayload : undefined;
    const merged = objectPayload(typeof networkOrPayload === "string" ? payload : (networkOrPayload ?? payload));
    merged.placement = placement;
    merged.adType = adType;
    merged.revenue = revenue;
    merged.currency = currency;
    if (network) merged.network = network;
    return this.track("ad_view", merged);
  }

  trackPurchase(productId?: string, revenue?: number, currency?: string, payload: JsonValue = {}): boolean {
    const merged = objectPayload(payload);
    if (productId) merged.productId = productId;
    if (revenue !== undefined) merged.revenue = revenue;
    if (currency) merged.currency = currency;
    return this.track("purchase", merged);
  }

  gameStart(payload: JsonValue = {}): boolean {
    return this.track("game_start", payload);
  }

  gameOver(payload: JsonValue = {}): boolean {
    return this.track("game_over", payload);
  }

  move(payload: JsonValue = {}): boolean {
    return this.track("move", payload);
  }

  replay(payload: JsonValue = {}): boolean {
    return this.track("replay", payload);
  }

  quit(payload: JsonValue = {}): boolean {
    return this.track("quit", payload);
  }

  async flush(): Promise<EventBatchResponse[]> {
    if (this.flushing) return [];
    this.flushing = true;

    const responses: EventBatchResponse[] = [];
    try {
      while (this.retryBatch.length > 0 || this.queue.length > 0) {
        const pending = [...this.retryBatch, ...this.queue];
        const batch = pending.slice(0, this.maxBatchSize);
        const resolvedContextId = clean(this.contextId);
        if (batch.some((event) => !clean(event.contextId)) && !resolvedContextId) {
          this.retryBatch = [];
          this.queue = pending;
          return responses;
        }
        const uploadBatch = batch.map((event) => clean(event.contextId) ? event : { ...event, contextId: resolvedContextId! });
        this.retryBatch = [];
        this.queue = pending.slice(this.maxBatchSize);

        try {
          responses.push(await this.uploadEvents(uploadBatch));
        } catch (error) {
          this.retryBatch = uploadBatch;
          throw error;
        }
      }
      return responses;
    } finally {
      this.flushing = false;
    }
  }

  close(): void {
    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = undefined;
    }
  }

  private enqueue(event: GameEvent): void {
    this.queue.push(event);
    if (this.queue.length > this.queueLimit) {
      this.queue.splice(0, this.queue.length - this.queueLimit);
    }
    this.startTimer();
    if (this.queue.length >= this.maxBatchSize) {
      void this.flush().catch(() => undefined);
    }
  }

  private startTimer(): void {
    if (this.flushTimer || this.flushIntervalMs <= 0) return;
    this.flushTimer = setInterval(() => {
      void this.flush().catch(() => undefined);
    }, this.flushIntervalMs);
    this.flushTimer.unref?.();
  }
}

export class GameAlgoExperimentExecutor {
  private readonly key: string;
  private readonly snapshotProvider: () => GameAlgoSnapshot;
  private readonly scriptRuntime: GameAlgoScriptRuntime;
  private readonly logger?: (message: string) => void;

  constructor(
    key: string,
    snapshotProvider: () => GameAlgoSnapshot,
    scriptRuntime: GameAlgoScriptRuntime,
    logger?: (message: string) => void,
  ) {
    this.key = key;
    this.snapshotProvider = snapshotProvider;
    this.scriptRuntime = scriptRuntime;
    this.logger = logger;
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
    if (!snapshot.config || !assignment) {
      this.log(`execute skipped: ${this.key} is not ready`);
      return undefined;
    }

    if (!assignment.script) {
      return {
        payload: assignment.config,
        diagnostics: { mode: "config-only" },
        assignment,
      };
    }

    const scriptFile = snapshot.configFiles.get(assignment.script.name);
    if (!scriptFile) {
      this.log(`execute skipped: script not loaded: ${assignment.key} -> ${assignment.script.name}`);
      return undefined;
    }

    try {
      await verifyScriptHash(scriptFile.content, assignment.script.hash);
    } catch (error) {
      this.log(`execute skipped: script hash mismatch: ${assignment.key} -> ${assignment.script.name}`);
      throw error;
    }
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
      this.log(`execute failed for ${assignment.key}: result must be an object`);
      return undefined;
    }
    const payload = (output as Record<string, JsonValue>).payload;
    const diagnostics = (output as Record<string, JsonValue>).diagnostics;
    if (payload === undefined) {
      this.log(`execute failed for ${assignment.key}: result must contain payload`);
      return undefined;
    }
    return {
      payload,
      diagnostics: diagnostics ?? {},
      assignment,
    };
  }

  private log(message: string): void {
    this.logger?.(`[GameAlgoSDK] ${message}`);
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
    eventId: input.eventId ?? randomId(),
    timestamp: input.timestamp ?? new Date().toISOString(),
    payload: normalizePayload(input.payload ?? {}),
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

function randomId(): string {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function clean(value: string | undefined | null): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function resolveLogger(logger: GameAlgoLogger | undefined): ((message: string) => void) | undefined {
  if (logger === false) return undefined;
  return logger ?? ((message) => console.log(message));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function defaultTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

function defaultDeviceContext(): Record<string, JsonValue> {
  const context: Record<string, JsonValue> = {};
  const navigatorValue = (globalThis as {
    navigator?: { language?: string; platform?: string; userAgent?: string };
  }).navigator;
  const processValue = (globalThis as {
    process?: {
      arch?: string;
      platform?: string;
      versions?: { node?: string };
    };
  }).process;

  if (processValue?.versions?.node) {
    context.runtime = "node";
    context.nodeVersion = processValue.versions.node;
  } else if (navigatorValue) {
    context.runtime = "browser";
  }
  if (processValue?.platform) context.os = processValue.platform;
  if (processValue?.arch) context.arch = processValue.arch;
  if (navigatorValue?.language) context.locale = navigatorValue.language;
  if (navigatorValue?.platform) context.browserPlatform = navigatorValue.platform;
  if (navigatorValue?.userAgent) context.userAgent = navigatorValue.userAgent;
  return context;
}

function objectPayload(value: JsonValue): Record<string, JsonValue> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return { ...(value as Record<string, JsonValue>) };
  }
  return {};
}

function normalizePayload(value: JsonValue): EventPayload {
  const payload: EventPayload = {};
  const object = objectPayload(value);
  for (const [key, rawValue] of Object.entries(object)) {
    if (!key) continue;
    const normalized = payloadValue(rawValue);
    if (normalized !== undefined) {
      payload[key] = normalized;
    }
  }
  return payload;
}

function payloadValue(value: JsonValue): EventPayloadValue | undefined {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (value !== undefined) return JSON.stringify(value);
  return undefined;
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
