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

test("input queues retain paused values and reliable batches wait for acknowledgement", async (context) => {
  const { room, socket } = await connectedRoom({ seat: 1, hostSeat: 0 });
  context.after(() => room.disconnect({ reconnect: false }));
  const errors: Error[] = [];
  const queue = room.createInputQueue({
    delivery: "reliable",
    intervalMs: 10_000,
    ackTimeoutMs: 500,
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
  queue.flush();
  const first = binaryFrames(socket, MultiplayerMessageType.inputBatch);
  assert.equal(first.length, 1);
  assert.equal(first[0].flags & RELIABLE_INPUT_FLAG, RELIABLE_INPUT_FLAG);

  queue.push({ action: "tap-again" });
  queue.flush();
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputBatch).length, 1, "only one reliable batch may be in flight");

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
  assert.equal(binaryFrames(socket, MultiplayerMessageType.inputBatch).length, 2);
  assert.deepEqual(errors, []);

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

async function connectedRoom(input: { seat: number; hostSeat: number }): Promise<{ room: MultiplayerRoom; socket: FakeSocket }> {
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
