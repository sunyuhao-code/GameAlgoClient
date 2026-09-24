import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol GameAlgoEventBatchUploading: Sendable {
    func uploadEvents(_ events: [GameAlgoEvent]) async throws -> GameAlgoEventBatchResponse
    func uploadEventGuardDiagnostic(_ diagnostic: GameAlgoEventGuardDiagnostic) async throws
}

extension GameAlgoEventBatchUploading {
    func uploadEventGuardDiagnostic(_ diagnostic: GameAlgoEventGuardDiagnostic) async throws {}
}

struct GameAlgoEventGuardDiagnostic: Encodable, Sendable {
    let diagnosticId: String
    let userId: String?
    let sessionId: String
    let contextId: String?
    let platform: GameAlgoPlatform
    let sdkVersion: String
    let appVersion: String?
    let stage = "event_guard"
    let status = "degraded"
    let reasonCode = "custom_event_quota_exceeded"
    let reasonDetail: String
    let createdAt: String
    let createdLocalAt: String
    let isDebug: Bool
}

public actor GameAlgoEventTracker {
    private static let standardEventTypes: Set<String> = [
        "session_end", "level_start", "level_end", "ad_view", "purchase", "milestone",
    ]
    private struct CustomCountBucket {
        var total = 0
        var byType: [String: Int] = [:]
    }
    private let uploader: any GameAlgoEventBatchUploading
    private let maxBatchSize: Int
    private let queueLimit: Int
    private let flushInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: GameAlgoLogHandler?
    private let storage: (any GameAlgoCacheStorage)?
    private let persistenceKey: String?
    private let milestonePersistenceKey: String?

    private var userId: String?
    private var sessionId = UUID().uuidString
    private var contextId: String?
    private var platform: GameAlgoPlatform?
    private var sdkVersion: String?
    private var appVersion: String?
    private var timezone: String
    private var userCreatedAt: String?
    private var accountUserId: String?
    private var isDebug: Bool
    private var queue: [GameAlgoEvent] = []
    private var retryBatch: [GameAlgoEvent] = []
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var sessionStartDate: Date?
    private var currentAssignments: [GameAlgoExperimentAssignment] = []
    private var consecutiveFailures = 0
    private var hasPersistedQueue = false
    private var customCounts: [String: CustomCountBucket] = [:]
    private var diagnosticKeys: Set<String> = []
    private var diagnosticCount = 0
    private var reachedMilestoneKeys: Set<String> = []
    private var pendingMilestoneKeys: Set<String> = []

    init(
        uploader: any GameAlgoEventBatchUploading,
        maxBatchSize: Int = 100,
        queueLimit: Int = 1000,
        flushInterval: TimeInterval = 30,
        isDebug: Bool = false,
        initialIdentity: GameAlgoUserIdentity? = nil,
        initialPlatform: GameAlgoPlatform? = nil,
        initialSDKVersion: String? = nil,
        initialAppVersion: String? = nil,
        storage: (any GameAlgoCacheStorage)? = nil,
        persistenceKey: String? = nil,
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
        self.storage = storage
        self.persistenceKey = persistenceKey
        self.milestonePersistenceKey = persistenceKey.map { "\($0):milestones" }
        self.userId = initialIdentity?.userId
        self.userCreatedAt = initialIdentity?.userCreatedAt
        self.platform = initialPlatform
        self.sdkVersion = initialSDKVersion
        self.appVersion = initialAppVersion
        self.timezone = Self.defaultTimezone()
        if let storage, let persistenceKey,
           let raw = try? storage.loadValue(cacheKey: persistenceKey),
           !raw.isEmpty {
            let decoder = JSONDecoder()
            let restored = raw.split(separator: "\n").compactMap { line in
                try? decoder.decode(GameAlgoEvent.self, from: Data(line.utf8))
            }
            self.retryBatch = restored
            self.hasPersistedQueue = !restored.isEmpty
        }
        if let storage, let milestonePersistenceKey,
           let raw = try? storage.loadValue(cacheKey: milestonePersistenceKey),
           let data = raw.data(using: .utf8),
           let restored = try? JSONDecoder().decode([String].self, from: data) {
            self.reachedMilestoneKeys.formUnion(restored)
        }

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
        accountUserId: String? = nil,
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
        if let accountUserId = clean(accountUserId) {
            self.accountUserId = accountUserId
        }
        if let isDebug {
            self.isDebug = isDebug
        }
    }

    public func newSession(_ sessionId: String = UUID().uuidString) {
        let previousSessionId = self.sessionId
        retryBatch.removeAll { clean($0.contextId) == nil && $0.sessionId == previousSessionId }
        queue.removeAll { clean($0.contextId) == nil && $0.sessionId == previousSessionId }
        self.sessionId = sessionId
        diagnosticKeys.removeAll()
        diagnosticCount = 0
        pendingMilestoneKeys.removeAll()
        contextId = nil
        sessionStartDate = now()
        if hasPersistedQueue { persistPendingQueue() }
    }

    public func currentSessionId() -> String {
        sessionId
    }

    public func setContextId(_ contextId: String) {
        let resolved = clean(contextId)
        self.contextId = resolved
        guard let resolved else { return }
        mergeCustomCountBucket(from: "pending:\(sessionId)", to: "context:\(resolved)")
        retryBatch = retryBatch.map { bindContext($0, contextId: resolved) }
        queue = queue.map { bindContext($0, contextId: resolved) }
        rememberBoundMilestones(contextId: resolved)
        if hasPersistedQueue { persistPendingQueue() }
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

    public func markSessionStarted() {
        sessionStartDate = now()
    }

    @discardableResult
    public func track(
        _ eventType: String,
        payload: JSONValue = .object([:]),
        userId: String? = nil,
        sessionId: String? = nil,
        contextId: String? = nil
    ) -> Bool {
        guard let resolvedUserId = clean(userId ?? self.userId) else {
            return false
        }
        let resolvedContextId = clean(contextId ?? self.contextId) ?? ""
        let resolvedSessionId = clean(sessionId) ?? self.sessionId
        guard consumeCustomEventQuota(eventType, contextId: clean(resolvedContextId), sessionId: resolvedSessionId) else {
            return false
        }

        let eventDate = now()
        var normalizedPayload = normalizePayload(payload)
        let milestone = eventType == "milestone"
            ? prepareMilestone(
                userId: resolvedUserId,
                contextId: clean(resolvedContextId),
                isDebug: isDebug,
                payload: &normalizedPayload,
                eventDate: eventDate
            )
            : nil
        if milestone?.duplicate == true { return false }
        let event = GameAlgoEvent(
            eventId: UUID().uuidString,
            contextId: resolvedContextId,
            userId: resolvedUserId,
            sessionId: resolvedSessionId,
            eventType: eventType,
            isDebug: isDebug,
            timestamp: GameAlgoEventBatchUploader.isoTimestamp(eventDate),
            createdLocalAt: GameAlgoEventBatchUploader.localTimestamp(eventDate),
            accountUserId: accountUserId,
            payload: normalizedPayload
        )
        enqueue(event)
        if let milestone, let key = milestone.key {
            rememberMilestone(key, durable: milestone.durable)
        }
        return true
    }

    private func prepareMilestone(
        userId: String,
        contextId: String?,
        isDebug: Bool,
        payload: inout [String: JSONValue],
        eventDate: Date
    ) -> (duplicate: Bool, key: String?, durable: Bool) {
        payload.removeValue(forKey: "elapsedSinceRegistrationMs")
        if let userCreatedAt, let registeredAt = Self.isoDate(userCreatedAt) {
            let elapsed = max(0, Int(eventDate.timeIntervalSince(registeredAt) * 1000))
            payload["elapsedSinceRegistrationMs"] = .number(Double(elapsed))
        }

        guard let milestoneType = clean(payload["milestoneType"]?.stringValue),
              let milestonePoint = clean(payload["milestonePoint"]?.stringValue) else {
            return (false, nil, false)
        }
        let key = Self.milestoneKey(
            userId: userId,
            isDebug: isDebug,
            milestoneType: milestoneType,
            milestonePoint: milestonePoint
        )
        let durable = contextId != nil
        let duplicate = !durable
            ? pendingMilestoneKeys.contains(key)
            : reachedMilestoneKeys.contains(key)
        return (duplicate, key, durable)
    }

    private func rememberMilestone(_ key: String, durable: Bool) {
        if !durable {
            pendingMilestoneKeys.insert(key)
            return
        }
        guard reachedMilestoneKeys.insert(key).inserted else { return }
        persistReachedMilestones()
    }

    private func rememberBoundMilestones(contextId: String) {
        var changed = false
        for event in retryBatch + queue
        where event.contextId == contextId && event.eventType == "milestone" {
            guard let milestoneType = clean(event.payload["milestoneType"]?.stringValue),
                  let milestonePoint = clean(event.payload["milestonePoint"]?.stringValue) else {
                continue
            }
            let key = Self.milestoneKey(
                userId: event.userId,
                isDebug: event.isDebug == true,
                milestoneType: milestoneType,
                milestonePoint: milestonePoint
            )
            if reachedMilestoneKeys.insert(key).inserted { changed = true }
        }
        if changed { persistReachedMilestones() }
    }

    private func persistReachedMilestones() {
        guard let storage, let milestonePersistenceKey,
              let data = try? JSONEncoder().encode(reachedMilestoneKeys.sorted()),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? storage.saveValue(raw, cacheKey: milestonePersistenceKey)
    }

    private static func milestoneKey(
        userId: String,
        isDebug: Bool,
        milestoneType: String,
        milestonePoint: String
    ) -> String {
        let parts = [isDebug ? "debug" : "live", userId, milestoneType, milestonePoint]
        guard let data = try? JSONEncoder().encode(parts),
              let encoded = String(data: data, encoding: .utf8) else {
            return parts.map { "\($0.count):\($0)" }.joined()
        }
        return encoded
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func consumeCustomEventQuota(_ eventType: String, contextId: String?, sessionId: String) -> Bool {
        if Self.standardEventTypes.contains(eventType) { return true }
        let bucketKey = contextId.map { "context:\($0)" } ?? "pending:\(sessionId)"
        var bucket = customCounts[bucketKey] ?? CustomCountBucket()
        let current = bucket.byType[eventType] ?? 0
        let rejection: (String, Int)?
        if bucket.byType[eventType] == nil && bucket.byType.count >= 100 {
            rejection = ("distinct_event_types", 100)
        } else if current >= 1000 {
            rejection = ("context_event_type", 1000)
        } else if bucket.total >= 5000 {
            rejection = ("context_total", 5000)
        } else {
            rejection = nil
        }
        if let (scope, limit) = rejection {
            let observed = scope == "context_total"
                ? bucket.total + 1
                : scope == "distinct_event_types" ? bucket.byType.count + 1 : current + 1
            reportQuotaDiagnostic(eventType, sessionId: sessionId, contextId: contextId, scope: scope, limit: limit,
                                  observed: observed)
            return false
        }
        bucket.total += 1
        bucket.byType[eventType] = current + 1
        customCounts[bucketKey] = bucket
        return true
    }

    private func mergeCustomCountBucket(from: String, to: String) {
        guard let pending = customCounts.removeValue(forKey: from) else { return }
        var target = customCounts[to] ?? CustomCountBucket()
        target.total += pending.total
        for (eventType, count) in pending.byType { target.byType[eventType, default: 0] += count }
        customCounts[to] = target
    }

    private func reportQuotaDiagnostic(_ eventType: String, sessionId: String, contextId: String?, scope: String, limit: Int, observed: Int) {
        guard let platform, let sdkVersion else { return }
        let key = "\(sessionId)\u{0}\(eventType)\u{0}\(scope)"
        guard !diagnosticKeys.contains(key), diagnosticCount < 10 else { return }
        diagnosticKeys.insert(key)
        diagnosticCount += 1
        let safeEventType = String(eventType.replacingOccurrences(of: ";", with: "_").replacingOccurrences(of: "\n", with: "_").prefix(96))
        let created = now()
        let diagnostic = GameAlgoEventGuardDiagnostic(
            diagnosticId: UUID().uuidString,
            userId: userId,
            sessionId: sessionId,
            contextId: contextId,
            platform: platform,
            sdkVersion: sdkVersion,
            appVersion: appVersion,
            reasonDetail: "eventType=\(safeEventType);scope=\(scope);limit=\(limit);observed=\(observed);dropped=1",
            createdAt: GameAlgoEventBatchUploader.isoTimestamp(created),
            createdLocalAt: GameAlgoEventBatchUploader.localTimestamp(created),
            isDebug: isDebug
        )
        Task { try? await uploader.uploadEventGuardDiagnostic(diagnostic) }
    }

    @discardableResult
    public func trackEvent(
        _ type: String,
        payload: JSONValue = .object([:]),
        userId: String? = nil,
        sessionId: String? = nil,
        contextId: String? = nil
    ) -> Bool {
        let eventType = type.hasPrefix("_") ? type : "_\(type)"
        return track(
            eventType,
            payload: payload,
            userId: userId,
            sessionId: sessionId,
            contextId: contextId
        )
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
    public func trackLevelStart(payload: JSONValue = .object([:])) -> Bool {
        track("level_start", payload: payload)
    }

    @discardableResult
    public func trackLevelEnd(payload: JSONValue = .object([:])) -> Bool {
        track("level_end", payload: payload)
    }

    @discardableResult
    public func trackMilestone(
        milestoneType: String,
        milestonePoint: String,
        payload: JSONValue = .object([:])
    ) -> Bool {
        var merged = payload.objectValue ?? [:]
        merged["milestoneType"] = .string(milestoneType)
        merged["milestonePoint"] = .string(milestonePoint)
        return track("milestone", payload: .object(merged))
    }

    @discardableResult
    public func trackAd(
        placement: String,
        adType: String,
        revenue: Double,
        currency: String,
        network: String? = nil,
        payload: JSONValue = .object([:])
    ) -> Bool {
        var merged = payload.objectValue ?? [:]
        merged["placement"] = .string(placement)
        merged["adType"] = .string(adType)
        merged["revenue"] = .number(revenue)
        merged["currency"] = .string(currency)
        if let network, !network.isEmpty {
            merged["network"] = .string(network)
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

    public func flush() async {
        guard !isFlushing else {
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        while !retryBatch.isEmpty || !queue.isEmpty {
            let pending = retryBatch + queue
            let batch = Array(pending.prefix(maxBatchSize))
            let resolvedContextId = clean(contextId)
            if batch.contains(where: { clean($0.contextId) == nil }) && resolvedContextId == nil {
                retryBatch = []
                queue = pending
                return
            }
            let uploadBatch = batch.map { event in
                if clean(event.contextId) != nil {
                    return event
                }
                var updated = event
                updated.contextId = resolvedContextId!
                return updated
            }
            queue = Array(pending.dropFirst(maxBatchSize))
            retryBatch = []

            log("flushing \(uploadBatch.count) events")
            do {
                _ = try await uploader.uploadEvents(uploadBatch)
                consecutiveFailures = 0
                if hasPersistedQueue { persistPendingQueue() }
                log("flush success: \(uploadBatch.count) events")
            } catch {
                retryBatch = uploadBatch
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    hasPersistedQueue = true
                    persistPendingQueue()
                }
                log("flush failed: \(error)")
                return
            }
        }
        if hasPersistedQueue { clearPersistedQueue() }
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

    private func bindContext(_ event: GameAlgoEvent, contextId: String) -> GameAlgoEvent {
        guard clean(event.contextId) == nil, event.sessionId == sessionId else { return event }
        var updated = event
        updated.contextId = contextId
        return updated
    }

    private func persistPendingQueue() {
        guard let storage, let persistenceKey else { return }
        let pending = retryBatch + queue
        guard !pending.isEmpty else {
            clearPersistedQueue()
            return
        }
        let encoder = JSONEncoder()
        let lines = pending.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? storage.saveValue(lines.joined(separator: "\n"), cacheKey: persistenceKey)
    }

    private func clearPersistedQueue() {
        if let storage, let persistenceKey { try? storage.removeValue(cacheKey: persistenceKey) }
        hasPersistedQueue = false
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

    private func normalizePayload(_ payload: JSONValue) -> [String: JSONValue] {
        guard let object = payload.objectValue else {
            return [:]
        }

        var normalized: [String: JSONValue] = [:]
        for (key, value) in object where !key.isEmpty {
            if let payloadValue = payloadValue(value) {
                normalized[key] = payloadValue
            }
        }
        return normalized
    }

    private func payloadValue(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .string, .bool, .null:
            return value
        case let .number(number):
            return number.isFinite ? value : nil
        case .object, .array:
            guard let data = try? JSONEncoder().encode(value),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return .string(string)
        }
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

        let uploadDate = now()
        let timestamp = Self.isoTimestamp(uploadDate)
        let normalizedEvents = events.map { event in
            var normalized = event
            if normalized.eventId?.isEmpty ?? true {
                normalized.eventId = UUID().uuidString
            }
            if normalized.isDebug == nil {
                normalized.isDebug = false
            }
            if normalized.timestamp?.isEmpty ?? true {
                normalized.timestamp = timestamp
            }
            if normalized.createdLocalAt?.isEmpty ?? true {
                let eventDate = normalized.timestamp.flatMap(Self.date(from:)) ?? uploadDate
                normalized.createdLocalAt = Self.localTimestamp(eventDate)
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

    func uploadEventGuardDiagnostic(_ diagnostic: GameAlgoEventGuardDiagnostic) async throws {
        let body = try encode(diagnostic)
        _ = try await request(GameAlgoHTTPRequest(
            url: try endpoint("/v1/diagnostics/sdk"),
            method: .post,
            headers: ["content-type": "application/json"],
            body: body
        ))
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func localTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
        guard let url = gameAlgoEndpoint(baseURL: baseURL, path: path) else {
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
