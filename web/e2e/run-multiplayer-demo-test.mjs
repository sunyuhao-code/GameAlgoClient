import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { chromium } from "playwright-core";
import { createServer as createViteServer } from "vite";

const chromePath = findChrome();
if (!chromePath) {
  console.log("Multiplayer browser E2E skipped: set GAMEALGO_CHROME_PATH to Chrome/Chromium");
  process.exit(0);
}

const local = process.env.GAMEALGO_MULTIPLAYER_DEMO_URL ? undefined : await startLocalDemo();
const baseUrl = process.env.GAMEALGO_MULTIPLAYER_DEMO_URL || local.baseUrl;
const controllerQuery = local ? `&controller=${encodeURIComponent(local.controllerUrl)}` : "";
const browser = await chromium.launch({ executablePath: chromePath, headless: true });
try {
  const first = await browser.newPage();
  const second = await browser.newPage();
  for (const [name, page] of [["first", first], ["second", second]]) {
    page.on("pageerror", (error) => console.error(`[${name}] pageerror:`, error));
    page.on("console", (message) => {
      if (message.type() === "error") console.error(`[${name}] console:`, message.text());
    });
  }
  await Promise.all([
    first.goto(`${baseUrl}/?player=e2e-alice&rtt=10${controllerQuery}`),
    second.goto(`${baseUrl}/?player=e2e-bob&rtt=30${controllerQuery}`),
  ]);
  try {
    await Promise.all([
      first.waitForFunction(() => window.__gameAlgoMultiplayerDemo?.ready === true, undefined, { timeout: 10_000 }),
      second.waitForFunction(() => window.__gameAlgoMultiplayerDemo?.ready === true, undefined, { timeout: 10_000 }),
    ]);
  } catch (error) {
    console.error("first state", await pageState(first));
    console.error("second state", await pageState(second));
    throw error;
  }
  await Promise.all([
    first.waitForFunction(() => document.querySelector("#status")?.textContent === "对战中"),
    second.waitForFunction(() => document.querySelector("#status")?.textContent === "对战中"),
  ]);

  const firstIsHost = await first.evaluate(() => window.__gameAlgoMultiplayerDemo.room.isHost);
  const host = firstIsHost ? first : second;
  const peer = firstIsHost ? second : first;
  const hostSeat = Number(await host.textContent("#seat"));
  const peerSeat = Number(await peer.textContent("#seat"));
  assert.notEqual(hostSeat, peerSeat);

  await peer.click("#tap", { clickCount: 3, delay: 10 });
  await Promise.all([
    first.waitForFunction((seat) => Number(document.querySelector(`#score-${seat}`)?.textContent) >= 3, peerSeat),
    second.waitForFunction((seat) => Number(document.querySelector(`#score-${seat}`)?.textContent) >= 3, peerSeat),
  ]);

  await peer.click("#reconnect");
  await peer.waitForTimeout(600);
  await peer.click("#tap");
  await host.waitForFunction((seat) => Number(document.querySelector(`#score-${seat}`)?.textContent) >= 4, peerSeat);

  await host.click("#tap");
  await peer.waitForFunction((seat) => Number(document.querySelector(`#score-${seat}`)?.textContent) >= 1, hostSeat);
  await host.click("#migrate");
  await peer.waitForFunction(() => window.__gameAlgoMultiplayerDemo.room.isHost && window.__gameAlgoMultiplayerDemo.room.hostEpoch >= 2);
  await host.waitForFunction(() => !window.__gameAlgoMultiplayerDemo.room.isHost && window.__gameAlgoMultiplayerDemo.room.hostEpoch >= 2);
  await Promise.all([
    peer.waitForFunction(() => window.__gameAlgoMultiplayerDemo.room.phase === "active"),
    host.waitForFunction(() => window.__gameAlgoMultiplayerDemo.room.phase === "active"),
  ]);
  await host.click("#tap");
  await peer.waitForFunction((seat) => Number(document.querySelector(`#score-${seat}`)?.textContent) >= 2, hostSeat);

  console.log(JSON.stringify({
    ok: true,
    roomId: await peer.evaluate(() => window.__gameAlgoMultiplayerDemo.room.id),
    migratedHostSeat: peerSeat,
    hostEpoch: await peer.evaluate(() => window.__gameAlgoMultiplayerDemo.room.hostEpoch),
    scores: [Number(await peer.textContent("#score-0")), Number(await peer.textContent("#score-1"))],
  }));
} finally {
  await browser.close();
  await local?.close();
}

function findChrome() {
  const candidates = [
    process.env.GAMEALGO_CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  return candidates.find((candidate) => existsSync(candidate));
}

async function pageState(page) {
  return await page.evaluate(() => ({
    result: window.__gameAlgoMultiplayerDemo,
    status: document.querySelector("#status")?.textContent,
    log: document.querySelector("#log")?.textContent,
  }));
}

async function startLocalDemo() {
  const repositoryRoot = resolve(import.meta.dirname, "../..");
  const serverRoot = process.env.GAMEALGO_SERVER_ROOT || resolve(repositoryRoot, "../GameAlgoServer");
  const [{ createMultiplayerRelayServer }, { createMatchControllerServer }] = await Promise.all([
    import(pathToFileURL(resolve(serverRoot, "server/runtimes/multiplayer-relay/src/server.ts"))),
    import(pathToFileURL(resolve(serverRoot, "server/runtimes/match-controller/src/server.ts"))),
  ]);
  const secret = "browser-e2e-signing-secret";
  const internalToken = "browser-e2e-internal-token";
  const relay = createMultiplayerRelayServer({
    signingSecret: secret,
    internalToken,
    relayId: "browser-e2e-relay",
    publicWsUrl: "ws://placeholder/room",
    port: 0,
    host: "127.0.0.1",
    hostReconnectGraceMs: 100,
  });
  await relay.listen();
  const relayPort = relay.server.address().port;
  const relayHttp = `http://127.0.0.1:${relayPort}`;
  const relayWs = `ws://127.0.0.1:${relayPort}/room`;
  const controller = createMatchControllerServer({
    signingSecret: secret,
    internalToken,
    relayId: "browser-e2e-relay",
    relayInternalUrl: relayHttp,
    relayPublicWsUrl: relayWs,
    region: "browser-e2e",
    queues: [{ gameId: "counter-duel-demo", queueId: "casual_1v1", region: "browser-e2e", targetPlayers: 2, maxWaitSeconds: 10 }],
    port: 0,
    host: "127.0.0.1",
    devMode: true,
  });
  await controller.listen();
  const controllerUrl = `http://127.0.0.1:${controller.server.address().port}`;
  const vite = await createViteServer({
    root: resolve(repositoryRoot, "examples/multiplayer-web-demo"),
    logLevel: "error",
    server: { host: "127.0.0.1", port: 0, strictPort: false, fs: { allow: [repositoryRoot] } },
  });
  await vite.listen();
  const viteAddress = vite.httpServer.address();
  return {
    baseUrl: `http://127.0.0.1:${viteAddress.port}`,
    controllerUrl,
    async close() {
      await vite.close();
      await controller.close();
      await relay.close();
    },
  };
}
