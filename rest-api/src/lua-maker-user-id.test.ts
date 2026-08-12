import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const gameAlgoUrl = new URL("../../lua/GameAlgo.lua", import.meta.url);

test("Lua SDK automatically resolves the Maker user id before anonymous fallback", async () => {
  const source = await readFile(gameAlgoUrl, "utf8");

  assert.doesNotMatch(source, /rawget\s*\(\s*_G\s*,\s*["']lobby["']\s*\)/);
  assert.match(source, /local function resolveMakerUserId\s*\(\s*\)/);
  assert.match(source, /pcall\s*\(\s*function\s*\(\s*\)\s*return\s+lobby\s+end\s*\)/s);
  assert.match(source, /makerLobby:GetMyUserId\s*\(\s*\)/);
  assert.match(source, /local resolvedUserId = options\.userId/);
  assert.match(source, /resolvedUserId = resolveMakerUserId\s*\(\s*\)/);
  assert.match(source, /ensureIdentity\s*\(\s*resolvedUserId\s*\)/);
});
