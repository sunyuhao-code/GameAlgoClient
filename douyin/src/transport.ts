import type { GameAlgoFetch, GameAlgoHttpResponse } from "../../rest-api/src/types.ts";
import type { DouyinHost } from "./host.ts";

/** tt.request accepts structured JSON data and dataType=string, unlike wx.request. */
export class GamePropelDouyinTransport {
  private readonly pending = new Set<() => void>();
  private closed = false;
  readonly fetch: GameAlgoFetch;

  constructor(host: DouyinHost, timeoutMs = 15_000) {
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) throw new Error("Invalid requestTimeoutMs");
    this.fetch = (url, init = {}) => new Promise<GameAlgoHttpResponse>((resolve, reject) => {
      if (this.closed) { reject(new Error("GamePropel client is closed")); return; }
      if (init.method !== undefined && init.method !== "GET" && init.method !== "POST") { reject(new Error("Unsupported Douyin request method")); return; }
      let data: Record<string, unknown> | unknown[] = {};
      try {
        if (init.body) {
          const value = JSON.parse(init.body);
          if (!value || typeof value !== "object") throw new Error("Douyin request body must be a JSON object or array");
          data = value;
        }
      } catch (error) { reject(error); return; }
      let settled = false;
      let task: ReturnType<DouyinHost["request"]>;
      const finish = (error?: unknown, result?: GameAlgoHttpResponse) => {
        if (settled) return;
        settled = true; clearTimeout(timer); this.pending.delete(cancel);
        if (result) resolve(result);
        else {
          const failure = error as { errMsg?: unknown; errNo?: unknown } | undefined;
          reject(error instanceof Error ? error : Object.assign(new Error(typeof failure?.errMsg === "string" ? failure.errMsg : "Douyin network request failed"), { code: failure?.errNo }));
        }
      };
      const cancel = () => { finish(new Error("GamePropel client is closed")); try { task?.abort?.(); } catch { /* Already settled. */ } };
      const timer = setTimeout(() => { finish(new Error("Douyin request timed out")); try { task?.abort?.(); } catch { /* Already settled. */ } }, timeoutMs);
      this.pending.add(cancel);
      try {
        task = host.request({ url, method: init.method ?? "GET", data, header: init.headers, timeout: timeoutMs, dataType: "string",
          success(result) {
            try {
              const status = result.statusCode;
              if (!Number.isInteger(status) || status < 100 || status > 599) throw new Error("Invalid Douyin HTTP status");
              const body = typeof result.data === "string" ? result.data : JSON.stringify(result.data ?? null);
              const headers = new Map(Object.entries(result.header ?? {}).map(([key, value]) => [key.toLowerCase(), String(value)]));
              finish(undefined, { status, ok: status >= 200 && status < 300, headers: { get: name => headers.get(name.toLowerCase()) ?? null },
                text: async () => body, json: async () => JSON.parse(body) });
            } catch (error) { finish(error); }
          }, fail: error => finish(error),
        });
      } catch (error) { finish(error); }
    });
  }
  close(): void { this.closed = true; for (const cancel of [...this.pending]) cancel(); }
}
