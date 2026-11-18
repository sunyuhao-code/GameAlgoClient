import { GameAlgoApiError } from "../../rest-api/src/core-client.ts";

/** Bound headers and body consumption together. A host fetch may ignore abort. */
export async function fetchWithDeadline(
  fetchImpl: typeof fetch,
  input: Parameters<typeof fetch>[0],
  init: RequestInit,
  timeoutMs: number,
  isConfig: boolean,
): Promise<Response> {
  const controller = typeof AbortController === "function" ? new AbortController() : undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      reject(new GameAlgoApiError(0, `HTTP request timed out after ${timeoutMs}ms`, "request_timeout"));
      controller?.abort();
    }, timeoutMs);
    timer.unref?.();
  });
  const request = (async () => {
    const response = await fetchImpl(input, { ...init, ...(controller ? { signal: controller.signal } : {}) });
    const body = await response.text();
    if (isConfig && response.ok) {
      let config: { contextId?: unknown; experiments?: unknown; configFiles?: unknown } | undefined;
      try { config = JSON.parse(body); } catch { /* Invalid configuration remains retryable. */ }
      if (!config || typeof config.contextId !== "string" || !config.contextId.trim()
        || !Array.isArray(config.experiments) || !Array.isArray(config.configFiles)) {
        throw new GameAlgoApiError(0, "Invalid config response: contextId, experiments and configFiles are required", "invalid_config");
      }
    }
    return new Response(body || null, { status: response.status, statusText: response.statusText, headers: response.headers });
  })();
  try { return await Promise.race([request, timeout]); }
  finally { if (timer) clearTimeout(timer); }
}
