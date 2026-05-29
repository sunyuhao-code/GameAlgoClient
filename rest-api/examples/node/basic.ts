import { GameAlgoRestClient, createEvent } from "../../src/index.ts";

const client = new GameAlgoRestClient({
  baseUrl: process.env.GAMEALGO_BASE_URL || "https://gamealgo.example.com",
  gameKey: process.env.GAMEALGO_KEY || "ga_live_xxx",
  sdkVersion: "1.0.0",
  appVersion: "1.0.0",
});

const userId = process.env.GAMEALGO_USER_ID || "user-001";
const sessionId = crypto.randomUUID();

const config = await client.fetchConfig({
  userId,
  platform: "rest",
});

console.log("config", {
  gameId: config.gameId,
  configVersion: config.configVersion,
  experiments: config.experiments,
  configFiles: config.configFiles.map((file) => file.name),
});

await client.uploadEvents([
  createEvent({
    userId,
    sessionId,
    eventType: "session_start",
    payload: {},
  }),
]);

for (const file of config.configFiles) {
  const content = await client.fetchConfigFile(file.name);
  console.log("config file", file.name, content.etag);
}
