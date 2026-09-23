import type { MultiplayerProtocol } from "./multiplayer-protocol.ts";
import { decodeMultiplayerFrame, encodeMultiplayerFrame, MultiplayerMessageType, NO_TARGET_SEAT } from "./multiplayer-wire.ts";

export type MultiplayerSocketFactory = (url: string) => WebSocket;

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
};

export type MatchedRoom = {
  roomId: string;
  relayId: string;
  relayUrl: string;
  seat: number;
  hostSeat: number;
  ticket: string;
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
}

export class MatchHandle {
  private socket?: WebSocket;
  private cancelled = false;
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
    if (this.cancelled) return;
    this.cancelled = true;
    if (this.socket?.readyState === 1) this.socket.send(JSON.stringify({ type: "cancel" }));
    this.socket?.close(1000, "cancelled");
    this.rejectMatched(new Error("match_cancelled"));
  }

  private async start(): Promise<void> {
    try {
      const identity = await this.client.identity(this.options.userId, this.options.sessionId);
      const explicitControllerUrl = this.options.controllerUrl ?? this.client.controllerUrl;
      const credentials = this.options.accessToken && explicitControllerUrl
        ? { accessToken: this.options.accessToken, controllerUrl: explicitControllerUrl }
        : await this.issueAccessToken(identity);
      if (this.cancelled) return;
      const socket = (this.client.socketFactory ?? defaultSocketFactory)(credentials.controllerUrl);
      this.socket = socket;
      socket.addEventListener("open", () => {
        socket.send(JSON.stringify({
          type: "join",
          accessToken: credentials.accessToken,
          queueId: this.options.queueId,
          protocolHash: this.options.protocolHash,
          rating: this.options.rating,
          canHost: this.options.canHost !== false,
          foreground: this.options.foreground !== false,
          rttMs: this.options.rttMs,
          deviceScore: this.options.deviceScore,
        }));
      });
      socket.addEventListener("message", (event) => this.onMessage(String(event.data)));
      socket.addEventListener("error", () => this.fail(new Error("match_connection_failed")));
      socket.addEventListener("close", (event) => {
        if (!this.cancelled && event.code !== 1000) this.fail(new Error(event.reason || "match_connection_closed"));
      });
    } catch (error) {
      this.fail(asError(error));
    }
  }

  private async issueAccessToken(identity: { userId: string; sessionId: string }): Promise<{ accessToken: string; controllerUrl: string }> {
    const url = apiUrl(this.client.apiBaseUrl, "/v1/multiplayer/access-token");
    const response = await this.client.fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json", "X-GameAlgo-Key": this.client.gameKey },
      body: JSON.stringify({ userId: identity.userId, sessionId: identity.sessionId, region: this.options.region }),
    });
    if (!response.ok) throw new Error(`multiplayer_access_token_failed_${response.status}`);
    const payload = await response.json() as { accessToken?: unknown; controllerUrl?: unknown };
    if (typeof payload.accessToken !== "string") throw new Error("multiplayer_access_token_missing");
    const controllerUrl = typeof payload.controllerUrl === "string" ? payload.controllerUrl : this.client.controllerUrl;
    if (!controllerUrl) throw new Error("multiplayer_controller_url_missing");
    return { accessToken: payload.accessToken, controllerUrl };
  }

  private onMessage(raw: string): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return this.fail(new Error("invalid_match_message"));
    }
    if (message.type === "matched") {
      const match = message as unknown as MatchedRoom;
      if (!match.ticket || !match.relayUrl) return this.fail(new Error("invalid_matched_message"));
      this.resolveMatched(match);
      for (const listener of this.matchedListeners) listener(match);
      this.socket?.close(1000, "matched");
      return;
    }
    if (message.type === "error") this.fail(new Error(String(message.code || "match_failed")));
  }

  private fail(error: Error): void {
    if (this.cancelled) return;
    this.cancelled = true;
    this.socket?.close(1000, "match_failed");
    this.rejectMatched(error);
    for (const listener of this.errorListeners) listener(error);
  }
}

export type ConnectRoomOptions = {
  socketFactory?: MultiplayerSocketFactory;
  reconnect?: boolean;
  reconnectWindowMs?: number;
};

export type MultiplayerRoomState = {
  sharedState?: Record<string, unknown>;
  seatState?: Record<string, unknown>;
  stateRevision: number;
};

type RoomEventMap = {
  initialized: Record<string, unknown>;
  input: { seat: number; input: Record<string, unknown>; sequence: number };
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
  private heartbeatTimer?: ReturnType<typeof setInterval>;
  private pendingHostRecovery = false;
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

  connect(): Promise<void> {
    return this.openSocket({ type: "join", ticket: this.ticket });
  }

  async initialize(initData: Record<string, unknown>): Promise<void> {
    this.requireHost();
    this.sendFrame(MultiplayerMessageType.roomInit, this.protocol.encodeRoomInit(initData), NO_TARGET_SEAT, 4 * 1024);
  }

  async ready(): Promise<void> {
    this.sendControl({ type: "ready" });
  }

  createInputQueue(options: InputQueueOptions): MultiplayerInputQueue {
    return new MultiplayerInputQueue(this, options);
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
  onState(listener: (value: MultiplayerRoomState) => void): () => void { return this.on("state", listener); }
  onEvent(listener: (value: RoomEventMap["event"]) => void): () => void { return this.on("event", listener); }
  onPeerChanged(listener: (value: RoomEventMap["peerChanged"]) => void): () => void { return this.on("peerChanged", listener); }
  onPhase(listener: (value: RoomEventMap["phase"]) => void): () => void { return this.on("phase", listener); }
  onPaused(listener: (value: RoomEventMap["paused"]) => void): () => void { return this.on("paused", listener); }
  onResumed(listener: () => void): () => void { return this.on("resumed", listener); }
  onBecomeHost(listener: (hostState: Record<string, unknown> | undefined) => void | Promise<void>): () => void { return this.on("becomeHost", listener); }
  onClosed(listener: (value: RoomEventMap["closed"]) => void): () => void { return this.on("closed", listener); }
  onError(listener: (error: Error) => void): () => void { return this.on("error", listener); }

  sendAggregatedInput(value: Record<string, unknown>, firstSequence: number, lastSequence: number): void {
    const payload = this.protocol.encodeInput(value);
    this.sendFrame(MultiplayerMessageType.inputBatch, payload, NO_TARGET_SEAT, 512, lastSequence || firstSequence);
  }

  private openSocket(authentication: Record<string, unknown>): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = (this.options.socketFactory ?? defaultSocketFactory)(this.relayUrl);
      this.socket = socket;
      socket.binaryType = "arraybuffer";
      let welcomed = false;
      socket.addEventListener("open", () => socket.send(JSON.stringify(authentication)));
      socket.addEventListener("message", (event) => {
        if (typeof event.data === "string") {
          const message = JSON.parse(event.data) as Record<string, unknown>;
          if (message.type === "welcome" && !welcomed) {
            welcomed = true;
            this.applyWelcome(message);
            this.attachLifecycle();
            this.startHeartbeat();
            resolve();
          } else {
            void this.onControl(message);
          }
          return;
        }
        const data = event.data instanceof ArrayBuffer ? event.data : event.data instanceof Blob ? event.data.arrayBuffer() : Promise.resolve(event.data as ArrayBuffer);
        void Promise.resolve(data).then((buffer) => this.onBinary(buffer)).catch((error) => this.emit("error", asError(error)));
      });
      socket.addEventListener("error", () => {
        if (!welcomed) reject(new Error("room_connection_failed"));
        else this.emit("error", new Error("room_connection_failed"));
      });
      socket.addEventListener("close", (event) => {
        this.stopHeartbeat();
        if (!welcomed) reject(new Error(event.reason || "room_connection_closed"));
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
    this.isHost = this.seat === this.hostSeat;
    this.sessionToken = String(message.sessionToken);
    this.reconnectStartedAt = undefined;
  }

  private async onControl(message: Record<string, unknown>): Promise<void> {
    if (message.type === "error") return this.emit("error", new Error(String(message.code || "multiplayer_error")));
    if (message.type === "peer_joined" || message.type === "peer_disconnected" || message.type === "peer_reconnected" || message.type === "peer_ready") {
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
      return this.emit("input", { seat: frame.targetSeat, input: this.protocol.decodeInput(frame.payload), sequence: frame.sequence });
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

  private sendFrame(type: number, payload: Uint8Array, targetSeat: number, limit: number, sequence?: number): void {
    if (payload.byteLength > limit) throw new Error("payload_too_large");
    if (this.socket?.readyState !== 1) throw new Error("room_connection_unavailable");
    this.socket.send(encodeMultiplayerFrame({
      type,
      flags: 0,
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
    this.heartbeatTimer = setInterval(() => {
      if (this.socket?.readyState === 1) this.sendControl({
        type: "heartbeat",
        sentAt: Date.now(),
        foreground: typeof document === "undefined" || document.visibilityState !== "hidden",
      });
    }, interval);
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
    setTimeout(() => {
      if (this.closed || !this.sessionToken) return;
      void this.openSocket({ type: "resume", sessionToken: this.sessionToken }).catch(() => this.scheduleReconnect());
    }, 250);
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
  aggregate: (inputs: readonly Record<string, unknown>[]) => Record<string, unknown> | undefined;
  onError?: (error: Error) => void;
};

export class MultiplayerInputQueue {
  private readonly values: Array<{ sequence: number; value: Record<string, unknown> }> = [];
  private nextSequence = 0;
  private readonly timer: ReturnType<typeof setInterval>;
  private readonly room: MultiplayerRoom;
  private readonly options: InputQueueOptions;

  constructor(room: MultiplayerRoom, options: InputQueueOptions) {
    this.room = room;
    this.options = options;
    this.timer = setInterval(() => this.flush(), Math.max(50, options.intervalMs ?? 50));
  }

  push(value: Record<string, unknown>): void {
    const maximum = Math.max(1, this.options.maxQueuedInputs ?? 128);
    if (this.values.length >= maximum) this.values.shift();
    this.values.push({ sequence: ++this.nextSequence, value });
  }

  flush(): void {
    if (this.values.length === 0) return;
    const pending = this.values.splice(0);
    try {
      const result = this.options.aggregate(pending.map((item) => item.value));
      if (result) this.room.sendAggregatedInput(result, pending[0].sequence, pending[pending.length - 1].sequence);
    } catch (error) {
      this.options.onError?.(asError(error));
    }
  }

  close(): void {
    clearInterval(this.timer);
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

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}
