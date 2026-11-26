import XCTest
import Foundation
import GameAlgoSDK
@testable import GamePropelUnity

final class BridgeTests: XCTestCase {
    func testNativeBridgeUsesRealIdentityContextAndNativeQueue() async throws {
        let suite = "gamepropel-unity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = MockHTTP()
        let bridge = UnityBridge()
        let options = try JSONDecoder().decode(UnityOptions.self, from: Data("""
        {"gameKey":"ga_live_unity_offline_test","baseUrl":"https://offline-test.invalid/prefix","appVersion":"test","experimentIntegrationVersion":1,"isDebug":true,"device":{"runtime":"incorrect","unityVersion":"test"}}
        """.utf8))
        _ = try bridge.initialize(options, httpClient: http, cacheStorage: nil, ddaStorage: nil,
                                  identityStore: GameAlgoUserIdentityStore(userDefaults: defaults))
        let ready = try await bridge.perform(UnityRequest(method: "ready", args: ["timeoutMs": .number(1000)]))
        XCTAssertEqual(ready, .bool(true))
        let identity = try bridge.read(UnityRequest(method: "identity", args: [:]))
        XCTAssertFalse(identity["userId"]!.stringValue!.isEmpty)
        XCTAssertEqual(try bridge.read(UnityRequest(method: "strategyConfig", args: ["strategy": .string("difficulty"), "path": .string("value"), "fallback": .number(1)])), .number(3))
        let payload: JSONValue = .object(["level_id": .string("第一关"), "level_attempt_id": .string("attempt-1")])
        let start = try await bridge.perform(UnityRequest(method: "levelStart", args: ["payload": payload]))
        let end = try await bridge.perform(UnityRequest(method: "levelEnd", args: ["payload": payload]))
        XCTAssertEqual(start, .bool(true))
        XCTAssertEqual(end, .bool(true))
        _ = try await bridge.perform(UnityRequest(method: "flush", args: [:]))
        let requests = http.snapshot()
        let config = try XCTUnwrap(requests.first { $0.url.path.hasSuffix("/v1/config") })
        let configBody = try JSONSerialization.jsonObject(with: config.body!) as! [String: Any]
        XCTAssertEqual((configBody["device"] as? [String: Any])?["runtime"] as? String, "unity")
        XCTAssertEqual(configBody["platform"] as? String, "ios")
        let batch = try XCTUnwrap(requests.first { $0.url.path.hasSuffix("/v1/events/batch") })
        let events = (try JSONSerialization.jsonObject(with: batch.body!) as! [String: Any])["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?["contextId"] as? String, "ctx-unity")
        XCTAssertEqual((events.first?["payload"] as? [String: Any])?["level_id"] as? String, "第一关")
        XCTAssertGreaterThanOrEqual(bridge.foregroundTime(), 0)
        let session = try XCTUnwrap(identity["sessionId"]?.stringValue)
        _ = try await bridge.perform(UnityRequest(method: "newSession", args: ["sessionId": .string("  " + session + "  ")]))
        XCTAssertEqual(http.snapshot().filter { $0.url.path.hasSuffix("/v1/config") }.count, 1, "Same session is a no-op")
        _ = try await bridge.perform(UnityRequest(method: "refresh", args: [:]))
        XCTAssertEqual(http.snapshot().filter { $0.url.path.hasSuffix("/v1/config") }.count, 1, "Default refresh respects native TTL")
        _ = try await bridge.perform(UnityRequest(method: "refresh", args: ["forceRefresh": .bool(true)]))
        XCTAssertEqual(http.snapshot().filter { $0.url.path.hasSuffix("/v1/config") }.count, 2)
        _ = try await bridge.perform(UnityRequest(method: "newSession", args: ["sessionId": .string("   ")]))
        let nextIdentity = try bridge.read(UnityRequest(method: "identity", args: [:]))
        XCTAssertNotEqual(nextIdentity["sessionId"]?.stringValue, session, "Blank session asks native SDK to generate an ID")
    }

    func testInvalidRequestsReturnOwnedUtf8ErrorBuffers() throws {
        let result = "{}".withCString { GPUnity_Initialize($0) }
        let pointer = try XCTUnwrap(result)
        defer { GPUnity_Free(pointer) }
        let body = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as! [String: Any]
        XCTAssertEqual(body["ok"] as? Bool, false)
    }

    func testInitializeRejectsMissingOrNonPositiveExperimentIntegrationVersion() throws {
        let cases = [
            """
            {"gameKey":"ga_live_unity_offline_test","baseUrl":"https://offline-test.invalid/prefix"}
            """,
            """
            {"gameKey":"ga_live_unity_offline_test","baseUrl":"https://offline-test.invalid/prefix","experimentIntegrationVersion":0}
            """,
            """
            {"gameKey":"ga_live_unity_offline_test","baseUrl":"https://offline-test.invalid/prefix","experimentIntegrationVersion":-2}
            """,
        ]
        for json in cases {
            let options = try JSONDecoder().decode(UnityOptions.self, from: Data(json.utf8))
            XCTAssertThrowsError(try UnityBridge().initialize(options, httpClient: MockHTTP(), cacheStorage: nil, ddaStorage: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("experimentIntegrationVersion must be a positive integer"))
            }
        }
    }

    func testSynchronousReadsRejectUseBeforeInitialization() {
        XCTAssertThrowsError(try UnityBridge().read(UnityRequest(method: "identity", args: [:])))
    }
}

private final class MockHTTP: GameAlgoHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [GameAlgoHTTPRequest] = []
    func snapshot() -> [GameAlgoHTTPRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    private func record(_ request: GameAlgoHTTPRequest) { lock.lock(); requests.append(request); lock.unlock() }
    func send(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse {
        record(request)
        let body: String
        if request.url.path.hasSuffix("/v1/config") {
            body = """
            {"contextId":"ctx-unity","gameId":"offline-test","environment":"live","configVersion":"1","ttlSeconds":300,"serverTime":"2026-11-18T00:00:00Z","experiments":[{"key":"difficulty","experimentId":"exp-unity","variant":"control","config":{"value":3}}],"configFiles":[]}
            """
        } else {
            let value = try JSONSerialization.jsonObject(with: request.body ?? Data("{}".utf8)) as! [String: Any]
            let count = (value["events"] as? [Any])?.count ?? 1
            body = "{\"ok\":true,\"accepted\":\(count),\"stored\":\(count),\"rejected\":[]}"
        }
        return GameAlgoHTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}
