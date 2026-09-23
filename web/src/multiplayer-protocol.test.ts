import assert from "node:assert/strict";
import test from "node:test";
import { defineMultiplayerProtocol } from "./multiplayer-protocol.ts";

test("static multiplayer protocol round-trips bounded binary values", () => {
  const protocol = defineMultiplayerProtocol({
    id: "demo",
    version: 1,
    roomInit: { seed: "u32", map: { type: "string", maxBytes: 16 } },
    sharedState: { tick: "u32", x: "i16", alive: "bool" },
    seatState: { score: "u16" },
    hostState: { tick: "u32", scores: { type: "array", items: "u16", maxLength: 4 } },
    input: { direction: { type: "enum", values: ["left", "right"] }, pressed: "bool" },
    events: { winner: { seat: "u8" } },
  });
  assert.match(protocol.hash, /^ga1_[0-9a-f]{16}$/);
  assert.deepEqual(protocol.decodeRoomInit(protocol.encodeRoomInit({ seed: 42, map: "island" })), { seed: 42, map: "island" });
  assert.deepEqual(protocol.decodeSharedState(protocol.encodeSharedState({ tick: 7, x: -12, alive: true })), { tick: 7, x: -12, alive: true });
  assert.deepEqual(protocol.decodeHostState(protocol.encodeHostState({ tick: 9, scores: [1, 2] })), { tick: 9, scores: [1, 2] });
  assert.deepEqual(protocol.decodeEvent(protocol.encodeEvent("winner", { seat: 1 })), { type: "winner", payload: { seat: 1 } });
  assert.throws(() => protocol.encodeRoomInit({ seed: 1, map: "x".repeat(17) }), /bound/);
});
