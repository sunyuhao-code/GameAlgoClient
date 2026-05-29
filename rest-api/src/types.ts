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
  platform?: Platform;
  sdkVersion?: string;
  appVersion?: string;
  deviceId?: string;
  forceRefresh?: boolean;
};

export type StartOptions = FetchConfigOptions & {
  preloadConfigFiles?: boolean | string[];
};

export type ConfigFileResponse = {
  name: string;
  content: string;
  contentType: string;
  etag?: string;
};

export type GameEvent = {
  eventId?: string;
  userId: string;
  sessionId: string;
  eventType: string;
  platform?: Platform;
  sdkVersion?: string;
  appVersion?: string;
  timezone?: string;
  isDebug?: boolean;
  timestamp?: string;
  payload: JsonValue;
};

export type EventBatchResponse = {
  ok: boolean;
  accepted: number;
};

export type GameAlgoRestClientOptions = {
  baseUrl: string;
  gameKey: string;
  sdkVersion?: string;
  appVersion?: string;
  platform?: Platform;
  isDebug?: boolean;
  timezone?: string;
  eventFlushIntervalMs?: number;
  eventMaxBatchSize?: number;
  eventQueueLimit?: number;
  fetchImpl?: typeof fetch;
  now?: () => number;
  storage?: GameAlgoStorage;
  scriptRuntime?: GameAlgoScriptRuntime;
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
  platform?: Platform;
  sdkVersion?: string;
  appVersion?: string;
  timezone?: string;
  isDebug?: boolean;
  timestamp?: string;
};

export type GameAlgoStorage = {
  getItem(key: string): string | undefined | null | Promise<string | undefined | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem?(key: string): void | Promise<void>;
};

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
