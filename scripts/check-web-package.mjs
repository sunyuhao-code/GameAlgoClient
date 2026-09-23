import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const packageJson = JSON.parse(await readFile(resolve(root, "web/package.json"), "utf8"));
const sdk = await import(`${pathToFileURL(resolve(root, "web/dist/web/src/index.js"))}?check=${Date.now()}`);

if (sdk.GAMEALGO_WEB_SDK_VERSION !== packageJson.version) {
  throw new Error(
    `Web SDK version mismatch: package=${packageJson.version}, runtime=${sdk.GAMEALGO_WEB_SDK_VERSION}`,
  );
}

const sourceMaps = await collectFiles(resolve(root, "web/dist"), (name) => name.endsWith(".js.map"));
if (sourceMaps.length === 0) throw new Error("Web SDK package has no JavaScript source maps");
for (const file of sourceMaps) {
  const sourceMap = JSON.parse(await readFile(file, "utf8"));
  if (!Array.isArray(sourceMap.sourcesContent)
    || sourceMap.sourcesContent.length !== sourceMap.sources.length
    || sourceMap.sourcesContent.some((source) => typeof source !== "string" || source.length === 0)) {
    throw new Error(`Source map does not embed its TypeScript source: ${file}`);
  }
}

console.log(`Web package contract passed: version=${packageJson.version}, sourceMaps=${sourceMaps.length}`);

async function collectFiles(directory, select) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) result.push(...await collectFiles(path, select));
    else if (select(entry.name)) result.push(path);
  }
  return result;
}
