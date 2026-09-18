#!/usr/bin/env node
// Builds the GameAlgo Godot runtime (a GDExtension around runtime/rust) and
// installs it into godot/addons/gamealgo/runtime/.
//
//   node scripts/build-godot-runtime.mjs            # host only, for tests
//   node scripts/build-godot-runtime.mjs --all      # macos, ios and android
//   node scripts/build-godot-runtime.mjs ios android
//
// Apple deployment targets match runtime/rust's own Apple build scripts, and
// Android goes through cargo-ndk, so the runtime keeps the same floors as the
// iOS and Android SDKs.

import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const crateDir = fileURLToPath(new URL("../runtime/godot", import.meta.url));
const installRoot = fileURLToPath(new URL("../godot/addons/gamealgo/runtime", import.meta.url));

const IOS_DEPLOYMENT_TARGET = "13.0";
const MACOS_DEPLOYMENT_TARGET = "12.0";

// Each entry installs one built library under its own directory.
const TARGETS = {
  macos: [{ rustTarget: "aarch64-apple-darwin", dir: "macos", file: "libgamealgo_godot_runtime.dylib", env: { MACOSX_DEPLOYMENT_TARGET: MACOS_DEPLOYMENT_TARGET } }],
  ios: [
    { rustTarget: "aarch64-apple-ios", dir: "ios", file: "libgamealgo_godot_runtime.dylib", env: { IPHONEOS_DEPLOYMENT_TARGET: IOS_DEPLOYMENT_TARGET } },
    { rustTarget: "aarch64-apple-ios-sim", dir: "ios-simulator", file: "libgamealgo_godot_runtime.dylib", env: { IPHONEOS_DEPLOYMENT_TARGET: IOS_DEPLOYMENT_TARGET } },
  ],
  android: [
    { rustTarget: "aarch64-linux-android", abi: "arm64-v8a", dir: "android/arm64-v8a", file: "libgamealgo_godot_runtime.so" },
    { rustTarget: "armv7-linux-androideabi", abi: "armeabi-v7a", dir: "android/armeabi-v7a", file: "libgamealgo_godot_runtime.so" },
    { rustTarget: "x86_64-linux-android", abi: "x86_64", dir: "android/x86_64", file: "libgamealgo_godot_runtime.so" },
  ],
};

function hostPlatform() {
  if (process.platform === "darwin") return "macos";
  // Linux and Windows are not shipped targets, so there is no host build there.
  console.error(
    `no Godot runtime target for this host (${process.platform}); shipped targets are macos, ios and android`,
  );
  process.exit(1);
}

function build(entry) {
  const isAndroid = Boolean(entry.abi);
  const command = isAndroid ? "cargo" : "cargo";
  const args = isAndroid
    ? ["ndk", "-t", entry.abi, "build", "--release"]
    : ["build", "--release", "--target", entry.rustTarget];
  const result = spawnSync(command, args, {
    cwd: crateDir,
    stdio: "inherit",
    env: { ...process.env, ...(entry.env ?? {}) },
  });
  if (result.status !== 0) {
    console.error(`FAILED: ${entry.rustTarget}`);
    return false;
  }
  const built = join(crateDir, "target", entry.rustTarget, "release", entry.file);
  if (!existsSync(built)) {
    console.error(`FAILED: ${entry.rustTarget} produced no ${entry.file}`);
    return false;
  }
  const destination = join(installRoot, entry.dir);
  mkdirSync(destination, { recursive: true });
  copyFileSync(built, join(destination, entry.file));
  console.log(`installed ${entry.rustTarget} -> addons/gamealgo/runtime/${entry.dir}/${entry.file}`);
  return true;
}

const requested = process.argv.slice(2);
const platforms = requested.includes("--all")
  ? Object.keys(TARGETS)
  : requested.length > 0
    ? requested
    : [hostPlatform()];

let failed = 0;
for (const platform of platforms) {
  const entries = TARGETS[platform];
  if (!entries) {
    console.error(`unknown platform: ${platform}`);
    failed += 1;
    continue;
  }
  for (const entry of entries) {
    if (!build(entry)) failed += 1;
  }
}

if (failed > 0) {
  console.error(`\n${failed} target(s) failed.`);
  process.exit(1);
}
console.log("\nGodot runtime built.");
