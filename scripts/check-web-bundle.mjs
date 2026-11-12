import assert from "node:assert/strict";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { basename, join, relative, resolve } from "node:path";
import { gzipSync } from "node:zlib";

import { build } from "vite";

const root = resolve(import.meta.dirname, "..");
const checkRoot = join(root, ".build/web-bundle-check");
const fixture = join(checkRoot, "fixture");
const output = join(checkRoot, "dist");
await mkdir(fixture, { recursive: true });
await writeFile(join(fixture, "index.html"),
  '<html><body><script type="module" src="./main.js"></script></body></html>');
// Keep both the client and the worker API reachable, as they are in a game.
// Import the built package entry so its rewritten worker URL is tested too.
await writeFile(join(fixture, "main.js"), `
import { GamePropelTapTapH5Client, GamePropelTapTapH5ScriptRuntime } from "@gamepropel/taptap-h5";
import { GameAlgoWebClient } from "@gamealgo/web";
globalThis.__gameAlgoBundleProbe = { GamePropelTapTapH5Client, GameAlgoWebClient, GamePropelTapTapH5ScriptRuntime };
`);
await build({
  configFile: false,
  root: fixture,
  logLevel: "error",
  worker: { format: "es" },
  build: { outDir: output, emptyOutDir: true, sourcemap: false, minify: true },
});

const files = await collectFiles(output);
const wasmFiles = files.filter((file) => file.endsWith(".wasm"));
assert.equal(wasmFiles.length, 1,
  `Expected one release-sync WASM asset, got ${wasmFiles.length}: ${wasmFiles.map((file) => basename(file)).join(", ")}`);
const wasm = await readFile(wasmFiles[0]);
const releaseSync = await readFile(new URL(import.meta.resolve("@jitl/quickjs-wasmfile-release-sync/wasm")));
assert.ok(wasm.equals(releaseSync), "Bundled WASM must be the installed release-sync variant");
const javascript = await Promise.all(files.filter((file) => file.endsWith(".js")).map((file) => readFile(file, "utf8")));
assert.ok(javascript.some((source) => source.includes(basename(wasmFiles[0]))),
  "The release-sync WASM must be referenced by a generated JavaScript chunk");

const assets = await Promise.all(files.map(async (file) => {
  const bytes = await readFile(file);
  return { file: relative(output, file), bytes: bytes.length, gzipBytes: gzipSync(bytes, { level: 9 }).length };
}));
const result = {
  wasmFiles: wasmFiles.length,
  wasmBytes: wasm.length,
  totalBytes: assets.reduce((sum, asset) => sum + asset.bytes, 0),
  totalGzipBytes: assets.reduce((sum, asset) => sum + asset.gzipBytes, 0),
  assets,
};
await writeFile(join(checkRoot, "result.json"), JSON.stringify(result, null, 2) + "\n");
console.log(`Web production bundle passed: release-sync WASM=${result.wasmBytes} bytes, `
  + `total=${result.totalBytes} bytes, gzip=${result.totalGzipBytes} bytes`);

async function collectFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await collectFiles(path));
    else files.push(path);
  }
  return files;
}
