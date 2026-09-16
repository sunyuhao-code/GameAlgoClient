import assert from "node:assert/strict";
import { existsSync } from "node:fs";

import { chromium } from "playwright-core";

import { startGameAlgoE2EServer } from "./test-server.mjs";

const chromePath = findChrome();
if (!chromePath) {
  console.log("H5 browser E2E skipped: set GAMEALGO_CHROME_PATH to a Chrome/Chromium executable");
  process.exit(0);
}

let browser;
const server = await startGameAlgoE2EServer();
try {
  browser = await chromium.launch({ executablePath: chromePath, headless: true });
  const page = await browser.newPage();
  await page.goto(`${server.baseUrl}/?utm_source=taptap&utm_campaign=e2e&secret=omit`);
  await page.waitForFunction(() => window.__gameAlgoE2E !== undefined, undefined, { timeout: 20_000 });
  const first = await page.evaluate(() => window.__gameAlgoE2E);
  assert.equal(first?.error, undefined);
  assert.equal(first?.ready, true);
  assert.deepEqual(first?.execution?.payload, {
    adjustment: "keep",
    difficulty: "hard",
    level: 7,
    fetchType: "undefined",
    documentType: "undefined",
  });
  assert.equal(first?.execution?.diagnostics?.worker, true);
  assert.equal(first?.ddaDecision?.adjustment, "keep");
  assert.equal(first?.ddaDecision?.isFallback, false);

  await page.reload();
  await page.waitForFunction(() => window.__gameAlgoE2E !== undefined, undefined, { timeout: 20_000 });
  const second = await page.evaluate(() => window.__gameAlgoE2E);
  assert.equal(second?.error, undefined);
  assert.equal(second?.userId, first?.userId);

  assert.ok(server.configRequests.length >= 4, "initial and pageshow contexts should refresh across two loads");
  assert.ok(server.configRequests.every((request) => request.platform === "web"));
  const eventTypes = server.eventBatches.flatMap((batch) => batch.events ?? []).map((event) => event.eventType);
  assert.ok(eventTypes.includes("milestone"));
  assert.ok(eventTypes.includes("ad_view"));
  assert.ok(eventTypes.includes("session_end"));
  assert.ok(server.attributionRequests.length >= 1);
  assert.deepEqual(server.attributionRequests[0].attribution, {
    utm_source: "taptap",
    utm_campaign: "e2e",
  });
  console.log("H5 browser E2E passed: QuickJS worker, DDA, IndexedDB identity, lifecycle, events, and URL attribution");
} finally {
  await browser?.close();
  await server.close();
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
