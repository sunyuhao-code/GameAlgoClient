import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { runInNewContext } from "node:vm";
import { gzipSync } from "node:zlib";

const root = resolve(import.meta.dirname, "..");
const run = promisify(execFile);
const pkg = JSON.parse(await readFile(join(root, "wechat/package.json"), "utf8"));
const source = await readFile(join(root, "wechat/dist/commonjs/index.js"), "utf8");
assert.doesNotMatch(source, /node:child_process|RustProcessScriptRuntime|quickjs-emscripten|new Worker\(|\b(?:eval|Function|require)\s*\(|\bimport\s*\(/,
  "The WeChat bundle must not load browser, dynamic-code or Node runtimes");
assert.deepEqual(pkg.dependencies ?? {}, {}, "The standalone WeChat package has no runtime dependencies");
assert.ok(Buffer.byteLength(source) < 128 * 1024, "The standalone adapter must remain below 128 KiB without a script runtime");

const requests = [];
const server = createServer(async (request, response) => {
  let raw = "";
  for await (const chunk of request) raw += chunk;
  const body = raw ? JSON.parse(raw) : {};
  requests.push({ url: request.url, body, headers: request.headers });
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify(request.url.endsWith("/v1/config")
    ? { contextId: "ctx-wechat-pack", gameId: "pack-test", environment: "live", configVersion: "1", ttlSeconds: 60, configFiles: [], experiments: [
      { key: "difficulty", experimentId: "exp-pack", variant: "a", config: { difficulty: 3 } },
    ] }
    : { ok: true, accepted: body.events?.length ?? 1, rejected: [] }));
});
await new Promise(resolveReady => server.listen(0, "127.0.0.1", resolveReady));
const values = new Map();
const hide = new Set(), show = new Set();
const nativeFetch = globalThis.fetch;
const wx = {
  request(options) {
    const controller = new AbortController();
    void nativeFetch(options.url, { method: options.method, headers: options.header, body: options.data, signal: controller.signal })
      .then(async result => options.success({ statusCode: result.status, data: await result.text(), header: Object.fromEntries(result.headers) }))
      .catch(error => options.fail(error));
    return { abort() { controller.abort(); } };
  },
  getStorageSync: key => values.get(key) ?? "",
  setStorageSync: (key, value) => { values.set(key, value); },
  removeStorageSync: key => { values.delete(key); },
  onHide: callback => { hide.add(callback); }, offHide: callback => { hide.delete(callback); },
  onShow: callback => { show.add(callback); }, offShow: callback => { show.delete(callback); },
};
const exports = {};
runInNewContext(source, {
  module: { exports }, exports, wx, console, setTimeout, clearTimeout, setInterval, clearInterval,
  fetch: undefined, URL: undefined, Headers: undefined, Response: undefined,
  TextEncoder: undefined, crypto: undefined, Worker: undefined, WebAssembly: undefined,
  process: undefined, Buffer: undefined, require: undefined, window: undefined, document: undefined,
}, { filename: "gamealgo-wechat.js", timeout: 5000 });
let client;
const directory = await mkdtemp(join(tmpdir(), "gamealgo-wechat-pack-"));
try {
  assert.equal(exports.GAMEALGO_WECHAT_SDK_VERSION, pkg.version);
  client = exports.GameAlgoWechatClient.init({ baseUrl: `http://127.0.0.1:${server.address().port}/algo_sdk`, gameKey: "ga_live_pack_test", eventFlushIntervalMs: 0 });
  assert.equal(await client.waitForReady(), true);
  assert.equal(client.executor("difficulty").number("difficulty"), 3);
  client.tracker.trackLevelStart({ level_id: "关卡🙂" });
  for (const callback of hide) callback();
  await client.flush();
  const session = client.tracker.currentSessionId();
  for (const callback of show) callback();
  assert.equal(client.tracker.currentSessionId(), session);
  assert.equal(requests[0].body.platform, "wechat");
  assert.equal(requests[0].headers["x-gamealgo-key"], "ga_live_pack_test");
  assert.ok(requests.flatMap(request => request.body.events ?? []).some(event => event.payload?.level_id === "关卡🙂"));
  assert.ok(requests.flatMap(request => request.body.events ?? []).some(event => event.eventType === "session_end"));

  const { stdout } = await run("npm", ["pack", "./wechat", "--ignore-scripts", "--pack-destination", directory, "--json"], { cwd: root });
  const [packed] = JSON.parse(stdout);
  assert.ok(!packed.files.some(file => /\.(?:wasm|node)$|rust-script-runtime|script-worker/.test(file.path)));
  await writeFile(join(directory, "package.json"), JSON.stringify({ private: true, type: "module", dependencies: { "@gamealgo/wechat": `file:${join(directory, packed.filename)}` } }));
  await run("npm", ["install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false"], { cwd: directory });
  await writeFile(join(directory, "esm.mjs"), `import { GameAlgoWechatClient, GAMEALGO_WECHAT_SDK_VERSION } from "@gamealgo/wechat"; if (typeof GameAlgoWechatClient.init !== "function" || GAMEALGO_WECHAT_SDK_VERSION !== ${JSON.stringify(pkg.version)}) throw new Error("Invalid ESM package");`);
  await writeFile(join(directory, "cjs.cjs"), `const sdk = require("@gamealgo/wechat"); if (typeof sdk.GameAlgoWechatClient.init !== "function") throw new Error("Invalid CJS package");`);
  await run(process.execPath, [join(directory, "esm.mjs")]);
  await run(process.execPath, [join(directory, "cjs.cjs")]);
  await writeFile(join(directory, "types.mts"), `import { GameAlgoWechatClient, type GameAlgoWechatClientOptions } from "@gamealgo/wechat"; declare const options: GameAlgoWechatClientOptions; const sdk = GameAlgoWechatClient.init(options); sdk.getForegroundTimeMs(); sdk.flush(); sdk.createAdSpace({adUnitId:"type-only"}).show("type-only");`);
  await run(process.execPath, [join(root, "node_modules/typescript/bin/tsc"), "--noEmit", "--strict", "--skipLibCheck", "--lib", "ES2022", "--target", "ES2022", "--module", "NodeNext", join(directory, "types.mts")]);
  console.log(`WeChat package passed: version=${pkg.version}, standalone CJS=${Buffer.byteLength(source)} bytes (gzip=${gzipSync(source).length}), restricted JS host, real HTTP, ESM/CJS install, and types`);
} finally {
  client?.close();
  server.closeAllConnections();
  await new Promise(resolveClosed => server.close(resolveClosed));
  await rm(directory, { recursive: true, force: true });
}
