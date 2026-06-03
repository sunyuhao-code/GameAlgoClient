export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export type Platform = "ios" | "android" | "rest";
export type GameEnvironment = "test" | "live";

export type ExperimentAssignment = {
  key: string;
  experimentId: string;
  variant: string;
  config: JsonValue;
  script?: ConfigFileRef;
};

export type ConfigFileRef = {
  name: string;
  url: string;
  hash: string;
  contentType?: string;
  updatedAt?: string;
};

export type ConfigResponse = {
  contextId: string;
  gameId: string;
  environment: GameEnvironment;
  configVersion: string;
  ttlSeconds: number;
  serverTime: string;
  experiments: ExperimentAssignment[];
  configFiles: ConfigFileRef[];
};

export type FetchConfigOptions = {
  userId?: string;
  userCreatedAt?: string;
  sessionId?: string;
  platform?: Platform;
  sdkVersion?: string;
  appVersion?: string;
  deviceId?: string;
  timezone?: string;
  device?: Record<string, JsonValue>;
  forceRefresh?: boolean;
};

export type ConfigFileResponse = {
  name: string;
  content: string;
  contentType: string;
  etag?: string;
};

export type GameEvent = {
  eventId?: string;
  contextId: string;
  userId: string;
  sessionId: string;
  eventType: string;
  isDebug?: boolean;
  timestamp?: string;
  payload?: EventPayload;
};

export type EventPayloadValue = string | number | boolean | null;
export type EventPayload = Record<string, EventPayloadValue>;

export type EventBatchResponse = {
  ok: boolean;
  accepted: number;
};

export type GameAlgoRestClientOptions = {
  baseUrl: string;
  gameKey: string;
  userId?: string;
  userCreatedAt?: string;
  sessionId?: string;
  sdkVersion?: string;
  appVersion?: string;
  platform?: Platform;
  deviceId?: string;
  device?: Record<string, JsonValue>;
  preloadConfigFiles?: boolean | string[];
  isDebug?: boolean;
  timezone?: string;
  eventFlushIntervalMs?: number;
  eventMaxBatchSize?: number;
  eventQueueLimit?: number;
  fetchImpl?: typeof fetch;
  now?: () => number;
  storage?: GameAlgoStorage;
  scriptRuntime?: GameAlgoScriptRuntime;
  logger?: GameAlgoLogger;
  cacheKey?: string;
};

export type GameAlgoSnapshot = {
  config?: ConfigResponse;
  configFiles: Map<string, ConfigFileResponse>;
  updatedAt: number;
  userId?: string;
};

export type GameAlgoUserIdentity = {
  userId: string;
  userCreatedAt: string;
};

export type TrackEventOptions = {
  userId?: string;
  sessionId?: string;
  contextId?: string;
  isDebug?: boolean;
  timestamp?: string;
};

export type GameAlgoStorage = {
  getItem(key: string): string | undefined | null | Promise<string | undefined | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem?(key: string): void | Promise<void>;
};

export type GameAlgoLogger = false | ((message: string) => void);

export type GameAlgoExecutionResult = {
  payload: JsonValue;
  diagnostics: JsonValue;
  assignment: ExperimentAssignment;
};

export type GameAlgoScriptInput = {
  state: JsonValue;
  config: JsonValue;
  meta: {
    gameId: string;
    userId: string;
    environment: GameEnvironment;
    strategy: string;
    experimentId: string;
    variant: string;
  };
};

export type GameAlgoScriptRuntime = {
  execute(script: string, input: GameAlgoScriptInput): JsonValue | Promise<JsonValue>;
};
