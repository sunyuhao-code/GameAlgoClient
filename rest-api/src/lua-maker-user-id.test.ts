import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const gameAlgoUrl = new URL("../../lua/GameAlgo.lua", import.meta.url);

test("Lua SDK maps the Maker user id to account identity without replacing anonymous userId", async () => {
  const source = await readFile(gameAlgoUrl, "utf8");

  assert.doesNotMatch(source, /rawget\s*\(\s*_G\s*,\s*["']lobby["']\s*\)/);
  assert.match(source, /local function resolveMakerUserId\s*\(\s*\)/);
  assert.match(source, /pcall\s*\(\s*function\s*\(\s*\)\s*return\s+lobby\s+end\s*\)/s);
  assert.match(source, /makerLobby:GetMyUserId\s*\(\s*\)/);
  assert.match(source, /ensureIdentity\s*\(\s*options\.userId\s*\)/);
  assert.match(source, /if accountUserId == nil or accountUserId == "" then accountUserId = resolveMakerUserId\s*\(\s*\) end/);
  assert.match(source, /ensureAccountIdentity\s*\(\s*options\.accountUserId, options\.accountUserCreatedAt\s*\)/);
});
