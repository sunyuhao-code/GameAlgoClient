import type {
  ConfigFileRef,
  ConfigFileResponse,
  ConfigResponse,
  ContextIdentifierResponse,
  ContextIdentifierType,
  EventBatchResponse,
  EventQuotaConfig,
  EventPayload,
  EventPayloadValue,
  ExperimentAssignment,
  FetchConfigOptions,
  GameAlgoExecutionResult,
  GameAlgoLogger,
  GameAlgoFetch,
  GameAlgoHttpRequest,
  GameAlgoHttpResponse,
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
import { encodeUtf8 } from "./utf8.ts";
import { parseHttpBaseUrl, resolveHttpUrl, type HttpBaseUrl } from "./http-url.ts";
import type { GameAlgoDDAOptions } from "./types.ts";
import { GameAlgoDDAController } from "./dda.ts";
import { IncrementalEventQueue } from "./event-queue-store.ts";

type RefreshOptions = FetchConfigOptions & {
  preloadConfigFiles?: boolean | string[];
};

type InternalClientOptions = GameAlgoRestClientOptions & {
  autoStart?: boolean;
  autoSessionHeartbeat?: boolean;
};

type SyncBackupStorage = GameAlgoStorage & {
  getSyncItem?(key: string): string | undefined;
  setSyncItem?(key: string, value: string): boolean;
  removeSyncItem?(key: string): void;
};

type ActiveSessionCheckpoint = {
  sessionId: string;
  contextId: string;
  userId: string;
  accountUserId?: string;
  isDebug: boolean;
  sessionDurationMs: number;
  timestamp: string;
  createdLocalAt: string;
  ended: boolean;
};

const WEB_SESSION_CHECKPOINT_MIN_MS = 15_000;
const WEB_SESSION_CHECKPOINT_INTERVAL_MS = 15_000;
const WEB_SESSION_HEARTBEAT_INITIAL_MS = 30_000;
const WEB_SESSION_HEARTBEAT_INTERVAL_MS = 120_000;
const MAX_SYNC_SESSION_END_MIRROR = 5;

const STANDARD_EVENT_TYPES = new Set([
  "session_end", "level_start", "level_end", "ad_view", "purchase", "milestone",
]);

export class GameAlgoApiError extends Error {
  readonly status: number;
  readonly code?: string;
  readonly retryAfterMs?: number;

  constructor(status: number, message: string, code?: string, retryAfterMs?: number) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryAfterMs = retryAfterMs;
  }
}

export class GameAlgoRestClient {
  private readonly baseUrl: HttpBaseUrl;
  private readonly gameKey: string;
  private readonly sdkVersion: string;
  private readonly appVersion?: string;
  private readonly accountUserId?: string;
  private readonly accountUserCreatedAt?: string;
  private readonly experimentIntegrationVersion: number;
  private readonly platform: Platform;
  private readonly timezone: string;
  private readonly isDebug: boolean;
  private readonly fetchImpl: GameAlgoFetch;
  private readonly now: () => number;
  private readonly storage?: GameAlgoStorage;
  private readonly scriptRuntime: GameAlgoScriptRuntime;
  private readonly logger?: (message: string) => void;
  private readonly snapshotCacheKey: string;
  private readonly legacySnapshotCacheKey: string;
  private readonly attributionAckCacheKey: string;
  private readonly userIdKey: string;
  private readonly userCreatedAtKey: string;
  private readonly userCreatedLocalAtKey: string;
  private readonly initialIsOldUser?: boolean;
  private readonly oldUserStates = new Map<string, Promise<boolean | undefined>>();
  private cachedConfig: { value: ConfigResponse; expiresAt: number; cacheKey: string } | null = null;
  private snapshot: GameAlgoSnapshot = { configFiles: new Map(), updatedAt: 0 };
  private currentIdentity: GameAlgoUserIdentity | null = null;
  private pendingAnonymousIdentity: Promise<GameAlgoUserIdentity> | null = null;
  private readyPromise: Promise<void> | null = null;
  private didLogUserId = false;
  private legacyMigrationPromise: Promise<void> | null = null;
  private readonly ddaControllers = new Map<string, GameAlgoDDAController>();
  readonly config: GameAlgoConfigReader;
  readonly tracker: GameAlgoEventTracker;

  constructor(options: GameAlgoRestClientOptions) {
    if (!options.baseUrl) throw new Error("baseUrl is required");
    if (!options.gameKey) throw new Error("gameKey is required");
    if (options.isOldUser !== undefined && typeof options.isOldUser !== "boolean") {
      throw new Error("isOldUser must be a boolean");
    }
    this.initialIsOldUser = options.isOldUser;

    this.baseUrl = parseHttpBaseUrl(options.baseUrl);
    this.gameKey = options.gameKey;
    this.sdkVersion = options.sdkVersion ?? "1.0.0";
    this.appVersion = options.appVersion;
    this.accountUserId = clean(options.accountUserId);
    this.accountUserCreatedAt = clean(options.accountUserCreatedAt);
    this.experimentIntegrationVersion = normalizeExperimentIntegrationVersion(options.experimentIntegrationVersion);
    // `rest` was the historical Maker platform value. JavaScript callers can
    // still pass it at runtime even though it is no longer in the public type.
    this.platform = (options.platform as unknown) === "rest" ? "maker" : (options.platform ?? "maker");
    this.timezone = clean(options.timezone) ?? defaultTimezone();
    this.isDebug = options.isDebug ?? false;
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch?.bind(globalThis);
    if (!this.fetchImpl) throw new Error("An HTTP transport is required");
    this.now = options.now ?? Date.now;
    this.storage = options.storage;
    this.scriptRuntime = options.scriptRuntime ?? { execute() { throw new Error("Remote scripts are unavailable in this host"); } };
    this.logger = resolveLogger(options.logger);
    const baseCacheNamespace = normalizedBaseUrl(this.baseUrl);
    const gameKeyHash = sha256HexSync(this.gameKey);
    const userScope = clean(options.userId) ?? "anonymous";
    this.legacySnapshotCacheKey = `gamealgo:v1:snapshot:${baseCacheNamespace}:${this.gameKey.slice(0, 16)}`;
    this.snapshotCacheKey = options.cacheKey ?? `gamealgo:v1:snapshot:${baseCacheNamespace}:${gameKeyHash}:${userScope}`;
    this.attributionAckCacheKey = `gamealgo:v1:attribution:${baseCacheNamespace}:${gameKeyHash}:${userScope}`;
    this.userIdKey = `gamealgo:v1:identity:${baseCacheNamespace}:${gameKeyHash}:user-id`;
    this.userCreatedAtKey = `gamealgo:v1:identity:${baseCacheNamespace}:${gameKeyHash}:created-at`;
    this.userCreatedLocalAtKey = `gamealgo:v1:identity:${baseCacheNamespace}:${gameKeyHash}:created-local-at`;
    this.config = new GameAlgoConfigReader(() => this.snapshot);
    const internalOptions = options as InternalClientOptions;
    this.tracker = new GameAlgoEventTracker({
      uploadEvents: (events) => this.uploadEvents(events),
      reportDiagnostic: (diagnostic) => this.reportSdkDiagnostic(diagnostic),
      platform: this.platform,
      sdkVersion: this.sdkVersion,
      appVersion: this.appVersion,
      timezone: this.timezone,
      isDebug: this.isDebug,
      flushIntervalMs: options.eventFlushIntervalMs ?? 30000,
      maxBatchSize: options.eventMaxBatchSize ?? 100,
      maxBatchBytes: options.eventMaxBatchBytes,
      queueLimit: options.eventQueueLimit ?? 1000,
      persistOnEnqueue: options.eventPersistOnEnqueue ?? false,
      autoSessionHeartbeat: internalOptions.autoSessionHeartbeat,
      now: this.now,
      storage: this.storage,
      persistenceKey: `gamealgo:v1:event-queue:${baseCacheNamespace}:${gameKeyHash}:${userScope}`,
      onAdIdentityState: (state, count) => {
        try { this.log(`ad_view identity ${state}: count=${count}`); } catch { /* Diagnostics cannot block telemetry. */ }
      },
    });
    if (internalOptions.autoStart !== false) {
      this.readyPromise = this.initialize(options);
      // Games may read local defaults without awaiting startup; keep an offline
      // initialization failure observable through waitForReady, not unhandled.
      void this.readyPromise.catch(() => undefined);
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

    if (!this.pendingAnonymousIdentity) {
      this.pendingAnonymousIdentity = (async () => {
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

        const created: GameAlgoUserIdentity = {
          userId: randomId(),
          userCreatedAt: new Date(this.now()).toISOString(),
          userCreatedLocalAt: localTimestamp(this.now()),
        };
        await this.storage?.setItem(this.userIdKey, created.userId);
        await this.storage?.setItem(this.userCreatedAtKey, created.userCreatedAt);
        await this.storage?.setItem(this.userCreatedLocalAtKey, created.userCreatedLocalAt);
        this.currentIdentity = created;
        return created;
      })().finally(() => {
        this.pendingAnonymousIdentity = null;
      });
    }
    return this.pendingAnonymousIdentity;
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

  protected defaultDeviceContext(): Record<string, JsonValue> {
    return defaultDeviceContext();
  }

  /** Platform hook for a fresh server context, with the identity that created it. */
  protected onConfigReady(_config: ConfigResponse, _identity: { userId: string; sessionId: string; isDebug: boolean }): void {}

  /** Apply live delivery controls before binding a context can start an urgent upload. */
  protected onConfigReceived(_config: ConfigResponse, _identity: { userId: string; sessionId: string; isDebug: boolean }): void {}

  /** Resolve a first-install identity before any Context is attached to events. */
  protected async resolveConfigIdentity(_config: ConfigResponse, identity: GameAlgoUserIdentity): Promise<GameAlgoUserIdentity> { return identity; }

  protected async persistResolvedIdentity(identity: GameAlgoUserIdentity): Promise<void> {
    if (this.currentIdentity && this.currentIdentity.userId !== identity.userId) {
      const first = await this.oldUserState(this.currentIdentity.userId);
      await this.oldUserState(identity.userId, first);
    }
    await this.storage?.setItem(this.userIdKey, identity.userId);
    await this.storage?.setItem(this.userCreatedAtKey, identity.userCreatedAt);
    await this.storage?.setItem(this.userCreatedLocalAtKey, identity.userCreatedLocalAt);
    this.currentIdentity = identity;
  }

  /** A second delivery channel may still need data already acknowledged by HTTP. */
  protected useAttributionAckCache(): boolean { return true; }

  /** Hosts may recover a failed initial request without refreshing on resume. */
  protected recoverInitialConfig(_error: unknown, _options: RefreshOptions): Promise<void> | undefined { return undefined; }

  private oldUserState(userId: string, initialValue = this.initialIsOldUser): Promise<boolean | undefined> {
    let pending = this.oldUserStates.get(userId);
    if (!pending) {
      pending = (async () => {
        const key = `${this.userIdKey}:is-old-user:${userId}`;
        const stored = await this.storage?.getItem(key);
        if (stored === "true" || stored === "false") return stored === "true";
        if (initialValue !== undefined) {
          await this.storage?.setItem(key, String(initialValue));
        }
        return initialValue;
      })();
      this.oldUserStates.set(userId, pending);
    }
    return pending;
  }

  async fetchConfig(options: FetchConfigOptions = {}): Promise<ConfigResponse> {
    const identity = await this.userIdentity(options.userId);
    const isOldUser = await this.oldUserState(identity.userId);
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
    const experimentIntegrationVersion = options.experimentIntegrationVersion !== undefined
      ? normalizeExperimentIntegrationVersion(options.experimentIntegrationVersion)
      : this.experimentIntegrationVersion;
    const sessionId = clean(options.sessionId) ?? this.tracker.currentSessionId();
    const isDebug = options.isDebug ?? this.isDebug;
    const device = {
      ...this.defaultDeviceContext(),
      ...(options.device ?? {}),
      ...(options.deviceId ? { deviceId: options.deviceId } : {}),
    };
    const cacheKey = JSON.stringify({
      userId: identity.userId,
      isOldUser,
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
          isOldUser,
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
          ...(this.platform === "wechat" && clean(options.wechatLoginCode)
            ? { wechatLoginCode: clean(options.wechatLoginCode) } : {}),
        }),
      });
      const resolvedIdentity = await this.resolveConfigIdentity(config, identity);
      if (sessionId === this.tracker.currentSessionId()) {
        this.onConfigReceived(config, { userId: resolvedIdentity.userId, sessionId, isDebug });
      }
      this.tracker.bindSessionContext(sessionId, config.contextId);
      if (isBrowserHost(this.platform) && clean(config.contextId)) {
        try { this.log("context ready"); } catch { /* Optional diagnostics. */ }
      }
      if (sessionId !== this.tracker.currentSessionId()) return config;
      const resolvedUserCreatedAt = clean(options.userCreatedAt) ?? resolvedIdentity.userCreatedAt;
      const resolvedUserCreatedLocalAt = clean(options.userCreatedLocalAt)
        ?? (clean(options.userCreatedAt) ? localTimestamp(Date.parse(resolvedUserCreatedAt)) : resolvedIdentity.userCreatedLocalAt);
      const resolvedCacheKey = resolvedIdentity.userId === identity.userId
        && resolvedUserCreatedAt === userCreatedAt
        && resolvedUserCreatedLocalAt === userCreatedLocalAt
        ? cacheKey
        : JSON.stringify({
            userId: resolvedIdentity.userId,
            isOldUser,
            userCreatedAt: resolvedUserCreatedAt,
            userCreatedLocalAt: resolvedUserCreatedLocalAt,
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
      this.cachedConfig = {
        value: config,
        cacheKey: resolvedCacheKey,
        expiresAt: this.now() + Math.max(Number(config.ttlSeconds) || 0, 0) * 1000,
      };
      this.tracker.setEventQuota(config.eventQuota);
      this.tracker.setAssignments(config.experiments);
      this.snapshot = {
        ...this.snapshot,
        config,
        updatedAt: this.now(),
        userId: resolvedIdentity.userId,
      };
      // Apply live operational controls before optional cache I/O: a delayed or
      // failed snapshot write must not leave a disabled native bridge active.
      this.onConfigReady(config, { userId: resolvedIdentity.userId, sessionId, isDebug });
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

  async fetchConfigFile(name: string, options?: { expectedHash?: string; persist?: boolean }): Promise<ConfigFileResponse> {
    const safeName = normalizeFileName(name);
    const existing = this.snapshot.configFiles.get(safeName);
    if (options?.expectedHash && existing && etagMatchesHash(existing.etag, options.expectedHash)) {
      this.log(`config file cache hit: ${existing.name}`);
      return existing;
    }
    const headers: Record<string, string> = {};
    if (existing?.etag) headers["If-None-Match"] = existing.etag;
    let response: GameAlgoHttpResponse;
    try {
      response = await this.request(this.url(`/v1/config-files/${encodeURIComponent(safeName)}`), {
        method: "GET",
        ...(Object.keys(headers).length ? { headers } : {}),
      });
    } catch (error) {
      if (error instanceof GameAlgoApiError && error.status === 304 && existing) {
        this.log(`config file not modified: ${existing.name}`);
        return existing;
      }
      throw error;
    }
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
    if (options?.persist !== false) {
      await this.persistSnapshot();
    }
    this.log(`config file loaded: ${file.name} (${file.contentType})`);
    return file;
  }

  private async fetchScriptFile(script: ConfigFileRef, options?: { persist?: boolean }): Promise<ConfigFileResponse> {
    const versionId = clean(script.versionId);
    if (!versionId) throw new Error(`script versionId is required: ${script.name}`);
    if (!clean(script.url)) throw new Error(`script url is required: ${script.name}@${versionId}`);
    if (!/^sha256:[a-f0-9]{64}$/i.test(script.hash)) throw new Error(`script hash is invalid: ${script.name}@${versionId}`);
    const key = scriptCacheKey(script);
    const existing = this.snapshot.configFiles.get(key);
    if (existing) {
      try {
        await verifyScriptHash(existing.content, script.hash);
        await this.scriptRuntime.prepare?.(existing.content);
        this.log(`script cache hit: ${script.name} (${versionId})`);
        return existing;
      } catch {
        // Cached content does not match expected hash; re-fetch below.
      }
    }
    const scriptUrl = resolveHttpUrl(script.url, this.baseUrl);
    const response = await this.request(scriptUrl, { method: "GET" });
    const content = await response.text();
    await verifyScriptHash(content, script.hash);
    await this.scriptRuntime.prepare?.(content);
    const file = {
      name: key,
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
    if (options?.persist !== false) {
      await this.persistSnapshot();
    }
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

    const response = await this.requestJson<EventBatchResponse>(this.url("/v1/events/batch"), {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify({ events: normalizedEvents }),
    });
    if (normalizedEvents.some(event => event.eventType === "ad_view")) {
      const stored = (response as EventBatchResponse & { stored?: number }).stored;
      try {
        if (response.skipped) this.log(`ad_view direct upload skipped: count=${response.skipped} tapdbAttempted=${response.tapdbAttempted ?? 0}`);
        else this.log(`ad_view upload ack: accepted=${response.accepted} stored=${typeof stored === "number" ? stored : "unknown"} rejected=${response.rejected?.length ?? 0}`);
      } catch { /* A logger failure must not turn an HTTP ACK into a retry. */ }
    }
    return response;
  }

  private async reportSdkDiagnostic(diagnostic: Record<string, unknown>): Promise<void> {
    await this.requestJson(this.url("/v1/diagnostics/sdk"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(diagnostic),
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
    if (this.useAttributionAckCache() && attributionHash && await this.storage?.getItem(ackKey) === attributionHash) {
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
    if (response.attributionHash && !response.skipped) {
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

  async setIdfa(value: string | null, observedAt?: string): Promise<ContextIdentifierResponse> {
    return this.setContextIdentifier("idfa", value, observedAt);
  }

  async setIdfv(value: string | null, observedAt?: string): Promise<ContextIdentifierResponse> {
    return this.setContextIdentifier("idfv", value, observedAt);
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
    let stage = "identity";
    try {
      const identityStartedAt = this.now();
      if (isBrowserHost(this.platform)) {
        try { this.log("identity restore started"); } catch { /* Optional diagnostics. */ }
      }
      const identity = await this.userIdentity(options.userId);
      const userCreatedAt = clean(options.userCreatedAt) ?? identity.userCreatedAt;
      this.logUserId(identity.userId);
      this.tracker.identify(identity.userId, options.sessionId, userCreatedAt, clean(options.accountUserId) ?? this.accountUserId);
      if (isBrowserHost(this.platform)) {
        try { this.log(`identity ready: elapsedMs=${Math.max(0, this.now() - identityStartedAt)}`); } catch { /* Optional diagnostics. */ }
      }
      this.tracker.markSessionStarted();
      stage = "event-queue-restore";
      await this.tracker.waitForRestore();
      stage = "snapshot-restore";
      await this.loadPersistedSnapshot();
      const refreshOptions = { ...options, userId: identity.userId, userCreatedAt,
        sessionId: this.tracker.currentSessionId(), forceRefresh: true };
      try {
        stage = "config";
        await this.refresh(refreshOptions);
      } catch (error) {
        const recovery = this.recoverInitialConfig(error, refreshOptions);
        if (!this.snapshot.config) {
          if (recovery) await recovery;
          else {
            this.log(`config fetch failed: ${errorMessage(error)}`);
            throw error;
          }
        } else {
          this.log(`config fetch failed, using cached snapshot: ${errorMessage(error)}`);
          void recovery?.catch(() => undefined);
        }
      }
    } catch (error) {
      if (isBrowserHost(this.platform)) {
        try { this.log(`initialization failed: stage=${stage} errorType=${error instanceof Error ? error.name : typeof error}`); } catch { /* Optional diagnostics. */ }
      }
      throw error;
    }
  }

  protected async refresh(options: RefreshOptions): Promise<void> {
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
    const configFileHashes = new Map(config.configFiles.map((file) => [file.name, file.hash]));
    const uniqueFileNames = [...new Set(configFileNames)];
    if (uniqueFileNames.length > 0 || scriptRefs.length > 0) {
      await Promise.all([
        ...uniqueFileNames.map((name) => this.fetchConfigFile(name, { expectedHash: configFileHashes.get(name), persist: false })),
        ...scriptRefs.map((script) => this.fetchScriptFile(script, { persist: false })),
      ]);
      await this.persistSnapshot();
    }
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

  protected async persistSnapshot(): Promise<void> {
    if (!this.storage) return;
    await this.storage.setItem(this.snapshotCacheKey, JSON.stringify({
      config: this.snapshot.config,
      configFiles: [...this.snapshot.configFiles.values()],
      updatedAt: this.snapshot.updatedAt,
      userId: this.snapshot.userId,
    }));
  }

  private migrateLegacyIdentity(): Promise<void> {
    if (!this.storage) return Promise.resolve();
    if (!this.legacyMigrationPromise) {
      this.legacyMigrationPromise = (async () => {
        const current = await this.storage!.getItem(this.userIdKey);
        if (clean(current)) return;
        const legacyUserId = clean(await this.storage!.getItem("gamealgo_user_id"));
        if (!legacyUserId) return;
        const legacyCreatedAt = clean(await this.storage!.getItem("gamealgo_user_created_at"));
        const legacyCreatedLocalAt = clean(await this.storage!.getItem("gamealgo_user_created_local_at"));
        await this.storage!.setItem(this.userIdKey, legacyUserId);
        if (legacyCreatedAt) await this.storage!.setItem(this.userCreatedAtKey, legacyCreatedAt);
        if (legacyCreatedLocalAt) await this.storage!.setItem(this.userCreatedLocalAtKey, legacyCreatedLocalAt);
        await this.storage!.removeItem?.("gamealgo_user_id");
        await this.storage!.removeItem?.("gamealgo_user_created_at");
        await this.storage!.removeItem?.("gamealgo_user_created_local_at");
      })().catch((error) => {
        this.legacyMigrationPromise = null;
        throw error;
      });
    }
    return this.legacyMigrationPromise;
  }

  private url(path: string): string {
    return `${normalizedBaseUrl(this.baseUrl)}/${path.replace(/^\/+/, "")}`;
  }

  private async requestJson<T>(url: string, init: GameAlgoHttpRequest): Promise<T> {
    const response = await this.request(url, init);
    return response.json() as Promise<T>;
  }

  protected async request(url: string, init: GameAlgoHttpRequest): Promise<GameAlgoHttpResponse> {
    const response = await this.fetchImpl(url, {
      ...init,
      headers: { ...init.headers, "X-GameAlgo-Key": this.gameKey },
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
  private readonly reportDiagnostic?: (diagnostic: Record<string, unknown>) => Promise<void>;
  private readonly platform: Platform;
  private readonly sdkVersion: string;
  private readonly appVersion?: string;
  private readonly maxBatchSize: number;
  private readonly maxBatchBytes?: number;
  private readonly queueLimit: number;
  private readonly persistOnEnqueue: boolean;
  private readonly sessionHeartbeatEnabled: boolean;
  private readonly flushIntervalMs: number;
  private readonly now: () => number;
  private readonly storage?: GameAlgoStorage;
  private readonly persistenceKey?: string;
  private readonly syncSessionEndKey?: string;
  private readonly sessionCheckpointKey?: string;
  private readonly milestonePersistenceKey?: string;
  private readonly milestoneRestorePromise: Promise<void>;
  private readonly restorePromise: Promise<void>;
  private sessionCheckpointForegroundMs = 0;
  private sessionCheckpointWritten = false;
  private sessionCheckpointEnded = false;
  private sessionHeartbeatEmitted = false;
  private sessionHeartbeatLastForegroundMs = 0;

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
  private inflightBatch: GameEvent[] = [];
  private readonly urgentEventIds = new Set<string>();
  private readonly urgentFlushes = new Map<string, Promise<EventBatchResponse[]>>();
  // A real Web ad can close before asynchronous identity restoration finishes.
  // Hold its immutable close envelope; never invent a temporary player ID.
  private readonly pendingIdentityAds: Array<{ payload: JsonValue; options: TrackEventOptions }> = [];
  private readonly pendingIdentitySessionEnds: Array<Omit<GameEvent, "userId">> = [];
  private timersStopped = false;
  private readonly onAdIdentityState?: (state: "buffered" | "released", count: number) => void;
  private restored = false;
  private flushTimer?: ReturnType<typeof setInterval>;
  private activeFlush?: Promise<EventBatchResponse[]>;
  private sessionStartMs?: number;
  private sessionDurationTimer?: ReturnType<typeof setInterval>;
  private sampledForegroundTimeMs = 0;
  private sessionForegroundStartMs = 0;
  private sessionDurationSampleAt = 0;
  private sessionDurationVisible?: () => boolean;
  private sessionDurationWasVisible = true;
  private sessionHasEnd = false;
  private sessionHasSnapshot = false;
  private consecutiveFailures = 0;
  private nextAutoFlushAt = 0;
  private hasPersistedQueue = false;
  private queueRestorePending = false;
  private incrementalQueue?: IncrementalEventQueue;
  private queuePersistActive?: Promise<void>;
  private queuePersistRevision = 0;
  private readonly customCounts = new Map<string, { total: number; byType: Map<string, number> }>();
  private readonly ordinaryCounts = new Map<string, number>();
  private eventQuota?: EventQuotaConfig;
  private readonly diagnosticKeys = new Set<string>();
  private diagnosticCount = 0;
  private readonly reachedMilestoneKeys = new Set<string>();
  private readonly pendingMilestoneKeys = new Set<string>();
  private milestonePersistPromise: Promise<void> = Promise.resolve();
  private queuePersistPromise: Promise<void> = Promise.resolve();

  constructor(options: {
    uploadEvents: (events: GameEvent[]) => Promise<EventBatchResponse>;
    reportDiagnostic?: (diagnostic: Record<string, unknown>) => Promise<void>;
    platform: Platform;
    sdkVersion: string;
    appVersion?: string;
    timezone?: string;
    isDebug: boolean;
    flushIntervalMs: number;
    maxBatchSize: number;
    maxBatchBytes?: number;
    queueLimit: number;
    persistOnEnqueue?: boolean;
    autoSessionHeartbeat?: boolean;
    now: () => number;
    storage?: GameAlgoStorage;
    persistenceKey?: string;
    onAdIdentityState?: (state: "buffered" | "released", count: number) => void;
  }) {
    this.uploadEvents = options.uploadEvents;
    this.reportDiagnostic = options.reportDiagnostic;
    this.platform = options.platform;
    this.sdkVersion = options.sdkVersion;
    this.appVersion = options.appVersion;
    this.timezone = clean(options.timezone) ?? defaultTimezone();
    this.isDebug = options.isDebug;
    this.flushIntervalMs = options.flushIntervalMs;
    this.maxBatchSize = Math.max(1, Math.min(options.maxBatchSize, 100));
    this.maxBatchBytes = Number.isFinite(options.maxBatchBytes) && Number(options.maxBatchBytes) > 0
      ? Math.floor(Number(options.maxBatchBytes))
      : undefined;
    this.queueLimit = Math.max(options.queueLimit, this.maxBatchSize);
    this.persistOnEnqueue = options.persistOnEnqueue ?? false;
    this.sessionHeartbeatEnabled = isBrowserHost(this.platform) && options.autoSessionHeartbeat !== false;
    this.now = options.now;
    this.onAdIdentityState = options.onAdIdentityState;
    this.sessionStartMs = this.now();
    this.sessionDurationSampleAt = this.sessionStartMs;
    if (isBrowserHost(this.platform)) {
      this.sessionDurationTimer = setInterval(() => this.sampleSessionDuration(), 1000);
      this.sessionDurationTimer.unref?.();
    }
    this.storage = options.storage;
    this.persistenceKey = clean(options.persistenceKey);
    this.syncSessionEndKey = this.persistenceKey && isBrowserHost(this.platform)
      ? `${this.persistenceKey}:sync-session-ends` : undefined;
    this.sessionCheckpointKey = this.persistenceKey && isBrowserHost(this.platform)
      ? `${this.persistenceKey}:session-checkpoint` : undefined;
    if (this.persistOnEnqueue && this.storage && this.persistenceKey) {
      this.incrementalQueue = new IncrementalEventQueue(this.storage, this.persistenceKey);
    }
    this.milestonePersistenceKey = this.persistenceKey ? `${this.persistenceKey}:milestones` : undefined;
    this.milestoneRestorePromise = this.restorePersistedMilestones();
    this.restorePromise = Promise.all([
      this.restorePersistedQueue().then(() => this.restoreSyncSessionEndsAndCheckpoint()),
      this.milestoneRestorePromise,
    ]).then(() => { this.restored = true; });
  }

  identify(userId: string, sessionId?: string, userCreatedAt?: string, accountUserId?: string): void {
    if (clean(userId)) this.userId = userId;
    if (clean(sessionId) && sessionId !== this.sessionId) {
      this.sessionId = sessionId!;
      this.sessionHasEnd = false;
      this.sessionHasSnapshot = false;
      this.sessionCheckpointForegroundMs = 0;
      this.sessionCheckpointWritten = false;
      this.sessionCheckpointEnded = false;
      this.sessionHeartbeatEmitted = false;
      this.sessionHeartbeatLastForegroundMs = 0;
      this.sessionStartMs = this.now();
      this.resetSessionDuration(this.sessionStartMs);
    }
    if (clean(userCreatedAt)) this.userCreatedAt = userCreatedAt;
    if (clean(accountUserId)) this.accountUserId = accountUserId;
    if (clean(this.userId)) {
      const pending = this.pendingIdentityAds.splice(0);
      if (pending.length) {
        try { this.onAdIdentityState?.("released", pending.length); } catch { /* Optional diagnostics. */ }
      }
      for (const event of pending) this.track("ad_view", event.payload, event.options);
      const ends = this.pendingIdentitySessionEnds.splice(0);
      for (const event of ends) this.enqueueSessionEndSnapshot({ ...event, userId: this.userId!,
        accountUserId: event.accountUserId ?? this.accountUserId });
    }
  }

  /** First-install only: unbound events keep their IDs/times while identity settles. */
  async resolveInitialUserId(previousUserId: string, userId: string, userCreatedAt: string): Promise<void> {
    await this.restorePromise;
    if (!clean(previousUserId) || !clean(userId) || previousUserId === userId) return;
    if (this.userId !== previousUserId || this.contextId) throw new Error("Initial identity is already bound");
    const resolve = (event: GameEvent): GameEvent => !clean(event.contextId) && event.userId === previousUserId
      ? { ...event, userId } : event;
    this.queue = this.queue.map(resolve);
    this.retryBatch = this.retryBatch.map(resolve);
    // Milestone keys include their user; only pending keys may be reassigned.
    const milestones = [...this.pendingMilestoneKeys];
    this.pendingMilestoneKeys.clear();
    for (const key of milestones) {
      const parts = JSON.parse(key);
      if (parts[1] === previousUserId) parts[1] = userId;
      this.pendingMilestoneKeys.add(JSON.stringify(parts));
    }
    this.identify(userId, undefined, userCreatedAt, this.accountUserId);
    this.hasPersistedQueue = true;
    await this.persistPendingQueue();
  }

  newSession(sessionId = randomId()): void {
    sessionId = clean(sessionId) ?? randomId();
    if (sessionId === this.sessionId) return;
    const previousSessionId = this.sessionId;
    const endedAt = this.now();
    const userId = clean(this.userId);
    if (userId && !this.sessionHasEnd) {
      // SDK-owned boundaries bypass gameplay quotas, just like Godot's native
      // session marker. The envelope is captured before switching ownership.
      const endEvent: GameEvent = {
        eventId: randomId(), contextId: this.contextId ?? "", userId,
        sessionId: previousSessionId, eventType: "session_end", isDebug: this.isDebug,
        timestamp: new Date(endedAt).toISOString(), createdLocalAt: localTimestamp(endedAt),
        accountUserId: this.accountUserId,
        payload: { reason: "new_session", sessionDurationMs: this.sessionDuration(endedAt) },
      };
      this.enqueue(endEvent);
      this.mirrorSyncSessionEnd(endEvent);
    }
    this.persistSessionCheckpoint(true);
    this.sessionId = sessionId;
    this.sessionHasEnd = false;
    this.sessionHasSnapshot = false;
    this.sessionCheckpointForegroundMs = 0;
    this.sessionCheckpointWritten = false;
    this.sessionCheckpointEnded = false;
    this.sessionHeartbeatEmitted = false;
    this.sessionHeartbeatLastForegroundMs = 0;
    this.ordinaryCounts.delete(`pending:${previousSessionId}`);
    this.diagnosticKeys.clear();
    this.diagnosticCount = 0;
    this.pendingMilestoneKeys.clear();
    this.contextId = undefined;
    this.eventQuota = undefined;
    this.sessionStartMs = endedAt;
    this.resetSessionDuration(endedAt);
    this.hasPersistedQueue = true;
    void this.persistPendingQueue().catch(() => undefined);
    if (isBrowserHost(this.platform)) void this.flushUrgent().catch(() => undefined);
    void this.flush().catch(() => undefined);
  }

  currentSessionId(): string {
    return this.sessionId;
  }

  async waitForRestore(): Promise<void> {
    await this.restorePromise;
  }

  setContextId(contextId: string): void {
    this.bindSessionContext(this.sessionId, contextId);
  }

  bindSessionContext(sessionId: string, contextId: string): void {
    const resolved = clean(contextId);
    if (sessionId === this.sessionId) this.contextId = resolved;
    if (!resolved) return;
    this.mergeCustomCountBucket(`pending:${sessionId}`, `context:${resolved}`);
    this.mergeOrdinaryCountBucket(`pending:${sessionId}`, `context:${resolved}`);
    const bind = (event: GameEvent) => (
      !clean(event.contextId) && event.sessionId === sessionId
        ? { ...event, contextId: resolved }
        : event
    );
    this.retryBatch = this.retryBatch.map(bind);
    this.queue = this.queue.map(bind);
    this.bindSyncSessionEnds(sessionId, resolved);
    if (sessionId === this.sessionId) {
      if (this.sessionHasEnd || this.hasQueuedSessionEnd(sessionId)) this.persistSessionCheckpoint(true);
      else this.persistSessionCheckpoint(false);
    }
    this.rememberBoundMilestones(resolved);
    if (this.hasPersistedQueue) void this.persistPendingQueue().catch(() => undefined);
    if (isBrowserHost(this.platform)) void this.flushUrgent().catch(() => undefined);
    if ([...this.retryBatch, ...this.queue].some((event) => event.sessionId === sessionId && event.eventType === "session_end")) {
      void this.flush().catch(() => undefined);
    }
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

  setEventQuota(quota?: EventQuotaConfig): void {
    const limit = Math.floor(Number(quota?.ordinaryEventLimit));
    this.eventQuota = quota?.mode === "enforce" && Number.isSafeInteger(limit) && limit >= 0
      ? {
          ...quota,
          ordinaryEventLimit: limit,
          exemptEventTypes: Array.isArray(quota.exemptEventTypes)
            ? quota.exemptEventTypes.filter((value): value is string => typeof value === "string" && value.length > 0)
            : [],
        }
      : undefined;
  }

  markSessionStarted(): void {
    // An early lifecycle snapshot already exposed this session's clock origin.
    if (isBrowserHost(this.platform) && this.sessionHasSnapshot) return;
    this.sessionStartMs = this.now();
    this.resetSessionDuration(this.sessionStartMs);
  }

  /** Sampled web foreground milliseconds since tracker creation. Pure memory read. */
  getForegroundTimeMs(): number {
    return Math.round(this.sampledForegroundTimeMs);
  }

  /** @internal Read live visibility on every sample; no resume notification is required. */
  setSessionDurationVisibility(visible: () => boolean): void {
    this.sessionDurationVisible = visible;
    this.sessionDurationWasVisible = visible();
  }

  /** @internal Lifecycle callbacks can observe a boundary, but never gate future samples. */
  observeSessionDurationVisibility(): void {
    if (isBrowserHost(this.platform)) this.sampleSessionDuration();
  }

  private resetSessionDuration(now: number): void {
    if (isBrowserHost(this.platform)) this.sampleSessionDuration(now);
    this.sessionForegroundStartMs = this.getForegroundTimeMs();
  }

  private sampleSessionDuration(now = this.now()): void {
    if (!Number.isFinite(now)) return;
    const visible = this.sessionDurationVisible?.() ?? true;
    if (this.sessionDurationWasVisible) {
      // Never catch up a suspended WebView. Short tails are captured at an
      // explicit boundary, while each observation contributes at most 1s.
      this.sampledForegroundTimeMs += Math.min(1000, Math.max(0, now - this.sessionDurationSampleAt));
    }
    this.sessionDurationWasVisible = visible;
    this.sessionDurationSampleAt = now;
    if (visible && isBrowserHost(this.platform)) this.updateSessionCheckpointAndHeartbeat(now);
  }

  private updateSessionCheckpointAndHeartbeat(now: number): void {
    if (this.timersStopped || this.sessionHasEnd) return;
    const userId = clean(this.userId);
    const contextId = clean(this.contextId);
    if (!userId || !contextId) return;
    const durationMs = Math.max(0, this.getForegroundTimeMs() - this.sessionForegroundStartMs);
    if (durationMs < WEB_SESSION_CHECKPOINT_MIN_MS) return;

    if (this.sessionHeartbeatEnabled) {
      const due = (!this.sessionHeartbeatEmitted && durationMs >= WEB_SESSION_HEARTBEAT_INITIAL_MS)
        || (this.sessionHeartbeatEmitted && durationMs - this.sessionHeartbeatLastForegroundMs >= WEB_SESSION_HEARTBEAT_INTERVAL_MS);
      if (due) {
        const heartbeat: GameEvent = {
          eventId: randomId(),
          contextId,
          userId,
          sessionId: this.sessionId,
          eventType: "session_end",
          isDebug: this.isDebug,
          timestamp: new Date(now).toISOString(),
          createdLocalAt: localTimestamp(now),
          accountUserId: this.accountUserId,
          payload: { reason: "heartbeat", sessionDurationMs: durationMs },
        };
        this.enqueue(heartbeat, true);
        this.mirrorSyncSessionEnd(heartbeat);
        this.sessionHeartbeatEmitted = true;
        this.sessionHeartbeatLastForegroundMs = durationMs;
        this.persistSessionCheckpoint(true, now);
        return;
      }
    }

    if (!this.sessionCheckpointWritten
      || durationMs - this.sessionCheckpointForegroundMs >= WEB_SESSION_CHECKPOINT_INTERVAL_MS) {
      this.persistSessionCheckpoint(false, now);
    }
  }

  private sessionDuration(now: number): number {
    if (!isBrowserHost(this.platform)) return Math.max(0, now - (this.sessionStartMs ?? now));
    this.sampleSessionDuration(now);
    return this.getForegroundTimeMs() - this.sessionForegroundStartMs;
  }

  track(eventType: string, payload: JsonValue = {}, options: TrackEventOptions = {}): boolean {
    const userId = clean(options.userId ?? this.userId);
    if (!userId) {
      if (!isBrowserHost(this.platform) || eventType !== "ad_view" || options.userId !== undefined) return false;
      const timestamp = options.timestamp ?? new Date(this.now()).toISOString();
      this.pendingIdentityAds.push({
        payload: normalizePayload(payload),
        options: {
          ...options,
          sessionId: clean(options.sessionId) ?? this.sessionId,
          isDebug: options.isDebug ?? this.isDebug,
          timestamp,
          createdLocalAt: options.createdLocalAt ?? localTimestamp(Date.parse(timestamp)),
        },
      });
      if (this.pendingIdentityAds.length > this.queueLimit) this.pendingIdentityAds.shift();
      try { this.onAdIdentityState?.("buffered", this.pendingIdentityAds.length); } catch { /* Optional diagnostics. */ }
      return true;
    }
    const resolvedSessionId = clean(options.sessionId) ?? this.sessionId;
    const contextId = clean(options.contextId ?? (resolvedSessionId === this.sessionId ? this.contextId : undefined));

    const eventTimeMs = options.timestamp ? Date.parse(options.timestamp) : this.now();
    const resolvedIsDebug = options.isDebug ?? this.isDebug;
    const normalizedPayload = normalizePayload(payload);
    const milestone = eventType === "milestone"
      ? this.prepareMilestone(userId, contextId, resolvedIsDebug, normalizedPayload, eventTimeMs)
      : undefined;
    if (milestone?.duplicate) return false;
    if (!this.consumeOrdinaryEventQuota(eventType, contextId, resolvedSessionId, false)) return false;
    if (!this.consumeCustomEventQuota(eventType, contextId, resolvedSessionId)) return false;
    this.consumeOrdinaryEventQuota(eventType, contextId, resolvedSessionId, true);

    const trackedEvent: GameEvent = {
      eventId: randomId(),
      contextId: contextId ?? "",
      userId,
      sessionId: resolvedSessionId,
      eventType,
      isDebug: resolvedIsDebug,
      timestamp: options.timestamp ?? new Date(this.now()).toISOString(),
      createdLocalAt: options.createdLocalAt ?? localTimestamp(options.timestamp ? Date.parse(options.timestamp) : this.now()),
      accountUserId: this.accountUserId,
      payload: normalizedPayload,
    };
    this.enqueue(trackedEvent);
    if (eventType === "session_end" && resolvedSessionId === this.sessionId) {
      this.mirrorSyncSessionEnd(trackedEvent);
      this.sessionHeartbeatEmitted = true;
      this.sessionHeartbeatLastForegroundMs = Math.max(0, this.getForegroundTimeMs() - this.sessionForegroundStartMs);
      this.persistSessionCheckpoint(true);
    }
    if (milestone?.key) this.rememberMilestone(milestone.key, milestone.durable);
    if (isBrowserHost(this.platform) && eventType === "ad_view") {
      void this.flushUrgent().then(() => this.flush()).catch(() => undefined);
    } else if (isBrowserHost(this.platform) && eventType === "session_end") {
      void this.flushUrgent().catch(() => undefined);
    }
    return true;
  }

  private prepareMilestone(
    userId: string,
    contextId: string | undefined,
    isDebug: boolean,
    payload: EventPayload,
    eventTimeMs: number,
  ): { duplicate: boolean; key?: string; durable: boolean } {
    const registeredAtMs = this.userCreatedAt ? Date.parse(this.userCreatedAt) : Number.NaN;
    delete payload.elapsedSinceRegistrationMs;
    if (Number.isFinite(eventTimeMs) && Number.isFinite(registeredAtMs)) {
      payload.elapsedSinceRegistrationMs = Math.max(0, Math.floor(eventTimeMs - registeredAtMs));
    }

    const milestoneType = clean(typeof payload.milestoneType === "string" ? payload.milestoneType : undefined);
    const milestonePoint = clean(typeof payload.milestonePoint === "string" ? payload.milestonePoint : undefined);
    if (!milestoneType || !milestonePoint) return { duplicate: false, durable: false };

    const key = JSON.stringify([
      isDebug ? "debug" : "live",
      userId,
      milestoneType,
      milestonePoint,
    ]);
    const durable = Boolean(contextId);
    const keys = durable ? this.reachedMilestoneKeys : this.pendingMilestoneKeys;
    return { duplicate: keys.has(key), key, durable };
  }

  private rememberMilestone(key: string, durable: boolean): void {
    if (!durable) {
      this.pendingMilestoneKeys.add(key);
      return;
    }
    if (this.reachedMilestoneKeys.has(key)) return;
    this.reachedMilestoneKeys.add(key);
    void this.persistReachedMilestones();
  }

  private rememberBoundMilestones(contextId: string): void {
    let changed = false;
    for (const event of [...this.retryBatch, ...this.queue]) {
      if (event.contextId !== contextId || event.eventType !== "milestone") continue;
      const milestoneType = clean(typeof event.payload?.milestoneType === "string" ? event.payload.milestoneType : undefined);
      const milestonePoint = clean(typeof event.payload?.milestonePoint === "string" ? event.payload.milestonePoint : undefined);
      if (!milestoneType || !milestonePoint) continue;
      const key = JSON.stringify([
        event.isDebug ? "debug" : "live",
        event.userId,
        milestoneType,
        milestonePoint,
      ]);
      if (!this.reachedMilestoneKeys.has(key)) {
        this.reachedMilestoneKeys.add(key);
        changed = true;
      }
    }
    if (changed) void this.persistReachedMilestones();
  }

  private consumeCustomEventQuota(eventType: string, contextId: string | undefined, sessionId: string): boolean {
    if (STANDARD_EVENT_TYPES.has(eventType)) return true;
    const bucketKey = contextId ? `context:${contextId}` : `pending:${sessionId}`;
    const bucket = this.customCounts.get(bucketKey) ?? { total: 0, byType: new Map<string, number>() };
    const current = bucket.byType.get(eventType) ?? 0;
    let scope: string | undefined;
    let limit = 0;
    if (!bucket.byType.has(eventType) && bucket.byType.size >= 100) {
      scope = "distinct_event_types";
      limit = 100;
    } else if (current >= 1000) {
      scope = "context_event_type";
      limit = 1000;
    } else if (bucket.total >= 5000) {
      scope = "context_total";
      limit = 5000;
    }
    if (scope) {
      const observed = scope === "context_total"
        ? bucket.total + 1
        : scope === "distinct_event_types"
          ? bucket.byType.size + 1
          : current + 1;
      this.reportQuotaDiagnostic(eventType, sessionId, contextId, scope, limit, observed);
      return false;
    }
    bucket.total += 1;
    bucket.byType.set(eventType, current + 1);
    this.customCounts.set(bucketKey, bucket);
    pruneMapLimit(this.customCounts, 64);
    return true;
  }

  private mergeCustomCountBucket(from: string, to: string): void {
    const pending = this.customCounts.get(from);
    if (!pending) return;
    const target = this.customCounts.get(to) ?? { total: 0, byType: new Map<string, number>() };
    target.total += pending.total;
    for (const [eventType, count] of pending.byType) target.byType.set(eventType, (target.byType.get(eventType) ?? 0) + count);
    this.customCounts.set(to, target);
    this.customCounts.delete(from);
    pruneMapLimit(this.customCounts, 64);
  }

  private consumeOrdinaryEventQuota(
    eventType: string,
    contextId: string | undefined,
    sessionId: string,
    consume: boolean,
  ): boolean {
    const quota = this.eventQuota;
    const exempt = eventType === "purchase"
      || eventType === "ad_view"
      || quota?.exemptEventTypes.includes(eventType);
    if (exempt) return true;
    const bucketKey = contextId ? `context:${contextId}` : `pending:${sessionId}`;
    const current = this.ordinaryCounts.get(bucketKey) ?? 0;
    if (quota && current >= quota.ordinaryEventLimit) {
      this.reportContextQuotaDiagnostic(eventType, sessionId, contextId, quota, current + 1);
      return false;
    }
    if (consume) {
      this.ordinaryCounts.set(bucketKey, current + 1);
      pruneMapLimit(this.ordinaryCounts, 64);
    }
    return true;
  }

  private mergeOrdinaryCountBucket(from: string, to: string): void {
    const pending = this.ordinaryCounts.get(from);
    if (pending === undefined) return;
    this.ordinaryCounts.set(to, (this.ordinaryCounts.get(to) ?? 0) + pending);
    this.ordinaryCounts.delete(from);
    pruneMapLimit(this.ordinaryCounts, 64);
  }

  private reportContextQuotaDiagnostic(
    eventType: string,
    sessionId: string,
    contextId: string | undefined,
    quota: EventQuotaConfig,
    observed: number,
  ): void {
    const key = `${contextId ?? `pending:${sessionId}`}\u0000context_event_quota`;
    if (!this.reportDiagnostic || this.diagnosticKeys.has(key) || this.diagnosticCount >= 10) return;
    this.diagnosticKeys.add(key);
    this.diagnosticCount += 1;
    const createdAt = new Date(this.now()).toISOString();
    const safeEventType = eventType.replace(/[;\r\n]/g, "_").slice(0, 96);
    void this.reportDiagnostic({
      diagnosticId: randomId(),
      userId: this.userId,
      sessionId,
      contextId,
      platform: this.platform,
      sdkVersion: this.sdkVersion,
      appVersion: this.appVersion,
      stage: "event_guard",
      status: "degraded",
      reasonCode: "context_event_quota_exceeded",
      reasonDetail: `eventType=${safeEventType};scope=context_total;limit=${quota.ordinaryEventLimit};observed=${observed};policyVersion=${quota.policyVersion};quotaDate=${quota.quotaDate};dropped=1`,
      createdAt,
      createdLocalAt: localTimestamp(this.now()),
      isDebug: this.isDebug,
    }).catch(() => undefined);
  }

  private reportQuotaDiagnostic(eventType: string, sessionId: string, contextId: string | undefined, scope: string, limit: number, observed: number): void {
    const key = `${sessionId}\u0000${eventType}\u0000${scope}`;
    if (!this.reportDiagnostic || this.diagnosticKeys.has(key) || this.diagnosticCount >= 10) return;
    this.diagnosticKeys.add(key);
    this.diagnosticCount += 1;
    const createdAt = new Date(this.now()).toISOString();
    const safeEventType = eventType.replace(/[;\r\n]/g, "_").slice(0, 96);
    void this.reportDiagnostic({
      diagnosticId: randomId(),
      userId: this.userId,
      sessionId,
      contextId,
      platform: this.platform,
      sdkVersion: this.sdkVersion,
      appVersion: this.appVersion,
      stage: "event_guard",
      status: "degraded",
      reasonCode: "custom_event_quota_exceeded",
      reasonDetail: `eventType=${safeEventType};scope=${scope};limit=${limit};observed=${observed};dropped=1`,
      createdAt,
      createdLocalAt: localTimestamp(this.now()),
      isDebug: this.isDebug,
    }).catch(() => undefined);
  }

  trackEvent(type: string, payload: JsonValue = {}, options: TrackEventOptions = {}): boolean {
    return this.track(type.startsWith("_") ? type : `_${type}`, payload, options);
  }

  trackSessionEnd(payload: JsonValue = {}): boolean {
    const merged = objectPayload(payload);
    if (this.sessionStartMs !== undefined) {
      merged.sessionDurationMs = this.sessionDuration(this.now());
    }
    return this.track("session_end", merged);
  }

  /** SDK lifecycle snapshot: retain the live session and bypass gameplay quotas. */
  trackSessionEndSnapshot(payload: JsonValue = {}): boolean {
    const userId = clean(this.userId);
    if (!userId && !isBrowserHost(this.platform)) return false;
    const occurredAt = this.now();
    const merged = objectPayload(payload);
    merged.sessionDurationMs = this.sessionDuration(occurredAt);
    this.sessionHasSnapshot = true;
    const event = {
      eventId: randomId(), contextId: this.contextId ?? "",
      sessionId: this.sessionId, eventType: "session_end", isDebug: this.isDebug,
      timestamp: new Date(occurredAt).toISOString(), createdLocalAt: localTimestamp(occurredAt),
      accountUserId: this.accountUserId, payload: normalizePayload(merged),
    };
    if (!userId) {
      this.pendingIdentitySessionEnds.push(event);
      if (this.pendingIdentitySessionEnds.length > this.queueLimit) this.pendingIdentitySessionEnds.shift();
    } else this.enqueueSessionEndSnapshot({ ...event, userId });
    return true;
  }

  private enqueueSessionEndSnapshot(event: GameEvent): void {
    this.hasPersistedQueue = true;
    this.enqueue(event, true);
    this.mirrorSyncSessionEnd(event);
    if (event.sessionId === this.sessionId) {
      this.sessionHeartbeatEmitted = true;
      this.sessionHeartbeatLastForegroundMs = Math.max(0, this.getForegroundTimeMs() - this.sessionForegroundStartMs);
      this.persistSessionCheckpoint(true);
    }
    if (!this.persistOnEnqueue) void this.persistPendingQueue().catch(() => undefined);
    if (isBrowserHost(this.platform)) void this.flushUrgent().catch(() => undefined);
  }

  trackLevelStart(payload: JsonValue = {}): boolean {
    return this.track("level_start", payload);
  }

  trackLevelEnd(payload: JsonValue = {}): boolean {
    return this.track("level_end", payload);
  }

  trackMilestone(milestoneType: string, milestonePoint: string, payload: JsonValue = {}): boolean {
    const merged = objectPayload(payload);
    merged.milestoneType = milestoneType;
    merged.milestonePoint = milestonePoint;
    return this.track("milestone", merged);
  }

  /** Track a registered placement; static fields are resolved by the server. */
  trackAdPlacement(adPlacementId: string, revenue: number, payload?: JsonValue): boolean;
  trackAdPlacement(adPlacementId: string, revenue: number, network?: string, payload?: JsonValue): boolean;
  trackAdPlacement(
    adPlacementId: string,
    revenue: number,
    networkOrPayload?: string | JsonValue,
    payload: JsonValue = {},
  ): boolean {
    if (typeof adPlacementId !== "string" || adPlacementId.length !== 36 || !/^gap_[a-f0-9]{32}$/.test(adPlacementId) || !Number.isFinite(revenue)) return false;
    const network = typeof networkOrPayload === "string" ? networkOrPayload : undefined;
    const merged = objectPayload(typeof networkOrPayload === "string" ? payload : (networkOrPayload ?? payload));
    delete merged.placement;
    delete merged.adType;
    delete merged.currency;
    merged.adPlacementId = adPlacementId;
    merged.revenue = revenue;
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

  flush(): Promise<EventBatchResponse[]> {
    if (this.activeFlush) return this.activeFlush;
    const operation = this.drain();
    this.activeFlush = operation;
    void operation.finally(() => {
      if (this.activeFlush === operation) this.activeFlush = undefined;
    }).catch(() => undefined);
    return operation;
  }

  private async drain(): Promise<EventBatchResponse[]> {
    await this.restorePromise;
    await this.milestonePersistPromise;
    await this.queuePersistPromise;
    if (this.queueRestorePending) await this.persistPendingQueue().catch(() => undefined);

    const responses: EventBatchResponse[] = [];
    while (this.retryBatch.length > 0 || this.queue.length > 0) {
      const pending = [...this.retryBatch, ...this.queue];
      const available = pending.filter((event) => !this.urgentEventIds.has(event.eventId!) && clean(event.contextId));
      const availableIds = new Set(available.map((event) => event.eventId));
      const held = pending.filter((event) => !availableIds.has(event.eventId));
      if (available.length === 0) return responses;
      const uploadBatch = eventBatchWithinBudget(available, this.maxBatchSize, this.maxBatchBytes);
      this.retryBatch = [];
      this.queue = [...held, ...available.slice(uploadBatch.length)];
      this.inflightBatch = uploadBatch;

      try {
        responses.push(await this.uploadEvents(uploadBatch));
        this.inflightBatch = [];
        this.consecutiveFailures = 0;
        this.nextAutoFlushAt = 0;
        this.removeSyncSessionEnds(new Set(uploadBatch.map((event) => event.eventId!)));
        // A storage failure after a successful HTTP ACK must not turn that
        // response into a transport failure or requeue the acknowledged batch.
        if (this.hasPersistedQueue) await this.persistPendingQueue().catch(() => undefined);
      } catch (error) {
        this.inflightBatch = [];
        if (isPermanentBatchError(error)) {
          // Terminal 4xx payload rejection: drop the poison-pill batch so later
          // valid events are not permanently head-of-line blocked across restarts.
          this.removeSyncSessionEnds(new Set(uploadBatch.map((event) => event.eventId!)));
          if (this.hasPersistedQueue) await this.persistPendingQueue().catch(() => undefined);
          throw error;
        }
        this.retryBatch = [...uploadBatch, ...this.retryBatch];
        this.enforceQueueLimit();
        this.consecutiveFailures += 1;
        this.nextAutoFlushAt = this.now() + computeRetryDelayMs(error, this.consecutiveFailures);
        if (this.hasPersistedQueue || this.consecutiveFailures >= 3) {
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
    await this.queuePersistPromise;
    if (this.hasPersistedQueue && this.retryBatch.length === 0 && this.queue.length === 0) {
      await this.clearPersistedQueue().catch(() => undefined);
    }
    return responses;
  }

  /** H5 critical events start uploading without waiting for browser storage or
   * an ordinary batch. Each event stays queued until the HTTP request succeeds.
   * Separate lanes keep a pending ad request from blocking session_end. */
  async flushUrgent(): Promise<EventBatchResponse[]> {
    const lanes = ["session_end", "ad_view"].map((eventType) => {
      const active = this.urgentFlushes.get(eventType);
      if (active) return active;
      if (!this.urgentCandidates(eventType).length) return Promise.resolve([]);
      const operation = this.drainUrgent(eventType);
      this.urgentFlushes.set(eventType, operation);
      return operation;
    });
    return (await Promise.all(lanes)).flat();
  }

  private urgentCandidates(eventType: string): GameEvent[] {
    return [...this.retryBatch, ...this.queue].filter((event) =>
      event.eventType === eventType && !this.urgentEventIds.has(event.eventId!)
      && (clean(event.contextId) || (event.sessionId === this.sessionId && clean(this.contextId)))
    );
  }

  private async drainUrgent(eventType: string): Promise<EventBatchResponse[]> {
    const responses: EventBatchResponse[] = [];
    try {
      if (!this.restored) await this.restorePromise;
      while (true) {
        const candidates = this.urgentCandidates(eventType);
        if (candidates.length === 0) return responses;
        const batch = eventBatchWithinBudget(candidates, this.maxBatchSize, this.maxBatchBytes);
        const ids = new Set(batch.map((event) => event.eventId!));
        for (const id of ids) this.urgentEventIds.add(id);
        const uploadBatch = batch.map((event) => clean(event.contextId)
          ? event : { ...event, contextId: this.contextId! });
        try {
          responses.push(await this.uploadEvents(uploadBatch));
          this.retryBatch = this.retryBatch.filter((event) => !ids.has(event.eventId!));
          this.queue = this.queue.filter((event) => !ids.has(event.eventId!));
          this.removeSyncSessionEnds(ids);
          // Serialize cleanup behind enqueue writes, but do not delay the next
          // critical request on an IndexedDB transaction or a paused callback.
          if (this.hasPersistedQueue) void this.persistPendingQueue().catch(() => undefined);
        } catch (error) {
          if (isPermanentBatchError(error)) {
            this.retryBatch = this.retryBatch.filter((event) => !ids.has(event.eventId!));
            this.queue = this.queue.filter((event) => !ids.has(event.eventId!));
            this.removeSyncSessionEnds(ids);
            if (this.hasPersistedQueue) void this.persistPendingQueue().catch(() => undefined);
            throw error;
          }
          // Queue overflow or a session transition may have removed an
          // unacknowledged row while the request was in flight.
          const pendingIds = new Set([...this.retryBatch, ...this.queue, ...this.inflightBatch].map((event) => event.eventId));
          this.retryBatch = [...uploadBatch.filter((event) => !pendingIds.has(event.eventId)), ...this.retryBatch];
          this.enforceQueueLimit();
          if (this.hasPersistedQueue) void this.persistPendingQueue().catch(() => undefined);
          throw error;
        } finally {
          for (const id of ids) this.urgentEventIds.delete(id);
        }
      }
    } finally {
      this.urgentFlushes.delete(eventType);
    }
  }

  close(): void {
    this.timersStopped = true;
    if (this.sessionDurationTimer) {
      clearInterval(this.sessionDurationTimer);
      this.sessionDurationTimer = undefined;
    }
    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = undefined;
    }
  }

  private enqueue(event: GameEvent, sessionEndSnapshot = false): void {
    this.queue.push(event);
    if (!sessionEndSnapshot && event.eventType === "session_end" && event.sessionId === this.sessionId) this.sessionHasEnd = true;
    this.enforceQueueLimit();
    if (this.persistOnEnqueue) {
      this.hasPersistedQueue = true;
      void this.persistPendingQueue().catch(() => undefined);
    }
    this.startTimer();
    if (this.queue.length >= this.maxBatchSize && this.now() >= this.nextAutoFlushAt) {
      void this.flush().catch(() => undefined);
    }
  }

  private enforceQueueLimit(): void {
    const overflow = this.retryBatch.length + this.queue.length - this.queueLimit;
    if (overflow <= 0) return;
    if (this.queue.length >= overflow) {
      this.queue.splice(0, overflow);
      return;
    }
    const remainingOverflow = overflow - this.queue.length;
    this.queue = [];
    this.retryBatch.splice(0, remainingOverflow);
  }

  private startTimer(): void {
    if (this.timersStopped || this.flushTimer || this.flushIntervalMs <= 0) return;
    this.flushTimer = setInterval(() => {
      if (this.now() < this.nextAutoFlushAt) return;
      void this.flush().catch(() => undefined);
    }, this.flushIntervalMs);
    this.flushTimer.unref?.();
  }

  private async restorePersistedQueue(): Promise<void> {
    if (!this.storage || !this.persistenceKey) return;
    // A transient root read failure must not clear or overwrite durable data.
    const durable = this.storage as GameAlgoStorage & { getItemDurably?: GameAlgoStorage["getItem"] };
    let raw: string | undefined | null;
    try {
      raw = await (durable.getItemDurably ?? durable.getItem).call(durable, this.persistenceKey);
    } catch {
      // Keep the unread queue untouched. New events can still upload from
      // memory; a later persistence attempt retries restoration first.
      this.queueRestorePending = true;
      this.hasPersistedQueue = true;
      return;
    }
    this.queueRestorePending = false;
    if (!raw) return;
    if (this.incrementalQueue) {
      let restored: GameEvent[];
      try { restored = await this.incrementalQueue.load(raw); }
      catch {
        this.incrementalQueue.reset();
        await this.storage.removeItem?.(this.persistenceKey);
        return;
      }
      const existingIds = new Set([...this.retryBatch, ...this.inflightBatch, ...this.queue].map(event => event.eventId));
      this.retryBatch = [...restored.filter(event => !existingIds.has(event.eventId)), ...this.retryBatch];
      this.hasPersistedQueue = restored.length > 0;
      if (restored.length > 0) this.startTimer();
      return;
    }
    try {
      if (raw.includes('"format":"gamealgo-event-chunks-v2"')) {
        this.incrementalQueue = new IncrementalEventQueue(this.storage, this.persistenceKey);
        const restored = await this.incrementalQueue.load(raw);
        const existingIds = new Set([...this.retryBatch, ...this.inflightBatch, ...this.queue].map(event => event.eventId));
        this.retryBatch = [...restored.filter(event => !existingIds.has(event.eventId)), ...this.retryBatch];
        this.hasPersistedQueue = restored.length > 0;
        if (restored.length > 0) this.startTimer();
        return;
      }
      const restored = raw
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => JSON.parse(line) as GameEvent)
        .filter((event) => clean(event.eventId) && clean(event.userId) && clean(event.sessionId) && clean(event.eventType));
      const existingIds = new Set([...this.retryBatch, ...this.inflightBatch, ...this.queue].map((event) => event.eventId));
      this.retryBatch = [...restored.filter((event) => !existingIds.has(event.eventId)), ...this.retryBatch];
      this.hasPersistedQueue = restored.length > 0;
      if (restored.length > 0) this.startTimer();
    } catch {
      await this.storage.removeItem?.(this.persistenceKey);
    }
  }

  private syncStorage(): SyncBackupStorage | undefined {
    return this.storage as SyncBackupStorage | undefined;
  }

  private hasQueuedSessionEnd(sessionId: string): boolean {
    return [...this.retryBatch, ...this.inflightBatch, ...this.queue].some(
      (event) => event.eventType === "session_end" && event.sessionId === sessionId,
    );
  }

  private readSyncSessionEnds(): GameEvent[] {
    const sync = this.syncStorage();
    if (!this.syncSessionEndKey || !sync?.getSyncItem) return [];
    const raw = sync.getSyncItem(this.syncSessionEndKey);
    if (!raw) return [];
    try {
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return [];
      return parsed.filter(
        (event): event is GameEvent => Boolean(
          event && typeof event === "object"
          && clean(event.eventId) && clean(event.userId) && clean(event.sessionId)
          && event.eventType === "session_end",
        ),
      );
    } catch {
      sync.removeSyncItem?.(this.syncSessionEndKey);
      return [];
    }
  }

  private writeSyncSessionEnds(events: GameEvent[]): void {
    const sync = this.syncStorage();
    if (!this.syncSessionEndKey || !sync?.setSyncItem) return;
    if (events.length === 0) {
      sync.removeSyncItem?.(this.syncSessionEndKey);
      return;
    }
    const bounded = events.slice(-MAX_SYNC_SESSION_END_MIRROR);
    sync.setSyncItem(this.syncSessionEndKey, JSON.stringify(bounded));
  }

  private mirrorSyncSessionEnd(event: GameEvent): void {
    if (!this.syncSessionEndKey || !this.syncStorage()?.setSyncItem) return;
    if (!clean(event.eventId) || !clean(event.userId) || !clean(event.sessionId)) return;
    const existing = this.readSyncSessionEnds().filter((item) => item.eventId !== event.eventId);
    existing.push(event);
    this.writeSyncSessionEnds(existing);
  }

  private bindSyncSessionEnds(sessionId: string, contextId: string): void {
    if (!this.syncSessionEndKey || !this.syncStorage()?.setSyncItem) return;
    const existing = this.readSyncSessionEnds();
    if (existing.length === 0) return;
    let changed = false;
    const updated = existing.map((event) => {
      if (!clean(event.contextId) && event.sessionId === sessionId) {
        changed = true;
        return { ...event, contextId };
      }
      return event;
    });
    if (changed) this.writeSyncSessionEnds(updated);
  }

  private removeSyncSessionEnds(ids: Set<string>): void {
    if (!this.syncSessionEndKey || ids.size === 0 || !this.syncStorage()?.getSyncItem) return;
    const existing = this.readSyncSessionEnds();
    if (existing.length === 0) return;
    const remaining = existing.filter((event) => !ids.has(event.eventId!));
    if (remaining.length !== existing.length) this.writeSyncSessionEnds(remaining);
  }

  private persistSessionCheckpoint(ended: boolean, now = this.now()): void {
    if (!this.sessionCheckpointKey || !this.storage) return;
    const userId = clean(this.userId);
    const contextId = clean(this.contextId);
    if (!userId || !contextId) return;
    const durationMs = Math.max(0, this.getForegroundTimeMs() - this.sessionForegroundStartMs);
    if (ended && !this.sessionCheckpointWritten) {
      this.sessionCheckpointEnded = true;
      return;
    }
    if (!ended && durationMs < WEB_SESSION_CHECKPOINT_MIN_MS) return;
    const checkpoint: ActiveSessionCheckpoint = {
      sessionId: this.sessionId,
      contextId,
      userId,
      accountUserId: this.accountUserId,
      isDebug: this.isDebug,
      sessionDurationMs: durationMs,
      timestamp: new Date(now).toISOString(),
      createdLocalAt: localTimestamp(now),
      ended,
    };
    const encoded = JSON.stringify(checkpoint);
    const sync = this.syncStorage();
    if (sync?.setSyncItem) {
      if (sync.setSyncItem(this.sessionCheckpointKey, encoded)) {
        this.sessionCheckpointForegroundMs = durationMs;
        this.sessionCheckpointWritten = true;
        this.sessionCheckpointEnded = ended;
      }
      return;
    }
    this.sessionCheckpointForegroundMs = durationMs;
    this.sessionCheckpointWritten = true;
    this.sessionCheckpointEnded = ended;
    void Promise.resolve(this.storage.setItem(this.sessionCheckpointKey, encoded)).catch(() => undefined);
  }

  private async restoreSyncSessionEndsAndCheckpoint(): Promise<void> {
    if (!isBrowserHost(this.platform)) return;
    const sync = this.syncStorage();
    const syncEnds = this.readSyncSessionEnds();
    let added = false;
    if (syncEnds.length > 0) {
      const existingIds = new Set([...this.retryBatch, ...this.inflightBatch, ...this.queue].map((event) => event.eventId));
      const missing = syncEnds.filter((event) => !existingIds.has(event.eventId));
      if (missing.length > 0) {
        this.retryBatch = [...missing, ...this.retryBatch];
        added = true;
      }
    }

    if (this.sessionCheckpointKey && this.storage) {
      let raw: string | undefined | null = sync?.getSyncItem?.(this.sessionCheckpointKey);
      if (raw === undefined) {
        try { raw = await this.storage.getItem(this.sessionCheckpointKey); } catch { raw = undefined; }
      }
      if (raw) {
        try {
          const parsed = JSON.parse(raw) as Partial<ActiveSessionCheckpoint>;
          const previousSessionId = clean(parsed.sessionId);
          if (previousSessionId && previousSessionId !== this.sessionId) {
            sync?.removeSyncItem?.(this.sessionCheckpointKey);
            await Promise.resolve(this.storage.removeItem?.(this.sessionCheckpointKey)).catch(() => undefined);
            const previousContextId = clean(parsed.contextId);
            const previousUserId = clean(parsed.userId);
            if (!parsed.ended && previousContextId && previousUserId && !this.hasQueuedSessionEnd(previousSessionId)) {
              const durationMs = Number.isFinite(parsed.sessionDurationMs)
                ? Math.max(0, Math.round(Number(parsed.sessionDurationMs)))
                : 0;
              const now = this.now();
              const recovered: GameEvent = {
                eventId: randomId(),
                contextId: previousContextId,
                userId: previousUserId,
                accountUserId: clean(parsed.accountUserId),
                sessionId: previousSessionId,
                eventType: "session_end",
                isDebug: Boolean(parsed.isDebug),
                timestamp: clean(parsed.timestamp) ?? new Date(now).toISOString(),
                createdLocalAt: clean(parsed.createdLocalAt) ?? localTimestamp(now),
                payload: { reason: "crash_recovery", sessionDurationMs: durationMs },
              };
              this.retryBatch = [recovered, ...this.retryBatch];
              this.mirrorSyncSessionEnd(recovered);
              added = true;
            }
          }
        } catch {
          sync?.removeSyncItem?.(this.sessionCheckpointKey);
          await Promise.resolve(this.storage.removeItem?.(this.sessionCheckpointKey)).catch(() => undefined);
        }
      }
    }

    if (added) {
      this.hasPersistedQueue = true;
      this.startTimer();
    }
  }

  private async restorePersistedMilestones(): Promise<void> {
    if (!this.storage || !this.milestonePersistenceKey) return;
    const raw = await this.storage.getItem(this.milestonePersistenceKey);
    if (!raw) return;
    try {
      const restored = JSON.parse(raw);
      if (!Array.isArray(restored)) throw new Error("invalid milestone cache");
      for (const key of restored) {
        if (typeof key === "string" && key) this.reachedMilestoneKeys.add(key);
      }
    } catch {
      await this.storage.removeItem?.(this.milestonePersistenceKey);
    }
  }

  private persistReachedMilestones(): Promise<void> {
    if (!this.storage || !this.milestonePersistenceKey) return Promise.resolve();
    const persist = async () => {
      await this.milestoneRestorePromise;
      await this.storage!.setItem(
        this.milestonePersistenceKey!,
        JSON.stringify([...this.reachedMilestoneKeys].sort()),
      );
    };
    this.milestonePersistPromise = this.milestonePersistPromise.then(persist, persist);
    return this.milestonePersistPromise;
  }

  private persistPendingQueue(): Promise<void> {
    if (!this.storage || !this.persistenceKey) return Promise.resolve();
    this.queuePersistRevision++;
    if (this.queuePersistActive) return this.queuePersistActive;
    const persist = async () => {
      try {
        await this.restorePromise;
        if (this.queueRestorePending) {
          await this.restorePersistedQueue();
          if (this.queueRestorePending) throw new Error("Event queue storage is unavailable");
        }
        let revision: number;
        do {
          revision = this.queuePersistRevision;
          const pending = [...this.retryBatch, ...this.inflightBatch, ...this.queue];
          if (this.incrementalQueue) this.hasPersistedQueue = await this.incrementalQueue.save(pending);
          else if (pending.length === 0) {
            await this.storage!.removeItem?.(this.persistenceKey!);
            this.hasPersistedQueue = false;
          } else {
            await this.storage!.setItem(this.persistenceKey!, pending.map((event) => JSON.stringify(event)).join("\n"));
            this.hasPersistedQueue = true;
          }
        } while (revision !== this.queuePersistRevision);
      } finally {
        this.queuePersistActive = undefined;
      }
    };
    const operation = this.queuePersistPromise.then(persist, persist);
    this.queuePersistActive = operation;
    this.queuePersistPromise = operation.catch(() => undefined);
    return operation;
  }

  private async clearPersistedQueue(): Promise<void> {
    if (!this.storage || !this.persistenceKey) {
      this.hasPersistedQueue = false;
      return;
    }
    await this.persistPendingQueue();
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

export class GameAlgoConfigReader {
  private readonly snapshotProvider: () => GameAlgoSnapshot;
  private readonly parsedFileCache = new WeakMap<ConfigFileResponse, { ok: true; value: JsonValue } | { ok: false }>();

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

  private parseCachedJson(file: ConfigFileResponse): JsonValue | undefined {
    const cached = this.parsedFileCache.get(file);
    if (cached) return cached.ok ? cached.value : undefined;
    try {
      const value = JSON.parse(file.content) as JsonValue;
      this.parsedFileCache.set(file, { ok: true, value });
      return value;
    } catch {
      this.parsedFileCache.set(file, { ok: false });
      return undefined;
    }
  }

  private defaultJsonSource(fileName?: string): JsonValue | undefined {
    if (fileName) {
      const file = this.file(fileName);
      return file ? this.parseCachedJson(file) : undefined;
    }

    const jsonFiles = [...this.snapshotProvider().configFiles.values()].filter((file) => (
      file.contentType.includes("application/json") || file.name.endsWith(".json")
    ));
    if (jsonFiles.length !== 1) return undefined;

    return this.parseCachedJson(jsonFiles[0]);
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

async function apiError(response: GameAlgoHttpResponse): Promise<GameAlgoApiError> {
  const fallback = `GameAlgo API returned ${response.status}`;
  const retryAfterMs = parseRetryAfterMs(response.headers?.get?.("retry-after"));
  try {
    const payload = await response.json() as { error?: string; message?: string };
    return new GameAlgoApiError(response.status, payload.message ?? payload.error ?? fallback, payload.error, retryAfterMs);
  } catch {
    return new GameAlgoApiError(response.status, fallback, undefined, retryAfterMs);
  }
}

function parseRetryAfterMs(header: string | null | undefined): number | undefined {
  const raw = header?.trim();
  if (!raw) return undefined;
  const seconds = Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.min(60_000, Math.round(seconds * 1000));
  }
  const timestamp = Date.parse(raw);
  if (Number.isFinite(timestamp)) {
    return Math.min(60_000, Math.max(0, timestamp - Date.now()));
  }
  return undefined;
}

function isPermanentBatchError(error: unknown): boolean {
  return error instanceof GameAlgoApiError && (error.status === 400 || error.status === 413 || error.status === 422);
}

function computeRetryDelayMs(error: unknown, consecutiveFailures: number): number {
  if (error instanceof GameAlgoApiError && error.retryAfterMs !== undefined) {
    return Math.max(1_000, Math.min(60_000, error.retryAfterMs));
  }
  return Math.min(60_000, 1_000 * 2 ** Math.min(Math.max(consecutiveFailures - 1, 0), 6));
}

function etagMatchesHash(etag: string | undefined, expectedHash: string | undefined): boolean {
  const normalizedExpected = clean(expectedHash);
  const normalizedEtag = clean(etag)?.replace(/^W\//i, "").replace(/^"|"$/g, "");
  return Boolean(normalizedExpected && normalizedEtag && normalizedEtag === normalizedExpected);
}

function pruneMapLimit<K, V>(map: Map<K, V>, maxSize: number): void {
  while (map.size > maxSize) {
    const oldest = map.keys().next().value;
    if (oldest === undefined) break;
    map.delete(oldest);
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

function normalizedBaseUrl(url: HttpBaseUrl): string {
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

function clean(value: string | undefined | null): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function normalizeContextIdentifier(type: ContextIdentifierType, value: string | null): string | null {
  const cleaned = clean(value);
  if (!cleaned) return null;
  if ((type === "gaid" || type === "idfa") && /^0{8}-0{4}-0{4}-0{4}-0{12}$/i.test(cleaned)) return null;
  return cleaned;
}

function normalizeExperimentIntegrationVersion(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw new Error("experimentIntegrationVersion must be a positive integer");
  }
  return value;
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

function eventBatchWithinBudget(events: GameEvent[], maxCount: number, maxBytes?: number): GameEvent[] {
  const countLimited = events.slice(0, maxCount);
  if (!maxBytes || countLimited.length <= 1) return countLimited;
  const batch: GameEvent[] = [];
  // '{"events":[]}' is 12 ASCII bytes; each additional element adds 1 comma byte.
  let totalBytes = 12;
  for (const event of countLimited) {
    const eventBytes = utf8Bytes(JSON.stringify(event)) + (batch.length > 0 ? 1 : 0);
    if (batch.length > 0 && totalBytes + eventBytes > maxBytes) break;
    totalBytes += eventBytes;
    batch.push(event);
  }
  return batch;
}

function utf8Bytes(value: string): number {
  return encodeUtf8(value).byteLength;
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
  if (!globalThis.crypto?.subtle) return `sha256:${sha256HexSync(content)}`;
  const digest = await globalThis.crypto.subtle.digest("SHA-256", encodeUtf8(content));
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

/** Hosts that share durable browser queues, urgent delivery and sampled time. */
function isBrowserHost(platform: Platform): boolean {
  return platform === "web" || platform === "wechat" || platform === "crazygames" || platform === "douyin";
}
