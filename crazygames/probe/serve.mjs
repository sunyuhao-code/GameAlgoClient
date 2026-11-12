import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "../..");
const officialUrl = "https://sdk.crazygames.com/crazygames-sdk-v3.js";

/** Local fixture only: no real credentials, portal upload or production endpoint. */
export async function startCrazyGamesProbe(port = 0) {
  const cache = resolve(root, ".build/crazygames-probe/official-sdk.js");
  let official;
  try {
    const response = await fetch(officialUrl, { signal: AbortSignal.timeout(15_000) });
    if (!response.ok) throw new Error(`Official SDK download failed: HTTP ${response.status}`);
    official = await response.text();
    await mkdir(resolve(cache, ".."), { recursive: true });
    await writeFile(cache, official);
  } catch (error) {
    try { official = await readFile(cache, "utf8"); console.warn("Using cached official CrazyGames SDK:", error.message); }
    catch { throw error; }
  }
  const state = { mode: "local_fixture", officialUrl, configs: [], events: [], logs: [], offline: false };
  let context = 0;
  const server = createServer(async (request, response) => {
    try {
      const path = new URL(request.url, "http://localhost").pathname;
      response.setHeader("cache-control", "no-store");
      if (request.method === "GET" && ["/", "/index.html", "/probe.js", "/sdk.js", "/official-sdk.js"].includes(path)) {
        response.setHeader("content-type", path.endsWith(".js") ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8");
        const files = { "/": "crazygames/probe/index.html", "/index.html": "crazygames/probe/index.html", "/probe.js": "crazygames/probe/probe.js", "/sdk.js": "crazygames/dist/index.js" };
        response.end(path === "/official-sdk.js" ? official : await readFile(resolve(root, files[path]))); return;
      }
      response.setHeader("content-type", "application/json");
      if (path === "/probe/state" && request.method === "GET") { response.end(JSON.stringify(state)); return; }
      let raw = ""; for await (const chunk of request) raw += chunk;
      const body = raw ? JSON.parse(raw) : {};
      if (path === "/probe/log" && request.method === "POST") {
        state.logs.push(body); if (state.logs.length > 500) state.logs.shift();
        response.end(JSON.stringify({ ok: true })); return;
      }
      if (path === "/probe/network" && request.method === "POST") {
        state.offline = Boolean(body.offline); response.end(JSON.stringify({ offline: state.offline })); return;
      }
      if (path === "/algo_sdk/v1/config" && request.method === "POST") {
        state.configs.push(body);
        response.end(JSON.stringify({ contextId: `ctx-local-${++context}`, gameId: "local-probe-fixture", environment: "test", configVersion: "1", ttlSeconds: 60,
          configFiles: [], experiments: [{ key: "difficulty", experimentId: "local-exp", variant: "a", config: { difficulty: 3 } }] })); return;
      }
      if (path === "/algo_sdk/v1/events/batch" && request.method === "POST") {
        if (state.offline) { response.statusCode = 503; response.end(JSON.stringify({ error: "Local probe simulates failed upload" })); return; }
        state.events.push(...(body.events ?? []));
        response.end(JSON.stringify({ ok: true, accepted: body.events?.length ?? 0, rejected: [] })); return;
      }
      response.statusCode = 404; response.end(JSON.stringify({ error: "Unknown local fixture route" }));
    } catch (error) { response.statusCode = 500; response.end(JSON.stringify({ error: error.message })); }
  });
  await new Promise(ready => server.listen(port, "127.0.0.1", ready));
  return { server, state, url: `http://127.0.0.1:${server.address().port}`,
    async close() { server.closeAllConnections(); await new Promise(done => server.close(done)); } };
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  const probe = await startCrazyGamesProbe(Number(process.env.GAMEPROPEL_PROBE_PORT ?? 4892));
  console.log(`CrazyGames official v3 local probe: ${probe.url}`);
  console.log("GamePropel endpoint is a local fixture; no production credentials or uploads.");
  for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => { void probe.close().then(() => process.exit(0)); });
}
