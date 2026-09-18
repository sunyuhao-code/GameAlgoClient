import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import YAML from "yaml";
import type { Platform } from "./types.ts";

// The Godot SDK is GDScript, so it cannot import the TypeScript protocol types
// or be covered by the other SDKs' test suites. These checks read its source
// directly and fail when a protocol value drifts away from openapi.yaml.

const godotSource = (name: string): string =>
  readFileSync(new URL(`../../godot/addons/gamealgo/${name}`, import.meta.url), "utf8");

const openapi = (): { components: { schemas: Record<string, { properties?: Record<string, { enum?: string[] }> }> } } =>
  YAML.parse(readFileSync(new URL("../../protocol/openapi.yaml", import.meta.url), "utf8"));

function gdscriptStringArray(source: string, constName: string): string[] {
  const match = source.match(new RegExp(`const ${constName}\\s*:?=\\s*\\[([^\\]]*)\\]`));
  assert.ok(match, `${constName} not found in the Godot SDK`);
  return [...match[1].matchAll(/"([^"]*)"/g)].map((entry) => entry[1]);
}

test("Godot platform allowlist stays inside the protocol enum", () => {
  const platforms = gdscriptStringArray(godotSource("gamealgo_client.gd"), "ALLOWED_PLATFORMS");
  const schemas = openapi().components.schemas;
  const protocolPlatforms = schemas.ConfigRequest.properties?.platform?.enum;
  assert.ok(protocolPlatforms, "ConfigRequest.platform has no enum");

  assert.ok(platforms.length > 0, "Godot SDK declares no platforms");
  for (const platform of platforms) {
    assert.ok(
      protocolPlatforms.includes(platform),
      `Godot SDK reports platform "${platform}", which openapi.yaml does not allow`,
    );
    // Also proves the value is assignable to the shared Platform type.
    const typed: Platform = platform as Platform;
    assert.equal(typed, platform);
  }
});

test("every schema carrying a platform shares one enum", () => {
  const schemas = openapi().components.schemas;
  const carriers = Object.entries(schemas).filter(([, schema]) => schema.properties?.platform?.enum);
  assert.ok(carriers.length >= 3, "expected platform on the context, attribution and identifier schemas");
  const [, first] = carriers[0];
  const expected = first.properties?.platform?.enum;
  for (const [name, schema] of carriers) {
    assert.deepEqual(
      schema.properties?.platform?.enum,
      expected,
      `${name}.platform diverged from the other platform enums`,
    );
  }
});

test("Godot SDK never hardcodes the engine as a platform", () => {
  // The engine belongs in the device context so it does not consume the
  // platform dimension used for targeting and reporting.
  const client = godotSource("gamealgo_client.gd");
  const platforms = gdscriptStringArray(client, "ALLOWED_PLATFORMS");
  assert.ok(!platforms.includes("godot"), "godot is an engine, not a platform");
  assert.match(client, /"runtime"\s*:\s*"godot"/, "device context must report the engine");
});

test("Godot custom event quota matches the canonical client", () => {
  const tracker = godotSource("gamealgo_tracker.gd");
  const constant = (name: string): number => {
    const match = tracker.match(new RegExp(`const ${name}\\s*:?=\\s*(\\d+)`));
    assert.ok(match, `${name} not found in the Godot tracker`);
    return Number(match[1]);
  };

  // Mirrors consumeCustomEventQuota in rest-api/src/client.ts.
  assert.equal(constant("QUOTA_PER_EVENT_TYPE"), 1000);
  assert.equal(constant("QUOTA_PER_CONTEXT"), 5000);
  assert.equal(constant("QUOTA_DISTINCT_EVENT_TYPES"), 100);

  const canonical = readFileSync(new URL("./client.ts", import.meta.url), "utf8");
  const start = canonical.indexOf("private consumeCustomEventQuota");
  assert.notEqual(start, -1, "consumeCustomEventQuota not found in the canonical client");
  const quota = canonical.slice(start, start + 1200);
  for (const limit of [1000, 5000, 100]) {
    assert.ok(
      new RegExp(`>=\\s*${limit}\\b`).test(quota),
      `rest-api no longer enforces the ${limit} custom event limit`,
    );
  }
});

test("both clients exempt the same standard event types", () => {
  const godotList = gdscriptStringArray(godotSource("gamealgo_tracker.gd"), "STANDARD_EVENT_TYPES");
  const canonical = readFileSync(new URL("./client.ts", import.meta.url), "utf8");
  const match = canonical.match(/const STANDARD_EVENT_TYPES = new Set\(\[([^\]]*)\]/);
  assert.ok(match, "STANDARD_EVENT_TYPES not found in the canonical client");
  const canonicalList = [...match[1].matchAll(/"([^"]*)"/g)].map((entry) => entry[1]);

  assert.deepEqual(
    [...godotList].sort(),
    [...canonicalList].sort(),
    "the Godot SDK exempts a different set of standard events",
  );
});

test("Godot SDK reports a concrete SDK version", () => {
  const client = godotSource("gamealgo_client.gd");
  const match = client.match(/const SDK_VERSION\s*:?=\s*"([^"]+)"/);
  assert.ok(match, "SDK_VERSION not found in the Godot SDK");
  assert.match(match[1], /^\d+\.\d+\.\d+$/, "SDK_VERSION must be semantic");
});
