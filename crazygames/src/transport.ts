import { encodeUtf8 } from "../../rest-api/src/utf8.ts";
import type { GameAlgoFetch } from "../../rest-api/src/types.ts";

export class CrazyGamesTransport {
  private readonly pending = new Set<() => void>();
  private closed = false;
  readonly fetch: GameAlgoFetch;
  constructor(browserFetch: typeof fetch, timeoutMs = 10_000) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("requestTimeoutMs must be positive");
    this.fetch = async (url, init = {}) => {
      if (this.closed) throw new Error("GamePropel client is closed");
      const controller = new AbortController();
      const eventBatch = /\/v1\/events\/batch(?:\?|$)/.test(url);
      const keepalive = eventBatch && encodeUtf8(init.body ?? "").length <= 60 * 1024;
      let cancel!: () => void;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const stopped = new Promise<never>((_, reject) => {
        cancel = () => { controller.abort(); reject(new Error("GamePropel client is closed")); };
        timer = setTimeout(() => { controller.abort(); reject(new Error("GamePropel request timed out")); }, timeoutMs);
      });
      this.pending.add(cancel);
      try {
        // Include response-body reads in the timeout, not only receipt of headers.
        const operation = (async () => {
          const response = await browserFetch(url, { ...init, keepalive, signal: controller.signal });
          const body = await response.text();
          return { ok: response.ok, status: response.status, headers: response.headers,
            text: async () => body, json: async () => JSON.parse(body) as unknown };
        })();
        return await Promise.race([operation, stopped]);
      } finally {
        if (timer) clearTimeout(timer);
        this.pending.delete(cancel);
      }
    };
  }
  close(): void {
    this.closed = true;
    for (const cancel of this.pending) cancel();
    this.pending.clear();
  }
}
