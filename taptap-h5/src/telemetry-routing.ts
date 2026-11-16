import type { ConfigResponse, GameEvent, JsonValue } from "../../rest-api/src/types.ts";
import { sha256HexSync } from "../../rest-api/src/sha256.ts";

export type TapDbProperties = Record<string, string | boolean>;
const REPORT_PATHS = new Set(["/v1/events/batch", "/v1/attribution", "/v1/context-identifiers", "/v1/diagnostics/sdk", "/v1/diagnostics/init"]);

/** Only telemetry is routed. Config, files, scripts and multiplayer remain direct. */
export function telemetryPath(url: string, method?: string): string | undefined {
  if (method !== "POST") return undefined;
  const path = /\/v1\/(?:events\/batch|attribution|context-identifiers|diagnostics\/(?:sdk|init))$/.exec(url)?.[0];
  return path && REPORT_PATHS.has(path) ? path : undefined;
}

/** Split at UTF-8 boundaries, below TapDB's documented 256-character value limit. */
function parts(value: string): string[] {
  const result: string[] = [];
  let part = "", bytes = 0;
  for (const character of value) {
    const code = character.codePointAt(0)!;
    const size = code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
    if (bytes + size > 240) { result.push(part); part = ""; bytes = 0; }
    part += character; bytes += size;
  }
  if (part || !result.length) result.push(part);
  return result;
}

/** A single native event carries a complete, versioned envelope without truncation. */
export function tapDbEnvelope(envelope: Record<string, unknown>, event: Partial<GameEvent>): TapDbProperties {
  const chunks = parts(JSON.stringify(envelope));
  const properties: TapDbProperties = {
    gamealgo_envelope_version: "1",
    gamealgo_part_count: String(chunks.length),
    gamealgo_event_id: parts(String(event.eventId ?? ""))[0],
    gamealgo_event_type: parts(String(event.eventType ?? ""))[0],
    gamealgo_context_id: parts(String(event.contextId ?? ""))[0],
    gamealgo_device_id: parts(String(event.userId ?? ""))[0],
    gamealgo_session_id: parts(String(event.sessionId ?? ""))[0],
    gamealgo_is_debug: event.isDebug === true,
  };
  chunks.forEach((chunk, index) => { properties[`gamealgo_part_${index}`] = chunk; });
  return properties;
}

/** Native TapDB owns delivery after handoff. Never replay failed host calls in a hot loop. */
export class TapTapTelemetryRouter {
  gamealgoEnabled = true;
  tapdbEnabled = false;
  tapdbExplicitlyDisabled = false;
  private readonly attempted = new Map<string, { promise: Promise<void>; state: "pending" | "accepted" | "failed" }>();
  private readonly limit: number;
  private identity: { userId?: string; sessionId?: string; isDebug?: boolean } = {};
  private readonly send: (name: string, properties: TapDbProperties) => Promise<void>;
  constructor(send: (name: string, properties: TapDbProperties) => Promise<void>, queueLimit = 1000) {
    this.send = send;
    this.limit = Math.max(1000, queueLimit * 2);
  }

  configure(config: ConfigResponse, identity: { userId: string; sessionId: string; isDebug: boolean }): void {
    this.identity = { ...identity };
    this.gamealgoEnabled = config.gamealgoReportingEnabled !== false;
    this.tapdbEnabled = config.tapdbReportingEnabled === true;
    this.tapdbExplicitlyDisabled = config.tapdbReportingEnabled !== undefined && !this.tapdbEnabled;
  }

  async forward(path: string, body: Record<string, unknown>): Promise<number> {
    if (!this.tapdbEnabled) return 0;
    let count = 0;
    const confirmations: Promise<void>[] = [];
    const events = path === "/v1/events/batch" ? body.events as GameEvent[] : undefined;
    const records = events?.map(event => ({ name: "gamealgo_event", event,
      key: `event:${event.eventId}`, envelope: { schemaVersion: 1, path, event } })) ?? (() => {
        const requestId = sha256HexSync(JSON.stringify({ path, body }));
        return [{ name: "gamealgo_request", key: `request:${requestId}`,
          event: { ...this.identity, ...body, eventId: String(body.diagnosticId ?? requestId), eventType: path } as Partial<GameEvent>,
          envelope: { schemaVersion: 1, path, requestId, body } }];
      })();
    for (const record of records) {
      if (!this.tapdbEnabled) break;
      const previous = this.attempted.get(record.key);
      if (previous && (previous.state !== "failed" || this.gamealgoEnabled)) {
        confirmations.push(previous.promise); continue;
      }
      // Construct before recording so serialization failures remain observable.
      const properties = tapDbEnvelope(record.envelope, record.event);
      let resolve!: () => void, reject!: (error: unknown) => void;
      const entry = { state: "pending" as "pending" | "accepted" | "failed", promise: new Promise<void>((yes, no) => { resolve = yes; reject = no; }) };
      this.attempted.set(record.key, entry);
      if (this.attempted.size > this.limit) {
        for (const [key, value] of this.attempted) if (value.state !== "pending") { this.attempted.delete(key); break; }
      }
      count++;
      confirmations.push(entry.promise);
      void this.send(record.name, properties).then(() => { entry.state = "accepted"; resolve(); }, error => { entry.state = "failed"; reject(error); });
    }
    await Promise.all(confirmations);
    return count;
  }

  localReceipt(path: string, body: Record<string, unknown>, tapdbAttempted: number): Record<string, JsonValue> {
    return { ok: true, accepted: 0, skipped: path === "/v1/events/batch" ? (body.events as unknown[]).length : 1,
      tapdbAttempted,
      ...(typeof body.attributionHash === "string" ? { attributionHash: body.attributionHash } : {}),
      ...(typeof body.identifierHash === "string" ? { identifierHash: body.identifierHash } : {}) };
  }

  close(): void { this.tapdbEnabled = false; this.attempted.clear(); }
}
