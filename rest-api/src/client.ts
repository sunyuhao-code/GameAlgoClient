import type {
  ConfigFileResponse,
  ConfigResponse,
  ContextIdentifierResponse,
  ContextIdentifierType,
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
  UserAttributionInput,
  UserAttributionResponse,
} from "./types.ts";
import { sha256HexSync } from "./sha256.ts";
import type { GameAlgoDDAOptions } from "./types.ts";
import { GameAlgoDDAController } from "./dda.ts";

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
  private readonly accountUserId?: string;
  private readonly accountUserCreatedAt?: string;
  private readonly experimentIntegrationVersion: number;
  private readonly platform: Platform;
  private readonly timezone: string;
  private readonly isDebug: boolean;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly storage?: GameAlgoStorage;
  private readonly scriptRuntime: GameAlgoScriptRuntime;
  private readonly logger?: (message: string) => void;
  private readonly snapshotCacheKey: string;
  private readonly legacySnapshotCacheKey: string;
  private readonly attributionAckCacheKey: string;
  private readonly contextIdentifierAckCacheKey: string;
  private readonly userIdKey: string;
  private readonly userCreatedAtKey: string;
  private readonly userCreatedLocalAtKey: string;
  private cachedConfig: { value: ConfigResponse; expiresAt: number; cacheKey: string } | null = null;
  private snapshot: GameAlgoSnapshot = { configFiles: new Map(), updatedAt: 0 };
  private currentIdentity: GameAlgoUserIdentity | null = null;
  private readyPromise: Promise<void> | null = null;
  private didLogUserId = false;
  private didMigrateLegacyIdentity = false;
  private readonly ddaControllers = new Map<string, GameAlgoDDAController>();
  readonly config: GameAlgoConfigReader;
  readonly tracker: GameAlgoEventTracker;

  constructor(options: GameAlgoRestClientOptions) {
    if (!options.baseUrl) throw new Error("baseUrl is required");
    if (!options.gameKey) throw new Error("gameKey is required");

    this.baseUrl = new URL(options.baseUrl);
    this.gameKey = options.gameKey;
    this.sdkVersion = options.sdkVersion ?? "1.0.0";
    this.appVersion = options.appVersion;
    this.accountUserId = clean(options.accountUserId);
    this.accountUserCreatedAt = clean(options.accountUserCreatedAt);
    this.experimentIntegrationVersion = normalizeExperimentIntegrationVersion(options.experimentIntegrationVersion);
    this.platform = options.platform ?? "rest";
    this.timezone = clean(options.timezone) ?? defaultTimezone();
    this.isDebug = options.isDebug ?? false;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
    this.storage = options.storage;
    this.scriptRuntime = options.scriptRuntime ?? new RustProcessScriptRuntime(options.scriptRuntimeBinaryPath);
    this.logger = resolveLogger(options.logger);
    const baseCacheNamespace = normalizedBaseUrl(this.baseUrl);
    const gameKeyHash = sha256HexSync(this.gameKey);
    const userScope = clean(options.userId) ?? "anonymous";
    this.legacySnapshotCacheKey = `gamealgo:v1:snapshot:${baseCacheNamespace}:${this.gameKey.slice(0, 16)}`;
    this.snapshotCacheKey = options.cacheKey ?? `gamealgo:v1:snapshot:${baseCacheNamespace}:${gameKeyHash}:${userScope}`;
    this.attributionAckCacheKey = `gamealgo:v1:attribution:${baseCacheNamespace}:${gameKeyHash}:${userScope}`;
    this.contextIdentifierAckCacheKey = `gamealgo:v1:context-identifier:${baseCacheNamespace}:${gameKeyHash}:${userScope}`;
    this.userIdKey = `gamealgo:v1:identity:${baseCacheNamespace}:${gameKeyHash}:user-id`;
    this.userCreatedAtKey = `gamealgo:v1:identity:${baseCacheNamespace}:${gameKeyHash}:created-at`;
    this.userCreatedLocalAtKey = `gamealgo:v1:identity:${baseCacheNamespace}:${gameKeyHash}:created-local-at`;
    this.config = new GameAlgoConfigReader(() => this.snapshot);
    this.tracker = new GameAlgoEventTracker({
      uploadEvents: (events) => this.uploadEvents(events),
      platform: this.platform,
      sdkVersion: this.sdkVersion,
      appVersion: this.appVersion,
      timezone: this.timezone,
      isDebug: this.isDebug,
      flushIntervalMs: options.eventFlushIntervalMs ?? 30000,
      maxBatchSize: options.eventMaxBatchSize ?? 100,
      queueLimit: options.eventQueueLimit ?? 1000,
      now: this.now,
      storage: this.storage,
      persistenceKey: `gamealgo:v1:event-queue:${baseCacheNamespace}:${gameKeyHash}:${userScope}`,
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

  dda(key: string, options: GameAlgoDDAOptions = {}): GameAlgoDDAController {
    const strategy = clean(key);
    if (!strategy) throw new Error("DDA strategy key is required");
    const existing = this.ddaControllers.get(strategy);
    if (existing) return existing;
    const identityScope = this.currentIdentity?.userId ?? "anonymous";
    const storageKey = `gamealgo:v1:dda:${normalizedBaseUrl(this.baseUrl)}:${sha256HexSync(this.gameKey)}:${identityScope}:${strategy}`;
    const controller = new GameAlgoDDAController(this.executor(strategy), this.storage, storageKey, options, this.logger);
    this.ddaControllers.set(strategy, controller);
    return controller;
  }

  async userIdentity(explicitUserId?: string): Promise<GameAlgoUserIdentity> {
    await this.migrateLegacyIdentity();
    const cleanExplicit = clean(explicitUserId);

    if (cleanExplicit) {
      if (this.currentIdentity?.userId === cleanExplicit) return this.currentIdentity;
      const existing = clean(await this.storage?.getItem(this.userIdKey));
      const existingCreatedAt = clean(await this.storage?.getItem(this.userCreatedAtKey));
      const existingCreatedLocalAt = clean(await this.storage?.getItem(this.userCreatedLocalAtKey));
      const createdAt = existing === cleanExplicit && existingCreatedAt ? existingCreatedAt : new Date(this.now()).toISOString();
      this.currentIdentity = {
        userId: cleanExplicit,
        userCreatedAt: createdAt,
        userCreatedLocalAt: existing === cleanExplicit && existingCreatedLocalAt
          ? existingCreatedLocalAt
          : localTimestamp(Date.parse(createdAt)),
      };
      await this.storage?.setItem(this.userIdKey, this.currentIdentity.userId);
      await this.storage?.setItem(this.userCreatedAtKey, this.currentIdentity.userCreatedAt);
      await this.storage?.setItem(this.userCreatedLocalAtKey, this.currentIdentity.userCreatedLocalAt);
      return this.currentIdentity;
    }
    if (this.currentIdentity) return this.currentIdentity;

    const existing = clean(await this.storage?.getItem(this.userIdKey));
    if (existing) {
      const existingCreatedAt = clean(await this.storage?.getItem(this.userCreatedAtKey)) ?? new Date(this.now()).toISOString();
      const existingCreatedLocalAt = clean(await this.storage?.getItem(this.userCreatedLocalAtKey)) ?? localTimestamp(Date.parse(existingCreatedAt));
      this.currentIdentity = {
        userId: existing,
        userCreatedAt: existingCreatedAt,
        userCreatedLocalAt: existingCreatedLocalAt,
      };
      await this.storage?.setItem(this.userCreatedAtKey, existingCreatedAt);
      await this.storage?.setItem(this.userCreatedLocalAtKey, existingCreatedLocalAt);
      return this.currentIdentity;
    }

    this.currentIdentity = {
      userId: randomId(),
      userCreatedAt: new Date(this.now()).toISOString(),
      userCreatedLocalAt: localTimestamp(this.now()),
    };
    await this.storage?.setItem(this.userIdKey, this.currentIdentity.userId);
    await this.storage?.setItem(this.userCreatedAtKey, this.currentIdentity.userCreatedAt);
    await this.storage?.setItem(this.userCreatedLocalAtKey, this.currentIdentity.userCreatedLocalAt);
    return this.currentIdentity;
  }

  async configureAdjustServerCallbackParams(
    setCallbackParam: (key: string, value: string) => void | Promise<void>,
    explicitUserId?: string,
  ): Promise<void> {
    if (typeof setCallbackParam !== "function") {
      throw new Error("callback parameter setter is required");
    }
    const identity = await this.userIdentity(explicitUserId);
    await setCallbackParam("gamealgo_user_id", identity.userId);
    await setCallbackParam("gamealgo_user_created_at", identity.userCreatedAt);
  }

  async fetchConfig(options: FetchConfigOptions = {}): Promise<ConfigResponse> {
    const identity = await this.userIdentity(options.userId);
    const userCreatedAt = clean(options.userCreatedAt) ?? identity.userCreatedAt;
    const userCreatedLocalAt = clean(options.userCreatedLocalAt)
      ?? (clean(options.userCreatedAt) ? localTimestamp(Date.parse(userCreatedAt)) : identity.userCreatedLocalAt);
    const createdLocalAt = localTimestamp(this.now());
    const accountUserId = clean(options.accountUserId) ?? this.accountUserId;
    const accountUserCreatedAt = clean(options.accountUserCreatedAt) ?? this.accountUserCreatedAt;
    this.logUserId(identity.userId);
    this.tracker.identify(identity.userId, options.sessionId, userCreatedAt, accountUserId);
    const platform = options.platform ?? this.platform;
    const sdkVersion = options.sdkVersion ?? this.sdkVersion;
    const appVersion = options.appVersion ?? this.appVersion;
    const experimentIntegrationVersion = normalizeExperimentIntegrationVersion(
      options.experimentIntegrationVersion ?? this.experimentIntegrationVersion,
    );
    const sessionId = clean(options.sessionId) ?? this.tracker.currentSessionId();
    const isDebug = options.isDebug ?? this.isDebug;
    const device = {
      ...defaultDeviceContext(),
      ...(options.device ?? {}),
      ...(options.deviceId ? { deviceId: options.deviceId } : {}),
    };
    const cacheKey = JSON.stringify({
      userId: identity.userId,
      userCreatedAt,
      userCreatedLocalAt,
      accountUserId,
      accountUserCreatedAt,
      sessionId,
      platform,
      sdkVersion,
      appVersion,
      experimentIntegrationVersion,
      deviceId: options.deviceId,
      timezone: options.timezone ?? this.timezone,
      device,
      isDebug,
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
          userCreatedLocalAt,
          accountUserId,
          accountUserCreatedAt,
          createdLocalAt,
          sessionId,
          platform,
          sdkVersion,
          appVersion,
          experimentIntegrationVersion,
          timezone: options.timezone ?? this.timezone,
          device,
          isDebug,
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

  private async fetchScriptFile(script: ConfigFileRef): Promise<ConfigFileResponse> {
    const versionId = clean(script.versionId);
    if (!versionId) throw new Error(`script versionId is required: ${script.name}`);
    if (!clean(script.url)) throw new Error(`script url is required: ${script.name}@${versionId}`);
    if (!/^sha256:[a-f0-9]{64}$/i.test(script.hash)) throw new Error(`script hash is invalid: ${script.name}@${versionId}`);
    const scriptUrl = new URL(script.url, this.baseUrl);
    const response = await this.request(scriptUrl, { method: "GET" });
    const content = await response.text();
    await verifyScriptHash(content, script.hash);
    await this.scriptRuntime.prepare?.(content);
    const file = {
      name: scriptCacheKey(script),
      content,
      contentType: response.headers.get("content-type") ?? script.contentType ?? "application/octet-stream",
      etag: response.headers.get("etag") ?? undefined,
    };
    const configFiles = new Map(this.snapshot.configFiles);
    configFiles.set(file.name, file);
    this.snapshot = {
      ...this.snapshot,
      configFiles,
      updatedAt: this.now(),
    };
    await this.persistSnapshot();
    this.log(`script loaded: ${script.name}${script.versionId ? ` (${script.versionId})` : ""}`);
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
      createdLocalAt: event.createdLocalAt ?? localTimestamp(event.timestamp ? Date.parse(event.timestamp) : this.now()),
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

  async setAttribution(input: UserAttributionInput): Promise<UserAttributionResponse> {
    const provider = clean(input.provider);
    if (!provider) throw new Error("provider is required");
    const identity = await this.userIdentity(input.userId);
    const platform = input.platform ?? this.platform;
    const attribution = normalizeAttribution(input.attribution);
    const status = normalizeAttributionStatus(provider, clean(input.status), attribution);
    const attributedAt = clean(input.attributedAt);
    const attributionHash = clean(input.attributionHash) ?? await sha256(stableStringify({
      platform,
      provider,
      status,
      attribution,
      attributedAt: attributedAt ?? "",
    }));
    const ackKey = `${this.attributionAckCacheKey}:${provider}`;
    if (attributionHash && await this.storage?.getItem(ackKey) === attributionHash) {
      this.log(`attribution already synced: provider=${provider}`);
      return { ok: true, accepted: 0, attributionHash };
    }

    const response = await this.requestJson<UserAttributionResponse>(this.url("/v1/attribution"), {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify({
        userId: identity.userId,
        userCreatedAt: clean(input.userCreatedAt) ?? identity.userCreatedAt,
        sessionId: clean(input.sessionId) ?? this.tracker.currentSessionId(),
        contextId: clean(input.contextId) ?? this.snapshot.config?.contextId,
        platform,
        provider,
        status,
        attribution,
        attributedAt,
        attributionHash,
      }),
    });
    if (response.attributionHash) {
      await this.storage?.setItem(ackKey, response.attributionHash);
    }
    this.log(`attribution synced: provider=${provider}, accepted=${response.accepted}`);
    return response;
  }

  async setAdjustAdid(value: string | null, observedAt?: string): Promise<ContextIdentifierResponse> {
    return this.setContextIdentifier("adjust_adid", value, observedAt);
  }

  async setFirebaseAppInstanceId(value: string | null, observedAt?: string): Promise<ContextIdentifierResponse> {
    return this.setContextIdentifier("firebase_app_instance_id", value, observedAt);
  }

  async setGoogleAdvertisingId(value: string | null, observedAt?: string): Promise<ContextIdentifierResponse> {
    return this.setContextIdentifier("gaid", value, observedAt);
  }

  private async setContextIdentifier(
    identifierType: ContextIdentifierType,
    value: string | null,
    observedAt?: string,
  ): Promise<ContextIdentifierResponse> {
    if (!this.snapshot.config && this.readyPromise) await this.readyPromise;
    const contextId = clean(this.snapshot.config?.contextId);
    if (!contextId) throw new Error("config context is not ready");

    const identity = await this.userIdentity();
    const identifierValue = normalizeContextIdentifier(identifierType, value);
    const identifierHash = await sha256(JSON.stringify({ identifierType, identifierValue }));
    const ackKey = `${this.contextIdentifierAckCacheKey}:${identifierType}`;
    if (await this.storage?.getItem(ackKey) === identifierHash) {
      this.log(`context identifier already synced: type=${identifierType}`);
      return { ok: true, accepted: 0, identifierHash };
    }

    const response = await this.requestJson<ContextIdentifierResponse>(this.url("/v1/context-identifiers"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        userId: identity.userId,
        sessionId: this.tracker.currentSessionId(),
        contextId,
        platform: this.platform,
        identifierType,
        identifierValue,
        observedAt: clean(observedAt) ?? new Date(this.now()).toISOString(),
        identifierHash,
      }),
    });
    await this.storage?.setItem(ackKey, response.identifierHash);
    this.log(`context identifier synced: type=${identifierType}, accepted=${response.accepted}`);
    return response;
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
    this.tracker.identify(identity.userId, options.sessionId, userCreatedAt, clean(options.accountUserId) ?? this.accountUserId);
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

    const configFileNames = Array.isArray(preload) ? preload : config.configFiles.map((file) => file.name);
    const scriptRefs = Array.isArray(preload)
      ? []
      : [...new Map(config.experiments.flatMap((experiment) => experiment.script ? [[scriptCacheKey(experiment.script), experiment.script] as const] : [])).values()];
    const preloadLabels = [
      ...new Set([
        ...configFileNames,
        ...scriptRefs.map((script) => script.versionId ? `${script.name}@${script.versionId}` : script.name),
      ]),
    ];
    if (preloadLabels.length === 0) {
      this.log("no config files to preload");
    } else {
      this.log(`preloading config files: ${preloadLabels.sort().join(", ")}`);
    }
    await Promise.all([
      ...[...new Set(configFileNames)].map((name) => this.fetchConfigFile(name)),
      ...scriptRefs.map((script) => this.fetchScriptFile(script)),
    ]);
    for (const experiment of config.experiments) {
      const script = experiment.script;
      if (script && this.snapshot.configFiles.has(scriptCacheKey(script))) {
        this.log(`script ready: ${experiment.key} -> ${script.name}${script.versionId ? ` (${script.versionId})` : ""}`);
      }
    }
    if (preloadLabels.length > 0) {
      this.log("all config files loaded");
    }
    this.tracker.setAssignments(config.experiments);
    this.logAssignments(config.experiments, "experiment");
  }

  private async loadPersistedSnapshot(): Promise<void> {
    if (!this.storage) return;
    let raw = await this.storage.getItem(this.snapshotCacheKey);
    if (!raw && this.legacySnapshotCacheKey !== this.snapshotCacheKey) {
      raw = await this.storage.getItem(this.legacySnapshotCacheKey);
      if (raw) {
        await this.storage.setItem(this.snapshotCacheKey, raw);
        await this.storage.removeItem?.(this.legacySnapshotCacheKey);
      }
    }
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

  private async migrateLegacyIdentity(): Promise<void> {
    if (this.didMigrateLegacyIdentity || !this.storage) return;
    this.didMigrateLegacyIdentity = true;
    const current = await this.storage.getItem(this.userIdKey);
    if (clean(current)) return;
    const legacyUserId = clean(await this.storage.getItem("gamealgo_user_id"));
    if (!legacyUserId) return;
    const legacyCreatedAt = clean(await this.storage.getItem("gamealgo_user_created_at"));
    const legacyCreatedLocalAt = clean(await this.storage.getItem("gamealgo_user_created_local_at"));
    await this.storage.setItem(this.userIdKey, legacyUserId);
    if (legacyCreatedAt) await this.storage.setItem(this.userCreatedAtKey, legacyCreatedAt);
    if (legacyCreatedLocalAt) await this.storage.setItem(this.userCreatedLocalAtKey, legacyCreatedLocalAt);
    await this.storage.removeItem?.("gamealgo_user_id");
    await this.storage.removeItem?.("gamealgo_user_created_at");
    await this.storage.removeItem?.("gamealgo_user_created_local_at");
  }

  private url(path: string): URL {
    const url = new URL(this.baseUrl);
    const basePath = url.pathname.replace(/\/+$/, "");
    const endpointPath = path.replace(/^\/+/, "");
    url.pathname = `${basePath}/${endpointPath}`;
    url.search = "";
    url.hash = "";
    return url;
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
  private readonly storage?: GameAlgoStorage;
  private readonly persistenceKey?: string;
  private readonly restorePromise: Promise<void>;

  private userId?: string;
  private sessionId = randomId();
  private contextId?: string;
  private timezone?: string;
  private userCreatedAt?: string;
  private accountUserId?: string;
  private isDebug: boolean;
  private currentExperiments: Record<string, string> = {};
  private queue: GameEvent[] = [];
  private retryBatch: GameEvent[] = [];
  private flushTimer?: ReturnType<typeof setInterval>;
  private flushing = false;
  private sessionStartMs?: number;
  private consecutiveFailures = 0;
  private hasPersistedQueue = false;

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
    storage?: GameAlgoStorage;
    persistenceKey?: string;
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
    this.storage = options.storage;
    this.persistenceKey = clean(options.persistenceKey);
    this.restorePromise = this.restorePersistedQueue();
  }

  identify(userId: string, sessionId?: string, userCreatedAt?: string, accountUserId?: string): void {
    if (clean(userId)) this.userId = userId;
    if (clean(sessionId)) this.sessionId = sessionId!;
    if (clean(userCreatedAt)) this.userCreatedAt = userCreatedAt;
    if (clean(accountUserId)) this.accountUserId = accountUserId;
  }

  newSession(sessionId = randomId()): void {
    const previousSessionId = this.sessionId;
    this.retryBatch = this.retryBatch.filter((event) => clean(event.contextId) || event.sessionId !== previousSessionId);
    this.queue = this.queue.filter((event) => clean(event.contextId) || event.sessionId !== previousSessionId);
    this.sessionId = sessionId;
    this.contextId = undefined;
    this.sessionStartMs = this.now();
    if (this.hasPersistedQueue) void this.persistPendingQueue();
  }

  currentSessionId(): string {
    return this.sessionId;
  }

  setContextId(contextId: string): void {
    const resolved = clean(contextId);
    this.contextId = resolved;
    if (!resolved) return;
    const bind = (event: GameEvent) => (
      !clean(event.contextId) && event.sessionId === this.sessionId
        ? { ...event, contextId: resolved }
        : event
    );
    this.retryBatch = this.retryBatch.map(bind);
    this.queue = this.queue.map(bind);
    if (this.hasPersistedQueue) void this.persistPendingQueue();
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
      createdLocalAt: options.createdLocalAt ?? localTimestamp(options.timestamp ? Date.parse(options.timestamp) : this.now()),
      accountUserId: this.accountUserId,
      payload: normalizePayload(payload),
    });
    return true;
  }

  trackEvent(type: string, payload: JsonValue = {}, options: TrackEventOptions = {}): boolean {
    return this.track(type.startsWith("_") ? type : `_${type}`, payload, options);
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
    await this.restorePromise;
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
          this.consecutiveFailures = 0;
          if (this.hasPersistedQueue) await this.persistPendingQueue();
        } catch (error) {
          this.retryBatch = uploadBatch;
          this.consecutiveFailures += 1;
          if (this.consecutiveFailures >= 3) {
            this.hasPersistedQueue = true;
            try {
              await this.persistPendingQueue();
            } catch {
              // Preserve the transport error; persistence is a recovery aid.
            }
          }
          throw error;
        }
      }
      if (this.hasPersistedQueue) await this.clearPersistedQueue();
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

  private async restorePersistedQueue(): Promise<void> {
    if (!this.storage || !this.persistenceKey) return;
    const raw = await this.storage.getItem(this.persistenceKey);
    if (!raw) return;
    try {
      const restored = raw
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => JSON.parse(line) as GameEvent)
        .filter((event) => clean(event.eventId) && clean(event.userId) && clean(event.sessionId) && clean(event.eventType));
      const existingIds = new Set([...this.retryBatch, ...this.queue].map((event) => event.eventId));
      this.retryBatch = [...restored.filter((event) => !existingIds.has(event.eventId)), ...this.retryBatch];
      this.hasPersistedQueue = restored.length > 0;
    } catch {
      await this.storage.removeItem?.(this.persistenceKey);
    }
  }

  private async persistPendingQueue(): Promise<void> {
    if (!this.storage || !this.persistenceKey) return;
    const pending = [...this.retryBatch, ...this.queue];
    if (pending.length === 0) {
      await this.clearPersistedQueue();
      return;
    }
    await this.storage.setItem(this.persistenceKey, pending.map((event) => JSON.stringify(event)).join("\n"));
  }

  private async clearPersistedQueue(): Promise<void> {
    if (this.storage && this.persistenceKey) await this.storage.removeItem?.(this.persistenceKey);
    this.hasPersistedQueue = false;
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

    const scriptFile = snapshot.configFiles.get(scriptCacheKey(assignment.script));
    if (!scriptFile) {
      this.log(`execute skipped: script not loaded: ${assignment.key} -> ${assignment.script.name}${assignment.script.versionId ? ` (${assignment.script.versionId})` : ""}`);
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

type RustRuntimeResponse = {
  status?: string;
  result?: JsonValue;
  message?: string;
  prepared?: boolean;
};

type RustRuntimeRequest = {
  op: "prepare" | "execute";
  script: string;
  input?: GameAlgoScriptInput;
};

type PendingRustRequest = {
  request: RustRuntimeRequest;
  timeoutMs: number;
  resolve: (response: RustRuntimeResponse) => void;
  reject: (error: Error) => void;
};

type ActiveRustRequest = PendingRustRequest & {
  child: import("node:child_process").ChildProcessWithoutNullStreams;
  timeout: ReturnType<typeof setTimeout>;
};

export class RustProcessScriptRuntime implements GameAlgoScriptRuntime {
  private readonly binaryPath: string;
  private readonly processTimeoutMs: number;
  private readonly prepareTimeoutMs: number;
  private child?: import("node:child_process").ChildProcessWithoutNullStreams;
  private stdoutBuffer = "";
  private stdoutBytes = 0;
  private readonly queue: PendingRustRequest[] = [];
  private active?: ActiveRustRequest;
  private pumpPromise?: Promise<void>;
  private closed = false;

  constructor(binaryPath?: string, processTimeoutMs = 2000) {
    this.binaryPath = clean(binaryPath) ?? defaultRustRuntimeBinaryPath();
    this.processTimeoutMs = processTimeoutMs;
    // Parsing a 10 MB script is a load operation, not a strategy execution.
    this.prepareTimeoutMs = Math.max(processTimeoutMs, 10_000);
  }

  async prepare(script: string): Promise<void> {
    const response = await this.request({ op: "prepare", script }, this.prepareTimeoutMs);
    this.assertOk(response, "GameAlgo Rust runtime script preparation failed");
  }

  async execute(script: string, input: GameAlgoScriptInput): Promise<JsonValue> {
    const response = await this.request({ op: "execute", script, input }, this.processTimeoutMs);
    this.assertOk(response, "GameAlgo Rust runtime failed");
    return normalizeJsonValue(response.result);
  }

  close(): void {
    this.closed = true;
    const error = new Error("GameAlgo Rust runtime was closed");
    for (const pending of this.queue.splice(0)) pending.reject(error);
    if (this.child) {
      const child = this.child;
      this.failWorker(child, error);
      child.kill("SIGKILL");
    }
  }

  private assertOk(response: RustRuntimeResponse, fallback: string): void {
    if (response.status !== "ok") {
      throw new Error(response.message ?? fallback);
    }
  }

  private request(request: RustRuntimeRequest, timeoutMs: number): Promise<RustRuntimeResponse> {
    if (typeof process === "undefined" || !process.versions?.node) {
      return Promise.reject(new Error(
        "The canonical GameAlgo Rust runtime is unavailable in this environment; provide scriptRuntime explicitly",
      ));
    }
    if (this.closed) return Promise.reject(new Error("GameAlgo Rust runtime was closed"));
    return new Promise<RustRuntimeResponse>((resolve, reject) => {
      this.queue.push({ request, timeoutMs, resolve, reject });
      void this.pump();
    });
  }

  private async pump(): Promise<void> {
    if (this.pumpPromise) return this.pumpPromise;
    this.pumpPromise = (async () => {
      while (this.queue.length > 0 && !this.closed) {
        const pending = this.queue.shift()!;
        try {
          await this.ensureWorker();
          const response = await this.send(pending, pending.timeoutMs);
          pending.resolve(response);
        } catch (error) {
          pending.reject(error instanceof Error ? error : new Error(String(error)));
          // The current request is lost, but later queued requests can use a
          // freshly started worker. The Rust cache is rebuilt by prepare/execute.
          if (this.child) this.failWorker(this.child, error instanceof Error ? error : new Error(String(error)));
        }
      }
    })().finally(() => {
      this.pumpPromise = undefined;
      if (this.queue.length > 0 && !this.closed) void this.pump();
    });
    return this.pumpPromise;
  }

  private async ensureWorker(): Promise<void> {
    if (this.child && !this.child.killed) return;
    const { spawn } = await import("node:child_process");
    const child = spawn(this.binaryPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.stdoutBuffer = "";
    this.stdoutBytes = 0;
    // The cache worker should not keep a short-lived CLI/test process alive.
    // A server with an active event loop still keeps using the same worker.
    child.unref();
    child.stdin.unref?.();
    child.stdout.unref?.();
    child.stderr.unref?.();
    child.stdout.on("data", (chunk: Buffer) => this.handleStdout(child, chunk));
    child.stderr.on("data", () => undefined);
    child.once("error", (error) => {
      this.failWorker(child, new Error(`Unable to start GameAlgo Rust runtime at ${this.binaryPath}: ${error.message}`));
    });
    child.once("close", (code, signal) => {
      if (this.child !== child) return;
      this.failWorker(child, new Error(
        `GameAlgo Rust runtime exited with ${code ?? "unknown"}${signal ? ` (${signal})` : ""}`,
      ));
    });
  }

  private send(pending: PendingRustRequest, timeoutMs: number): Promise<RustRuntimeResponse> {
    const child = this.child;
    if (!child) return Promise.reject(new Error("GameAlgo Rust runtime worker is unavailable"));
    return new Promise<RustRuntimeResponse>((resolve, reject) => {
      const timeout = setTimeout(() => {
        const error = new Error(`GameAlgo Rust runtime request exceeded ${timeoutMs}ms`);
        child.kill("SIGKILL");
        this.failWorker(child, error);
      }, timeoutMs);
      this.active = { ...pending, child, timeout, resolve, reject };
      const encoded = `${JSON.stringify(pending.request)}\n`;
      child.stdin.write(encoded, (error) => {
        if (error) this.failWorker(child, error);
      });
    });
  }

  private handleStdout(child: import("node:child_process").ChildProcessWithoutNullStreams, chunk: Buffer): void {
    if (this.child !== child) return;
    this.stdoutBytes += chunk.length;
    if (this.stdoutBytes > 512 * 1024) {
      const error = new Error("GameAlgo Rust runtime response exceeds 524288 bytes");
      child.kill("SIGKILL");
      this.failWorker(child, error);
      return;
    }
    this.stdoutBuffer += chunk.toString("utf8");
    let newlineIndex = this.stdoutBuffer.indexOf("\n");
    while (newlineIndex >= 0) {
      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (!line) {
        newlineIndex = this.stdoutBuffer.indexOf("\n");
        continue;
      }
      if (!this.active) {
        this.failWorker(child, new Error("GameAlgo Rust runtime returned an unsolicited response"));
        return;
      }
      let response: RustRuntimeResponse;
      try {
        response = JSON.parse(line) as RustRuntimeResponse;
      } catch (error) {
        this.failWorker(child, new Error(
          `Invalid GameAlgo Rust runtime response: ${error instanceof Error ? error.message : String(error)}`,
        ));
        return;
      }
      const active = this.active;
      this.active = undefined;
      clearTimeout(active.timeout);
      active.resolve(response);
      newlineIndex = this.stdoutBuffer.indexOf("\n");
    }
  }

  private failWorker(child: import("node:child_process").ChildProcessWithoutNullStreams, error: Error): void {
    if (this.child !== child) return;
    this.child = undefined;
    this.stdoutBuffer = "";
    this.stdoutBytes = 0;
    const active = this.active;
    this.active = undefined;
    if (active) {
      clearTimeout(active.timeout);
      active.reject(error);
    }
  }
}

function defaultRustRuntimeBinaryPath(): string {
  const configured = typeof process !== "undefined" ? clean(process.env.GAMEALGO_SCRIPT_RUNTIME_BIN) : undefined;
  if (configured) return configured;
  const profile = typeof process !== "undefined" && process.env.NODE_ENV === "production" ? "release" : "debug";
  return decodeURIComponent(new URL(`../../runtime/rust/target/${profile}/gamealgo-script-runtime`, import.meta.url).pathname);
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

export function createEvent(input: Omit<GameEvent, "eventId" | "timestamp" | "createdLocalAt"> & {
  eventId?: string;
  timestamp?: string;
  createdLocalAt?: string;
}): GameEvent {
  const timestamp = input.timestamp ?? new Date().toISOString();
  return {
    ...input,
    eventId: input.eventId ?? randomId(),
    timestamp,
    createdLocalAt: input.createdLocalAt ?? localTimestamp(Date.parse(timestamp)),
    payload: normalizePayload(input.payload ?? {}),
  };
}

function localTimestamp(timestamp: number): string {
  const date = new Date(Number.isFinite(timestamp) ? timestamp : Date.now());
  const offsetMinutes = -date.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? "+" : "-";
  const absoluteOffset = Math.abs(offsetMinutes);
  const offset = `${sign}${pad(Math.floor(absoluteOffset / 60))}:${pad(absoluteOffset % 60)}`;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
    + `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${String(date.getMilliseconds()).padStart(3, "0")}${offset}`;
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

function scriptCacheKey(script: ConfigFileRef): string {
  const versionId = clean(script.versionId);
  if (!versionId) throw new Error(`script versionId is required: ${script.name}`);
  return `script:${versionId}`;
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

function normalizedBaseUrl(url: URL): string {
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

function clean(value: string | undefined | null): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function normalizeContextIdentifier(type: ContextIdentifierType, value: string | null): string | null {
  const cleaned = clean(value);
  if (!cleaned) return null;
  if (type === "gaid" && /^0{8}-0{4}-0{4}-0{4}-0{12}$/i.test(cleaned)) return null;
  return cleaned;
}

function normalizeExperimentIntegrationVersion(value: number | undefined): number {
  const version = value ?? 0;
  if (!Number.isSafeInteger(version) || version < 0) {
    throw new Error("experimentIntegrationVersion must be a non-negative integer");
  }
  return version;
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
  if (!/^sha256:[a-f0-9]{64}$/i.test(expected)) {
    throw new Error("Script hash must use sha256:<64 lowercase hex characters>");
  }
  const actual = await sha256(content);
  if (!actual) throw new Error("SHA-256 is unavailable in this runtime");
  if (actual.toLowerCase() !== expected.toLowerCase()) {
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

function normalizeAttribution(value: Record<string, JsonValue>): Record<string, JsonValue> {
  const normalized = normalizeJsonValue(value);
  if (!normalized || typeof normalized !== "object" || Array.isArray(normalized)) {
    throw new Error("attribution must be an object");
  }
  return normalized as Record<string, JsonValue>;
}

function normalizeAttributionStatus(provider: string, rawStatus: string | undefined, attribution: Record<string, JsonValue>): string {
  const status = canonicalAttributionValue(rawStatus);
  if (status === "organic") return "organic";
  if (isUnknownAttributionValue(status)) return "unknown";
  if (provider.toLowerCase() === "adjust") {
    const network = canonicalAttributionField(attribution, "network");
    const trackerName = canonicalAttributionField(attribution, "tracker_name") || canonicalAttributionField(attribution, "trackerName");
    const trackerToken = canonicalAttributionField(attribution, "tracker_token") || canonicalAttributionField(attribution, "trackerToken");
    if ([network, trackerName, trackerToken].some(isUnknownAttributionValue)) return "unknown";
    if ([network, trackerName, trackerToken].some((value) => value === "organic")) return "organic";
  }
  return rawStatus ?? "attributed";
}

function canonicalAttributionField(attribution: Record<string, JsonValue>, field: string): string {
  const value = attribution[field];
  return typeof value === "string" ? canonicalAttributionValue(value) : "";
}

function canonicalAttributionValue(value: string | undefined): string {
  return (value ?? "").trim().toLowerCase().replace(/[_-]+/g, " ").replace(/\s+/g, " ");
}

function isUnknownAttributionValue(value: string): boolean {
  return value === "unknown" || value === "unattr" || value === "unattributed" || value === "no user consent";
}

function stableStringify(value: JsonValue): string {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(",")}]`;
  }
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
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
