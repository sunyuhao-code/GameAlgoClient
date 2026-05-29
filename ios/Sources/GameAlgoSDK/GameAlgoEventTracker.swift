import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol GameAlgoEventBatchUploading: Sendable {
    func uploadEvents(_ events: [GameAlgoEvent]) async throws -> GameAlgoEventBatchResponse
}

public actor GameAlgoEventTracker {
    private let uploader: any GameAlgoEventBatchUploading
    private let maxBatchSize: Int
    private let queueLimit: Int
    private let flushInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: GameAlgoLogHandler?

    private var userId: String?
    private var sessionId = UUID().uuidString
    private var platform: GameAlgoPlatform?
    private var sdkVersion: String?
    private var appVersion: String?
    private var timezone: String
    private var userCreatedAt: String?
    private var isDebug: Bool
    private var queue: [GameAlgoEvent] = []
    private var retryBatch: [GameAlgoEvent] = []
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var sessionStartDate: Date?
    private var currentAssignments: [GameAlgoExperimentAssignment] = []

    init(
        uploader: any GameAlgoEventBatchUploading,
        maxBatchSize: Int = 100,
        queueLimit: Int = 1000,
        flushInterval: TimeInterval = 30,
        isDebug: Bool = false,
        initialIdentity: GameAlgoUserIdentity? = nil,
        logger: GameAlgoLogHandler? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.maxBatchSize = min(max(maxBatchSize, 1), 100)
        self.queueLimit = max(queueLimit, self.maxBatchSize)
        self.flushInterval = flushInterval
        self.isDebug = isDebug
        self.now = now
        self.logger = logger
        self.userId = initialIdentity?.userId
        self.userCreatedAt = initialIdentity?.userCreatedAt
        self.timezone = Self.defaultTimezone()

        #if canImport(UIKit)
        let tracker = self
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in Task { await tracker.flush() } }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in Task { await tracker.flush() } }
        #endif
    }

    deinit {
        flushTask?.cancel()
    }

    public func identify(
        userId: String,
        sessionId: String? = nil,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        timezone: String? = nil,
        userCreatedAt: String? = nil,
        isDebug: Bool? = nil
    ) {
        self.userId = userId
        if let sessionId {
            self.sessionId = sessionId
        }
        if let platform {
            self.platform = platform
        }
        if let sdkVersion {
            self.sdkVersion = sdkVersion
        }
        if let appVersion {
            self.appVersion = appVersion
        }
        if let timezone = clean(timezone) {
            self.timezone = timezone
        }
        if let userCreatedAt {
            self.userCreatedAt = userCreatedAt
        }
        if let isDebug {
            self.isDebug = isDebug
        }
    }

    public func newSession(_ sessionId: String = UUID().uuidString) {
        self.sessionId = sessionId
        sessionStartDate = nil
    }

    public func setDebug(_ isDebug: Bool) {
        self.isDebug = isDebug
    }

    public func setTimezone(_ timezone: String?) {
        self.timezone = clean(timezone) ?? Self.defaultTimezone()
    }

    public func setAssignments(_ assignments: [GameAlgoExperimentAssignment]) {
        currentAssignments = assignments
    }

    @discardableResult
    public func track(
        _ eventType: String,
        payload: JSONValue = .object([:]),
        userId: String? = nil,
        sessionId: String? = nil,
        includeExperiments: Bool? = nil
    ) -> Bool {
        guard let resolvedUserId = clean(userId ?? self.userId) else {
            return false
        }

        let event = GameAlgoEvent(
            userId: resolvedUserId,
            sessionId: clean(sessionId) ?? self.sessionId,
            eventType: eventType,
            platform: platform,
            sdkVersion: sdkVersion,
            appVersion: appVersion,
            timezone: timezone,
            isDebug: isDebug,
            timestamp: GameAlgoEventBatchUploader.isoTimestamp(now()),
            payload: payloadWithExperiments(eventType: eventType, payload: payload, includeExperiments: includeExperiments)
        )
        enqueue(event)
        return true
    }

    @discardableResult
    public func trackEvent(
        _ type: String,
        payload: JSONValue = .object([:]),
        userId: String? = nil,
        sessionId: String? = nil,
        includeExperiments: Bool = false
    ) -> Bool {
        let eventType = type.hasPrefix("_") ? type : "_\(type)"
        return track(eventType, payload: payload, userId: userId, sessionId: sessionId, includeExperiments: includeExperiments)
    }

    @discardableResult
    public func trackSessionStart(payload: JSONValue = .object([:])) -> Bool {
        sessionStartDate = now()
        var merged = payload.objectValue ?? [:]
        if let userCreatedAt = clean(userCreatedAt), merged["userCreatedAt"] == nil {
            merged["userCreatedAt"] = .string(userCreatedAt)
        }
        return track("session_start", payload: .object(merged))
    }

    @discardableResult
    public func trackSessionEnd(payload: JSONValue = .object([:])) async -> Bool {
        var merged = payload.objectValue ?? [:]
        if let sessionStartDate {
            let durationMs = Int(now().timeIntervalSince(sessionStartDate) * 1000)
            merged["sessionDurationMs"] = .number(Double(durationMs))
        }
        let didTrack = track("session_end", payload: .object(merged))
        if didTrack {
            await flush()
        }
        return didTrack
    }

    @discardableResult
    public func trackConfigLoaded() -> Bool {
        track("config_loaded", payload: .object(["experiments": experimentsPayload()]))
    }

    @discardableResult
    public func trackLevelStart(payload: JSONValue = .object([:])) -> Bool {
        track("level_start", payload: payload)
    }

    @discardableResult
    public func trackLevelEnd(payload: JSONValue = .object([:])) -> Bool {
        track("level_end", payload: payload)
    }

    @discardableResult
    public func trackAdView(cpm: Double, placement: String? = nil, payload: JSONValue = .object([:])) -> Bool {
        var merged = payload.objectValue ?? [:]
        merged["cpm"] = .number(cpm)
        if let placement, !placement.isEmpty {
            merged["placement"] = .string(placement)
        }
        return track("ad_view", payload: .object(merged))
    }

    @discardableResult
    public func trackPurchase(
        productId: String? = nil,
        revenue: Double? = nil,
        currency: String? = nil,
        payload: JSONValue = .object([:])
    ) -> Bool {
        var merged = payload.objectValue ?? [:]
        if let productId, !productId.isEmpty {
            merged["productId"] = .string(productId)
        }
        if let revenue {
            merged["revenue"] = .number(revenue)
        }
        if let currency, !currency.isEmpty {
            merged["currency"] = .string(currency)
        }
        return track("purchase", payload: .object(merged))
    }

    @discardableResult
    public func gameStart(payload: JSONValue = .object([:])) -> Bool {
        track("game_start", payload: payload)
    }

    @discardableResult
    public func gameOver(payload: JSONValue = .object([:])) -> Bool {
        track("game_over", payload: payload)
    }

    @discardableResult
    public func move(payload: JSONValue = .object([:])) -> Bool {
        track("move", payload: payload)
    }

    @discardableResult
    public func replay(payload: JSONValue = .object([:])) -> Bool {
        track("replay", payload: payload)
    }

    @discardableResult
    public func quit(payload: JSONValue = .object([:])) -> Bool {
        track("quit", payload: payload)
    }

    public func flush() async {
        guard !isFlushing else {
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        while !retryBatch.isEmpty || !queue.isEmpty {
            let pending = retryBatch + queue
            let batch = Array(pending.prefix(maxBatchSize))
            queue = Array(pending.dropFirst(maxBatchSize))
            retryBatch = []

            log("flushing \(batch.count) events")
            do {
                _ = try await uploader.uploadEvents(batch)
                log("flush success: \(batch.count) events")
            } catch {
                retryBatch = batch
                log("flush failed: \(error)")
                return
            }
        }
    }

    private func enqueue(_ event: GameAlgoEvent) {
        queue.append(event)
        log("enqueued \(event.eventType), queue size: \(queue.count)")
        if queue.count > queueLimit {
            queue.removeFirst(queue.count - queueLimit)
        }
        startFlushTimerIfNeeded()
        if queue.count >= maxBatchSize {
            let tracker = self
            Task { await tracker.flush() }
        }
    }

    private func payloadWithExperiments(eventType: String, payload: JSONValue, includeExperiments: Bool?) -> JSONValue {
        guard shouldAttachExperiments(eventType: eventType, includeExperiments: includeExperiments) else {
            return payload
        }

        var object = payload.objectValue ?? [:]
        if object["experiments"] == nil {
            object["experiments"] = experimentsPayload()
        }
        return .object(object)
    }

    private func shouldAttachExperiments(eventType: String, includeExperiments: Bool?) -> Bool {
        guard !["session_start", "session_end", "config_loaded"].contains(eventType),
              !currentAssignments.isEmpty
        else {
            return false
        }
        if let includeExperiments {
            return includeExperiments
        }
        return !eventType.hasPrefix("_")
    }

    private func experimentsPayload() -> JSONValue {
        var experiments: [String: JSONValue] = [:]
        for assignment in currentAssignments {
            experiments[assignment.key] = .string(assignment.variant)
        }
        return .object(experiments)
    }

    private func startFlushTimerIfNeeded() {
        guard flushTask == nil, flushInterval > 0 else {
            return
        }

        let interval = UInt64(flushInterval * 1_000_000_000)
        let tracker = self
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await tracker.flush()
            }
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func log(_ message: String) {
        logger?("[GameAlgoSDK] \(message)")
    }

    private static func defaultTimezone() -> String {
        TimeZone.current.identifier
    }
}

final class GameAlgoEventBatchUploader: GameAlgoEventBatchUploading, @unchecked Sendable {
    private let gameKey: String
    private let baseURL: URL
    private let defaultPlatform: GameAlgoPlatform
    private let defaultSDKVersion: String
    private let defaultAppVersion: String?
    private let httpClient: any GameAlgoHTTPClient
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        gameKey: String,
        baseURL: URL,
        defaultPlatform: GameAlgoPlatform,
        defaultSDKVersion: String,
        defaultAppVersion: String?,
        httpClient: any GameAlgoHTTPClient,
        now: @escaping @Sendable () -> Date
    ) {
        self.gameKey = gameKey
        self.baseURL = baseURL
        self.defaultPlatform = defaultPlatform
        self.defaultSDKVersion = defaultSDKVersion
        self.defaultAppVersion = defaultAppVersion
        self.httpClient = httpClient
        self.now = now
    }

    func uploadEvents(_ events: [GameAlgoEvent]) async throws -> GameAlgoEventBatchResponse {
        guard !events.isEmpty else {
            throw GameAlgoError.invalidEvents("events must be a non-empty array")
        }
        guard events.count <= 100 else {
            throw GameAlgoError.invalidEvents("Maximum 100 events per batch")
        }

        let timestamp = Self.isoTimestamp(now())
        let normalizedEvents = events.map { event in
            var normalized = event
            if normalized.eventId?.isEmpty ?? true {
                normalized.eventId = UUID().uuidString
            }
            if normalized.platform == nil {
                normalized.platform = defaultPlatform
            }
            if normalized.sdkVersion?.isEmpty ?? true {
                normalized.sdkVersion = defaultSDKVersion
            }
            if normalized.appVersion == nil {
                normalized.appVersion = defaultAppVersion
            }
            if normalized.timezone?.isEmpty ?? true {
                normalized.timezone = TimeZone.current.identifier
            }
            if normalized.isDebug == nil {
                normalized.isDebug = false
            }
            if normalized.timestamp?.isEmpty ?? true {
                normalized.timestamp = timestamp
            }
            return normalized
        }

        let body = try encode(EventBatchRequest(events: normalizedEvents))
        let response = try await request(
            GameAlgoHTTPRequest(
                url: try endpoint("/v1/events/batch"),
                method: .post,
                headers: ["content-type": "application/json"],
                body: body
            )
        )
        do {
            return try decoder.decode(GameAlgoEventBatchResponse.self, from: response.body)
        } catch {
            throw GameAlgoError.decodingFailed(error.localizedDescription)
        }
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func request(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse {
        var request = request
        request.headers["X-GameAlgo-Key"] = gameKey
        request.headers["Accept"] = "application/json"

        let response = try await httpClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw apiError(from: response)
        }
        return response
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw GameAlgoError.encodingFailed(error.localizedDescription)
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw GameAlgoError.invalidURL(path)
        }
        return url
    }

    private func apiError(from response: GameAlgoHTTPResponse) -> GameAlgoError {
        let fallback = "GameAlgo API returned \(response.statusCode)"
        if let payload = try? decoder.decode(APIErrorPayload.self, from: response.body) {
            return .apiError(
                statusCode: response.statusCode,
                code: payload.error,
                message: payload.message ?? payload.error ?? fallback
            )
        }
        return .apiError(statusCode: response.statusCode, code: nil, message: fallback)
    }
}

private struct EventBatchRequest: Encodable {
    let events: [GameAlgoEvent]
}

private struct APIErrorPayload: Decodable {
    let error: String?
    let message: String?
}
