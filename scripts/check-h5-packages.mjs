import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";

import "./check-web-package.mjs";

const run = promisify(execFile);
const root = resolve(import.meta.dirname, "..");
const directory = await mkdtemp(join(tmpdir(), "gamealgo-h5-packages-"));
try {
  const dependencies = {};
  for (const name of ["taptap-h5", "web"]) {
    const { stdout } = await run("npm", ["pack", `./${name}`, "--ignore-scripts", "--json", "--pack-destination", directory], { cwd: root });
    const result = JSON.parse(stdout);
    // npm 12 keys JSON results by package name; npm 11 returns an array.
    const [packed] = Array.isArray(result) ? result : Object.values(result);
    dependencies[packed.name] = `file:${join(directory, packed.filename)}`;
    if (name === "web") {
      assert.ok(packed.unpackedSize < 16 * 1024, "The compatibility package must not contain a second SDK runtime");
      assert.ok(packed.files.every(({ path }) => !path.startsWith("dist/")));
    }
  }
  await writeFile(join(directory, "package.json"), JSON.stringify({ private: true, type: "module", dependencies }));
  // npm ci can cache dependency tarballs without caching the registry metadata
  // needed to resolve this isolated package's semver dependencies on a new runner.
  await run("npm", ["install", "--prefer-offline", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false"], { cwd: directory });
  await writeFile(join(directory, "smoke.mjs"), `
import assert from "node:assert/strict";
import * as current from "@gamepropel/taptap-h5";
import * as legacy from "@gamealgo/web";
assert.deepEqual(Object.keys(current), Object.keys(legacy));
for (const key of Object.keys(current)) assert.equal(current[key], legacy[key], key);
assert.equal(current.GameAlgoTapTapH5Client, legacy.GameAlgoWebClient);
assert.equal(current.GamePropelTapTapH5Client, legacy.GameAlgoWebClient);
const storageValues = new Map();
const requests = [];
let offline = true;
const options = {
  baseUrl: "https://gamealgo.test",
  gameKey: "ga_live_package_test",
  autoLifecycle: false,
  eventFlushIntervalMs: 0,
  storage: {
    getItem: key => storageValues.get(key),
    setItem: (key, value) => { storageValues.set(key, value); },
    removeItem: key => { storageValues.delete(key); },
  },
  fetchImpl: async (input, init) => {
    const body = JSON.parse(String(init?.body));
    requests.push({ url: String(input), body });
    if (offline && String(input).endsWith("/v1/events/batch")) return new Response("offline", { status: 503 });
    return Response.json(String(input).endsWith("/v1/config")
      ? { contextId: "ctx-package-test", gameId: "package-test", environment: "live", configVersion: "1", ttlSeconds: 60, experiments: [], configFiles: [] }
      : { ok: true, accepted: body.events?.length ?? 1 });
  },
};
let first;
let second;
try {
  first = legacy.GameAlgoWebClient.init(options);
  assert.equal(await first.waitForReady(), true);
  const identity = await first.userIdentity();
  assert.equal(first.tracker.trackLevelStart({ levelId: "pending-before-package-migration" }), true);
  await first.flush().catch(() => undefined);
  first.close();
  offline = false;
  requests.length = 0;
  second = current.GamePropelTapTapH5Client.init(options);
  assert.equal(await second.waitForReady(), true);
  assert.equal((await second.userIdentity()).userId, identity.userId, "Changing packages preserves stored identity");
  assert.equal(second.tracker.trackLevelStart({ levelId: "level-package-test" }), true);
  await second.flush();
  assert.ok(requests.some(request => request.body.events?.some(event => event.eventType === "level_start")));
  assert.ok(requests.some(request => request.body.events?.some(event => event.payload?.levelId === "pending-before-package-migration")), "Changing packages restores pending events");
  assert.ok(requests.filter(request => request.url.endsWith("/v1/config")).every(request => request.body.platform === "web"));
} finally {
  first?.close();
  second?.close();
}
`);
  await run(process.execPath, [join(directory, "smoke.mjs")], { cwd: directory });
  await writeFile(join(directory, "types.mts"), `
import { GamePropelTapTapH5Client, type GamePropelTapTapH5ClientOptions } from "@gamepropel/taptap-h5";
import { GameAlgoWebClient, type GameAlgoWebClientOptions } from "@gamealgo/web";
declare const options: GamePropelTapTapH5ClientOptions;
const oldOptions: GameAlgoWebClientOptions = options;
const current: GamePropelTapTapH5Client = GameAlgoWebClient.init(oldOptions);
const legacy: GameAlgoWebClient = GamePropelTapTapH5Client.init(options);
current.createAdSpace({ adUnitId: "type-check-only" });
legacy.getForegroundTimeMs();
`);
  await run(process.execPath, [join(root, "node_modules/typescript/bin/tsc"), "--noEmit", "--strict", "--skipLibCheck", "--target", "ES2022", "--module", "NodeNext", join(directory, "types.mts")], { cwd: directory });
  const canonical = JSON.parse(await readFile(join(directory, "node_modules/@gamepropel/taptap-h5/package.json"), "utf8"));
  console.log(`TapTap H5 tarball compatibility passed: version=${canonical.version}, both package entries, identity, pending-event recovery, wire platform, and TypeScript exports`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
