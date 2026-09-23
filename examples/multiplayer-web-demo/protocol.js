import { defineMultiplayerProtocol } from "../../web/dist/web/src/index.js";

export const DemoProtocol = defineMultiplayerProtocol({
  id: "counter-duel",
  version: 1,
  roomInit: {
    seed: "u32",
    maxScore: "u8",
  },
  sharedState: {
    tick: "u32",
    scores: { type: "array", items: "u16", maxLength: 2 },
    winner: "i8",
  },
  seatState: {
    ownScore: "u16",
    lastProcessedInputSeq: "u32",
  },
  hostState: {
    tick: "u32",
    scores: { type: "array", items: "u16", maxLength: 2 },
    winner: "i8",
  },
  input: {
    taps: "u8",
  },
  events: {
    winner: { seat: "u8" },
  },
});
