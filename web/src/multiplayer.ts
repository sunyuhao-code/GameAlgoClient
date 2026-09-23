import type { MultiplayerProtocol } from "./multiplayer-protocol.ts";
import {
  decodeMultiplayerFrame,
  encodeMultiplayerFrame,
  MultiplayerMessageType,
  NO_TARGET_SEAT,
  RELIABLE_INPUT_FLAG,
} from "./multiplayer-wire.ts";

export type MultiplayerSocketFactory = (url: string) => WebSocket;

export type MultiplayerErrorPhase = "token" | "match" | "lobby" | "room_join" | "room_active" | "input";

export class GameAlgoMultiplayerError extends Error {
  readonly code: string;
  readonly phase: MultiplayerErrorPhase;
  readonly retryable: boolean;

  constructor(
    code: string,
    phase: MultiplayerErrorPhase,
    options: { retryable?: boolean; cause?: unknown } = {},
  ) {
    super(code, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = "GameAlgoMultiplayerError";
    this.code = code;
    this.phase = phase;
    this.retryable = options.retryable === true;
  }
}

export type MatchJoinOptions = {
  accessToken?: string;
  controllerUrl?: string;
  userId?: string;
  sessionId?: string;
  region?: string;
  queueId: string;
  protocolHash: string;
  rating?: number;
  canHost?: boolean;
  foreground?: boolean;
  rttMs?: number;
  deviceScore?: number;
  connectionRetries?: number;
  connectionTimeoutMs?: number;
  retryDelayMs?: number;
};

export type MatchedRoom = {
  roomId: string;
  relayId: string;
  relayUrl: string;
  seat: number;
  hostSeat: number;
  ticket: string;
  teamIndex?: number;
};

export type LobbyMetadata = Record<string, string | number | boolean>;

export type LobbySummary = {
  lobbyId: string;
  queueId: string;
  protocolHash: string;
  visibility: "public" | "unlisted";
  launchMode: "direct" | "matchmaking";
  state: "open" | "queued" | "starting";
  minPlayers: number;
  maxPlayers: number;
  playerCount: number;
  metadata: LobbyMetadata;
  createdAt: string;
  expiresAt: string;
};

export type LobbySnapshot = LobbySummary & {
  roomCode: string;
  selfMemberId: string;
  leaderMemberId: string;
  isLeader: boolean;
  members: Array<{ memberId: string; userId: string; isLeader: boolean; canHost: boolean }>;
};

type LobbyAuthOptions = {
  accessToken?: string;
  controllerUrl?: string;
  userId?: string;
  sessionId?: string;
  region?: string;
  connectionRetries?: number;
  connectionTimeoutMs?: number;
  retryDelayMs?: number;
};

type LobbyMemberOptions = LobbyAuthOptions & {
  protocolHash: string;
  rating?: number;
  canHost?: boolean;
  foreground?: boolean;
  rttMs?: number;
  deviceScore?: number;
};

export type LobbyListOptions = LobbyAuthOptions & {
  queueId: string;
  protocolHash: string;
  limit?: number;
  cursor?: string;
};

export type LobbyPage = { items: LobbySummary[]; nextCursor?: string };

export type CreateLobbyOptions = LobbyMemberOptions & {
  queueId: string;
  visibility?: "public" | "unlisted";
  metadata?: LobbyMetadata;
};

export type JoinLobbyOptions = LobbyMemberOptions & {
  lobbyId?: string;
  roomCode?: string;
};

export type GameAlgoMatchmakingClientOptions = {
  apiBaseUrl: string;
  gameKey: string;
  controllerUrl?: string;
  fetchImpl: typeof fetch;
  socketFactory?: MultiplayerSocketFactory;
  identity: (userId?: string, sessionId?: string) => Promise<{ userId: string; sessionId: string }>;
};

export class GameAlgoMatchmakingClient {
  private readonly options: GameAlgoMatchmakingClientOptions;

  constructor(options: GameAlgoMatchmakingClientOptions) { this.options = options; }

  join(options: MatchJoinOptions): MatchHandle {
    return new MatchHandle(this.options, options);
  }

  createLobby(options: CreateLobbyOptions): LobbyHandle {
    return new LobbyHandle(this.options, { type: "create_lobby", ...options });
  }

  joinLobby(options: JoinLobbyOptions): LobbyHandle {
    return new LobbyHandle(this.options, { type: "join_lobby", ...options });
  }

  async listLobbies(options: LobbyListOptions): Promise<LobbyPage> {
    const identity = await this.options.identity(options.userId, options.sessionId);
    const credentials = await controllerCredentials(this.options, options, identity);
    const url = controllerHttpUrl(credentials.controllerUrl);
    url.pathname = `${url.pathname.replace(/\/+$/, "")}/lobbies`;
    url.searchParams.set("queueId", options.queueId);
    url.searchParams.set("protocolHash", options.protocolHash);
    if (options.limit !== undefined) url.searchParams.set("limit", String(options.limit));
    if (options.cursor) url.searchParams.set("cursor", options.cursor);
    const response = await this.options.fetchImpl(url, {
      headers: { authorization: `Bearer ${credentials.accessToken}` },
    });
    const payload = await response.json() as { items?: unknown; nextCursor?: unknown; error?: unknown };
    if (!response.ok) throw multiplayerError(String(payload.error || `lobby_list_failed_${response.status}`), "lobby", false);
    if (!Array.isArray(payload.items)) throw multiplayerError("invalid_lobby_list", "lobby", false);
    return {
      items: payload.items as LobbySummary[],
      ...(typeof payload.nextCursor === "string" ? { nextCursor: payload.nextCursor } : {}),
    };
  }
}

type LobbyHandleRequest = ({ type: "create_lobby" } & CreateLobbyOptions)
  | ({ type: "join_lobby" } & JoinLobbyOptions);

export class LobbyHandle {
  private socket?: WebSocket;
  private cancelled = false;
  private finished = false;
  private readySettled = false;
  private readonly changedListeners = new Set<(lobby: LobbySnapshot) => void>();
  private readonly matchedListeners = new Set<(match: MatchedRoom) => void>();
  private readonly errorListeners = new Set<(error: Error) => void>();
  private readonly lobbyPromise: Promise<LobbySnapshot>;
  private resolveLobby!: (lobby: LobbySnapshot) => void;
  private rejectLobby!: (error: Error) => void;
  private readonly matchedPromise: Promise<MatchedRoom>;
  private resolveMatched!: (match: MatchedRoom) => void;
  private rejectMatched!: (error: Error) => void;
  private readonly client: GameAlgoMatchmakingClientOptions;
  private readonly request: LobbyHandleRequest;

  constructor(
    client: GameAlgoMatchmakingClientOptions,
    request: LobbyHandleRequest,
  ) {
    this.client = client;
    this.request = request;
    this.lobbyPromise = new Promise<LobbySnapshot>((resolve, reject) => {
      this.resolveLobby = resolve;
      this.rejectLobby = reject;
    });
    this.matchedPromise = new Promise<MatchedRoom>((resolve, reject) => {
      this.resolveMatched = resolve;
      this.rejectMatched = reject;
    });
    void this.lobbyPromise.catch(() => undefined);
    void this.matchedPromise.catch(() => undefined);
    void this.connect();
  }

  waitForLobby(): Promise<LobbySnapshot> { return this.lobbyPromise; }
  waitForMatched(): Promise<MatchedRoom> { return this.matchedPromise; }

  onChanged(listener: (lobby: LobbySnapshot) => void): () => void {
    this.changedListeners.add(listener);
    return () => this.changedListeners.delete(listener);
  }

  onMatched(listener: (match: MatchedRoom) => void): () => void {
    this.matchedListeners.add(listener);
    return () => this.matchedListeners.delete(listener);
  }

  onError(listener: (error: Error) => void): () => void {
    this.errorListeners.add(listener);
    return () => this.errorListeners.delete(listener);
  }

  start(): void { this.send({ type: "lobby_start" }); }
  cancelMatchmaking(): void { this.send({ type: "lobby_cancel_matchmaking" }); }
  closeLobby(): void { this.send({ type: "lobby_close" }); }
  kick(memberId: string): void {
    if (!/^[A-Za-z0-9._:-]{1,128}$/.test(memberId)) throw multiplayerError("invalid_lobby_member_id", "lobby", false);
    this.send({ type: "lobby_kick", memberId });
  }

  leave(): void {
    if (this.cancelled || this.finished) return;
    this.cancelled = true;
    this.finished = true;
    if (this.socket?.readyState === 1) this.socket.send(JSON.stringify({ type: "cancel" }));
    this.socket?.close(1000, "lobby_left");
    const error = multiplayerError("lobby_left", "lobby", false);
    if (!this.readySettled) this.rejectLobby(error);
    this.rejectMatched(error);
  }

  private async connect(): Promise<void> {
    try {
      const identity = await this.client.identity(this.request.userId, this.request.sessionId);
      const credentials = await retryOperation(
        () => controllerCredentials(this.client, this.request, identity),
        boundedInteger(this.request.connectionRetries, 2, 0, 5),
        boundedInteger(this.request.retryDelayMs, 250, 50, 5_000),
        () => this.cancelled,
      );
      if (this.cancelled) return;
      const socket = (this.client.socketFactory ?? defaultSocketFactory)(credentials.controllerUrl);
      this.socket = socket;
      const timeout = setTimeout(() => {
        this.fail(multiplayerError("lobby_connection_timeout", "lobby", true));
      }, boundedInteger(this.request.connectionTimeoutMs, 8_000, 1_000, 30_000));
      socket.addEventListener("open", () => {
        clearTimeout(timeout);
        socket.send(JSON.stringify({
          type: this.request.type,
          accessToken: credentials.accessToken,
          queueId: "queueId" in this.request ? this.request.queueId : undefined,
          lobbyId: "lobbyId" in this.request ? this.request.lobbyId : undefined,
          roomCode: "roomCode" in this.request ? this.request.roomCode : undefined,
          protocolHash: this.request.protocolHash,
          visibility: "visibility" in this.request ? this.request.visibility : undefined,
          metadata: "metadata" in this.request ? this.request.metadata : undefined,
          rating: this.request.rating,
          canHost: this.request.canHost !== false,
          foreground: this.request.foreground !== false,
          rttMs: this.request.rttMs,
          deviceScore: this.request.deviceScore,
        }));
      });
      socket.addEventListener("message", (event) => this.onMessage(String(event.data)));
      socket.addEventListener("error", () => this.fail(multiplayerError("lobby_connection_failed", "lobby", true)));
      socket.addEventListener("close", (event) => {
        clearTimeout(timeout);
        if (!this.cancelled && !this.finished && event.code !== 1000) {
          this.fail(multiplayerError(event.reason || "lobby_connection_closed", "lobby", true));
        }
      });
    } catch (error) {
      this.fail(asMultiplayerError(error, "lobby", "lobby_connection_failed", true));
    }
  }

  private onMessage(raw: string): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw) as Record<string, unknown>;
    } catch (error) {
      return this.fail(multiplayerError("invalid_lobby_message", "lobby", false, error));
    }
    if (message.type === "lobby_snapshot") {
      const lobby = message.lobby as LobbySnapshot;
      if (!lobby?.lobbyId) return this.fail(multiplayerError("invalid_lobby_snapshot", "lobby", false));
      if (!this.readySettled) {
        this.readySettled = true;
        this.resolveLobby(lobby);
      }
      for (const listener of this.changedListeners) listener(lobby);
      return;
    }
    if (message.type === "matched") {
      const match = message as unknown as MatchedRoom;
      if (!match.ticket || !match.relayUrl) return this.fail(multiplayerError("invalid_matched_message", "lobby", false));
      this.finished = true;
      this.resolveMatched(match);
      for (const listener of this.matchedListeners) listener(match);
      this.socket?.close(1000, "matched");
      return;
    }
    if (message.type === "lobby_error" || message.type === "lobby_start_retrying") {
      const code = String(message.code || "lobby_failed");
      const error = multiplayerError(code, "lobby", retryableMultiplayerCode(code));
      for (const listener of this.errorListeners) listener(error);
      return;
    }
    if (message.type === "lobby_closed") {
      return this.fail(multiplayerError(String(message.reason || "lobby_closed"), "lobby", false));
    }
    if (message.type === "error") {
      const code = String(message.code || "lobby_failed");
      this.fail(multiplayerError(code, "lobby", retryableMultiplayerCode(code)));
    }
  }

  private send(message: Record<string, unknown>): void {
    if (this.socket?.readyState !== 1) throw multiplayerError("lobby_connection_unavailable", "lobby", true);
    this.socket.send(JSON.stringify(message));
  }

  private fail(error: Error): void {
    if (this.finished) return;
    this.finished = true;
    this.socket?.close(1000, "lobby_failed");
    if (!this.readySettled) this.rejectLobby(error);
    this.rejectMatched(error);
    for (const listener of this.errorListeners) listener(error);
  }
}

export class MatchHandle {
  private socket?: WebSocket;
  private cancelled = false;
  private finished = false;
  private connectionAttempt = 0;
  private retryTimer?: ReturnType<typeof setTimeout>;
  private connectionTimer?: ReturnType<typeof setTimeout>;
  private credentials?: { accessToken: string; controllerUrl: string };
  private readonly matchedListeners = new Set<(match: MatchedRoom) => void>();
  private readonly errorListeners = new Set<(error: Error) => void>();
  private readonly matchedPromise: Promise<MatchedRoom>;
  private resolveMatched!: (match: MatchedRoom) => void;
  private rejectMatched!: (error: Error) => void;
  private readonly client: GameAlgoMatchmakingClientOptions;
  private readonly options: MatchJoinOptions;

  constructor(client: GameAlgoMatchmakingClientOptions, options: MatchJoinOptions) {
    this.client = client;
    this.options = options;
    this.matchedPromise = new Promise<MatchedRoom>((resolve, reject) => {
      this.resolveMatched = resolve;
      this.rejectMatched = reject;
    });
    void this.matchedPromise.catch(() => undefined);
    void this.start();
  }

  onMatched(listener: (match: MatchedRoom) => void): () => void {
    this.matchedListeners.add(listener);
    return () => this.matchedListeners.delete(listener);
  }

  onError(listener: (error: Error) => void): () => void {
    this.errorListeners.add(listener);
    return () => this.errorListeners.delete(listener);
  }

  waitForMatched(): Promise<MatchedRoom> {
    return this.matchedPromise;
  }

  cancel(): void {
    if (this.cancelled || this.finished) return;
    this.cancelled = true;
    this.clearConnectionTimers();
    if (this.socket?.readyState === 1) this.socket.send(JSON.stringify({ type: "cancel" }));
    this.socket?.close(1000, "cancelled");
    this.rejectMatched(multiplayerError("match_cancelled", "match", false));
  }

  private async start(): Promise<void> {
    try {
      const identity = await this.client.identity(this.options.userId, this.options.sessionId);
      const explicitControllerUrl = this.options.controllerUrl ?? this.client.controllerUrl;
      this.credentials = this.options.accessToken && explicitControllerUrl
        ? { accessToken: this.options.accessToken, controllerUrl: explicitControllerUrl }
        : await retryOperation(
          () => this.issueAccessToken(identity),
          boundedInteger(this.options.connectionRetries, 2, 0, 5),
          boundedInteger(this.options.retryDelayMs, 250, 50, 5_000),
          () => this.cancelled,
        );
      if (this.cancelled) return;
      this.openMatchSocket();
    } catch (error) {
      this.fail(asMultiplayerError(error, "token", "multiplayer_access_token_failed", true));
    }
  }

  private openMatchSocket(): void {
    if (this.cancelled || this.finished || !this.credentials) return;
    const socket = (this.client.socketFactory ?? defaultSocketFactory)(this.credentials.controllerUrl);
    this.socket = socket;
    let attemptFinished = false;
    const failAttempt = (error: GameAlgoMultiplayerError): void => {
      if (attemptFinished || this.cancelled || this.finished || this.socket !== socket) return;
      attemptFinished = true;
      clearTimeout(this.connectionTimer);
      socket.close(1000, "match_retry");
      const retries = boundedInteger(this.options.connectionRetries, 2, 0, 5);
      if (error.retryable && this.connectionAttempt < retries) {
        const delay = boundedInteger(this.options.retryDelayMs, 250, 50, 5_000) * 2 ** this.connectionAttempt;
        this.connectionAttempt += 1;
        this.retryTimer = setTimeout(() => this.openMatchSocket(), Math.min(5_000, delay));
        return;
      }
      this.fail(error);
    };
    this.connectionTimer = setTimeout(() => failAttempt(
      multiplayerError("match_connection_timeout", "match", true),
    ), boundedInteger(this.options.connectionTimeoutMs, 8_000, 1_000, 30_000));
    socket.addEventListener("open", () => {
      clearTimeout(this.connectionTimer);
      socket.send(JSON.stringify({
        type: "join",
        accessToken: this.credentials!.accessToken,
        queueId: this.options.queueId,
        protocolHash: this.options.protocolHash,
        rating: this.options.rating,
        canHost: this.options.canHost !== false,
        foreground: this.options.foreground !== false,
        rttMs: this.options.rttMs,
        deviceScore: this.options.deviceScore,
      }));
    });
    socket.addEventListener("message", (event) => {
      if (this.socket === socket) this.onMessage(String(event.data));
    });
    socket.addEventListener("error", () => failAttempt(multiplayerError("match_connection_failed", "match", true)));
    socket.addEventListener("close", (event) => {
      if (!this.cancelled && !this.finished && event.code !== 1000) {
        failAttempt(multiplayerError(event.reason || "match_connection_closed", "match", true));
      }
    });
  }

  private async issueAccessToken(identity: { userId: string; sessionId: string }): Promise<{ accessToken: string; controllerUrl: string }> {
    return await controllerCredentials(this.client, this.options, identity);
  }

  private onMessage(raw: string): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return this.fail(multiplayerError("invalid_match_message", "match", false));
    }
    if (message.type === "matched") {
      const match = message as unknown as MatchedRoom;
      if (!match.ticket || !match.relayUrl) return this.fail(multiplayerError("invalid_matched_message", "match", false));
      this.finished = true;
      this.clearConnectionTimers();
      this.resolveMatched(match);
      for (const listener of this.matchedListeners) listener(match);
      this.socket?.close(1000, "matched");
      return;
    }
    if (message.type === "error") {
      const code = String(message.code || "match_failed");
      this.fail(multiplayerError(code, "match", retryableMultiplayerCode(code)));
    }
  }

  private fail(error: Error): void {
    if (this.cancelled || this.finished) return;
    this.finished = true;
    this.clearConnectionTimers();
    this.socket?.close(1000, "match_failed");
    this.rejectMatched(error);
    for (const listener of this.errorListeners) listener(error);
  }

  private clearConnectionTimers(): void {
    clearTimeout(this.retryTimer);
    clearTimeout(this.connectionTimer);
    this.retryTimer = undefined;
    this.connectionTimer = undefined;
  }
}

export type ConnectRoomOptions = {
  socketFactory?: MultiplayerSocketFactory;
  reconnect?: boolean;
  reconnectWindowMs?: number;
  connectRetries?: number;
  connectTimeoutMs?: number;
  retryDelayMs?: number;
};

export type MultiplayerRoomState = {
  sharedState?: Record<string, unknown>;
  seatState?: Record<string, unknown>;
  stateRevision: number;
};

export type MultiplayerRoomMember = {
  seat: number;
  connected: boolean;
  canHost: boolean;
  teamIndex?: number;
};

type RoomEventMap = {
  initialized: Record<string, unknown>;
  input: { seat: number; input: Record<string, unknown>; sequence: number };
  inputAcknowledged: { sequence: number };
  state: MultiplayerRoomState;
  event: { type: string; payload: Record<string, unknown> };
  peerChanged: { type: string; seat: number };
  phase: { phase: string };
  paused: { reason?: string };
  resumed: undefined;
  becomeHost: Record<string, unknown> | undefined;
  closed: { reason: string };
  error: Error;
};

export async function connectRoom(
  relayUrl: string,
  ticket: string,
  protocol: MultiplayerProtocol,
  options: ConnectRoomOptions = {},
): Promise<MultiplayerRoom> {
  const room = new MultiplayerRoom(relayUrl, ticket, protocol, options);
  await room.connect();
  return room;
}

export class MultiplayerRoom {
  id = "";
  seat = -1;
  isHost = false;
  hostEpoch = 0;
  phase = "connecting";
  teamIndex?: number;
  roster: MultiplayerRoomMember[] = [];
  readonly protocolId: string;
  readonly protocolVersion: number;

  private socket?: WebSocket;
  private sessionToken?: string;
  private hostSeat = -1;
  private sequence = 0;
  private stateRevision = 0;
  private closed = false;
  private reconnectEnabled: boolean;
  private reconnectStartedAt?: number;
  private reconnectAttempt = 0;
  private heartbeatTimer?: ReturnType<typeof setInterval>;
  private pendingHostRecovery = false;
  private readonly lastReliableInputSequenceBySeat = new Map<number, number>();
  private reliableInputQueue?: MultiplayerInputQueue;
  private sharedState?: Record<string, unknown>;
  private seatState?: Record<string, unknown>;
  private pendingState?: { sharedState: Record<string, unknown>; seatStates?: Record<number, Record<string, unknown>> };
  private stateTimer?: ReturnType<typeof setTimeout>;
  private lastStateSentAt = 0;
  private pendingHostState?: Record<string, unknown>;
  private hostStateTimer?: ReturnType<typeof setTimeout>;
  private lastHostStateSentAt = 0;
  private lifecycleAttached = false;
  private readonly onVisibilityChange = (): void => {
    if (typeof document === "undefined" || document.visibilityState !== "hidden") return;
    if (!this.isHost || this.phase !== "active" || this.socket?.readyState !== 1) return;
    try {
      this.yieldHost();
    } catch (error) {
      this.emit("error", asError(error));
    }
  };
  private readonly listeners = new Map<keyof RoomEventMap, Set<(value: never) => unknown>>();
  private readonly relayUrl: string;
  private readonly ticket: string;
  private readonly protocol: MultiplayerProtocol;
  private readonly options: ConnectRoomOptions;

  constructor(
    relayUrl: string,
    ticket: string,
    protocol: MultiplayerProtocol,
    options: ConnectRoomOptions,
  ) {
    this.relayUrl = relayUrl;
    this.ticket = ticket;
    this.protocol = protocol;
    this.options = options;
    this.protocolId = protocol.id;
    this.protocolVersion = protocol.version;
    this.reconnectEnabled = options.reconnect !== false;
  }

  async connect(): Promise<void> {
    const retries = boundedInteger(this.options.connectRetries, 1, 0, 3);
    let lastError: GameAlgoMultiplayerError | undefined;
    for (let attempt = 0; attempt <= retries; attempt += 1) {
      try {
        await this.openSocket({ type: "join", ticket: this.ticket });
        return;
      } catch (error) {
        lastError = asMultiplayerError(error, "room_join", "room_connection_failed", true);
        if (!lastError.retryable || attempt >= retries) throw lastError;
        await delay(boundedInteger(this.options.retryDelayMs, 250, 50, 5_000) * 2 ** attempt);
      }
    }
    throw lastError ?? multiplayerError("room_connection_failed", "room_join", true);
  }

  async initialize(initData: Record<string, unknown>): Promise<void> {
    this.requireHost();
    this.sendFrame(MultiplayerMessageType.roomInit, this.protocol.encodeRoomInit(initData), NO_TARGET_SEAT, 4 * 1024);
  }

  async ready(): Promise<void> {
    this.sendControl({ type: "ready" });
  }

  createInputQueue(options: InputQueueOptions): MultiplayerInputQueue {
    const delivery = options.delivery ?? "latest";
    if (delivery === "reliable" && this.reliableInputQueue) {
      throw multiplayerError("reliable_input_queue_exists", "input", false);
    }
    const queue = new MultiplayerInputQueue(this, options, () => {
      if (this.reliableInputQueue === queue) this.reliableInputQueue = undefined;
    });
    if (delivery === "reliable") this.reliableInputQueue = queue;
    return queue;
  }

  publishState(value: { sharedState: Record<string, unknown>; seatStates?: Record<number, Record<string, unknown>> }): void {
    this.requireHost();
    this.pendingState = value;
    const wait = Math.max(0, 100 - (Date.now() - this.lastStateSentAt));
    if (wait === 0) this.flushState();
    else if (!this.stateTimer) this.stateTimer = setTimeout(() => this.flushState(), wait);
  }

  commitHostState(value: Record<string, unknown>): void {
    this.requireHost();
    this.pendingHostState = value;
    const wait = Math.max(0, 1000 - (Date.now() - this.lastHostStateSentAt));
    if (wait === 0) this.flushHostState();
    else if (!this.hostStateTimer) this.hostStateTimer = setTimeout(() => this.flushHostState(), wait);
  }

  sendEvent(type: string, payload: Record<string, unknown>, options: { to?: "all" | { seat: number } } = {}): void {
    this.requireHost();
    const target = typeof options.to === "object" ? options.to.seat : NO_TARGET_SEAT;
    this.sendFrame(MultiplayerMessageType.gameEvent, this.protocol.encodeEvent(type, payload), target, 512);
  }

  yieldHost(): void {
    this.requireHost();
    this.sendControl({ type: "host_yield", hostEpoch: this.hostEpoch });
  }

  close(reason = "host_closed"): void {
    if (this.isHost && this.socket?.readyState === 1) this.sendControl({ type: "close_room", hostEpoch: this.hostEpoch, reason });
    this.disconnect({ reconnect: false, reason });
  }

  disconnect(options: { reconnect?: boolean; reason?: string } = {}): void {
    this.reconnectEnabled = options.reconnect === true;
    if (!this.reconnectEnabled) {
      this.closed = true;
      this.detachLifecycle();
    }
    this.socket?.close(1000, options.reason ?? "client_disconnect");
    this.stopHeartbeat();
  }

  onInitialized(listener: (value: Record<string, unknown>) => void): () => void { return this.on("initialized", listener); }
  onInput(listener: (value: RoomEventMap["input"]) => void): () => void { return this.on("input", listener); }
  onInputAcknowledged(listener: (value: RoomEventMap["inputAcknowledged"]) => void): () => void { return this.on("inputAcknowledged", listener); }
  onState(listener: (value: MultiplayerRoomState) => void): () => void { return this.on("state", listener); }
  onEvent(listener: (value: RoomEventMap["event"]) => void): () => void { return this.on("event", listener); }
  onPeerChanged(listener: (value: RoomEventMap["peerChanged"]) => void): () => void { return this.on("peerChanged", listener); }
  onPhase(listener: (value: RoomEventMap["phase"]) => void): () => void { return this.on("phase", listener); }
  onPaused(listener: (value: RoomEventMap["paused"]) => void): () => void { return this.on("paused", listener); }
  onResumed(listener: () => void): () => void { return this.on("resumed", listener); }
  onBecomeHost(listener: (hostState: Record<string, unknown> | undefined) => void | Promise<void>): () => void { return this.on("becomeHost", listener); }
  onClosed(listener: (value: RoomEventMap["closed"]) => void): () => void { return this.on("closed", listener); }
  onError(listener: (error: Error) => void): () => void { return this.on("error", listener); }

  sendAggregatedInput(
    value: Record<string, unknown>,
    firstSequence: number,
    lastSequence: number,
    options: { reliable?: boolean } = {},
  ): void {
    const payload = this.protocol.encodeInput(value);
    this.sendFrame(
      MultiplayerMessageType.inputBatch,
      payload,
      NO_TARGET_SEAT,
      512,
      lastSequence || firstSequence,
      options.reliable ? RELIABLE_INPUT_FLAG : 0,
    );
  }

  private openSocket(authentication: Record<string, unknown>): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = (this.options.socketFactory ?? defaultSocketFactory)(this.relayUrl);
      this.socket = socket;
      socket.binaryType = "arraybuffer";
      let welcomed = false;
      let settled = false;
      const rejectJoin = (error: GameAlgoMultiplayerError): void => {
        if (settled || welcomed) return;
        settled = true;
        clearTimeout(connectionTimer);
        socket.close(1000, "room_join_failed");
        reject(error);
      };
      const connectionTimer = setTimeout(() => rejectJoin(
        multiplayerError("room_connection_timeout", "room_join", true),
      ), boundedInteger(this.options.connectTimeoutMs, 8_000, 1_000, 30_000));
      socket.addEventListener("open", () => socket.send(JSON.stringify(authentication)));
      socket.addEventListener("message", (event) => {
        if (typeof event.data === "string") {
          let message: Record<string, unknown>;
          try {
            message = JSON.parse(event.data) as Record<string, unknown>;
          } catch (error) {
            if (!welcomed) return rejectJoin(multiplayerError("invalid_room_message", "room_join", false, error));
            return this.emit("error", multiplayerError("invalid_room_message", "room_active", false, error));
          }
          if (message.type === "welcome" && !welcomed) {
            welcomed = true;
            settled = true;
            clearTimeout(connectionTimer);
            this.applyWelcome(message);
            this.attachLifecycle();
            this.startHeartbeat();
            resolve();
          } else if (!welcomed && message.type === "error") {
            const code = String(message.code || "room_connection_failed");
            rejectJoin(multiplayerError(code, "room_join", retryableMultiplayerCode(code)));
          } else {
            void this.onControl(message);
          }
          return;
        }
        const data = event.data instanceof ArrayBuffer ? event.data : event.data instanceof Blob ? event.data.arrayBuffer() : Promise.resolve(event.data as ArrayBuffer);
        void Promise.resolve(data).then((buffer) => this.onBinary(buffer)).catch((error) => this.emit("error", asError(error)));
      });
      socket.addEventListener("error", () => {
        if (!welcomed) rejectJoin(multiplayerError("room_connection_failed", "room_join", true));
        else this.emit("error", multiplayerError("room_connection_failed", "room_active", true));
      });
      socket.addEventListener("close", (event) => {
        clearTimeout(connectionTimer);
        this.stopHeartbeat();
        if (!welcomed) {
          rejectJoin(multiplayerError(event.reason || "room_connection_closed", "room_join", true));
          return;
        }
        if (!this.closed && this.reconnectEnabled && this.sessionToken) this.scheduleReconnect();
        else if (!this.closed) this.emit("closed", { reason: event.reason || "connection_closed" });
      });
    });
  }

  private applyWelcome(message: Record<string, unknown>): void {
    this.id = String(message.roomId);
    this.seat = Number(message.seat);
    this.hostSeat = Number(message.hostSeat);
    this.hostEpoch = Number(message.hostEpoch);
    this.phase = String(message.phase || "joining");
    this.teamIndex = Number.isSafeInteger(message.teamIndex) ? Number(message.teamIndex) : undefined;
    this.roster = Array.isArray(message.roster)
      ? message.roster.flatMap((value) => {
        if (typeof value !== "object" || value === null) return [];
        const item = value as Record<string, unknown>;
        if (!Number.isSafeInteger(item.seat)) return [];
        return [{
          seat: Number(item.seat),
          connected: item.connected === true,
          canHost: item.canHost === true,
          ...(Number.isSafeInteger(item.teamIndex) ? { teamIndex: Number(item.teamIndex) } : {}),
        }];
      })
      : [];
    this.isHost = this.seat === this.hostSeat;
    this.sessionToken = String(message.sessionToken);
    this.reconnectStartedAt = undefined;
    this.reconnectAttempt = 0;
  }

  private async onControl(message: Record<string, unknown>): Promise<void> {
    if (message.type === "error") {
      const code = String(message.code || "multiplayer_error");
      return this.emit("error", multiplayerError(code, "room_active", retryableMultiplayerCode(code)));
    }
    if (message.type === "peer_joined" || message.type === "peer_disconnected" || message.type === "peer_reconnected" || message.type === "peer_ready") {
      if (message.type !== "peer_ready") {
        const seat = Number(message.seat);
        const connected = message.type !== "peer_disconnected";
        this.roster = this.roster.map((member) => member.seat === seat ? { ...member, connected } : member);
      }
      return this.emit("peerChanged", { type: String(message.type), seat: Number(message.seat) });
    }
    if (message.type === "room_phase") {
      this.phase = String(message.phase);
      return this.emit("phase", { phase: this.phase });
    }
    if (message.type === "room_paused") return this.emit("paused", { reason: typeof message.reason === "string" ? message.reason : undefined });
    if (message.type === "room_resumed") return this.emit("resumed", undefined);
    if (message.type === "host_changed") {
      this.hostSeat = Number(message.hostSeat);
      this.hostEpoch = Number(message.hostEpoch);
      this.isHost = this.seat === this.hostSeat;
      this.startHeartbeat();
      return;
    }
    if (message.type === "host_migrating") {
      this.hostSeat = Number(message.hostSeat);
      this.hostEpoch = Number(message.hostEpoch);
      this.isHost = this.seat === this.hostSeat;
      this.startHeartbeat();
      return;
    }
    if (message.type === "become_host") {
      this.isHost = true;
      this.hostSeat = this.seat;
      this.hostEpoch = Number(message.hostEpoch);
      this.pendingHostRecovery = message.recovery === true;
      this.startHeartbeat();
      if (!this.pendingHostRecovery) await this.emitAsync("becomeHost", undefined);
      return;
    }
    if (message.type === "room_closed") {
      this.closed = true;
      this.reconnectEnabled = false;
      this.detachLifecycle();
      this.emit("closed", { reason: String(message.reason || "room_closed") });
    }
  }

  private async onBinary(value: ArrayBuffer | Uint8Array): Promise<void> {
    const frame = decodeMultiplayerFrame(value);
    if (frame.type === MultiplayerMessageType.roomInit) return this.emit("initialized", this.protocol.decodeRoomInit(frame.payload));
    if (frame.type === MultiplayerMessageType.sharedState) {
      this.sharedState = this.protocol.decodeSharedState(frame.payload);
      return this.emitState(frame.stateRevision);
    }
    if (frame.type === MultiplayerMessageType.seatState) {
      this.seatState = this.protocol.decodeSeatState(frame.payload);
      return this.emitState(frame.stateRevision);
    }
    if (frame.type === MultiplayerMessageType.inputBatch) {
      if (!this.isHost || frame.hostEpoch !== this.hostEpoch) return;
      const reliable = (frame.flags & RELIABLE_INPUT_FLAG) !== 0;
      const previous = this.lastReliableInputSequenceBySeat.get(frame.targetSeat) ?? 0;
      if (!reliable || frame.sequence > previous) {
        const input = this.protocol.decodeInput(frame.payload);
        if (reliable) this.lastReliableInputSequenceBySeat.set(frame.targetSeat, frame.sequence);
        this.emit("input", { seat: frame.targetSeat, input, sequence: frame.sequence });
      }
      if (reliable) {
        this.sendFrame(MultiplayerMessageType.inputAck, new Uint8Array(), frame.targetSeat, 0, frame.sequence);
      }
      return;
    }
    if (frame.type === MultiplayerMessageType.inputAck) {
      return this.emit("inputAcknowledged", { sequence: frame.sequence });
    }
    if (frame.type === MultiplayerMessageType.gameEvent) return this.emit("event", this.protocol.decodeEvent(frame.payload));
    if (frame.type === MultiplayerMessageType.hostRecovery) {
      const state = this.protocol.decodeHostState(frame.payload);
      this.pendingHostRecovery = false;
      await this.emitAsync("becomeHost", state);
      this.sendControl({ type: "host_ready", hostEpoch: this.hostEpoch });
    }
  }

  private emitState(stateRevision: number): void {
    this.stateRevision = Math.max(this.stateRevision, stateRevision);
    this.emit("state", { sharedState: this.sharedState, seatState: this.seatState, stateRevision: this.stateRevision });
  }

  private flushState(): void {
    if (!this.pendingState || !this.isHost || this.closed) return;
    clearTimeout(this.stateTimer);
    this.stateTimer = undefined;
    const state = this.pendingState;
    this.pendingState = undefined;
    this.lastStateSentAt = Date.now();
    this.stateRevision += 1;
    this.sendFrame(MultiplayerMessageType.sharedState, this.protocol.encodeSharedState(state.sharedState), NO_TARGET_SEAT, 1024);
    for (const [seat, value] of Object.entries(state.seatStates ?? {})) {
      this.sendFrame(MultiplayerMessageType.seatState, this.protocol.encodeSeatState(value), Number(seat), 512);
    }
  }

  private flushHostState(): void {
    if (!this.pendingHostState || !this.isHost || this.closed) return;
    clearTimeout(this.hostStateTimer);
    this.hostStateTimer = undefined;
    const state = this.pendingHostState;
    this.pendingHostState = undefined;
    this.lastHostStateSentAt = Date.now();
    this.sendFrame(MultiplayerMessageType.hostState, this.protocol.encodeHostState(state), NO_TARGET_SEAT, 8 * 1024);
  }

  private sendFrame(
    type: number,
    payload: Uint8Array,
    targetSeat: number,
    limit: number,
    sequence?: number,
    flags = 0,
  ): void {
    if (payload.byteLength > limit) throw new Error("payload_too_large");
    if (this.socket?.readyState !== 1) throw new Error("room_connection_unavailable");
    this.socket.send(encodeMultiplayerFrame({
      type,
      flags,
      targetSeat,
      hostEpoch: this.hostEpoch,
      sequence: sequence ?? ++this.sequence,
      stateRevision: this.stateRevision,
      payload,
    }));
  }

  private sendControl(message: Record<string, unknown>): void {
    if (this.socket?.readyState !== 1) throw new Error("room_connection_unavailable");
    this.socket.send(JSON.stringify(message));
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    const interval = this.isHost ? 2_000 : 5_000;
    this.sendHeartbeat();
    this.heartbeatTimer = setInterval(() => this.sendHeartbeat(), interval);
  }

  private sendHeartbeat(): void {
    if (this.socket?.readyState !== 1) return;
    this.sendControl({
      type: "heartbeat",
      sentAt: Date.now(),
      foreground: typeof document === "undefined" || document.visibilityState !== "hidden",
    });
  }

  private stopHeartbeat(): void {
    clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
  }

  private scheduleReconnect(): void {
    const startedAt = this.reconnectStartedAt ?? Date.now();
    this.reconnectStartedAt = startedAt;
    if (Date.now() - startedAt >= (this.options.reconnectWindowMs ?? 30_000)) {
      this.closed = true;
      this.detachLifecycle();
      return this.emit("closed", { reason: "reconnect_expired" });
    }
    const delayMs = Math.min(2_000, 250 * 2 ** this.reconnectAttempt);
    this.reconnectAttempt += 1;
    setTimeout(() => {
      if (this.closed || !this.sessionToken) return;
      void this.openSocket({ type: "resume", sessionToken: this.sessionToken }).catch(() => this.scheduleReconnect());
    }, delayMs);
  }

  private requireHost(): void {
    if (!this.isHost) throw new Error("not_host");
  }

  private attachLifecycle(): void {
    if (this.lifecycleAttached || typeof document === "undefined") return;
    document.addEventListener("visibilitychange", this.onVisibilityChange);
    this.lifecycleAttached = true;
  }

  private detachLifecycle(): void {
    if (!this.lifecycleAttached || typeof document === "undefined") return;
    document.removeEventListener("visibilitychange", this.onVisibilityChange);
    this.lifecycleAttached = false;
  }

  private on<K extends keyof RoomEventMap>(type: K, listener: (value: RoomEventMap[K]) => unknown): () => void {
    let listeners = this.listeners.get(type);
    if (!listeners) {
      listeners = new Set();
      this.listeners.set(type, listeners);
    }
    listeners.add(listener as (value: never) => unknown);
    return () => listeners!.delete(listener as (value: never) => unknown);
  }

  private emit<K extends keyof RoomEventMap>(type: K, value: RoomEventMap[K]): void {
    for (const listener of this.listeners.get(type) ?? []) {
      try { void listener(value as never); } catch (error) { if (type !== "error") this.emit("error", asError(error)); }
    }
  }

  private async emitAsync<K extends keyof RoomEventMap>(type: K, value: RoomEventMap[K]): Promise<void> {
    const results = [...(this.listeners.get(type) ?? [])].map(async (listener) => listener(value as never));
    try {
      await Promise.all(results);
    } catch (error) {
      this.emit("error", asError(error));
      throw error;
    }
  }
}

export type InputQueueOptions = {
  intervalMs?: number;
  maxQueuedInputs?: number;
  delivery?: "latest" | "reliable";
  ackTimeoutMs?: number;
  aggregate: (inputs: readonly Record<string, unknown>[]) => Record<string, unknown> | undefined;
  onError?: (error: Error) => void;
};

export class MultiplayerInputQueue {
  private readonly values: Array<{ sequence: number; value: Record<string, unknown> }> = [];
  private inFlight?: {
    values: Array<{ sequence: number; value: Record<string, unknown> }>;
    aggregate: Record<string, unknown>;
    firstSequence: number;
    lastSequence: number;
    nextAttemptAt: number;
  };
  private nextSequence = 0;
  private readonly timer: ReturnType<typeof setInterval>;
  private readonly room: MultiplayerRoom;
  private readonly options: InputQueueOptions;
  private readonly delivery: "latest" | "reliable";
  private readonly unsubscribeAck: () => void;
  private readonly unsubscribePhase: () => void;
  private readonly release: () => void;
  private closed = false;

  constructor(room: MultiplayerRoom, options: InputQueueOptions, release: () => void = () => undefined) {
    this.room = room;
    this.options = options;
    this.release = release;
    this.delivery = options.delivery ?? "latest";
    this.unsubscribeAck = room.onInputAcknowledged(({ sequence }) => this.acknowledge(sequence));
    this.unsubscribePhase = room.onPhase(({ phase }) => {
      if (phase !== "active" || this.delivery !== "reliable") return;
      if (this.inFlight) this.inFlight.nextAttemptAt = 0;
      this.flush();
    });
    this.timer = setInterval(() => this.flush(), Math.max(50, options.intervalMs ?? 50));
  }

  push(value: Record<string, unknown>): void {
    const maximum = Math.max(1, this.options.maxQueuedInputs ?? 128);
    const queued = this.values.length + (this.inFlight?.values.length ?? 0);
    if (queued >= maximum) {
      if (this.delivery === "reliable") {
        this.options.onError?.(multiplayerError("input_queue_full", "input", true));
        return;
      }
      this.values.shift();
    }
    this.values.push({ sequence: ++this.nextSequence, value });
  }

  flush(): void {
    if (this.room.phase !== "active") return;
    if (this.inFlight) {
      if (Date.now() >= this.inFlight.nextAttemptAt) this.transmitReliable(this.inFlight);
      return;
    }
    if (this.values.length === 0) return;
    const pending = this.values.splice(0);
    let result: Record<string, unknown> | undefined;
    try {
      result = this.options.aggregate(pending.map((item) => item.value));
    } catch (error) {
      this.options.onError?.(asError(error));
      return;
    }
    if (!result) return;
    const firstSequence = pending[0].sequence;
    const lastSequence = pending[pending.length - 1].sequence;
    if (this.delivery === "reliable") {
      this.inFlight = {
        values: pending,
        aggregate: result,
        firstSequence,
        lastSequence,
        nextAttemptAt: 0,
      };
      this.transmitReliable(this.inFlight);
      return;
    }
    try {
      this.room.sendAggregatedInput(result, firstSequence, lastSequence);
    } catch (error) {
      this.values.unshift(...pending);
      this.options.onError?.(asMultiplayerError(error, "input", "input_send_failed", true));
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    this.unsubscribeAck();
    this.unsubscribePhase();
    this.inFlight = undefined;
    this.release();
  }

  private transmitReliable(batch: NonNullable<MultiplayerInputQueue["inFlight"]>): void {
    const retryMs = boundedInteger(this.options.ackTimeoutMs, 3_000, 250, 10_000);
    batch.nextAttemptAt = Date.now() + retryMs;
    try {
      this.room.sendAggregatedInput(
        batch.aggregate,
        batch.firstSequence,
        batch.lastSequence,
        { reliable: true },
      );
    } catch (error) {
      this.options.onError?.(asMultiplayerError(error, "input", "input_send_failed", true));
    }
  }

  private acknowledge(sequence: number): void {
    if (!this.inFlight || sequence < this.inFlight.lastSequence) return;
    this.inFlight = undefined;
    this.flush();
  }
}

function defaultSocketFactory(url: string): WebSocket {
  if (typeof WebSocket === "undefined") throw new Error("WebSocket is required");
  return new WebSocket(url);
}

function apiUrl(baseUrl: string, path: string): URL {
  const url = new URL(baseUrl);
  url.pathname = `${url.pathname.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;
  url.search = "";
  url.hash = "";
  return url;
}

async function controllerCredentials(
  client: GameAlgoMatchmakingClientOptions,
  options: LobbyAuthOptions,
  identity: { userId: string; sessionId: string },
): Promise<{ accessToken: string; controllerUrl: string }> {
  const explicitControllerUrl = options.controllerUrl ?? client.controllerUrl;
  if (options.accessToken && explicitControllerUrl) {
    return { accessToken: options.accessToken, controllerUrl: explicitControllerUrl };
  }
  const url = apiUrl(client.apiBaseUrl, "/v1/multiplayer/access-token");
  const response = await client.fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json", "X-GameAlgo-Key": client.gameKey },
    body: JSON.stringify({ userId: identity.userId, sessionId: identity.sessionId, region: options.region }),
  });
  if (!response.ok) {
    throw multiplayerError(
      `multiplayer_access_token_failed_${response.status}`,
      "token",
      response.status === 408 || response.status === 429 || response.status >= 500,
    );
  }
  const payload = await response.json() as { accessToken?: unknown; controllerUrl?: unknown };
  if (typeof payload.accessToken !== "string") throw multiplayerError("multiplayer_access_token_missing", "token", false);
  const controllerUrl = typeof payload.controllerUrl === "string" ? payload.controllerUrl : client.controllerUrl;
  if (!controllerUrl) throw multiplayerError("multiplayer_controller_url_missing", "token", false);
  return { accessToken: payload.accessToken, controllerUrl };
}

function controllerHttpUrl(controllerUrl: string): URL {
  const url = new URL(controllerUrl);
  if (url.protocol === "ws:") url.protocol = "http:";
  else if (url.protocol === "wss:") url.protocol = "https:";
  else if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("invalid multiplayer controller URL");
  url.search = "";
  url.hash = "";
  return url;
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function multiplayerError(
  code: string,
  phase: MultiplayerErrorPhase,
  retryable: boolean,
  cause?: unknown,
): GameAlgoMultiplayerError {
  return new GameAlgoMultiplayerError(code, phase, { retryable, cause });
}

function asMultiplayerError(
  error: unknown,
  phase: MultiplayerErrorPhase,
  fallbackCode: string,
  retryable: boolean,
): GameAlgoMultiplayerError {
  if (error instanceof GameAlgoMultiplayerError) return error;
  const code = error instanceof Error && /^[a-z][a-z0-9_]{1,127}$/.test(error.message)
    ? error.message
    : fallbackCode;
  return multiplayerError(code, phase, retryable, error);
}

function retryableMultiplayerCode(code: string): boolean {
  return new Set([
    "match_connection_failed",
    "match_connection_closed",
    "match_connection_timeout",
    "lobby_connection_failed",
    "lobby_connection_closed",
    "lobby_connection_timeout",
    "relay_unavailable",
    "room_connection_failed",
    "room_connection_closed",
    "room_connection_timeout",
    "host_unavailable",
    "heartbeat_timeout",
  ]).has(code);
}

function boundedInteger(value: number | undefined, fallback: number, minimum: number, maximum: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(maximum, Math.max(minimum, Math.floor(value!)));
}

async function retryOperation<T>(
  operation: () => Promise<T>,
  retries: number,
  delayMs: number,
  cancelled: () => boolean,
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    if (cancelled()) throw multiplayerError("match_cancelled", "match", false);
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      const typed = asMultiplayerError(error, "token", "multiplayer_access_token_failed", true);
      if (!typed.retryable || attempt >= retries) throw typed;
      await delay(Math.min(5_000, delayMs * 2 ** attempt));
    }
  }
  throw asMultiplayerError(lastError, "token", "multiplayer_access_token_failed", true);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
