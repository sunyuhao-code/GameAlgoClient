import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { promisify } from "node:util";

import { startGameAlgoE2EServer } from "./test-server.mjs";

const execFileAsync = promisify(execFile);
if (process.platform !== "darwin" || !(await hasSimulatorToolchain())) {
  console.log("H5 iOS WKWebView E2E skipped: Xcode Simulator toolchain is unavailable");
  process.exit(0);
}

const harnessRoot = resolve(import.meta.dirname, "ios-webview");
const bundleId = "cn.gamealgo.webview-e2e";
const workRoot = await mkdtemp(resolve(tmpdir(), "gamealgo-ios-webview-"));
const appRoot = resolve(workRoot, "GameAlgoWebViewE2E.app");
const executable = resolve(appRoot, "GameAlgoWebViewE2E");
const device = await findSimulator();
const simulatorWasBooted = device.state === "Booted";
const server = await startGameAlgoE2EServer();

try {
  await buildApp();
  await run("xcrun", ["simctl", "boot", device.udid], { allowFailure: true });
  await run("xcrun", ["simctl", "bootstatus", device.udid, "-b"], { timeout: 120_000 });
  await run("xcrun", ["simctl", "install", device.udid, appRoot]);
  await run("xcrun", ["simctl", "terminate", device.udid, bundleId], { allowFailure: true });
  const pageUrl = `${server.baseUrl}/?utm_source=taptap&utm_campaign=e2e&secret=omit&webview_e2e=1`;
  await run("xcrun", ["simctl", "launch", device.udid, bundleId], {
    env: { ...process.env, SIMCTL_CHILD_GAMEALGO_E2E_URL: pageUrl },
  });

  const [first, second] = await withTimeout(
    server.webViewResultsReady,
    45_000,
    "Timed out waiting for two WKWebView fixture results",
  );
  assertResult(first);
  assertResult(second);
  assert.equal(second.userId, first.userId, "IndexedDB anonymous identity should survive WKWebView reload");
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
  console.log(`H5 iOS WKWebView E2E passed on ${device.name}: QuickJS worker, DDA, IndexedDB identity, lifecycle, events, and URL attribution`);
} finally {
  await run("xcrun", ["simctl", "terminate", device.udid, bundleId], { allowFailure: true });
  await server.close();
  await rm(workRoot, { recursive: true, force: true });
  if (!simulatorWasBooted) {
    await run("xcrun", ["simctl", "shutdown", device.udid], { allowFailure: true });
  }
}

function assertResult(result) {
  assert.equal(result?.error, undefined);
  assert.equal(result?.ready, true);
  assert.deepEqual(result?.execution?.payload, {
    adjustment: "keep",
    difficulty: "hard",
    level: 7,
    fetchType: "undefined",
    documentType: "undefined",
  });
  assert.equal(result?.execution?.diagnostics?.worker, true);
  assert.equal(result?.ddaDecision?.adjustment, "keep");
  assert.equal(result?.ddaDecision?.isFallback, false);
}

async function buildApp() {
  const sdk = (await run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])).stdout.trim();
  const architecture = process.arch === "x64" ? "x86_64" : "arm64";
  await mkdir(appRoot, { recursive: true });
  await copyFile(resolve(harnessRoot, "Info.plist"), resolve(appRoot, "Info.plist"));
  await run("xcrun", [
    "swiftc",
    "-sdk", sdk,
    "-target", `${architecture}-apple-ios18.0-simulator`,
    "-framework", "UIKit",
    "-framework", "WebKit",
    resolve(harnessRoot, "AppDelegate.swift"),
    "-o", executable,
  ], { timeout: 120_000 });
  await run("codesign", ["--force", "--sign", "-", appRoot]);
}

async function findSimulator() {
  const { stdout } = await run("xcrun", ["simctl", "list", "devices", "available", "-j"]);
  const runtimes = Object.values(JSON.parse(stdout).devices);
  const devices = runtimes.flat().filter((candidate) => candidate.isAvailable && candidate.name.startsWith("iPhone"));
  const device = devices.find((candidate) => candidate.state === "Booted") ?? devices[0];
  if (!device) throw new Error("No available iPhone Simulator found");
  return device;
}

async function run(command, args, options = {}) {
  try {
    return await execFileAsync(command, args, {
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: options.timeout ?? 30_000,
      env: options.env ?? process.env,
    });
  } catch (error) {
    if (options.allowFailure) return { stdout: error.stdout ?? "", stderr: error.stderr ?? "" };
    throw error;
  }
}

function withTimeout(promise, timeoutMs, message) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), timeoutMs);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function hasSimulatorToolchain() {
  try {
    await execFileAsync("xcrun", ["--find", "simctl"]);
    await execFileAsync("xcrun", ["--find", "swiftc"]);
    return true;
  } catch {
    return false;
  }
}
