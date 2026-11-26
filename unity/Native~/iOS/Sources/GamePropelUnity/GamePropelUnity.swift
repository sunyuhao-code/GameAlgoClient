import Foundation
import GameAlgoSDK

public typealias GamePropelUnityCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

struct UnityRequest: Codable, Sendable {
    var id: String?
    var method: String
    var args: [String: JSONValue]
}

struct UnityOptions: Decodable {
    var gameKey: String
    var baseUrl: String
    var appVersion: String?
    var accountUserId: String?
    var accountUserCreatedAt: String?
    var experimentIntegrationVersion: Int?
    var isDebug: Bool?
    var isOldUser: Bool?
    var enableLogging: Bool?
    var device: [String: JSONValue]?
}

enum UnityBridgeError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(value) = self { return value }; return nil }
}

final class UnityBridge: @unchecked Sendable {
    static let shared = UnityBridge()
    private let lock = NSLock()
    private var sdk: GameAlgoSDK?
    private var session = ""
    private var device: [String: JSONValue] = [:]
    private var debug = false

    func initialize(_ options: UnityOptions, httpClient: any GameAlgoHTTPClient = URLSessionGameAlgoHTTPClient(),
                    cacheStorage: (any GameAlgoCacheStorage)? = GameAlgoFileCacheStorage(),
                    ddaStorage: (any GameAlgoDDAStorage)? = GameAlgoUserDefaultsDDAStorage(),
                    identityStore: GameAlgoUserIdentityStore = GameAlgoUserIdentityStore()) throws -> JSONValue {
        guard options.gameKey.hasPrefix("ga_live_"),
              let url = URL(string: options.baseUrl), let scheme = url.scheme,
              ["https", "http"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              (options.experimentIntegrationVersion ?? 0) >= 0 else {
            throw UnityBridgeError.invalid("Valid client key, HTTP(S) URL and integration version are required")
        }
        lock.lock(); defer { lock.unlock() }
        guard sdk == nil else { throw UnityBridgeError.invalid("GamePropel is already initialized") }
        session = UUID().uuidString
        device = options.device ?? [:]
        device["runtime"] = .string("unity")
        debug = options.isDebug ?? false
        sdk = GameAlgoSDK(gameKey: options.gameKey, baseURL: url, appVersion: options.appVersion,
                          accountUserId: options.accountUserId, accountUserCreatedAt: options.accountUserCreatedAt,
                          experimentIntegrationVersion: options.experimentIntegrationVersion ?? 0,
                          platform: .ios, httpClient: httpClient, cacheStorage: cacheStorage, ddaStorage: ddaStorage,
                          userIdentityStore: identityStore, sessionId: session, device: device,
                          isDebug: debug, isOldUser: options.isOldUser,
                          logger: options.enableLogging == true ? GameAlgoLoggers.console : nil)
        return .object(["nativeSdkVersion": .string(GameAlgoSDK.defaultSDKVersion)])
    }

    private func state() throws -> (GameAlgoSDK, String, [String: JSONValue], Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let sdk else { throw UnityBridgeError.invalid("Initialize GamePropel first") }
        return (sdk, session, device, debug)
    }

    func foregroundTime() -> Int64 { (try? state().0.getForegroundTimeMs()) ?? 0 }

    func read(_ request: UnityRequest) throws -> JSONValue {
        let (sdk, session, _, _) = try state(), args = request.args
        switch request.method {
        case "identity":
            return .object(["userId": .string(sdk.userId), "sessionId": .string(session),
                            "isReady": .bool(sdk.snapshotValue().config != nil), "nativeSdkVersion": .string(GameAlgoSDK.defaultSDKVersion)])
        case "config":
            return sdk.config.value(args["path"]?.stringValue ?? "", default: args["fallback"] ?? .null, fileName: args["fileName"]?.stringValue)
        case "strategyConfig":
            return sdk.executor(try required(args, "strategy")).value(args["path"]?.stringValue ?? "", default: args["fallback"] ?? .null)
        case "assignment":
            return try sdk.executor(required(args, "strategy")).assignment().map(json) ?? .null
        default: throw UnityBridgeError.invalid("Unsupported read operation")
        }
    }

    func perform(_ request: UnityRequest) async throws -> JSONValue {
        let (sdk, _, device, debug) = try state(), args = request.args
        let payload = args["payload"] ?? .object([:])
        switch request.method {
        case "ready":
            let milliseconds = args["timeoutMs"]?.doubleValue ?? 5000
            guard milliseconds >= 0 else { throw UnityBridgeError.invalid("Invalid timeout") }
            return .bool(await sdk.waitForReady(timeout: milliseconds / 1000))
        case "refresh":
            _ = try await sdk.fetchConfig(device: device, isDebug: debug, forceRefresh: args["forceRefresh"]?.boolValue ?? false)
        case "newSession":
            let requested = args["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = requested.flatMap { $0.isEmpty ? nil : $0 }
            if let next, next == (await sdk.tracker.currentSessionId()) { return .null }
            if let next { await sdk.tracker.newSession(next) }
            else { await sdk.tracker.newSession() }
            updateSession(await sdk.tracker.currentSessionId())
            _ = try await sdk.fetchConfig(device: device, isDebug: debug, forceRefresh: true)
        case "flush": await sdk.tracker.flush()
        case "event": return .bool(try await sdk.tracker.trackEvent(required(args, "name"), payload: payload))
        case "levelStart": return .bool(await sdk.tracker.trackLevelStart(payload: payload))
        case "levelEnd": return .bool(await sdk.tracker.trackLevelEnd(payload: payload))
        case "sessionEnd": return .bool(await sdk.tracker.trackSessionEnd(payload: payload))
        case "milestone":
            return .bool(try await sdk.tracker.trackMilestone(milestoneType: required(args, "type"), milestonePoint: required(args, "point"), payload: payload))
        case "ad":
            guard let revenue = args["revenue"]?.doubleValue, revenue.isFinite else { throw UnityBridgeError.invalid("Invalid revenue") }
            return .bool(try await sdk.tracker.trackAdPlacement(adPlacementId: required(args, "adPlacementId"), revenue: revenue, network: args["network"]?.stringValue, payload: payload))
        case "purchase":
            guard let revenue = args["revenue"]?.doubleValue, revenue.isFinite else { throw UnityBridgeError.invalid("Invalid revenue") }
            return .bool(try await sdk.tracker.trackPurchase(productId: required(args, "productId"), revenue: revenue, currency: required(args, "currency"), payload: payload))
        case "attribution":
            return try await json(sdk.setAttribution(GameAlgoUserAttribution(provider: required(args, "provider"), attribution: args["attribution"]?.objectValue ?? [:])))
        case "adjustParams":
            var values: [String: JSONValue] = [:]
            sdk.configureAdjustServerCallbackParams { key, value in values[key] = .string(value) }
            return .object(values)
        case "identifier":
            let input = try required(args, "value"), at = args["observedAt"]?.stringValue
            switch try required(args, "type") {
            case "AdjustAdid": return try await json(sdk.setAdjustAdid(input, observedAt: at))
            case "FirebaseAppInstanceId": return try await json(sdk.setFirebaseAppInstanceId(input, observedAt: at))
            case "GoogleAdvertisingId": return try await json(sdk.setGoogleAdvertisingId(input, observedAt: at))
            case "Idfa": return try await json(sdk.setIdfa(input, observedAt: at))
            case "Idfv": return try await json(sdk.setIdfv(input, observedAt: at))
            default: throw UnityBridgeError.invalid("This identifier is unavailable on iOS")
            }
        case "caid":
            guard let array = args["values"]?.arrayValue else { throw UnityBridgeError.invalid("CAID values are required") }
            let values = try array.map { value -> GameAlgoCaid in
                guard let object = value.objectValue else { throw UnityBridgeError.invalid("Invalid CAID entry") }
                return try GameAlgoCaid(caid: required(object, "caid"), version: required(object, "version"))
            }
            return try await json(sdk.setCaid(values, observedAt: args["observedAt"]?.stringValue))
        case "execute":
            guard let result = sdk.executor(try required(args, "strategy")).execute(args["state"] ?? .null) else { return .null }
            return .object(["payload": result.payload, "diagnostics": result.diagnostics, "assignment": try json(result.assignment)])
        case "ddaRecord":
            try sdk.dda(required(args, "strategy")).recordBehavior(required(args, "behavior"), amount: args["amount"]?.doubleValue ?? 1)
        case "ddaComplete": sdk.dda(try required(args, "strategy")).completeStep(args["stepId"]?.stringValue)
        case "ddaReset": try sdk.dda(required(args, "strategy")).reset(args["scope"]?.stringValue ?? "all")
        case "ddaDecide":
            let result = sdk.dda(try required(args, "strategy")).decide(context: args["context"] ?? .null)
            return .object(["adjustment": .string(result.adjustment.rawValue), "payload": result.payload,
                            "diagnostics": result.diagnostics, "isFallback": .bool(result.isFallback),
                            "assignment": try result.assignment.map(json) ?? .null])
        default: throw UnityBridgeError.invalid("Unsupported operation")
        }
        return .null
    }

    private func updateSession(_ value: String) { lock.lock(); session = value; lock.unlock() }
}

private func required(_ args: [String: JSONValue], _ key: String) throws -> String {
    guard let value = args[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw UnityBridgeError.invalid(key + " is required")
    }
    return value
}
private func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
private func decode<T: Decodable>(_ pointer: UnsafePointer<CChar>?, _ type: T.Type) throws -> T {
    guard let pointer, let data = String(validatingUTF8: pointer)?.data(using: .utf8) else { throw UnityBridgeError.invalid("Invalid UTF-8 request") }
    return try JSONDecoder().decode(type, from: data)
}
private func response(_ id: String? = nil, result: JSONValue = .null, error: Error? = nil) -> String {
    var fields: [String: JSONValue] = ["id": id.map(JSONValue.string) ?? .null, "ok": .bool(error == nil)]
    if let error { fields["error"] = .string(error.localizedDescription) } else { fields["result"] = result }
    guard let data = try? JSONEncoder().encode(JSONValue.object(fields)), let result = String(data: data, encoding: .utf8) else {
        return "{\"ok\":false,\"error\":\"Native bridge encoding failed\"}"
    }
    return result
}

@_cdecl("GPUnity_Initialize")
public func GPUnity_Initialize(_ input: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    do { return strdup(response(result: try UnityBridge.shared.initialize(decode(input, UnityOptions.self)))) }
    catch { return strdup(response(error: error)) }
}
@_cdecl("GPUnity_Read")
public func GPUnity_Read(_ input: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    do { return strdup(response(result: try UnityBridge.shared.read(decode(input, UnityRequest.self)))) }
    catch { return strdup(response(error: error)) }
}
@_cdecl("GPUnity_Send")
public func GPUnity_Send(_ input: UnsafePointer<CChar>?, _ callback: GamePropelUnityCallback?) {
    guard let callback else { return }
    do {
        // Copy all UTF-8 arguments before the P/Invoke call returns. Nothing
        // retains the managed string's temporary native buffer.
        let request = try decode(input, UnityRequest.self)
        Task {
            let reply: String
            do { reply = response(request.id, result: try await UnityBridge.shared.perform(request)) }
            catch { reply = response(request.id, error: error) }
            reply.withCString { callback($0) }
        }
    } catch { response(error: error).withCString { callback($0) } }
}
@_cdecl("GPUnity_Free")
public func GPUnity_Free(_ text: UnsafeMutablePointer<CChar>?) { if let text { free(text) } }
@_cdecl("GPUnity_GetForegroundTimeMs")
public func GPUnity_GetForegroundTimeMs() -> Int64 { UnityBridge.shared.foregroundTime() }
