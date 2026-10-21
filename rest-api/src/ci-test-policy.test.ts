import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import YAML from "yaml";

const workflows = new URL("../../.github/workflows/", import.meta.url);
const scripts = JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")).scripts;

test("cloud workflows keep simulator and browser integration checks local", () => {
  for (const name of readdirSync(workflows).filter((file) => /\.ya?ml$/.test(file))) {
    const workflow = YAML.parse(readFileSync(new URL(name, workflows), "utf8"));
    for (const job of Object.values(workflow.jobs) as Array<{ steps?: Array<{ run?: string; uses?: string }> }>) {
      for (const step of job.steps ?? []) {
        const command = `${step.run ?? ""}\n${step.uses ?? ""}`;
        assert.doesNotMatch(command,
          /simctl|android-emulator-runner|connected\w*AndroidTest|test-godot-ios-session\.mjs|check:web:(?:e2e|webview|multiplayer)\b/,
          `${name} must not launch a simulator or browser integration test`);
        assert.doesNotMatch(command, /\bnpm run check(?=\s|$)|\bnpm run check:godot(?=\s|$)/,
          `${name} must use a core entry point instead of the full local suite`);
      }
    }
  }
});

test("core commands retain SDK contracts without the local integration suites", () => {
  assert.match(scripts["check:core"], /build:runtime/);
  assert.match(scripts["check:core"], /check:web/);
  assert.match(scripts["check:core"], /node --test rest-api\/src\/\*\.test\.ts/);
  assert.match(scripts["check:core"], /check:web:pack/);
  assert.doesNotMatch(scripts["check:core"], /check:web:(?:e2e|webview|multiplayer)\b/);
  assert.equal(scripts["check:godot:core"], "node scripts/run-godot-tests.mjs --core");
});

test("local simulator and transport integration entry points remain available", () => {
  assert.match(scripts["check"], /check:web:e2e/);
  assert.match(scripts["check"], /check:web:webview/);
  assert.equal(scripts["check:godot"], "node scripts/run-godot-tests.mjs");
  assert.equal(scripts["check:godot:ios"], "node scripts/test-godot-ios-session.mjs");
  assert.equal(scripts["check:godot:http"], "python3 scripts/test-godot-http-timeout.py");
  for (const file of ["scripts/test-godot-ios-session.mjs", "scripts/test-godot-http-timeout.py",
    "web/e2e/run-browser-test.mjs", "web/e2e/run-ios-webview-test.mjs"]) {
    assert.ok(readFileSync(new URL(`../../${file}`, import.meta.url)).length > 0);
  }
});
