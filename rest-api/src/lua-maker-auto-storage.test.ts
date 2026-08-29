import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const gameAlgoUrl = new URL("../../lua/GameAlgo.lua", import.meta.url);
const storageUrl = new URL("../../lua/MakerAutoStorage.lua", import.meta.url);
const readmeUrl = new URL("../../lua/README.md", import.meta.url);
const exampleUrl = new URL("../../lua/client_main.lua", import.meta.url);

test("Lua SDK owns Maker persistence and rejects caller-provided storage", async () => {
  const [gameAlgo, storage, readme, example] = await Promise.all([
    readFile(gameAlgoUrl, "utf8"),
    readFile(storageUrl, "utf8"),
    readFile(readmeUrl, "utf8"),
    readFile(exampleUrl, "utf8"),
  ]);

  assert.match(gameAlgo, /local MakerAutoStorage = requireSdkModule\("MakerAutoStorage"\)/);
  assert.match(gameAlgo, /if options\.storage ~= nil then\s+error\("options\.storage is not supported;/s);
  assert.doesNotMatch(gameAlgo, /validateStorage/);
  assert.doesNotMatch(readme, /storage\s*=\s*\{/);
  assert.doesNotMatch(example, /storage\s*=/);
});

test("Maker automatic storage uses normal Maker global lookup and hydrates before SDK startup", async () => {
  const [gameAlgo, storage] = await Promise.all([
    readFile(gameAlgoUrl, "utf8"),
    readFile(storageUrl, "utf8"),
  ]);

  assert.doesNotMatch(storage, /rawget\s*\(/);
  assert.match(storage, /local function makerGlobal\(read\)\s+local ok, value = pcall\(read\)/s);
  assert.match(storage, /makerGlobal\(function\(\) return File end\)/);
  assert.match(storage, /makerGlobal\(function\(\) return fileSystem end\)/);
  assert.match(storage, /fileApi\.fileSystem:FileExists\(FILE_NAME\)/);
  assert.match(storage, /if not existsOk or not exists then return nil end/);
  assert.match(storage, /makerGlobal\(function\(\) return clientCloud end\)/);
  assert.match(storage, /cloud:Get\(CLOUD_KEY/);
  assert.match(storage, /DEFAULT_CLOUD_READ_TIMEOUT_MS = 5000/);
  assert.match(storage, /eventObject:SubscribeToEvent\("Update"/);
  assert.match(storage, /automatic storage cloud read timed out after/);
  assert.match(storage, /file:ReadString\(\)/);
  assert.match(storage, /file:WriteString\(encoded\)/);
  assert.match(gameAlgo, /storage:OnReady\(function\(\) completeInitialization\(options\) end\)/);
  assert.match(gameAlgo, /if not state_\.storageReady then[\s\S]*?table\.insert\(state_\.pendingTracks/s);
  assert.match(gameAlgo, /if actual or not state_\.storageReady then return end/);
  assert.match(gameAlgo, /CONFIG_FETCH_MAX_ATTEMPTS = 3/);
  assert.match(gameAlgo, /CONFIG_FETCH_RETRY_BASE_MS = 1000/);
  assert.doesNotMatch(gameAlgo, /SubscribeToEvent\("Update", handlerName\)/);
  assert.match(gameAlgo, /eventNode = nodeFactory\(\)/);
  assert.match(gameAlgo, /eventObject = eventNode:CreateScriptObject\("LuaScriptObject"\)/);
  assert.match(gameAlgo, /eventObject:SubscribeToEvent\("Update", function\(\)/);
  assert.match(gameAlgo, /state_\.internalUpdateObject = eventObject/);
  assert.match(gameAlgo, /isRetryableConfigFailure/);
  assert.match(gameAlgo, /prefetchedMakerUserId = options\.accountUserId or resolveMakerUserId\(\)/);
  assert.match(gameAlgo, /INIT_WATCHDOG_MS = 10000/);
  assert.match(gameAlgo, /"POST", "\/v1\/diagnostics\/init"/);
  assert.match(gameAlgo, /reasonCode = "initialization_timeout"/);
});
