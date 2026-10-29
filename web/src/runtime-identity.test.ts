import assert from "node:assert/strict";
import test from "node:test";
import { GameAlgoWebClient } from "./index.ts";

function host(t: test.TestContext, value: unknown) {
  const original = Object.getOwnPropertyDescriptor(globalThis, "tap");
  t.after(() => {
    if (original) Object.defineProperty(globalThis, "tap", original);
    else Reflect.deleteProperty(globalThis, "tap");
  });
  const set = (tap: unknown) => Object.defineProperty(globalThis, "tap", { configurable: true, value: tap });
  set(value);
  return set;
}

function fixture(t: test.TestContext, device: Record<string, string> = {}) {
  const configs: Array<{ device: Record<string, unknown> }> = [];
  const events: Array<{ payload: Record<string, unknown> }> = [];
  const values = new Map<string, string>();
  const client = new GameAlgoWebClient({
    baseUrl: "https://fixture.example", gameKey: "ga_live_fixture", userId: "fixture-user",
    autoLifecycle: false, preloadConfigFiles: false, device,
    storage: { getItem: key => values.get(key), setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } },
    fetchImpl: async (input, init) => {
      const body = JSON.parse(String(init?.body));
      if (String(input).endsWith("/v1/config")) {
        configs.push(body);
        return Response.json({ contextId: `ctx-${configs.length}`, configVersion: "1", ttlSeconds: 60, experiments: [], configFiles: [] });
      }
      if (String(input).endsWith("/v1/events/batch")) {
        events.push(...body.events);
        return Response.json({ ok: true, accepted: body.events.length });
      }
      throw new Error("Unexpected fixture endpoint");
    },
  });
  t.after(() => client.close());
  return { client, configs, events };
}

test("H5 reports native miniapp identity in Context and ignores copied device identity overrides", async t => {
  const tap = { getAccountInfoSync() { assert.equal(this, tap); return { miniProgram: { appId: "tapmcactualgame" } }; } };
  host(t, tap);
  const copied = { runtimeMiniappId: "tapmccopied", runtimeProjectId: "copied-project", runtimeAppId: "999", runtimeIdentitySource: "copied", custom: "kept" };
  const { client, configs, events } = fixture(t, copied);
  assert.equal(await client.waitForReady(), true);
  let device = configs.at(-1)!.device;
  assert.equal(device.runtimeMiniappId, "tapmcactualgame");
  assert.equal(device.runtimeIdentitySource, undefined);
  assert.equal(device.runtimeProjectId, undefined);
  assert.equal(device.runtimeAppId, undefined);
  assert.equal(device.custom, "kept");
  await client.fetchConfig({ forceRefresh: true, device: copied });
  device = configs.at(-1)!.device;
  assert.equal(device.runtimeMiniappId, "tapmcactualgame");
  assert.equal(device.runtimeProjectId, undefined);
  assert.equal(device.runtimeAppId, undefined);
  assert.equal(device.runtimeIdentitySource, undefined);
  assert.equal(copied.runtimeMiniappId, "tapmccopied", "caller options are not mutated");
  assert.equal(client.tracker.trackLevelStart({ levelId: "one" }), true);
  await client.flush();
  assert.equal(events[0].payload.runtimeMiniappId, undefined, "identity belongs to Context rather than every business event");
});

test("late miniapp identity is collected on refresh; stale and numeric App IDs are omitted", async t => {
  const set = host(t, undefined);
  const { client, configs } = fixture(t, { runtimeMiniappId: "tapmccopied", runtimeAppId: "copied" });
  assert.equal(await client.waitForReady(), true);
  assert.equal(configs[0].device.runtimeMiniappId, undefined);
  assert.equal(configs[0].device.runtimeIdentitySource, undefined);
  set({ getAccountInfoSync: () => ({ miniProgram: { appId: "  tapmcactualgame  " } }) });
  await client.fetchConfig({ forceRefresh: true });
  const observed = configs.at(-1)!.device;
  assert.equal(observed.runtimeMiniappId, "tapmcactualgame");
  assert.equal(observed.runtimeAppId, undefined);
  assert.equal(observed.runtimeIdentitySource, undefined);
  assert.equal(configs[0].device.runtimeMiniappId, undefined, "prior wire snapshots are unchanged");
  set({ getAccountInfoSync: () => ({ miniProgram: { appId: 944655 } }) });
  await client.fetchConfig({ forceRefresh: true });
  assert.equal(configs.at(-1)!.device.runtimeMiniappId, undefined);
  assert.equal(configs.at(-1)!.device.runtimeAppId, undefined, "numeric App ID is never uploaded");
  assert.equal(observed.runtimeMiniappId, "tapmcactualgame");
  set(undefined);
  await client.fetchConfig({ forceRefresh: true });
  assert.equal(configs.at(-1)!.device.runtimeMiniappId, undefined);
  assert.equal(configs.at(-1)!.device.runtimeIdentitySource, undefined);
});

test("unavailable, invalid and throwing host APIs never block Context creation or invent identity", async t => {
  const set = host(t, undefined);
  const { client, configs } = fixture(t, { runtimeMiniappId: "copied" });
  assert.equal(await client.waitForReady(), true);
  const cases: unknown[] = [
    { getAccountInfoSync() { throw new Error("not implemented"); } },
    { get getAccountInfoSync() { throw new Error("bridge unavailable"); } },
    { getAccountInfoSync: () => null },
    { getAccountInfoSync: () => ({ plugin: { appId: "plugin-id" }, host: { appId: "container-id" } }) },
    { getAccountInfoSync: () => Promise.reject(new Error("not synchronous")) },
    ...["", "tapmc", "tapmc-unsafe", "tapmcUPPER", "944655", "https://example.com/game", "two ids", "tapmc" + "x".repeat(124), {}, 944655, -1, Infinity, Number.MAX_SAFE_INTEGER + 1]
      .map(appId => ({ getAccountInfoSync: () => ({ miniProgram: { appId } }) })),
  ];
  for (const value of cases) {
    set(value);
    await client.fetchConfig({ forceRefresh: true, device: { runtimeMiniappId: "copied-again" } });
    const device = configs.at(-1)!.device;
    assert.equal(device.runtimeIdentitySource, undefined);
    assert.equal(device.runtimeAppId, undefined);
    assert.equal(device.runtimeMiniappId, undefined);
    assert.equal(device.runtimeProjectId, undefined);
  }
});
