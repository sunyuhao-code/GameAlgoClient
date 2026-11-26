import assert from "node:assert/strict";
import test from "node:test";
import { GameAlgoRestClient } from "./core-client.ts";

test("initial old-user classification preserves explicit false, survives restart and cannot be overwritten", async () => {
  for (const first of [true, false]) {
    const values = new Map<string, string>();
    const storage = { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value); }, removeItem: (key: string) => { values.delete(key); } };
    const bodies: Record<string, unknown>[] = [];
    const create = (isOldUser?: boolean, gameKey = "ga_live_old_user_test") => new GameAlgoRestClient({
      baseUrl: "https://test.invalid", gameKey, experimentIntegrationVersion: 1, storage, userId: "user", isOldUser,
      logger: false, preloadConfigFiles: false, eventFlushIntervalMs: 0,
      fetchImpl: async (input, init) => {
        const request = new Request(input, init);
        if (request.url.endsWith("/v1/config")) {
          bodies.push(await request.json() as Record<string, unknown>);
          return new Response(JSON.stringify({ contextId: "context", gameId: "game", environment: "live", configVersion: "1", ttlSeconds: 300, serverTime: new Date().toISOString(), experiments: [], configFiles: [] }));
        }
        return new Response(JSON.stringify({ ok: true, accepted: 0 }));
      },
    });
    const legacy = create();
    await legacy.waitForReady();
    assert.equal(Object.hasOwn(bodies.at(-1)!, "isOldUser"), false);
    const explicit = create(first);
    await explicit.waitForReady();
    assert.equal(bodies.at(-1)!.isOldUser, first);
    const restarted = create(!first);
    await restarted.waitForReady();
    await restarted.fetchConfig({ forceRefresh: true });
    assert.equal(bodies.at(-1)!.isOldUser, first);
    const omitted = create();
    await omitted.waitForReady();
    assert.equal(bodies.at(-1)!.isOldUser, first);
    await restarted.fetchConfig({ userId: "other-user", forceRefresh: true });
    assert.equal(bodies.at(-1)!.isOldUser, !first, "Identity changes do not inherit another user's classification");
    const otherGame = create(!first, "ga_live_other_game");
    await otherGame.waitForReady();
    assert.equal(bodies.at(-1)!.isOldUser, !first, "Game keys isolate classifications");
  }
});

test("old-user initialization rejects values that would coerce false into true", () => {
  for (const isOldUser of ["false", "true", null, 0, 1]) {
    assert.throws(() => new GameAlgoRestClient({ baseUrl: "https://test.invalid", gameKey: "ga_live_old_user_test", experimentIntegrationVersion: 1, isOldUser: isOldUser as never }), /isOldUser must be a boolean/);
  }
});
