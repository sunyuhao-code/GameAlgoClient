import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const packageJson = JSON.parse(await readFile(resolve(root, "taptap-h5/package.json"), "utf8"));
const sdk = await import(`${pathToFileURL(resolve(root, "taptap-h5/dist/taptap-h5/src/index.js"))}?check=${Date.now()}`);
const compatibilityPackage = JSON.parse(await readFile(resolve(root, "web/package.json"), "utf8"));

if (packageJson.name !== "@gamepropel/sdk-taptap-h5"
  || compatibilityPackage.name !== "@gamealgo/web"
  || compatibilityPackage.version !== packageJson.version
  || compatibilityPackage.dependencies?.[packageJson.name] !== packageJson.version) {
  throw new Error("TapTap H5 and legacy Web packages must publish matching, pinned versions");
}
if (sdk.GameAlgoTapTapH5Client !== sdk.GameAlgoWebClient
  || sdk.GamePropelTapTapH5Client !== sdk.GameAlgoWebClient
  || sdk.GamePropelBrowserStorage !== sdk.GameAlgoBrowserStorage
  || sdk.GamePropelTapTapH5ScriptRuntime !== sdk.GameAlgoWebScriptRuntime
  || sdk.initGamePropelTapTapH5 !== sdk.initGameAlgoWeb
  || sdk.GAMEPROPEL_TAPTAP_H5_SDK_VERSION !== sdk.GAMEALGO_WEB_SDK_VERSION
  || sdk.GAMEALGO_TAPTAP_H5_SDK_VERSION !== sdk.GAMEALGO_WEB_SDK_VERSION) {
  throw new Error("TapTap H5 and legacy Web exports must share one implementation");
}

if (sdk.GAMEALGO_WEB_SDK_VERSION !== packageJson.version) {
  throw new Error(
    `Web SDK version mismatch: package=${packageJson.version}, runtime=${sdk.GAMEALGO_WEB_SDK_VERSION}`,
  );
}

const sourceMaps = await collectFiles(resolve(root, "taptap-h5/dist"), (name) => name.endsWith(".js.map"));
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
