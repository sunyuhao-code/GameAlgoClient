export const MULTIPLAYER_FRAME_HEADER_BYTES = 20;
export const NO_TARGET_SEAT = 0xff;

export const MultiplayerMessageType = {
  roomInit: 1,
  sharedState: 2,
  seatState: 3,
  hostState: 4,
  inputBatch: 5,
  gameEvent: 6,
  hostRecovery: 7,
} as const;

export type MultiplayerFrame = {
  type: number;
  flags: number;
  targetSeat: number;
  hostEpoch: number;
  sequence: number;
  stateRevision: number;
  payload: Uint8Array;
};

export function encodeMultiplayerFrame(frame: MultiplayerFrame): Uint8Array {
  const result = new Uint8Array(MULTIPLAYER_FRAME_HEADER_BYTES + frame.payload.byteLength);
  const view = new DataView(result.buffer);
  result[0] = 0x47;
  result[1] = 0x41;
  result[2] = 1;
  result[3] = frame.type;
  result[4] = frame.flags;
  result[5] = frame.targetSeat;
  view.setUint32(8, frame.hostEpoch, true);
  view.setUint32(12, frame.sequence, true);
  view.setUint32(16, frame.stateRevision, true);
  result.set(frame.payload, MULTIPLAYER_FRAME_HEADER_BYTES);
  return result;
}

export function decodeMultiplayerFrame(value: ArrayBuffer | Uint8Array): MultiplayerFrame {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  if (bytes.byteLength < MULTIPLAYER_FRAME_HEADER_BYTES || bytes[0] !== 0x47 || bytes[1] !== 0x41 || bytes[2] !== 1) {
    throw new Error("invalid multiplayer frame");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return {
    type: bytes[3],
    flags: bytes[4],
    targetSeat: bytes[5],
    hostEpoch: view.getUint32(8, true),
    sequence: view.getUint32(12, true),
    stateRevision: view.getUint32(16, true),
    payload: bytes.subarray(MULTIPLAYER_FRAME_HEADER_BYTES),
  };
}
