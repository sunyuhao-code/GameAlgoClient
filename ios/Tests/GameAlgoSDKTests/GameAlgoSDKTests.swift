import XCTest
@testable import GameAlgoSDK

final class GameAlgoSDKTests: XCTestCase {
    func testSharedProtocolFixtureDecodesAndExecutesByImmutableScriptVersion() async throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures")
        let configData = try Data(contentsOf: fixtureRoot.appendingPathComponent("config-response.json"))
        let scriptData = try Data(contentsOf: fixtureRoot.appendingPathComponent("script-fixture.js"))
        let httpClient = FixtureHTTPClient(configData: configData, scriptData: scriptData)
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            cacheStorage: nil,
            userId: "fixture-user"
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(sdk.executor("difficulty").execute(.object([:]))?.payload, .object(["level": .number(2)]))
    }

    func testRustRuntimeBlocksIndirectFunctionConstructors() throws {
        let runtime = RustGameAlgoScriptRuntime()
        let input = GameAlgoScriptInput(
            state: .object([:]),
            config: .object([:]),
            meta: .init(
                gameId: "fixture",
                userId: "fixture-user",
                environment: .live,
                strategy: "fixture",
                experimentId: "fixture",
                variant: "control"
            )
        )

        XCTAssertThrowsError(try runtime.execute(
            script: "function execute() { return { payload: (function() {}).constructor('return 7')() }; }",
            input: input
        ))
    }

    private let gameKey = "ga_live_test_key_0123456789abcdef"

    func testConstructorUsesPersistedAnonymousUserIdByDefault() async throws {
        let suiteName = "GameAlgoSDKTests.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstHTTPClient = MockHTTPClient()
        try await firstHTTPClient.enqueueJSON(configResponse(version: "v1"))
        let first = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: firstHTTPClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let firstReady = await first.waitForReady()
        XCTAssertTrue(firstReady)
        let persistedUserId = first.userId
        let firstRequests = await firstHTTPClient.requests

        let secondHTTPClient = MockHTTPClient()
        try await secondHTTPClient.enqueueJSON(configResponse(version: "v2"))
        let second = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: secondHTTPClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults)
        )

        let secondReady = await second.waitForReady()
        XCTAssertTrue(secondReady)
        let secondRequests = await secondHTTPClient.requests

        XCTAssertFalse(persistedUserId.isEmpty)
        XCTAssertEqual(second.userId, persistedUserId)
        XCTAssertEqual(try requestBody(firstRequests[0])["userId"] as? String, persistedUserId)
        XCTAssertEqual(try requestBody(secondRequests[0])["userId"] as? String, persistedUserId)
    }

    func testConstructorBackfillsCreatedAtForPersistedLegacyUserId() async throws {
        let suiteName = "GameAlgoSDKTests.legacyIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("legacy-user", forKey: GameAlgoUserIdentityStore.legacyUserIdKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            eventFlushInterval: 0,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(sdk.userId, "legacy-user")
        XCTAssertEqual(defaults.string(forKey: GameAlgoUserIdentityStore.legacyUserCreatedAtKey), "2026-05-28T10:00:00.000Z")
        assertLocalTimestamp(defaults.string(forKey: GameAlgoUserIdentityStore.userCreatedLocalAtKey), sameInstantAs: "2026-05-28T10:00:00.000Z")

        let requests = await httpClient.requests
        let configRequest = try requestBody(requests[0])
        XCTAssertEqual(configRequest["userId"] as? String, "legacy-user")
        XCTAssertEqual(configRequest["userCreatedAt"] as? String, "2026-05-28T10:00:00.000Z")
        assertLocalTimestamp(configRequest["userCreatedLocalAt"], sameInstantAs: "2026-05-28T10:00:00.000Z")
        assertLocalTimestamp(configRequest["createdLocalAt"], sameInstantAs: "2026-05-28T10:00:00.000Z")
    }

    func testConfigureAdjustServerCallbackParamsUsesGameAlgoIdentity() throws {
        let suiteName = "GameAlgoSDKTests.adjustCallbackParams.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("u1", forKey: GameAlgoUserIdentityStore.legacyUserIdKey)
        defaults.set("2026-05-28T10:00:00.000Z", forKey: GameAlgoUserIdentityStore.legacyUserCreatedAtKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: MockHTTPClient(),
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            _autoStart: false
        )

        var params: [String: String] = [:]
        sdk.configureAdjustServerCallbackParams { key, value in
            params[key] = value
        }

        XCTAssertEqual(params["gamealgo_user_id"], "u1")
        XCTAssertEqual(params["gamealgo_user_created_at"], "2026-05-28T10:00:00.000Z")
    }

    func testTrackerBuffersEventsUntilConfigContextIsReady() async throws {
        let suiteName = "GameAlgoSDKTests.initialTrackerIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("u1", forKey: GameAlgoUserIdentityStore.legacyUserIdKey)
        defaults.set("2026-05-27T12:23:10Z", forKey: GameAlgoUserIdentityStore.legacyUserCreatedAtKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            _autoStart: false,
            eventFlushInterval: 0
        )

        let didTrackLevelEnd = await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3)]))
        XCTAssertTrue(didTrackLevelEnd)
        await sdk.tracker.flush()

        var requests = await httpClient.requests
        XCTAssertEqual(requests.count, 0)

        try await httpClient.enqueueJSON(["ok": true, "accepted": 1])
        await sdk.tracker.setContextId("ctx-1")
        await sdk.tracker.flush()

        requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(events?[0]["contextId"] as? String, "ctx-1")
        XCTAssertEqual(events?[0]["eventType"] as? String, "level_end")
    }

    func testTrackerKeepsBoundEventsAcrossSessionsAndDropsUnboundOldEvents() async throws {
        let uploader = QueueEventUploader(failures: 0)
        let tracker = GameAlgoEventTracker(uploader: uploader, flushInterval: 0)
        await tracker.identify(
            userId: "u1",
            sessionId: "session-1",
            userCreatedAt: "2026-05-28T10:00:00.000Z"
        )
        let queuedOldUnbound = await tracker.track("old_unbound")
        XCTAssertTrue(queuedOldUnbound)

        await tracker.newSession("session-2")
        await tracker.setContextId("ctx-2")
        let queuedBoundSession2 = await tracker.track("bound_session_2")
        XCTAssertTrue(queuedBoundSession2)

        await tracker.newSession("session-3")
        let queuedNewUnbound = await tracker.track("new_unbound")
        XCTAssertTrue(queuedNewUnbound)
        await tracker.setContextId("ctx-3")
        await tracker.flush()

        let uploaded = await uploader.uploadedEvents()
        XCTAssertEqual(uploaded.count, 2)
        XCTAssertEqual(uploaded[0].eventType, "bound_session_2")
        XCTAssertEqual(uploaded[0].contextId, "ctx-2")
        XCTAssertEqual(uploaded[0].sessionId, "session-2")
        XCTAssertEqual(uploaded[1].eventType, "new_unbound")
        XCTAssertEqual(uploaded[1].contextId, "ctx-3")
        XCTAssertEqual(uploaded[1].sessionId, "session-3")
    }

    func testFetchConfigSendsProtocolHeadersAndCachesByTTL() async throws {
        let suiteName = "GameAlgoSDKTests.fetchConfig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON([
            "contextId": "ctx-1",
            "gameId": "Mahjong",
            "environment": "live",
            "configVersion": "v1",
            "ttlSeconds": 60,
            "serverTime": "2026-05-28T10:00:00.000Z",
            "experiments": [],
            "configFiles": [],
        ])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test/algo_sdk")!,
            sdkVersion: "1.0.0",
            experimentIntegrationVersion: 7,
            httpClient: httpClient,
            cacheStorage: GameAlgoUserDefaultsCacheStorage(userDefaults: defaults),
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            _autoStart: false,
            isDebug: true,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let first = try await sdk.fetchConfig(userId: "u1")
        let second = try await sdk.fetchConfig(userId: "u1")
        let requests = await httpClient.requests

        XCTAssertEqual(first.gameId, "Mahjong")
        XCTAssertEqual(second.configVersion, "v1")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headers["X-GameAlgo-Key"], gameKey)
        XCTAssertEqual(requests[0].method, .post)
        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/algo_sdk/v1/config")
        let requestPayload = try requestBody(requests[0])
        XCTAssertEqual(requestPayload["userId"] as? String, "u1")
        XCTAssertEqual(requestPayload["userCreatedAt"] as? String, "1970-01-01T00:16:40.000Z")
        assertLocalTimestamp(requestPayload["userCreatedLocalAt"], sameInstantAs: "1970-01-01T00:16:40.000Z")
        XCTAssertEqual(requestPayload["createdLocalAt"] as? String, requestPayload["userCreatedLocalAt"] as? String)
        XCTAssertFalse((requestPayload["sessionId"] as? String ?? "").isEmpty)
        XCTAssertEqual(requestPayload["platform"] as? String, "ios")
        XCTAssertEqual(requestPayload["sdkVersion"] as? String, "1.0.0")
        XCTAssertEqual(requestPayload["experimentIntegrationVersion"] as? Int, 7)
        XCTAssertEqual(requestPayload["isDebug"] as? Bool, true)
        let device = try XCTUnwrap(requestPayload["device"] as? [String: Any])
        XCTAssertEqual(device["runtime"] as? String, "ios")
        XCTAssertEqual(device["locale"] as? String, Locale.current.identifier)
        XCTAssertFalse(device.isEmpty)
    }

    func testFetchConfigCanForceRefresh() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(configResponse(version: "v2"))
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            _autoStart: false,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        _ = try await sdk.fetchConfig(userId: "u1")
        let refreshed = try await sdk.fetchConfig(userId: "u1", forceRefresh: true)

        let requests = await httpClient.requests
        XCTAssertEqual(refreshed.configVersion, "v2")
        XCTAssertEqual(requests.count, 2)
    }

    func testFetchConfigFallsBackToExpiredCacheWhenNetworkFails() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1", ttlSeconds: 0))
        await httpClient.enqueueError(GameAlgoError.networkFailed("offline"))
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            _autoStart: false,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        _ = try await sdk.fetchConfig(userId: "u1")
        let fallback = try await sdk.fetchConfig(userId: "u1")

        let requests = await httpClient.requests
        XCTAssertEqual(fallback.configVersion, "v1")
        XCTAssertEqual(requests.count, 2)
    }

    func testFetchConfigFileReturnsTextAndETag() async throws {
        let httpClient = MockHTTPClient()
        await httpClient.enqueue(
            GameAlgoHTTPResponse(
                statusCode: 200,
                headers: [
                    "content-type": "application/json; charset=utf-8",
                    "etag": "\"sha256:test\"",
                ],
                body: Data("{\"difficulty\":\"normal\"}\n".utf8)
            )
        )
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            _autoStart: false
        )

        let file = try await sdk.fetchConfigFile("gameplay.json")
        let requests = await httpClient.requests

        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/v1/config-files/gameplay.json")
        XCTAssertEqual(file.name, "gameplay.json")
        XCTAssertEqual(file.etag, "\"sha256:test\"")
        XCTAssertEqual(file.content, "{\"difficulty\":\"normal\"}\n")
    }

    func testConstructorPreloadsConfigFilesAndExposesLocalExecutorAndConfigReaders() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON([
            "contextId": "ctx-1",
            "gameId": "Mahjong",
            "environment": "live",
            "configVersion": "v1",
            "ttlSeconds": 60,
            "serverTime": "2026-05-28T10:00:00.000Z",
            "experiments": [[
                "key": "level_generator",
                "experimentId": "exp-level-generator-001",
                "variant": "variant-a",
                "config": [
                    "difficulty": "hard",
                    "spawnRate": 0.7,
                ],
            ]],
            "configFiles": [[
                "name": "gameplay.json",
                "url": "https://gamealgo.test/v1/config-files/gameplay.json",
                "hash": "sha256:test",
            ]],
        ])
        await httpClient.enqueue(
            GameAlgoHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json; charset=utf-8"],
                body: Data("""
                {"ads":{"rewarded":{"enabled":false}},"economy":{"startCoins":120}}
                """.utf8)
            )
        )
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            sdkVersion: "1.0.0",
            httpClient: httpClient,
            userId: "u1"
        )
        let executor = sdk.executor("level_generator")

        XCTAssertFalse(executor.isReady)
        XCTAssertEqual(executor.variant(default: "control"), "control")

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)

        XCTAssertTrue(executor.isReady)
        XCTAssertEqual(executor.variant(default: "control"), "variant-a")
        XCTAssertEqual(executor.string("difficulty", default: "normal"), "hard")
        XCTAssertEqual(executor.double("spawnRate"), 0.7)
        XCTAssertEqual(sdk.config.bool("ads.rewarded.enabled", default: true, fileName: "gameplay.json"), false)
        XCTAssertEqual(sdk.config.int("economy.startCoins"), 120)
        let requests = await httpClient.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testExecutorExecutesPreloadedScriptAgainstLocalSnapshot() async throws {
        let script = """
        function execute(input) {
          return {
            payload: { difficulty: input.config.difficulty, turn: input.state.turn },
            diagnostics: { variant: input.meta.variant, userId: input.meta.userId }
          };
        }
        """
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON([
            "contextId": "ctx-1",
            "gameId": "Mahjong",
            "environment": "live",
            "configVersion": "v1",
            "ttlSeconds": 60,
            "serverTime": "2026-05-28T10:00:00.000Z",
            "experiments": [[
                "key": "level_generator",
                "experimentId": "exp-level-generator-001",
                "variant": "variant-a",
                "config": ["difficulty": "hard"],
                "script": [
                    "versionId": "sv_level_generator",
                    "name": "level-generator.js",
                    "url": "/v1/scripts/sv_level_generator",
                    "hash": GameAlgoSHA256.hash(script),
                ],
            ]],
            "configFiles": [],
        ])
        await httpClient.enqueue(
            GameAlgoHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data(script.utf8)
            )
        )
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            cacheStorage: nil,
            userId: "u1"
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        let result = sdk.executor("level_generator").execute(.object(["turn": .number(7)]))

        XCTAssertEqual(result?.payload, .object(["difficulty": .string("hard"), "turn": .number(7)]))
        XCTAssertEqual(result?.diagnostics, .object(["variant": .string("variant-a"), "userId": .string("u1")]))
    }

    func testConstructorRestoresPersistedSnapshotThenStillRefreshes() async throws {
        let cache = MemoryCacheStorage()
        let firstHTTPClient = MockHTTPClient()
        try await firstHTTPClient.enqueueJSON([
            "contextId": "ctx-1",
            "gameId": "Mahjong",
            "environment": "live",
            "configVersion": "cached-v1",
            "ttlSeconds": 60,
            "serverTime": "2026-05-28T10:00:00.000Z",
            "experiments": [[
                "key": "level_generator",
                "experimentId": "exp-level-generator-001",
                "variant": "variant-a",
                "config": ["difficulty": "cached-hard"],
            ]],
            "configFiles": [[
                "name": "gameplay.json",
                "url": "https://gamealgo.test/v1/config-files/gameplay.json",
                "hash": "sha256:test",
            ]],
        ])
        await firstHTTPClient.enqueue(
            GameAlgoHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json; charset=utf-8"],
                body: Data("{\"difficulty\":\"cached\"}\n".utf8)
            )
        )
        let first = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: firstHTTPClient,
            cacheStorage: cache,
            cacheKey: "test-cache",
            userId: "u1"
        )
        let firstReady = await first.waitForReady()
        XCTAssertTrue(firstReady)

        let secondHTTPClient = MockHTTPClient()
        await secondHTTPClient.enqueueError(GameAlgoError.networkFailed("offline"))
        let second = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: secondHTTPClient,
            cacheStorage: cache,
            cacheKey: "test-cache",
            userId: "u1"
        )
        let secondReady = await second.waitForReady()
        XCTAssertTrue(secondReady)

        XCTAssertEqual(sdkVariant(second, key: "level_generator"), "variant-a")
        XCTAssertEqual(second.config.string("difficulty", fileName: "gameplay.json"), "cached")
        let requests = await secondHTTPClient.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testUploadEventsFillsProtocolDefaults() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test/algo_sdk/")!,
            sdkVersion: "1.2.3",
            appVersion: "4.5.6",
            httpClient: httpClient,
            _autoStart: false,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let result = try await sdk.uploadEvents([
            GameAlgoEvent(
                eventId: "event-1",
                contextId: "ctx-1",
                userId: "u1",
                sessionId: "s1",
                eventType: "session_start"
            ),
        ])
        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]

        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(requests[0].method, .post)
        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/algo_sdk/v1/events/batch")
        XCTAssertEqual(requests[0].headers["X-GameAlgo-Key"], gameKey)
        XCTAssertEqual(events?.first?["contextId"] as? String, "ctx-1")
        XCTAssertEqual(events?.first?["timestamp"] as? String, "2026-05-28T10:00:00.000Z")
        assertLocalTimestamp(events?.first?["createdLocalAt"], sameInstantAs: "2026-05-28T10:00:00.000Z")
        XCTAssertEqual(events?.first?["isDebug"] as? Bool, false)
        XCTAssertEqual((events?.first?["payload"] as? [String: Any])?.count, 0)
    }

    func testSetAttributionPostsOnceUntilItChanges() async throws {
        let suiteName = "GameAlgoSDKTests.attribution.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectedHash = GameAlgoSHA256.hash("{\"attributedAt\":\"2026-05-28T09:59:00.000Z\",\"attribution\":{\"campaign\":\"launch\",\"network\":\"facebook\"},\"platform\":\"ios\",\"provider\":\"adjust\",\"status\":\"attributed\"}")
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1, "attributionHash": expectedHash])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test/algo_sdk")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            _autoStart: false,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let first = try await sdk.setAttribution(GameAlgoUserAttribution(
            provider: "adjust",
            attribution: [
                "network": .string("facebook"),
                "campaign": .string("launch"),
            ],
            userId: "u1",
            attributedAt: "2026-05-28T09:59:00.000Z"
        ))
        let second = try await sdk.setAttribution(GameAlgoUserAttribution(
            provider: "adjust",
            attribution: [
                "campaign": .string("launch"),
                "network": .string("facebook"),
            ],
            userId: "u1",
            attributedAt: "2026-05-28T09:59:00.000Z"
        ))

        let requests = await httpClient.requests
        let body = try requestBody(requests[0])

        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(second.accepted, 0)
        XCTAssertEqual(first.attributionHash, second.attributionHash)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/algo_sdk/v1/attribution")
        XCTAssertEqual(body["userId"] as? String, "u1")
        XCTAssertEqual(body["userCreatedAt"] as? String, "2026-05-28T10:00:00.000Z")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["provider"] as? String, "adjust")
        XCTAssertEqual((body["attribution"] as? [String: Any])?["network"] as? String, "facebook")
    }

    func testSetAttributionNormalizesAdjustNoConsentAsUnknown() async throws {
        let suiteName = "GameAlgoSDKTests.attribution.noConsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1, "attributionHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            _autoStart: false
        )

        _ = try await sdk.setAttribution(GameAlgoUserAttribution(
            provider: "adjust",
            status: "attributed",
            attribution: [
                "tracker_token": .string("unattr"),
                "network": .string("No User Consent"),
                "tracker_name": .string("No User Consent"),
            ]
        ))

        let requests = await httpClient.requests
        let body = try requestBody(requests[0])
        XCTAssertEqual(body["status"] as? String, "unknown")
    }

    func testContextIdentifierSettersUploadIndependentlyAndDeduplicate() async throws {
        let suiteName = "GameAlgoSDKTests.contextIdentifiers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let adjustHash = GameAlgoSHA256.hash("{\"identifierType\":\"adjust_adid\",\"identifierValue\":\"adjust-1\"}")
        let firebaseHash = GameAlgoSHA256.hash("{\"identifierType\":\"firebase_app_instance_id\",\"identifierValue\":\"firebase-1\"}")
        let gaidHash = GameAlgoSHA256.hash("{\"identifierType\":\"gaid\",\"identifierValue\":null}")
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1, "identifierHash": adjustHash])
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1, "identifierHash": firebaseHash])
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1, "identifierHash": gaidHash])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test/algo_sdk")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            _autoStart: false,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        _ = try await sdk.fetchConfig(userId: "u1")
        let first = try await sdk.setAdjustAdid("adjust-1")
        let duplicate = try await sdk.setAdjustAdid("adjust-1")
        _ = try await sdk.setFirebaseAppInstanceId("firebase-1")
        _ = try await sdk.setGoogleAdvertisingId("00000000-0000-0000-0000-000000000000")

        let requests = await httpClient.requests
        let identifierRequests = Array(requests.dropFirst())
        let bodies = try identifierRequests.map(requestBody)
        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(duplicate.accepted, 0)
        XCTAssertEqual(identifierRequests.count, 3)
        XCTAssertTrue(identifierRequests.allSatisfy { $0.url.absoluteString == "https://gamealgo.test/algo_sdk/v1/context-identifiers" })
        XCTAssertEqual(bodies.compactMap { $0["identifierType"] as? String }, ["adjust_adid", "firebase_app_instance_id", "gaid"])
        XCTAssertEqual(bodies[0]["contextId"] as? String, "ctx-1")
        XCTAssertEqual(bodies[0]["userId"] as? String, "u1")
        XCTAssertTrue(bodies[2]["identifierValue"] is NSNull)
        XCTAssertEqual(bodies[2]["identifierHash"] as? String, gaidHash)
    }

    func testTrackerQueuesAndFlushesEventsAfterReadyIdentifiesUser() async throws {
        let suiteName = "GameAlgoSDKTests.tracker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(
            version: "v1",
            experiments: [[
                "key": "level_generator",
                "experimentId": "exp-level-generator-001",
                "variant": "variant-a",
                "config": [String: Any](),
            ]]
        ))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            sdkVersion: "1.2.3",
            appVersion: "4.5.6",
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            isDebug: true,
            eventFlushInterval: 0,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        let didTrackLevelEnd = await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3)]))
        XCTAssertTrue(didTrackLevelEnd)
        await sdk.tracker.flush()

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].method, .post)
        XCTAssertEqual(requests[1].url.absoluteString, "https://gamealgo.test/v1/events/batch")
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?[0]["contextId"] as? String, "ctx-1")
        XCTAssertEqual(events?[0]["userId"] as? String, "u1")
        XCTAssertEqual(events?[0]["eventType"] as? String, "level_end")
        XCTAssertEqual(events?[0]["isDebug"] as? Bool, true)
        let levelPayload = events?[0]["payload"] as? [String: Any]
        XCTAssertEqual(levelPayload?["level"] as? Double, 3)
    }

    func testTrackerPersistsAfterThreeFailuresAndRestoresAfterRestart() async throws {
        let storage = MemoryCacheStorage()
        let failingUploader = QueueEventUploader(failures: 3)
        let firstTracker = GameAlgoEventTracker(
            uploader: failingUploader,
            flushInterval: 0,
            storage: storage,
            persistenceKey: "test-event-queue"
        )
        await firstTracker.identify(
            userId: "anonymous-user",
            sessionId: "session-1",
            userCreatedAt: "2026-05-28T10:00:00.000Z",
            accountUserId: "account-user"
        )
        await firstTracker.setContextId("ctx-1")
        let didTrack = await firstTracker.trackLevelEnd(payload: .object(["level": .number(7)]))
        XCTAssertTrue(didTrack)

        await firstTracker.flush()
        await firstTracker.flush()
        await firstTracker.flush()

        let jsonl = try XCTUnwrap(storage.value(cacheKey: "test-event-queue"))
        let persisted = try JSONDecoder().decode(GameAlgoEvent.self, from: Data(jsonl.utf8))
        XCTAssertEqual(persisted.contextId, "ctx-1")
        XCTAssertEqual(persisted.accountUserId, "account-user")

        let recoveredUploader = QueueEventUploader(failures: 0)
        let restoredTracker = GameAlgoEventTracker(
            uploader: recoveredUploader,
            flushInterval: 0,
            storage: storage,
            persistenceKey: "test-event-queue"
        )
        await restoredTracker.flush()
        let uploaded = await recoveredUploader.uploadedEvents()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.eventType, "level_end")
        XCTAssertNil(storage.value(cacheKey: "test-event-queue"))
    }

    func testCustomEventsPreservePayload() async throws {
        let suiteName = "GameAlgoSDKTests.customEventExperiments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(
            version: "v1",
            experiments: [[
                "key": "level_generator",
                "experimentId": "exp-level-generator-001",
                "variant": "variant-a",
                "config": [String: Any](),
            ]]
        ))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            eventFlushInterval: 0
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        let didTrackCustomEvent = await sdk.tracker.trackEvent(
            "custom_action",
            payload: .object(["button": .string("start"), "value": .number(2)])
        )
        XCTAssertTrue(didTrackCustomEvent)
        await sdk.tracker.flush()

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        let payload = events?[0]["payload"] as? [String: Any]

        XCTAssertEqual(events?[0]["eventType"] as? String, "_custom_action")
        XCTAssertEqual(payload?["button"] as? String, "start")
        XCTAssertEqual(payload?["value"] as? Double, 2)
    }

    func testTrackAdUploadsStandardAdViewPayload() async throws {
        let suiteName = "GameAlgoSDKTests.trackAd.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            eventFlushInterval: 0
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        let didTrackAd = await sdk.tracker.trackAd(
            placement: "rewarded_level_end",
            adType: "reward",
            revenue: 0.018,
            currency: "USD",
            network: "admob",
            payload: .object(["source": .string("reward")])
        )
        XCTAssertTrue(didTrackAd)
        await sdk.tracker.flush()

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        let payload = events?[0]["payload"] as? [String: Any]

        XCTAssertEqual(events?[0]["eventType"] as? String, "ad_view")
        XCTAssertEqual(payload?["source"] as? String, "reward")
        XCTAssertEqual(payload?["placement"] as? String, "rewarded_level_end")
        XCTAssertEqual(payload?["adType"] as? String, "reward")
        XCTAssertEqual(payload?["revenue"] as? Double, 0.018)
        XCTAssertEqual(payload?["currency"] as? String, "USD")
        XCTAssertEqual(payload?["network"] as? String, "admob")
    }

    func testTrackSessionEndFlushesImmediately() async throws {
        let suiteName = "GameAlgoSDKTests.sessionEnd.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 1])
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_779_962_400))
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            userId: "u1",
            eventFlushInterval: 0,
            now: { clock.now() }
        )

        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)
        clock.advance(2.5)
        let didTrackSessionEnd = await sdk.tracker.trackSessionEnd(payload: .object(["reason": .string("background")]))
        XCTAssertTrue(didTrackSessionEnd)

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        let sessionEnd = events?.last
        let sessionEndPayload = sessionEnd?["payload"] as? [String: Any]

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url.absoluteString, "https://gamealgo.test/v1/events/batch")
        XCTAssertEqual(events?.map { $0["eventType"] as? String }, ["session_end"])
        XCTAssertEqual(sessionEnd?["userId"] as? String, "u1")
        XCTAssertEqual(sessionEndPayload?["reason"] as? String, "background")
        XCTAssertEqual(sessionEndPayload?["sessionDurationMs"] as? Double, 2500)
    }

    func testThrowsStructuredAPIErrors() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(
            ["error": "invalid_game_key", "message": "Unknown key"],
            statusCode: 403
        )
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            _autoStart: false
        )

        do {
            _ = try await sdk.fetchConfig(userId: "u1")
            XCTFail("Expected API error")
        } catch let error as GameAlgoError {
            XCTAssertEqual(error, .apiError(statusCode: 403, code: "invalid_game_key", message: "Unknown key"))
        }
    }

    func testDDAControllerPersistsBehaviorWindowAndReturnsDecision() async throws {
        let storage = MemoryDDAStorage()
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1", experiments: [[
            "key": "level_dda",
            "experimentId": "exp-dda",
            "variant": "assist",
            "config": ["adjustment": "decrease"],
        ]]))
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            ddaStorage: storage
        )
        let ready = await sdk.waitForReady()
        XCTAssertTrue(ready)

        let dda = sdk.dda("level_dda", recentWindowSize: 2)
        try dda.recordBehavior("level_failed")
        try dda.recordBehavior("item_used", amount: 2)
        dda.completeStep("level-1")
        dda.completeStep("level-2")
        try dda.recordBehavior("mistake")

        let behavior = try XCTUnwrap(dda.snapshot(context: .object(["level": .number(3)]))["behavior"])
        XCTAssertEqual(behavior["completedSteps"]?.intValue, 2)
        XCTAssertEqual(behavior["recent"]?["level_failed"]?.doubleValue, 1)
        XCTAssertEqual(behavior["current"]?["mistake"]?.doubleValue, 1)
        XCTAssertEqual(dda.decide().adjustment, .decrease)

        let restoredSDK = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: MockHTTPClient(),
            ddaStorage: storage,
            _autoStart: false
        )
        let restored = restoredSDK.dda("level_dda", recentWindowSize: 2)
        XCTAssertEqual(restored.snapshot()["behavior"]?["lifetime"]?["item_used"]?.doubleValue, 2)
    }

    func testRejectsUnsafeConfigFileNames() async throws {
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: MockHTTPClient(),
            _autoStart: false
        )

        do {
            _ = try await sdk.fetchConfigFile("../secret.json")
            XCTFail("Expected invalid file name")
        } catch let error as GameAlgoError {
            XCTAssertEqual(error, .invalidConfigFileName("../secret.json"))
        }
    }

    private func configResponse(version: String, ttlSeconds: Int = 60, experiments: [[String: Any]] = []) -> [String: Any] {
        [
            "contextId": "ctx-1",
            "gameId": "Mahjong",
            "environment": "live",
            "configVersion": version,
            "ttlSeconds": ttlSeconds,
            "serverTime": "2026-05-28T10:00:00.000Z",
            "experiments": experiments,
            "configFiles": [],
        ]
    }

    private func sdkVariant(_ sdk: GameAlgoSDK, key: String) -> String {
        sdk.executor(key).variant(default: "control")
    }

    private func requestBody(_ request: GameAlgoHTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private func assertLocalTimestamp(_ value: Any?, sameInstantAs utcTimestamp: String? = nil) {
        guard let value = value as? String else {
            XCTFail("Expected a local timestamp string")
            return
        }
        XCTAssertNotNil(value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}$"#,
            options: .regularExpression
        ))
        guard let utcTimestamp else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(formatter.date(from: value), formatter.date(from: utcTimestamp))
    }
}

private actor MockHTTPClient: GameAlgoHTTPClient {
    private var queue: [Result<GameAlgoHTTPResponse, Error>] = []
    private(set) var requests: [GameAlgoHTTPRequest] = []

    func enqueue(_ response: GameAlgoHTTPResponse) {
        queue.append(.success(response))
    }

    func enqueueError(_ error: Error) {
        queue.append(.failure(error))
    }

    func enqueueJSON(_ payload: [String: Any], statusCode: Int = 200) throws {
        let body = try JSONSerialization.data(withJSONObject: payload)
        enqueue(
            GameAlgoHTTPResponse(
                statusCode: statusCode,
                headers: ["content-type": "application/json; charset=utf-8"],
                body: body
            )
        )
    }

    func send(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse {
        requests.append(request)
        guard !queue.isEmpty else {
            throw GameAlgoError.networkFailed("No mock response enqueued")
        }

        let next = queue.removeFirst()
        switch next {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        }
    }
}

private actor FixtureHTTPClient: GameAlgoHTTPClient {
    private let configData: Data
    private let scriptData: Data

    init(configData: Data, scriptData: Data) {
        self.configData = configData
        self.scriptData = scriptData
    }

    func send(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse {
        if request.url.path.hasSuffix("/v1/config") {
            return GameAlgoHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: configData
            )
        }
        if request.url.path.contains("/v1/scripts/") {
            return GameAlgoHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/javascript"],
                body: scriptData
            )
        }
        if request.url.path.contains("/v1/config-files/") {
            return GameAlgoHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            )
        }
        throw GameAlgoError.networkFailed("unexpected fixture URL: \(request.url.path)")
    }
}

private actor QueueEventUploader: GameAlgoEventBatchUploading {
    private var remainingFailures: Int
    private var uploaded: [GameAlgoEvent] = []

    init(failures: Int) {
        remainingFailures = failures
    }

    func uploadEvents(_ events: [GameAlgoEvent]) async throws -> GameAlgoEventBatchResponse {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw GameAlgoError.networkFailed("simulated offline transport")
        }
        uploaded.append(contentsOf: events)
        return GameAlgoEventBatchResponse(ok: true, accepted: events.count)
    }

    func uploadedEvents() -> [GameAlgoEvent] {
        uploaded
    }
}

private final class TestClock: @unchecked Sendable {
    private var date: Date
    private let lock = NSLock()

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class MemoryCacheStorage: GameAlgoCacheStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func loadSnapshot(cacheKey: String) throws -> GameAlgoSnapshot? {
        lock.lock()
        let data = values[cacheKey]
        lock.unlock()
        guard let data else { return nil }
        return try decoder.decode(GameAlgoSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: GameAlgoSnapshot, cacheKey: String) throws {
        let data = try encoder.encode(snapshot)
        lock.lock()
        values[cacheKey] = data
        lock.unlock()
    }

    func removeSnapshot(cacheKey: String) throws {
        lock.lock()
        values.removeValue(forKey: cacheKey)
        lock.unlock()
    }

    func loadValue(cacheKey: String) throws -> String? {
        lock.lock()
        let data = values[cacheKey]
        lock.unlock()
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveValue(_ value: String, cacheKey: String) throws {
        lock.lock()
        values[cacheKey] = Data(value.utf8)
        lock.unlock()
    }

    func removeValue(cacheKey: String) throws {
        lock.lock()
        values.removeValue(forKey: cacheKey)
        lock.unlock()
    }

    func value(cacheKey: String) -> String? {
        try? loadValue(cacheKey: cacheKey)
    }
}

private final class MemoryDDAStorage: GameAlgoDDAStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func load(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func save(_ data: Data, key: String) throws {
        lock.lock()
        values[key] = data
        lock.unlock()
    }

    func remove(key: String) throws {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }
}
