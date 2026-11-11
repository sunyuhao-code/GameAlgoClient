import type { GameAlgoFetch, GameAlgoHttpResponse } from "../../rest-api/src/types.ts";
import type { WechatHost } from "./host.ts";

/** wx.request adapter; never installs or reads a browser fetch polyfill. */
export class GameAlgoWechatTransport {
  private readonly pending = new Set<() => void>();
  private closed = false;
  readonly fetch: GameAlgoFetch;

  constructor(host: WechatHost, timeoutMs = 15_000) {
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000) throw new Error("Invalid requestTimeoutMs");
    this.fetch = (url, init = {}) => new Promise<GameAlgoHttpResponse>((resolve, reject) => {
      if (this.closed) { reject(new Error("GameAlgo client is closed")); return; }
      if (init.method !== undefined && init.method !== "GET" && init.method !== "POST") {
        reject(new Error("Unsupported WeChat request method")); return;
      }
      let settled = false;
      let task: ReturnType<WechatHost["request"]>;
      const finish = (error?: unknown, response?: GameAlgoHttpResponse): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.pending.delete(cancel);
        if (response) resolve(response);
        else reject(error instanceof Error ? error : new Error("WeChat network request failed"));
      };
      const cancel = (): void => {
        finish(new Error("GameAlgo client is closed"));
        try { task?.abort?.(); } catch { /* Already settled. */ }
      };
      const timer = setTimeout(() => {
        finish(new Error("WeChat network request timed out"));
        try { task?.abort?.(); } catch { /* Already settled. */ }
      }, timeoutMs);
      this.pending.add(cancel);
      try {
        task = host.request({
          url, method: init.method ?? "GET", data: init.body, header: init.headers,
          timeout: timeoutMs, dataType: "text", responseType: "text",
          success(result) {
            try {
              const status = result.statusCode;
              if (!Number.isInteger(status) || status < 100 || status > 599) throw new Error("Invalid WeChat HTTP status");
              const text = typeof result.data === "string" ? result.data : JSON.stringify(result.data ?? null);
              const headers = new Map(Object.entries(result.header ?? {}).map(([key, value]) => [key.toLowerCase(), String(value)]));
              finish(undefined, {
                status, ok: status >= 200 && status < 300,
                headers: { get: name => headers.get(name.toLowerCase()) ?? null },
                text: async () => text,
                json: async () => JSON.parse(text),
              });
            } catch (error) { finish(error); }
          },
          fail: error => finish(error),
        });
      } catch (error) { finish(error); }
    });
  }

  close(): void {
    this.closed = true;
    for (const cancel of [...this.pending]) cancel();
  }
}
