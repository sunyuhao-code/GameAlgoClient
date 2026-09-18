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
// Kept below every simulator runtime a CI image might carry, and in step with
// MinimumOSVersion in ios-webview/Info.plist. The harness only uses long-stable
// UIKit and WebKit APIs, and what this actually exercises is the simulator's
// WebKit, not the app's deployment target.
const DEPLOYMENT_TARGET = "15.0";
// A CI runner may be booting a simulator runtime for the first time, where
// installd and the first launch are far slower than on a warm machine. These
// are backstops against a hang, not latency budgets.
const SIMCTL_TIMEOUT_MS = 180_000;
const workRoot = await mkdtemp(resolve(tmpdir(), "gamealgo-ios-webview-"));
const appRoot = resolve(workRoot, "GameAlgoWebViewE2E.app");
const executable = resolve(appRoot, "GameAlgoWebViewE2E");
const device = await findSimulator();
const simulatorWasBooted = device.state === "Booted";
const server = await startGameAlgoE2EServer();

try {
  await buildApp();
  await run("xcrun", ["simctl", "boot", device.udid], { allowFailure: true, timeout: SIMCTL_TIMEOUT_MS });
  await run("xcrun", ["simctl", "bootstatus", device.udid, "-b"], { timeout: SIMCTL_TIMEOUT_MS });
  await run("xcrun", ["simctl", "install", device.udid, appRoot], { timeout: SIMCTL_TIMEOUT_MS });
  await run("xcrun", ["simctl", "terminate", device.udid, bundleId], { allowFailure: true });
  const pageUrl = `${server.baseUrl}/?utm_source=taptap&utm_campaign=e2e&secret=omit&webview_e2e=1`;
  await run("xcrun", ["simctl", "launch", device.udid, bundleId], {
    env: { ...process.env, SIMCTL_CHILD_GAMEALGO_E2E_URL: pageUrl },
    timeout: SIMCTL_TIMEOUT_MS,
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
    "-target", `${architecture}-apple-ios${DEPLOYMENT_TARGET}-simulator`,
    "-framework", "UIKit",
    "-framework", "WebKit",
    resolve(harnessRoot, "AppDelegate.swift"),
    "-o", executable,
  ], { timeout: 120_000 });
  await run("codesign", ["--force", "--sign", "-", appRoot]);
}

// Runner images carry different iOS runtimes over time, so prefer the newest
// one available rather than whichever the list happens to return first. The
// harness deployment target stays below every runtime we could pick, so the
// install never fails on a version mismatch.
async function findSimulator() {
  const { stdout } = await run("xcrun", ["simctl", "list", "devices", "available", "-j"]);
  const byRuntime = Object.entries(JSON.parse(stdout).devices)
    .map(([runtime, devices]) => ({
      version: runtimeVersion(runtime),
      devices: devices.filter((candidate) => candidate.isAvailable && candidate.name.startsWith("iPhone")),
    }))
    .filter((entry) => entry.version !== null && entry.devices.length > 0)
    .sort((a, b) => compareVersions(b.version, a.version));
  const newest = byRuntime[0];
  if (!newest) throw new Error("No available iPhone Simulator found");
  const device = newest.devices.find((candidate) => candidate.state === "Booted") ?? newest.devices[0];
  console.log(`Using iOS ${newest.version.join(".")} Simulator: ${device.name}`);
  return device;
}

/** `com.apple.CoreSimulator.SimRuntime.iOS-17-4` -> [17, 4] */
function runtimeVersion(identifier) {
  const match = /SimRuntime\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$/.exec(identifier);
  if (!match) return null;
  return [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)];
}

function compareVersions(a, b) {
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
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
    // A timeout arrives as SIGTERM with no output, which says nothing about
    // which step stalled. Name it.
    if (error.killed) {
      const seconds = Math.round((options.timeout ?? 30_000) / 1000);
      throw new Error(`${command} ${args.join(" ")} timed out after ${seconds}s`);
    }
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
