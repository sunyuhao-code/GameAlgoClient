import assert from "node:assert/strict";
import test from "node:test";
import { defineMultiplayerProtocol } from "./multiplayer-protocol.ts";
import {
  connectRoom,
  GameAlgoMatchmakingClient,
  GameAlgoMultiplayerError,
  type MultiplayerRoom,
} from "./multiplayer.ts";
import {
  decodeMultiplayerFrame,
  encodeMultiplayerFrame,
  MultiplayerMessageType,
  RELIABLE_INPUT_FLAG,
} from "./multiplayer-wire.ts";

const protocol = defineMultiplayerProtocol({
  id: "multiplayer-test",
  version: 1,
  roomInit: { seed: "u32" },
  sharedState: { score: "u16" },
  seatState: { secret: "u8" },
  hostState: { score: "u16" },
  input: { actions: "u8" },
});

test("a promoted host sends a heartbeat immediately", async (context) => {
  const { room, socket } = await connectedRoom({ seat: 1, hostSeat: 0 });
  context.after(() => room.disconnect({ reconnect: false }));
  socket.sent.length = 0;

  socket.receive(JSON.stringify({ type: "host_migrating", hostSeat: 1, hostEpoch: 2 }));

  const heartbeat = socket.sent.find((value): value is string => (
    typeof value === "string" && JSON.parse(value).type === "heartbeat"
  ));
  assert.ok(heartbeat, "host promotion must not wait for the first heartbeat interval");
  assert.equal(room.isHost, true);
  assert.equal(room.hostEpoch, 2);
});

test("room roster keeps connection state in sync with peer lifecycle messages", async (context) => {
  const { room, socket } = await connectedRoom({ seat: 0, hostSeat: 0, roster: [
    { seat: 0, connected: true, canHost: true, teamIndex: 0 },
    { seat: 1, connected: true, canHost: true, teamIndex: 1 },
  ] });
  context.after(() => room.disconnect({ reconnect: false }));

  socket.receive(JSON.stringify({ type: "peer_disconnected", seat: 1 }));
  assert.equal(room.roster.find((member) => member.seat === 1)?.connected, false);
  socket.receive(JSON.stringify({ type: "peer_reconnected", seat: 1 }));
  assert.equal(room.roster.find((member) => member.seat === 1)?.connected, true);
  assert.equal(room.roster.find((member) => member.seat === 1)?.teamIndex, 1);
});

test("input queues retain paused values and reliable batches wait for acknowledgement", async (context) => {
  const { room, socket } = await connectedRoom({ seat: 1, hostSeat: 0 });
  context.after(() => room.disconnect({ reconnect: false }));
  const errors: Error[] = [];
  const queue = room.createInputQueue({
    delivery: "reliable",
    intervalMs: 10_000,
    ackTimeoutMs: 10_000,
    aggregate: (values) => ({ actions: values.length }),
    onError: (error) => errors.push(error),
  });
  context.after(() => queue.close());
  socket.sent.length = 0;

  socket.receive(JSON.stringify({ type: "room_phase", phase: "host_grace" }));
  queue.push({ action: "tap" });
  queue.flush();
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputBatch).length, 0);

  socket.receive(JSON.stringify({ type: "room_phase", phase: "active" }));
  await settle();
  const first = binaryFrames(socket, MultiplayerMessageType.inputBatch);
  assert.equal(first.length, 1);
  assert.equal(first[0].flags & RELIABLE_INPUT_FLAG, RELIABLE_INPUT_FLAG);

  queue.push({ action: "tap-again" });
  queue.flush();
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputBatch).length, 1, "only one reliable batch may be in flight");

  socket.receive(JSON.stringify({ type: "room_phase", phase: "host_grace" }));
  socket.receive(JSON.stringify({ type: "room_phase", phase: "active" }));
  await settle();
  assert.equal(
    binaryFrames(socket, MultiplayerMessageType.inputBatch).length,
    2,
    "resuming must retry the in-flight batch without waiting for the acknowledgement timeout",
  );

  socket.receive(encodeMultiplayerFrame({
    type: MultiplayerMessageType.inputAck,
    flags: 0,
    targetSeat: 1,
    hostEpoch: 1,
    sequence: first[0].sequence,
    stateRevision: 0,
    payload: new Uint8Array(),
  }).buffer);
  await settle();
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputBatch).length, 3);
  assert.deepEqual(errors, []);

});

test("only one reliable input queue may exist per room", async (context) => {
  const { room } = await connectedRoom({ seat: 1, hostSeat: 0 });
  context.after(() => room.disconnect({ reconnect: false }));
  const options = {
    delivery: "reliable" as const,
    aggregate: (values: readonly Record<string, unknown>[]) => ({ actions: values.length }),
  };
  const first = room.createInputQueue(options);
  context.after(() => first.close());

  assert.throws(() => room.createInputQueue(options), (error: unknown) => {
    assert.ok(error instanceof GameAlgoMultiplayerError);
    assert.equal(error.code, "reliable_input_queue_exists");
    assert.equal(error.phase, "input");
    assert.equal(error.retryable, false);
    return true;
  });

  first.close();
  const replacement = room.createInputQueue(options);
  replacement.close();
});

test("a former host silently drops input already in transit", async (context) => {
  const { room, socket } = await connectedRoom({ seat: 0, hostSeat: 0 });
  context.after(() => room.disconnect({ reconnect: false }));
  const inputs: number[] = [];
  const errors: Error[] = [];
  room.onInput(({ sequence }) => inputs.push(sequence));
  room.onError((error) => errors.push(error));
  socket.sent.length = 0;

  socket.receive(JSON.stringify({ type: "host_changed", hostSeat: 1, hostEpoch: 2 }));
  socket.receive(encodeMultiplayerFrame({
    type: MultiplayerMessageType.inputBatch,
    flags: RELIABLE_INPUT_FLAG,
    targetSeat: 1,
    hostEpoch: 1,
    sequence: 7,
    stateRevision: 0,
    payload: protocol.encodeInput({ actions: 1 }),
  }).buffer);
  await settle();

  assert.deepEqual(inputs, []);
  assert.deepEqual(errors, []);
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputAck).length, 0);
});

test("a host acknowledges and de-duplicates reliable input", async (context) => {
  const { room, socket } = await connectedRoom({ seat: 0, hostSeat: 0 });
  context.after(() => room.disconnect({ reconnect: false }));
  const inputs: number[] = [];
  room.onInput(({ sequence }) => inputs.push(sequence));
  socket.sent.length = 0;
  const input = encodeMultiplayerFrame({
    type: MultiplayerMessageType.inputBatch,
    flags: RELIABLE_INPUT_FLAG,
    targetSeat: 1,
    hostEpoch: 1,
    sequence: 7,
    stateRevision: 0,
    payload: protocol.encodeInput({ actions: 1 }),
  }).buffer;

  socket.receive(input);
  socket.receive(input);
  await settle();

  assert.deepEqual(inputs, [7]);
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputAck).length, 2, "duplicates still need an acknowledgement");
});

test("room join errors expose a stable code, phase and retryability", async () => {
  const socket = new FakeSocket();
  const connecting = connectRoom("ws://relay.test/room", "bad-ticket", protocol, {
    connectRetries: 0,
    socketFactory: () => socket as unknown as WebSocket,
  });
  socket.open();
  socket.receive(JSON.stringify({ type: "error", code: "invalid_ticket" }));

  await assert.rejects(connecting, (error: unknown) => {
    assert.ok(error instanceof GameAlgoMultiplayerError);
    assert.equal(error.code, "invalid_ticket");
    assert.equal(error.phase, "room_join");
    assert.equal(error.retryable, false);
    return true;
  });
});

test("match timeout is terminal and not classified as a retryable connection failure", async () => {
  const sockets: FakeSocket[] = [];
  const matchmaking = new GameAlgoMatchmakingClient({
    apiBaseUrl: "https://api.test",
    gameKey: "ga_live_test",
    fetchImpl: fetch,
    identity: async () => ({ userId: "user-a", sessionId: "session-a" }),
    socketFactory: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket as unknown as WebSocket;
    },
  });
  const handle = matchmaking.join({
    accessToken: "access-token",
    controllerUrl: "ws://controller.test/match",
    queueId: "casual_1v1",
    protocolHash: protocol.hash,
    connectionRetries: 2,
  });

  await waitFor(() => sockets.length === 1);
  sockets[0].open();
  sockets[0].receive(JSON.stringify({ type: "error", code: "match_timeout" }));

  await assert.rejects(handle.waitForMatched(), (error: unknown) => {
    assert.ok(error instanceof GameAlgoMultiplayerError);
    assert.equal(error.code, "match_timeout");
    assert.equal(error.phase, "match");
    assert.equal(error.retryable, false);
    return true;
  });
  assert.equal(sockets.length, 1);
});

test("lobby handles create, start and resolve the existing matched room contract", async () => {
  const sockets: FakeSocket[] = [];
  const matchmaking = new GameAlgoMatchmakingClient({
    apiBaseUrl: "https://api.test",
    gameKey: "ga_live_test",
    fetchImpl: fetch,
    identity: async () => ({ userId: "user-a", sessionId: "session-a" }),
    socketFactory: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket as unknown as WebSocket;
    },
  });
  const handle = matchmaking.createLobby({
    accessToken: "access-token",
    controllerUrl: "ws://controller.test/match",
    queueId: "custom_duel",
    protocolHash: protocol.hash,
    visibility: "public",
    metadata: { map: "small" },
  });

  await waitFor(() => sockets.length === 1);
  sockets[0].open();
  const create = JSON.parse(String(sockets[0].sent[0]));
  assert.equal(create.type, "create_lobby");
  assert.equal(create.queueId, "custom_duel");
  assert.deepEqual(create.metadata, { map: "small" });

  sockets[0].receive(JSON.stringify({
    type: "lobby_snapshot",
    lobby: {
      lobbyId: "lobby-a",
      roomCode: "ABC123",
      queueId: "custom_duel",
      protocolHash: protocol.hash,
      visibility: "public",
      launchMode: "direct",
      state: "open",
      minPlayers: 2,
      maxPlayers: 2,
      playerCount: 1,
      metadata: { map: "small" },
      createdAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      selfMemberId: "member-a",
      leaderMemberId: "member-a",
      isLeader: true,
      members: [{ memberId: "member-a", userId: "user-a", isLeader: true, canHost: true }],
    },
  }));
  assert.equal((await handle.waitForLobby()).roomCode, "ABC123");

  handle.kick("member-b");
  assert.deepEqual(JSON.parse(String(sockets[0].sent.at(-1))), { type: "lobby_kick", memberId: "member-b" });
  handle.start();
  assert.equal(JSON.parse(String(sockets[0].sent.at(-1))).type, "lobby_start");
  sockets[0].receive(JSON.stringify({
    type: "matched",
    roomId: "room-a",
    relayId: "relay-a",
    relayUrl: "ws://relay.test/room",
    seat: 0,
    hostSeat: 0,
    teamIndex: 1,
    ticket: "ticket-a",
  }));
  const matched = await handle.waitForMatched();
  assert.equal(matched.roomId, "room-a");
  assert.equal(matched.teamIndex, 1);
});

test("lobby listing uses the controller HTTP endpoint and bearer access token", async () => {
  let requestedUrl = "";
  let authorization = "";
  const matchmaking = new GameAlgoMatchmakingClient({
    apiBaseUrl: "https://api.test",
    gameKey: "ga_live_test",
    identity: async () => ({ userId: "user-a", sessionId: "session-a" }),
    fetchImpl: async (input, init) => {
      requestedUrl = String(input);
      authorization = new Headers(init?.headers).get("authorization") ?? "";
      return new Response(JSON.stringify({
        items: [{
          lobbyId: "lobby-a",
          queueId: "custom_duel",
          protocolHash: protocol.hash,
          visibility: "public",
          launchMode: "direct",
          state: "open",
          minPlayers: 2,
          maxPlayers: 2,
          playerCount: 1,
          metadata: {},
          createdAt: new Date().toISOString(),
          expiresAt: new Date(Date.now() + 60_000).toISOString(),
        }],
      }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });

  const page = await matchmaking.listLobbies({
    accessToken: "access-token",
    controllerUrl: "wss://controller.test/match",
    queueId: "custom_duel",
    protocolHash: protocol.hash,
    limit: 20,
  });

  const url = new URL(requestedUrl);
  assert.equal(url.protocol, "https:");
  assert.equal(url.pathname, "/match/lobbies");
  assert.equal(url.searchParams.get("queueId"), "custom_duel");
  assert.equal(authorization, "Bearer access-token");
  assert.equal(page.items[0].lobbyId, "lobby-a");
});

test("matchmaking retries a transient controller connection with the same identity", async () => {
  const sockets: FakeSocket[] = [];
  const matchmaking = new GameAlgoMatchmakingClient({
    apiBaseUrl: "https://api.test",
    gameKey: "ga_live_test",
    fetchImpl: fetch,
    identity: async () => ({ userId: "user-a", sessionId: "session-a" }),
    socketFactory: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket as unknown as WebSocket;
    },
  });
  const handle = matchmaking.join({
    accessToken: "access-token",
    controllerUrl: "ws://controller.test/match",
    queueId: "casual_1v1",
    protocolHash: protocol.hash,
    connectionRetries: 1,
    retryDelayMs: 50,
  });

  await waitFor(() => sockets.length === 1);
  sockets[0].open();
  sockets[0].error();
  await waitFor(() => sockets.length === 2);
  sockets[1].open();
  sockets[1].receive(JSON.stringify({
    type: "matched",
    roomId: "room-a",
    relayId: "relay-a",
    relayUrl: "ws://relay.test/room",
    seat: 0,
    hostSeat: 0,
    ticket: "ticket-a",
  }));

  assert.equal((await handle.waitForMatched()).roomId, "room-a");
  const join = JSON.parse(String(sockets[1].sent[0]));
  assert.equal(join.accessToken, "access-token");
  assert.equal(join.queueId, "casual_1v1");
});

async function connectedRoom(input: {
  seat: number;
  hostSeat: number;
  roster?: Array<{ seat: number; connected: boolean; canHost: boolean; teamIndex?: number }>;
}): Promise<{ room: MultiplayerRoom; socket: FakeSocket }> {
  const socket = new FakeSocket();
  const connecting = connectRoom("ws://relay.test/room", "ticket", protocol, {
    connectRetries: 0,
    socketFactory: () => socket as unknown as WebSocket,
  });
  socket.open();
  socket.receive(JSON.stringify({
    type: "welcome",
    roomId: "room-test",
    seat: input.seat,
    hostSeat: input.hostSeat,
    hostEpoch: 1,
    phase: "active",
    sessionToken: "session-token",
    roster: input.roster,
  }));
  return { room: await connecting, socket };
}

function binaryFrames(socket: FakeSocket, type: number) {
  return socket.sent
    .filter((value): value is Uint8Array => value instanceof Uint8Array)
    .map((value) => decodeMultiplayerFrame(value))
    .filter((frame) => frame.type === type);
}

function settle(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

async function waitFor(condition: () => boolean, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() >= deadline) throw new Error("condition_timeout");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

class FakeSocket {
  readyState = 0;
  binaryType = "blob";
  readonly sent: Array<string | Uint8Array> = [];
  private readonly listeners = new Map<string, Set<(event: never) => void>>();

  addEventListener(type: string, listener: (event: never) => void): void {
    let listeners = this.listeners.get(type);
    if (!listeners) {
      listeners = new Set();
      this.listeners.set(type, listeners);
    }
    listeners.add(listener);
  }

  send(value: string | ArrayBufferLike | ArrayBufferView): void {
    if (typeof value === "string") this.sent.push(value);
    else if (ArrayBuffer.isView(value)) this.sent.push(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
    else this.sent.push(new Uint8Array(value));
  }

  close(code = 1000, reason = ""): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.dispatch("close", { code, reason });
  }

  open(): void {
    this.readyState = 1;
    this.dispatch("open", {});
  }

  receive(data: string | ArrayBuffer): void {
    this.dispatch("message", { data });
  }

  error(): void {
    this.dispatch("error", {});
  }

  private dispatch(type: string, event: object): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event as never);
  }
}
