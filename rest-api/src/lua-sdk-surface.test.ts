import test from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";

const luaRootUrl = new URL("../../lua/", import.meta.url);
const gameAlgoUrl = new URL("GameAlgo.lua", luaRootUrl);
const readmeUrl = new URL("README.md", luaRootUrl);

test("Maker SDK does not expose multiplayer", async () => {
  const [gameAlgo, readme, files] = await Promise.all([
    readFile(gameAlgoUrl, "utf8"),
    readFile(readmeUrl, "utf8"),
    readdir(luaRootUrl),
  ]);

  assert.match(gameAlgo, /local SDK_VERSION = "2\.0\.2-lua"/);
  assert.doesNotMatch(gameAlgo, /Multiplayer|multiplayer|Matchmaking|ConnectRoom/);
  assert.doesNotMatch(readme, /GameAlgo\.(?:Matchmaking|ConnectRoom|DefineMultiplayerProtocol)/);
  assert.match(readme, /Maker \/ Lua SDK 不提供匹配、Lobby、房间连接或实时状态同步/);
  assert.equal(files.includes("Multiplayer.lua"), false);
  assert.equal(files.includes("MultiplayerProtocol.lua"), false);
  assert.equal(files.includes("MultiplayerWire.lua"), false);
});
