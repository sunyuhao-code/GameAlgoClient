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
import { copyFileSync, mkdirSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const crateDir = fileURLToPath(new URL("../runtime/godot", import.meta.url));
const installRoot = fileURLToPath(new URL("../godot/addons/gamealgo/runtime", import.meta.url));

const IOS_DEPLOYMENT_TARGET = "13.0";
const MACOS_DEPLOYMENT_TARGET = "12.0";

// Godot loads the iOS runtime from an embedded framework, and dyld resolves it
// by the binary's own install name. A bare .dylib keeps the absolute build path
// the linker recorded, which exists on no device, so the app dies at launch with
// OS_REASON_DYLD. The framework name and the binary inside it must match.
const FRAMEWORK_NAME = "gamealgo_godot_runtime";

// Each entry installs one built library under its own directory.
const TARGETS = {
  macos: [{ rustTarget: "aarch64-apple-darwin", dir: "macos", file: "libgamealgo_godot_runtime.dylib", env: { MACOSX_DEPLOYMENT_TARGET: MACOS_DEPLOYMENT_TARGET } }],
  ios: [
    {
      rustTarget: "aarch64-apple-ios",
      dir: "ios",
      file: "libgamealgo_godot_runtime.dylib",
      env: { IPHONEOS_DEPLOYMENT_TARGET: IOS_DEPLOYMENT_TARGET },
      framework: { supportedPlatform: "iPhoneOS", platformName: "iphoneos" },
    },
    {
      rustTarget: "aarch64-apple-ios-sim",
      dir: "ios-simulator",
      file: "libgamealgo_godot_runtime.dylib",
      env: { IPHONEOS_DEPLOYMENT_TARGET: IOS_DEPLOYMENT_TARGET },
      framework: { supportedPlatform: "iPhoneSimulator", platformName: "iphonesimulator" },
    },
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
  if (entry.framework) return installFramework(entry, built, destination);
  copyFileSync(built, join(destination, entry.file));
  // Desktop loads by absolute path, but leaving the build machine's path as the
  // install name is noise at best; make it relocatable like the iOS binary.
  setInstallName(join(destination, entry.file), `@rpath/${entry.file}`);
  console.log(`installed ${entry.rustTarget} -> addons/gamealgo/runtime/${entry.dir}/${entry.file}`);
  return true;
}

function setInstallName(binary, name) {
  const result = spawnSync("install_name_tool", ["-id", name, binary], { stdio: "inherit" });
  return result.status === 0;
}

function installFramework(entry, built, destination) {
  const bundle = join(destination, `${FRAMEWORK_NAME}.framework`);
  const binary = join(bundle, FRAMEWORK_NAME);
  const installName = `@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}`;
  rmSync(bundle, { recursive: true, force: true });
  mkdirSync(bundle, { recursive: true });
  copyFileSync(built, binary);
  if (!setInstallName(binary, installName)) {
    console.error(`FAILED: could not set the install name for ${entry.rustTarget}`);
    return false;
  }
  // arm64 simulator slices floor at iOS 14 regardless of the requested target,
  // so take the real value rather than letting the bundle claim a lower one.
  const minimumOSVersion = machOMinimumOS(binary) ?? IOS_DEPLOYMENT_TARGET;
  writeFileSync(join(bundle, "Info.plist"), frameworkPlist(entry.framework, minimumOSVersion));

  const lint = spawnSync("plutil", ["-lint", join(bundle, "Info.plist")], { encoding: "utf8" });
  if (lint.status !== 0) {
    console.error(`FAILED: ${entry.rustTarget} framework Info.plist is malformed`);
    return false;
  }
  // dyld resolves the embedded framework through this name. If it ever reverts
  // to an absolute build path the app dies at launch, so fail the build here
  // rather than at someone's first device run.
  const recorded = spawnSync("otool", ["-D", binary], { encoding: "utf8" }).stdout.trim().split("\n").pop();
  if (recorded !== installName) {
    console.error(`FAILED: ${entry.rustTarget} install name is "${recorded}", expected "${installName}"`);
    return false;
  }
  console.log(`installed ${entry.rustTarget} -> addons/gamealgo/runtime/${entry.dir}/${FRAMEWORK_NAME}.framework`);
  return true;
}

function machOMinimumOS(binary) {
  const loadCommands = spawnSync("otool", ["-l", binary], { encoding: "utf8" }).stdout ?? "";
  return /^\s*minos\s+(\S+)/m.exec(loadCommands)?.[1] ?? null;
}

function frameworkPlist({ supportedPlatform, platformName }, minimumOSVersion) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
<key>CFBundleIdentifier</key><string>cn.gamealgo.godot-runtime</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>GameAlgoRuntime</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>10000</string>
<key>CFBundleSupportedPlatforms</key><array><string>${supportedPlatform}</string></array>
<key>DTPlatformName</key><string>${platformName}</string>
<key>MinimumOSVersion</key><string>${minimumOSVersion}</string>
</dict></plist>
`;
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
