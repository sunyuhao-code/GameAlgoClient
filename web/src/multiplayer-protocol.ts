export type MultiplayerPrimitive = "bool" | "u8" | "i8" | "u16" | "i16" | "u32" | "i32" | "f32";

export type MultiplayerFieldSchema = MultiplayerPrimitive | {
  type: "string" | "bytes";
  maxBytes: number;
} | {
  type: "enum";
  values: readonly string[];
} | {
  type: "array";
  items: MultiplayerFieldSchema;
  maxLength: number;
} | {
  type: "struct";
  fields: MultiplayerStructSchema;
};

export type MultiplayerStructSchema = Record<string, MultiplayerFieldSchema>;

export type MultiplayerProtocolDefinition = {
  id: string;
  version: number;
  roomInit: MultiplayerStructSchema;
  sharedState: MultiplayerStructSchema;
  seatState: MultiplayerStructSchema;
  hostState: MultiplayerStructSchema;
  input: MultiplayerStructSchema;
  events?: Record<string, MultiplayerStructSchema>;
};

export type MultiplayerProtocol = {
  id: string;
  version: number;
  hash: string;
  encodeRoomInit(value: Record<string, unknown>): Uint8Array;
  decodeRoomInit(value: Uint8Array): Record<string, unknown>;
  encodeSharedState(value: Record<string, unknown>): Uint8Array;
  decodeSharedState(value: Uint8Array): Record<string, unknown>;
  encodeSeatState(value: Record<string, unknown>): Uint8Array;
  decodeSeatState(value: Uint8Array): Record<string, unknown>;
  encodeHostState(value: Record<string, unknown>): Uint8Array;
  decodeHostState(value: Uint8Array): Record<string, unknown>;
  encodeInput(value: Record<string, unknown>): Uint8Array;
  decodeInput(value: Uint8Array): Record<string, unknown>;
  encodeEvent(type: string, value: Record<string, unknown>): Uint8Array;
  decodeEvent(value: Uint8Array): { type: string; payload: Record<string, unknown> };
};

export function defineMultiplayerProtocol(definition: MultiplayerProtocolDefinition): MultiplayerProtocol {
  if (!/^[A-Za-z0-9._:-]{1,64}$/.test(definition.id)) throw new Error("protocol id is invalid");
  if (!Number.isSafeInteger(definition.version) || definition.version < 1) throw new Error("protocol version must be positive");
  for (const schema of [definition.roomInit, definition.sharedState, definition.seatState, definition.hostState, definition.input]) {
    validateSchema({ type: "struct", fields: schema }, new Set());
  }
  const eventEntries = Object.entries(definition.events ?? {});
  if (eventEntries.length > 255) throw new Error("protocol supports at most 255 event types");
  eventEntries.forEach(([, schema]) => validateSchema({ type: "struct", fields: schema }, new Set()));
  const eventByName = new Map(eventEntries.map(([name, schema], index) => [name, { id: index + 1, schema }]));
  const eventById = new Map(eventEntries.map(([name, schema], index) => [index + 1, { name, schema }]));
  const codec = (schema: MultiplayerStructSchema) => ({
    encode(value: Record<string, unknown>) {
      const writer = new BinaryWriter();
      writeValue(writer, { type: "struct", fields: schema }, value);
      return writer.finish();
    },
    decode(value: Uint8Array) {
      const reader = new BinaryReader(value);
      const result = readValue(reader, { type: "struct", fields: schema }) as Record<string, unknown>;
      if (!reader.done) throw new Error("binary payload has trailing bytes");
      return result;
    },
  });
  const roomInit = codec(definition.roomInit);
  const sharedState = codec(definition.sharedState);
  const seatState = codec(definition.seatState);
  const hostState = codec(definition.hostState);
  const input = codec(definition.input);
  return {
    id: definition.id,
    version: definition.version,
    hash: `ga1_${fnv1a64(JSON.stringify(definition))}`,
    encodeRoomInit: roomInit.encode,
    decodeRoomInit: roomInit.decode,
    encodeSharedState: sharedState.encode,
    decodeSharedState: sharedState.decode,
    encodeSeatState: seatState.encode,
    decodeSeatState: seatState.decode,
    encodeHostState: hostState.encode,
    decodeHostState: hostState.decode,
    encodeInput: input.encode,
    decodeInput: input.decode,
    encodeEvent(type, value) {
      const event = eventByName.get(type);
      if (!event) throw new Error(`unknown multiplayer event: ${type}`);
      const payload = codec(event.schema).encode(value);
      const result = new Uint8Array(payload.byteLength + 1);
      result[0] = event.id;
      result.set(payload, 1);
      return result;
    },
    decodeEvent(value) {
      const event = eventById.get(value[0]);
      if (!event) throw new Error(`unknown multiplayer event id: ${value[0]}`);
      return { type: event.name, payload: codec(event.schema).decode(value.subarray(1)) };
    },
  };
}

class BinaryWriter {
  private bytes: number[] = [];

  writeUint8(value: number): void { this.bytes.push(value & 0xff); }
  writeInt8(value: number): void { this.writeUint8(value); }
  writeUint16(value: number): void { this.bytes.push(value & 0xff, (value >>> 8) & 0xff); }
  writeInt16(value: number): void { this.writeUint16(value); }
  writeUint32(value: number): void {
    this.bytes.push(value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff);
  }
  writeInt32(value: number): void { this.writeUint32(value); }
  writeFloat32(value: number): void {
    const buffer = new ArrayBuffer(4);
    new DataView(buffer).setFloat32(0, value, true);
    this.writeBytes(new Uint8Array(buffer));
  }
  writeBytes(value: Uint8Array): void { for (const byte of value) this.bytes.push(byte); }
  finish(): Uint8Array { return Uint8Array.from(this.bytes); }
}

class BinaryReader {
  private offset = 0;
  private readonly view: DataView;
  private readonly bytes: Uint8Array;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  get done(): boolean { return this.offset === this.bytes.byteLength; }
  readUint8(): number { return this.take(1, (offset) => this.view.getUint8(offset)); }
  readInt8(): number { return this.take(1, (offset) => this.view.getInt8(offset)); }
  readUint16(): number { return this.take(2, (offset) => this.view.getUint16(offset, true)); }
  readInt16(): number { return this.take(2, (offset) => this.view.getInt16(offset, true)); }
  readUint32(): number { return this.take(4, (offset) => this.view.getUint32(offset, true)); }
  readInt32(): number { return this.take(4, (offset) => this.view.getInt32(offset, true)); }
  readFloat32(): number { return this.take(4, (offset) => this.view.getFloat32(offset, true)); }
  readBytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.bytes.byteLength) throw new Error("binary payload ended early");
    const value = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return value;
  }
  private take<T>(length: number, read: (offset: number) => T): T {
    if (this.offset + length > this.bytes.byteLength) throw new Error("binary payload ended early");
    const value = read(this.offset);
    this.offset += length;
    return value;
  }
}

function writeValue(writer: BinaryWriter, schema: MultiplayerFieldSchema, value: unknown): void {
  if (schema === "bool") return writer.writeUint8(value === true ? 1 : value === false ? 0 : invalid("expected bool"));
  if (schema === "u8") return writer.writeUint8(integer(value, 0, 0xff));
  if (schema === "i8") return writer.writeInt8(integer(value, -0x80, 0x7f));
  if (schema === "u16") return writer.writeUint16(integer(value, 0, 0xffff));
  if (schema === "i16") return writer.writeInt16(integer(value, -0x8000, 0x7fff));
  if (schema === "u32") return writer.writeUint32(integer(value, 0, 0xffffffff));
  if (schema === "i32") return writer.writeInt32(integer(value, -0x80000000, 0x7fffffff));
  if (schema === "f32") {
    if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("expected finite f32");
    return writer.writeFloat32(value);
  }
  if (schema.type === "string") {
    if (typeof value !== "string") throw new Error("expected string");
    const bytes = new TextEncoder().encode(value);
    bounded(bytes.byteLength, schema.maxBytes, "string");
    writer.writeUint16(bytes.byteLength);
    return writer.writeBytes(bytes);
  }
  if (schema.type === "bytes") {
    if (!(value instanceof Uint8Array)) throw new Error("expected Uint8Array");
    bounded(value.byteLength, schema.maxBytes, "bytes");
    writer.writeUint16(value.byteLength);
    return writer.writeBytes(value);
  }
  if (schema.type === "enum") {
    const index = schema.values.indexOf(String(value));
    if (index < 0) throw new Error(`unknown enum value: ${String(value)}`);
    return writer.writeUint8(index);
  }
  if (schema.type === "array") {
    if (!Array.isArray(value)) throw new Error("expected array");
    bounded(value.length, schema.maxLength, "array");
    writer.writeUint16(value.length);
    value.forEach((item) => writeValue(writer, schema.items, item));
    return;
  }
  if (schema.type === "struct") {
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("expected object");
    for (const [name, field] of Object.entries(schema.fields)) writeValue(writer, field, (value as Record<string, unknown>)[name]);
  }
}

function readValue(reader: BinaryReader, schema: MultiplayerFieldSchema): unknown {
  if (schema === "bool") return reader.readUint8() !== 0;
  if (schema === "u8") return reader.readUint8();
  if (schema === "i8") return reader.readInt8();
  if (schema === "u16") return reader.readUint16();
  if (schema === "i16") return reader.readInt16();
  if (schema === "u32") return reader.readUint32();
  if (schema === "i32") return reader.readInt32();
  if (schema === "f32") return reader.readFloat32();
  if (schema.type === "string") {
    const length = reader.readUint16();
    bounded(length, schema.maxBytes, "string");
    return new TextDecoder("utf-8", { fatal: true }).decode(reader.readBytes(length));
  }
  if (schema.type === "bytes") {
    const length = reader.readUint16();
    bounded(length, schema.maxBytes, "bytes");
    return new Uint8Array(reader.readBytes(length));
  }
  if (schema.type === "enum") {
    const value = schema.values[reader.readUint8()];
    if (value === undefined) throw new Error("unknown enum id");
    return value;
  }
  if (schema.type === "array") {
    const length = reader.readUint16();
    bounded(length, schema.maxLength, "array");
    return Array.from({ length }, () => readValue(reader, schema.items));
  }
  if (schema.type !== "struct") throw new Error("unsupported schema type");
  const result: Record<string, unknown> = {};
  for (const [name, field] of Object.entries(schema.fields)) result[name] = readValue(reader, field);
  return result;
}

function validateSchema(schema: MultiplayerFieldSchema, ancestors: Set<object>): void {
  if (typeof schema === "string") return;
  if (ancestors.has(schema)) throw new Error("recursive multiplayer schemas are not supported");
  ancestors.add(schema);
  if ((schema.type === "string" || schema.type === "bytes") && (!Number.isSafeInteger(schema.maxBytes) || schema.maxBytes < 0 || schema.maxBytes > 0xffff)) {
    throw new Error("maxBytes must be between 0 and 65535");
  }
  if (schema.type === "enum" && (schema.values.length < 1 || schema.values.length > 256 || new Set(schema.values).size !== schema.values.length)) {
    throw new Error("enum values must contain 1 to 256 unique values");
  }
  if (schema.type === "array") {
    if (!Number.isSafeInteger(schema.maxLength) || schema.maxLength < 0 || schema.maxLength > 0xffff) throw new Error("invalid maxLength");
    validateSchema(schema.items, ancestors);
  }
  if (schema.type === "struct") {
    for (const [name, field] of Object.entries(schema.fields)) {
      if (!/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(name)) throw new Error(`invalid field name: ${name}`);
      validateSchema(field, ancestors);
    }
  }
  ancestors.delete(schema);
}

function integer(value: unknown, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) throw new Error(`integer must be between ${min} and ${max}`);
  return value;
}

function bounded(value: number, maximum: number, type: string): void {
  if (value > maximum) throw new Error(`${type} exceeds configured bound`);
}

function invalid(message: string): never { throw new Error(message); }

function fnv1a64(value: string): string {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(value)) {
    hash ^= BigInt(byte);
    hash = BigInt.asUintN(64, hash * 0x100000001b3n);
  }
  return hash.toString(16).padStart(16, "0");
}
