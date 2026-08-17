import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import YAML from "yaml";

const fixtureUrl = (name: string) => new URL(`../../protocol/fixtures/${name}`, import.meta.url);

function fixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(fixtureUrl(name), "utf8")) as Record<string, unknown>;
}

test("shared request fixtures preserve typed protocol values", () => {
  const config = fixture("config-request.json");
  const batch = fixture("events-batch-request.json");
  const attribution = fixture("attribution-request.json");
  const identifier = fixture("context-identifier-request.json");
  const event = (batch.events as Array<Record<string, unknown>>)[0];
  const payload = event.payload as Record<string, unknown>;

  assert.equal(config.accountUserId, "maker_user_fixture_001");
  assert.equal(config.experimentIntegrationVersion, 2);
  assert.equal(event.accountUserId, config.accountUserId);
  assert.equal(typeof payload.level, "number");
  assert.equal(typeof payload.success, "boolean");
  assert.equal((attribution.attribution as Record<string, unknown>).network, "Google Ads");
  assert.equal(identifier.identifierType, "adjust_adid");
});

test("OpenAPI exposes immutable scripts and every shared request contract", () => {
  const document = YAML.parse(readFileSync(new URL("../../protocol/openapi.yaml", import.meta.url), "utf8")) as {
    paths: Record<string, unknown>;
    components: { schemas: Record<string, unknown> };
  };

  assert.ok(document.paths["/v1/scripts/{versionId}"]);
  for (const schema of ["ConfigRequest", "EventBatchRequest", "UserAttributionRequest", "ContextIdentifierRequest"]) {
    assert.ok(document.components.schemas[schema], `missing OpenAPI schema ${schema}`);
  }
});
