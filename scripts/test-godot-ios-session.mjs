// Real UIKit lifecycle + the production Rust durable queue, in an isolated app.
// Requires Xcode and the Rust aarch64-apple-ios-sim target. No game data is used.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
const root = resolve(import.meta.dirname, "..");
const bundle = "cn.gamealgo.session-smoke";
const target = process.arch === "arm64" ? "aarch64-apple-ios-sim" : "x86_64-apple-ios";
const arch = process.arch === "arm64" ? "arm64" : "x86_64";
const work = await mkdtemp(resolve(tmpdir(), "gamealgo-ios-session-"));
const app = resolve(work, "GameAlgoSessionSmoke.app");
const harness = resolve(root, "runtime/godot/tests/ios-session");
let device;
let alreadyBooted;

try {
  // A fresh CI VM may need more than 30s to initialize CoreSimulatorService,
  // before any test app has launched. This is not a session callback deadline.
  const devices = JSON.parse((await run("xcrun", ["simctl", "list", "devices", "available", "-j"], 180_000)).stdout).devices;
  const available = Object.entries(devices).filter(([runtime]) => runtime.includes(".iOS-"))
    .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
    .flatMap(([, entries]) => entries.filter((d) => d.isAvailable && d.name.startsWith("iPhone")));
  device = available.find((d) => d.state === "Booted") ?? available[0];
  assert.ok(device, "an iPhone simulator is required");
  alreadyBooted = device.state === "Booted";
  await run("cargo", ["build", "--locked", "--manifest-path", "runtime/godot/Cargo.toml",
    "--example", "ios_session_smoke", "--target", target], 300_000);
  const sdk = (await run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])).stdout.trim();
  await mkdir(app);
  await copyFile(resolve(harness, "Info.plist"), resolve(app, "Info.plist"));
  await run("xcrun", ["clang", "-isysroot", sdk, "-target", `${arch}-apple-ios15.0-simulator`,
    "-fobjc-arc", "-fblocks", resolve(harness, "AppDelegate.m"),
    resolve(root, "runtime/godot/src/ios_lifecycle.m"),
    resolve(root, `runtime/godot/target/${target}/debug/examples/libios_session_smoke.a`),
    "-framework", "UIKit", "-framework", "Foundation", "-framework", "Security",
    "-liconv", "-o", resolve(app, "GameAlgoSessionSmoke")], 120_000);
  await run("codesign", ["--force", "--sign", "-", app]);
  if (!alreadyBooted) await run("xcrun", ["simctl", "boot", device.udid]);
  await run("xcrun", ["simctl", "bootstatus", device.udid, "-b"], 180_000);
  await run("xcrun", ["simctl", "install", device.udid, app], 180_000);
  await sim("launch", bundle);
  const data = (await sim("get_app_container", bundle, "data")).stdout.trim();
  const statePath = resolve(data, "Documents/session.json");
  const state = async () => JSON.parse(await readFile(statePath, "utf8"));
  await until(async () => (await readFile(resolve(data, "Documents/ready"), "utf8")) === "ad-visible");
  const first = await state();
  assert.equal(first.events.length, 0, "presenting a full-screen ad must not end the session");
  assert.equal(first.session.open, true);
  await until(async () => (await state()).session.last_seen_ms > first.session.last_seen_ms, 15_000);
  assert.equal((await state()).events.length, 0, "ad foreground heartbeat does not end the session");
  console.log("PASS: full-screen ad keeps the session open and the native heartbeat runs");

  // Switching to a different app is a real background transition, even with
  // the surrogate ad still presented and without any Godot callbacks.
  await sim("launch", "com.apple.Preferences");
  await until(async () => (await state()).events.some((e) => e.payload.reason === "background"));
  const background = await state();
  assert.equal(background.session.open, false);
  assert.equal(background.events.length, 1);
  assert.equal(background.events[0].payload.endTimeEstimated, false);
  assert.equal(background.events[0].payload.sessionDurationMs,
    background.session.duration_ms);
  assert.ok(background.session.duration_ms > 0, "the native timer accumulates while the surrogate ad is visible");
  assert.ok(background.session.duration_ms <= background.session.last_seen_ms - first.session.started_at_ms);
  console.log("PASS: leaving the ad for another app immediately persists a normal session_end");

  const resumed = await sim("launch", bundle);
  await until(async () => (await state()).session.open);
  const open = await state();
  assert.equal(open.session.event.sessionId, first.session.event.sessionId);
  assert.notEqual(open.session.event.eventId, first.session.event.eventId);
  const pid = Number(new RegExp(`${bundle}: (\\d+)`).exec(resumed.stdout)?.[1]);
  assert.ok(Number.isInteger(pid) && pid > 1, "simctl must return the exact test process PID");
  process.kill(pid, "SIGKILL");
  const killed = await state();
  // Wait for launchd to observe termination, not for a lifecycle callback.
  await delay(500);
  await sim("launch", bundle);
  await until(async () => (await state()).session.event.sessionId !== first.session.event.sessionId);
  const restored = await state();
  const recovered = restored.events.filter((e) => e.payload.reason === "process_restart");
  assert.equal(recovered.length, 1);
  assert.equal(recovered[0].eventId, killed.session.event.eventId);
  assert.equal(recovered[0].sessionId, first.session.event.sessionId);
  assert.equal(recovered[0].contextId, "smoke-context");
  assert.equal(recovered[0].payload.endTimeEstimated, true);
  assert.equal(recovered[0].payload.sessionDurationMs, killed.session.duration_ms);
  assert.equal(recovered[0].timestamp, killed.session.event.timestamp);
  console.log("PASS: SIGKILL during the ad recovers the old session identity and last-observed duration");
  console.log(`iOS native session integration passed on ${device.name}`);
} finally {
  if (device) {
    await sim("terminate", bundle).catch(() => {});
    await sim("uninstall", bundle).catch(() => {});
    if (!alreadyBooted) await sim("shutdown").catch(() => {});
  }
  await rm(work, { recursive: true, force: true });
}

async function run(command, args, timeout = 30_000) {
  try {
    return await exec(command, args, { cwd: root, encoding: "utf8", timeout, maxBuffer: 10 * 1024 * 1024 });
  } catch (error) {
    console.error(error.stdout ?? "", error.stderr ?? "");
    if (error.killed) throw new Error(`${command} ${args.join(" ")} timed out after ${timeout / 1000}s`);
    throw error;
  }
}
function sim(command, ...args) { return run("xcrun", ["simctl", command, device.udid, ...args], 60_000); }
function delay(ms) { return new Promise((done) => setTimeout(done, ms)); }
async function until(check, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try { if (await check()) return; } catch { /* the first atomic write may not exist yet */ }
    await delay(100);
  }
  throw new Error("Timed out waiting for the native session state");
}
