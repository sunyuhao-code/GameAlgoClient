#!/usr/bin/env node
// Runs the Godot SDK contract suites headlessly.
//
// The GDScript SDK cannot be exercised by the Node or Swift suites, so these
// run under a real Godot build. Set GODOT_BIN to point at one; otherwise the
// first `godot` on PATH is used.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const projectPath = fileURLToPath(new URL("../godot", import.meta.url));
const suites = ["res://tests/parse_check.gd", "res://tests/gamealgo_sdk_contracts.gd"];

// The runtime suite needs the GDExtension for this host. It is a build output,
// so it may be absent in a fresh checkout.
const runtimeSuite = "res://tests/gamealgo_runtime_contracts.gd";
// Only macOS has a host runtime build; the other shipped targets are mobile.
const runtimeLibrary = { darwin: "macos/libgamealgo_godot_runtime.dylib" }[process.platform];

function resolveGodot() {
  const explicit = process.env.GODOT_BIN;
  if (explicit) {
    if (!existsSync(explicit)) {
      console.error(`GODOT_BIN is set but does not exist: ${explicit}`);
      process.exit(1);
    }
    return explicit;
  }
  const found = spawnSync("command", ["-v", "godot"], { shell: true, encoding: "utf8" });
  const candidate = found.stdout.trim();
  if (!candidate) {
    console.error(
      "Godot was not found. Install Godot 4.7 and set GODOT_BIN, or put `godot` on PATH.",
    );
    process.exit(1);
  }
  return candidate;
}

function run(godot, args) {
  return spawnSync(godot, ["--headless", "--path", projectPath, ...args], {
    stdio: "inherit",
    encoding: "utf8",
  });
}

const godot = resolveGodot();
const version = spawnSync(godot, ["--version"], { encoding: "utf8" }).stdout.trim();
console.log(`Godot: ${version}`);
if (!version.startsWith("4.")) {
  console.error("The Godot SDK targets Godot 4.x.");
  process.exit(1);
}

// A clean checkout has no import cache; importing first keeps the suite output
// free of first-run import noise. An import failure is reported by the suites.
run(godot, ["--import"]);

const hasRuntime =
  runtimeLibrary !== undefined &&
  existsSync(fileURLToPath(new URL(`../godot/addons/gamealgo/runtime/${runtimeLibrary}`, import.meta.url)));
if (hasRuntime) {
  suites.push(runtimeSuite);
} else {
  console.warn(
    "\nSkipping the runtime contracts: no GDExtension for this host.\n" +
      "They need macOS and `npm run build:godot-runtime`.",
  );
}

let failed = 0;
for (const suite of suites) {
  console.log(`\n== ${suite} ==`);
  const result = run(godot, ["--script", suite]);
  if (result.status !== 0) {
    console.error(`FAILED: ${suite} (exit ${result.status})`);
    failed += 1;
  }
}

if (failed > 0) {
  console.error(`\n${failed} Godot suite(s) failed.`);
  process.exit(1);
}
console.log("\nGodot SDK contracts passed.");
