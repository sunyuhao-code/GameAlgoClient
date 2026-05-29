import XCTest
@testable import GameAlgoSDK

final class GameAlgoSDKTests: XCTestCase {
    private let gameKey = "ga_live_test_key_0123456789abcdef"

    func testStartUsesPersistedAnonymousUserIdByDefault() async throws {
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

        let firstTask = first.start()
        try await firstTask.value
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

        let secondTask = second.start()
        try await secondTask.value
        let secondRequests = await secondHTTPClient.requests

        XCTAssertFalse(persistedUserId.isEmpty)
        XCTAssertEqual(second.userId, persistedUserId)
        XCTAssertEqual(URLComponents(url: firstRequests[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "userId" }?.value, persistedUserId)
        XCTAssertEqual(URLComponents(url: secondRequests[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "userId" }?.value, persistedUserId)
    }

    func testStartBackfillsCreatedAtForPersistedLegacyUserId() async throws {
        let suiteName = "GameAlgoSDKTests.legacyIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("legacy-user", forKey: GameAlgoUserIdentityStore.legacyUserIdKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 2])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            eventFlushInterval: 0,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let task = sdk.start()
        try await task.value
        XCTAssertEqual(sdk.userId, "legacy-user")
        XCTAssertEqual(defaults.string(forKey: GameAlgoUserIdentityStore.legacyUserCreatedAtKey), "2026-05-28T10:00:00.000Z")

        let didTrackSessionStart = await sdk.tracker.trackSessionStart()
        XCTAssertTrue(didTrackSessionStart)
        _ = await sdk.tracker.flush()

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        let sessionStart = events?.first { $0["eventType"] as? String == "session_start" }
        let sessionPayload = sessionStart?["payload"] as? [String: Any]
        XCTAssertEqual(sessionStart?["userId"] as? String, "legacy-user")
        XCTAssertEqual(sessionPayload?["userCreatedAt"] as? String, "2026-05-28T10:00:00.000Z")
    }

    func testFetchConfigSendsProtocolHeadersAndCachesByTTL() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON([
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
            baseURL: URL(string: "https://gamealgo.test")!,
            sdkVersion: "1.0.0",
            httpClient: httpClient,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let first = try await sdk.fetchConfig(userId: "u1")
        let second = try await sdk.fetchConfig(userId: "u1")
        let requests = await httpClient.requests

        XCTAssertEqual(first.gameId, "Mahjong")
        XCTAssertEqual(second.configVersion, "v1")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headers["X-GameAlgo-Key"], gameKey)
        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/v1/config?userId=u1&platform=ios&sdkVersion=1.0.0")
    }

    func testFetchConfigCanForceRefresh() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(configResponse(version: "v2"))
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
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
            httpClient: httpClient
        )

        let file = try await sdk.fetchConfigFile("gameplay.json")
        let requests = await httpClient.requests

        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/v1/config-files/gameplay.json")
        XCTAssertEqual(file.name, "gameplay.json")
        XCTAssertEqual(file.etag, "\"sha256:test\"")
        XCTAssertEqual(file.content, "{\"difficulty\":\"normal\"}\n")
    }

    func testStartPreloadsConfigFilesAndExposesLocalExecutorAndConfigReaders() async throws {
        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON([
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
            httpClient: httpClient
        )
        let executor = sdk.executor("level_generator")

        XCTAssertFalse(executor.isReady)
        XCTAssertEqual(executor.variant(default: "control"), "control")

        let task = sdk.start(userId: "u1")
        try await task.value

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
                    "name": "level-generator.js",
                    "url": "https://gamealgo.test/v1/config-files/level-generator.js",
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
            cacheStorage: nil
        )

        let task = sdk.start(userId: "u1")
        try await task.value
        let result = sdk.executor("level_generator").execute(.object(["turn": .number(7)]))

        XCTAssertEqual(result?.payload, .object(["difficulty": .string("hard"), "turn": .number(7)]))
        XCTAssertEqual(result?.diagnostics, .object(["variant": .string("variant-a"), "userId": .string("u1")]))
    }

    func testStartRestoresPersistedSnapshotThenStillRefreshes() async throws {
        let cache = MemoryCacheStorage()
        let firstHTTPClient = MockHTTPClient()
        try await firstHTTPClient.enqueueJSON([
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
            cacheKey: "test-cache"
        )
        let firstTask = first.start(userId: "u1")
        try await firstTask.value

        let secondHTTPClient = MockHTTPClient()
        await secondHTTPClient.enqueueError(GameAlgoError.networkFailed("offline"))
        let second = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: secondHTTPClient,
            cacheStorage: cache,
            cacheKey: "test-cache"
        )
        let secondTask = second.start(userId: "u1")
        try await secondTask.value

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
            baseURL: URL(string: "https://gamealgo.test")!,
            sdkVersion: "1.2.3",
            appVersion: "4.5.6",
            httpClient: httpClient,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let result = try await sdk.uploadEvents([
            GameAlgoEvent(
                eventId: "event-1",
                userId: "u1",
                sessionId: "s1",
                eventType: "session_start",
                payload: .object([:])
            ),
        ])
        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]

        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(requests[0].method, .post)
        XCTAssertEqual(requests[0].url.absoluteString, "https://gamealgo.test/v1/events/batch")
        XCTAssertEqual(requests[0].headers["X-GameAlgo-Key"], gameKey)
        XCTAssertEqual(events?.first?["platform"] as? String, "ios")
        XCTAssertEqual(events?.first?["sdkVersion"] as? String, "1.2.3")
        XCTAssertEqual(events?.first?["appVersion"] as? String, "4.5.6")
        XCTAssertEqual(events?.first?["timezone"] as? String, TimeZone.current.identifier)
        XCTAssertEqual(events?.first?["timestamp"] as? String, "2026-05-28T10:00:00.000Z")
        XCTAssertEqual(events?.first?["isDebug"] as? Bool, false)
    }

    func testTrackerQueuesAndFlushesEventsAfterStartIdentifiesUser() async throws {
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
        try await httpClient.enqueueJSON(["ok": true, "accepted": 3])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            sdkVersion: "1.2.3",
            appVersion: "4.5.6",
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            isDebug: true,
            eventFlushInterval: 0,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let task = sdk.start(userId: "u1")
        try await task.value
        let didTrackSessionStart = await sdk.tracker.trackSessionStart()
        let didTrackLevelEnd = await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3)]))
        XCTAssertTrue(didTrackSessionStart)
        XCTAssertTrue(didTrackLevelEnd)
        await sdk.tracker.flush()

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].method, .post)
        XCTAssertEqual(requests[1].url.absoluteString, "https://gamealgo.test/v1/events/batch")
        XCTAssertEqual(events?.count, 3)
        XCTAssertEqual(events?[0]["eventType"] as? String, "config_loaded")
        XCTAssertEqual(events?[1]["userId"] as? String, "u1")
        XCTAssertEqual(events?[1]["sessionId"] as? String, events?.last?["sessionId"] as? String)
        XCTAssertEqual(events?[1]["eventType"] as? String, "session_start")
        let sessionPayload = events?[1]["payload"] as? [String: Any]
        XCTAssertEqual(sessionPayload?["userCreatedAt"] as? String, "2026-05-28T10:00:00.000Z")
        XCTAssertEqual(events?.last?["eventType"] as? String, "level_end")
        XCTAssertEqual(events?.last?["platform"] as? String, "ios")
        XCTAssertEqual(events?.last?["sdkVersion"] as? String, "1.2.3")
        XCTAssertEqual(events?.last?["appVersion"] as? String, "4.5.6")
        XCTAssertEqual(events?.last?["timezone"] as? String, TimeZone.current.identifier)
        XCTAssertEqual(events?.last?["isDebug"] as? Bool, true)
        let levelPayload = events?.last?["payload"] as? [String: Any]
        let experiments = levelPayload?["experiments"] as? [String: Any]
        XCTAssertEqual(experiments?["level_generator"] as? String, "variant-a")
    }

    func testTrackSessionEndFlushesImmediately() async throws {
        let suiteName = "GameAlgoSDKTests.sessionEnd.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let httpClient = MockHTTPClient()
        try await httpClient.enqueueJSON(configResponse(version: "v1"))
        try await httpClient.enqueueJSON(["ok": true, "accepted": 3])
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: httpClient,
            userIdentityStore: GameAlgoUserIdentityStore(userDefaults: defaults),
            eventFlushInterval: 0,
            now: { Date(timeIntervalSince1970: 1_779_962_400) }
        )

        let task = sdk.start(userId: "u1")
        try await task.value
        let didTrackSessionStart = await sdk.tracker.trackSessionStart()
        let didTrackSessionEnd = await sdk.tracker.trackSessionEnd(payload: .object(["reason": .string("background")]))
        XCTAssertTrue(didTrackSessionStart)
        XCTAssertTrue(didTrackSessionEnd)

        let requests = await httpClient.requests
        let body = try JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        let sessionEnd = events?.last
        let sessionEndPayload = sessionEnd?["payload"] as? [String: Any]

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url.absoluteString, "https://gamealgo.test/v1/events/batch")
        XCTAssertEqual(events?.map { $0["eventType"] as? String }, ["config_loaded", "session_start", "session_end"])
        XCTAssertEqual(sessionEnd?["userId"] as? String, "u1")
        XCTAssertEqual(sessionEndPayload?["reason"] as? String, "background")
        XCTAssertEqual(sessionEndPayload?["sessionDurationMs"] as? Double, 0)
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
            httpClient: httpClient
        )

        do {
            _ = try await sdk.fetchConfig(userId: "u1")
            XCTFail("Expected API error")
        } catch let error as GameAlgoError {
            XCTAssertEqual(error, .apiError(statusCode: 403, code: "invalid_game_key", message: "Unknown key"))
        }
    }

    func testRejectsUnsafeConfigFileNames() async throws {
        let sdk = GameAlgoSDK(
            gameKey: gameKey,
            baseURL: URL(string: "https://gamealgo.test")!,
            httpClient: MockHTTPClient()
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
}
