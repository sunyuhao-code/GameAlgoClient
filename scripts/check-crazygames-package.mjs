import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { gzipSync } from "node:zlib";

const root = resolve(import.meta.dirname, ".."), run = promisify(execFile);
const pkg = JSON.parse(await readFile(join(root, "crazygames/package.json"), "utf8"));
const source = await readFile(join(root, "crazygames/dist/commonjs/index.js"), "utf8");
assert.deepEqual(pkg.dependencies ?? {}, {});
assert.doesNotMatch(source, /node:child_process|quickjs-emscripten|new Worker\(|\b(?:eval|Function|require)\s*\(|\bimport\s*\(|createRewardedVideoAd|tapDbEvent|onTapHide/);
assert.ok(Buffer.byteLength(source) < 128 * 1024, "The basic CrazyGames SDK must remain below 128 KiB");
const requests = [];
const server = createServer(async (request, response) => {
  let raw = ""; for await (const chunk of request) raw += chunk;
  const body = raw ? JSON.parse(raw) : {};
  requests.push({ url: request.url, body, headers: request.headers });
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify(request.url.endsWith("/v1/config")
    ? { contextId: "ctx-pack", gameId: "pack-test", environment: "test", configVersion: "1", ttlSeconds: 60, configFiles: [], experiments: [] }
    : { ok: true, accepted: body.events?.length ?? 1, rejected: [] }));
});
await new Promise(resolveReady => server.listen(0, "127.0.0.1", resolveReady));
const directory = await mkdtemp(join(tmpdir(), "gamepropel-crazygames-pack-"));
try {
  const { stdout } = await run("npm", ["pack", "./crazygames", "--ignore-scripts", "--pack-destination", directory, "--json"], { cwd: root });
  const result = JSON.parse(stdout), [packed] = Array.isArray(result) ? result : Object.values(result);
  assert.ok(!packed.files.some(file => /\.(?:wasm|node)$|script-worker|rust-script-runtime/.test(file.path)));
  assert.ok(packed.files.some(file => file.path === "SERVER_HANDOFF.md"));
  await writeFile(join(directory, "package.json"), JSON.stringify({ private: true, type: "module", dependencies: { [pkg.name]: `file:${join(directory, packed.filename)}` } }));
  await run("npm", ["install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false"], { cwd: directory });
  await writeFile(join(directory, "smoke.mjs"), `
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { GamePropelCrazyGamesClient, GAMEPROPEL_CRAZYGAMES_SDK_VERSION } from '${pkg.name}';
assert.equal(GAMEPROPEL_CRAZYGAMES_SDK_VERSION, '${pkg.version}');
assert.equal(typeof createRequire(import.meta.url)('${pkg.name}').GamePropelCrazyGamesClient.init, 'function');
const values = new Map();
const host = {init: async () => {}, environment:'crazygames', ad:{requestAd(type,c){c.adStarted();c.adFinished();}}};
const sdk = await GamePropelCrazyGamesClient.init({crazyGames:host, baseUrl: process.argv[2], gameKey:'ga_live_pack_test', eventFlushIntervalMs:0,
  storage:{getItem:k=>values.get(k),setItem:(k,v)=>{values.set(k,v)},removeItem:k=>{values.delete(k)}}});
try {
  assert.equal(await sdk.waitForReady(), true);
  sdk.tracker.trackLevelStart({levelId:'关卡🙂'});
  await sdk.createAdSpace({adType:'rewarded'}).show('gap_0123456789abcdef0123456789abcdef');
  sdk.tracker.trackSessionEnd();
  await sdk.flush();
} finally { sdk.close(); }
`);
  await run(process.execPath, [join(directory, "smoke.mjs"), `http://127.0.0.1:${server.address().port}/algo_sdk`], { cwd: directory });
  assert.equal(requests[0].body.platform, "crazygames");
  assert.equal(requests[0].headers["x-gamealgo-key"], "ga_live_pack_test");
  const events = requests.flatMap(request => request.body.events ?? []);
  for (const type of ["level_start", "ad_view", "session_end"]) assert.ok(events.some(event => event.eventType === type));
  assert.equal(events.find(event => event.eventType === "ad_view").payload.revenueStatus, "unavailable");
  await writeFile(join(directory, "types.mts"), `import { GamePropelCrazyGamesClient, type GamePropelCrazyGamesClientOptions } from '${pkg.name}'; declare const options: GamePropelCrazyGamesClientOptions; const sdk = await GamePropelCrazyGamesClient.init(options); sdk.getForegroundTimeMs(); await sdk.createAdSpace({adType:'midgame'}).show('type-only');`);
  await run(process.execPath, [join(root, "node_modules/typescript/bin/tsc"), "--noEmit", "--strict", "--skipLibCheck", "--target", "ES2022", "--module", "NodeNext", join(directory, "types.mts")]);
  console.log(`CrazyGames package passed: version=${pkg.version}, CJS=${Buffer.byteLength(source)} bytes (gzip=${gzipSync(source).length}), real HTTP, ESM/CJS installation and types`);
} finally {
  server.closeAllConnections();
  await new Promise(resolveClosed => server.close(resolveClosed));
  await rm(directory, { recursive: true, force: true });
}
