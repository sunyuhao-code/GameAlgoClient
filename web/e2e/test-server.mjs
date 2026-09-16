import { createHash } from "node:crypto";
import { resolve } from "node:path";

import { createServer } from "vite";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const fixtureRoot = resolve(import.meta.dirname, "fixture");
const strategyScript = `function execute(input) {
  return {
    payload: {
      adjustment: "keep",
      difficulty: input.config.difficulty,
      level: input.state.level ?? input.state.context?.level ?? 0,
      fetchType: typeof fetch,
      documentType: typeof document
    },
    diagnostics: { worker: true }
  };
}`;
const strategyHash = `sha256:${createHash("sha256").update(strategyScript).digest("hex")}`;

export async function startGameAlgoE2EServer() {
  const configRequests = [];
  const eventBatches = [];
  const attributionRequests = [];
  const webViewResults = [];
  let resolveWebViewResults;
  const webViewResultsReady = new Promise((resolveResults) => {
    resolveWebViewResults = resolveResults;
  });

  const vite = await createServer({
    root: fixtureRoot,
    logLevel: "error",
    server: {
      host: "127.0.0.1",
      port: 0,
      strictPort: false,
      fs: { allow: [repositoryRoot] },
    },
    plugins: [{
      name: "gamealgo-e2e-api",
      configureServer(server) {
        server.middlewares.use(async (request, response, next) => {
          const url = new URL(request.url ?? "/", "http://gamealgo.test");
          if (url.pathname === "/v1/scripts/browser-strategy-v1") {
            response.setHeader("content-type", "text/javascript; charset=utf-8");
            response.end(strategyScript);
            return;
          }
          if (request.method !== "POST") {
            next();
            return;
          }
          if (url.pathname === "/v1/config") {
            const body = await readJson(request);
            configRequests.push(body);
            sendJson(response, {
              contextId: `ctx-browser-${configRequests.length}`,
              gameId: "web-browser-e2e",
              environment: "live",
              configVersion: "browser-v1",
              ttlSeconds: 60,
              serverTime: new Date().toISOString(),
              experiments: [{
                key: "browser_strategy",
                experimentId: "experiment-browser",
                variant: "treatment",
                config: { difficulty: "hard" },
                script: {
                  versionId: "browser-strategy-v1",
                  name: "browser-strategy.js",
                  url: "/v1/scripts/browser-strategy-v1",
                  hash: strategyHash,
                },
              }],
              configFiles: [],
            });
            return;
          }
          if (url.pathname === "/v1/events/batch") {
            const body = await readJson(request);
            eventBatches.push(body);
            sendJson(response, { ok: true, accepted: body.events?.length ?? 0 });
            return;
          }
          if (url.pathname === "/v1/attribution") {
            const body = await readJson(request);
            attributionRequests.push(body);
            sendJson(response, { ok: true, accepted: 1, attributionHash: body.attributionHash });
            return;
          }
          if (url.pathname === "/__webview-result") {
            webViewResults.push(await readJson(request));
            sendJson(response, { ok: true });
            if (webViewResults.length >= 2) resolveWebViewResults(webViewResults);
            return;
          }
          next();
        });
      },
    }],
  });

  await vite.listen();
  const address = vite.httpServer?.address();
  if (!address || typeof address !== "object") {
    await vite.close();
    throw new Error("Vite did not expose a TCP address");
  }
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    configRequests,
    eventBatches,
    attributionRequests,
    webViewResults,
    webViewResultsReady,
    close: () => vite.close(),
  };
}

function readJson(request) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      try {
        resolveBody(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function sendJson(response, body) {
  response.statusCode = 200;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.end(JSON.stringify(body));
}
