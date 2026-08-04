import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const transportUrl = new URL("../../lua/HttpTransport.lua", import.meta.url);

test("Lua HTTP transport resolves Maker globals through the environment metatable", async () => {
  const source = await readFile(transportUrl, "utf8");

  assert.doesNotMatch(source, /rawget\s*\(\s*_G\s*,\s*["']http["']\s*\)/);
  assert.match(source, /pcall\s*\(\s*function\s*\(\s*\)\s*return\s+http\s+end\s*\)/s);
  assert.match(source, /httpManager:Create\s*\(\s*\)/);
  assert.match(source, /http client unavailable in this runtime/);
});
