import Foundation

/// Thread-safe journal shared with UIKit callbacks, which must persist before
/// returning rather than waiting for an actor task to receive execution time.
final class GameAlgoLifecycleJournal: @unchecked Sendable {
    private struct Session: Codable {
        var event: GameAlgoEvent
        var startedAt: Date
        var lastSeen: Date
        var open: Bool
        var hasEnd: Bool
        var nextEventId: String
        var timestamp: String
        var createdLocalAt: String
        // Optional so journals written before sampled timing remain readable.
        var durationMs: Double?
    }
    private struct State: Codable {
        var version = 1
        var events: [GameAlgoEvent] = []
        var session: Session?
        var configRequests: [String: String] = [:]
    }
    private let lock = NSLock()
    private let storage: (any GameAlgoCacheStorage)?
    private let key: String?
    private let queueLimit: Int
    private var state = State()
    private var active = false
    private var foreground = true
    private var durable = false
    private var sampleAt: Date?
    private var sampleForeground = true

    init(storage: (any GameAlgoCacheStorage)?, key: String?, queueLimit: Int = 1000) {
        self.storage = storage
        self.key = key
        self.queueLimit = max(1, queueLimit)
        if let key, let raw = try? storage?.loadValue(cacheKey: key),
           let data = raw.data(using: .utf8), let restored = try? JSONDecoder().decode(State.self, from: data) {
            state = restored
        }
    }

    func activate(_ template: GameAlgoEvent, startedAt: Date, hasEnd: Bool, foreground initialForeground: Bool?, pending: [GameAlgoEvent]) {
        lock.lock(); defer { lock.unlock() }
        for event in pending { merge(event) }
        if !active, let previous = state.session, previous.open {
            merge(end(previous, reason: "process_restart", at: previous.lastSeen, recovered: true))
        }
        if !active || state.session?.event.sessionId != template.sessionId {
            if let initialForeground { foreground = initialForeground }
            state.session = Session(event: template, startedAt: startedAt, lastSeen: startedAt,
                                    open: foreground, hasEnd: hasEnd, nextEventId: UUID().uuidString,
                                    timestamp: GameAlgoEventBatchUploader.isoTimestamp(startedAt),
                                    createdLocalAt: GameAlgoEventBatchUploader.localTimestamp(startedAt), durationMs: 0)
            sampleAt = startedAt
            sampleForeground = foreground
        } else {
            state.session?.event = template
            if state.session?.startedAt != startedAt {
                state.session?.durationMs = 0
                sampleAt = startedAt
            }
            state.session?.startedAt = startedAt
        }
        active = true
        persist()
    }

    func record(_ event: GameAlgoEvent) {
        lock.lock(); defer { lock.unlock() }
        merge(event)
        if event.eventType == "session_end", state.session?.event.sessionId == event.sessionId {
            state.session?.open = false
            state.session?.hasEnd = true
        }
        persist()
    }

    func observe(foreground next: Bool, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        sampleLocked(foreground: next, at: date)
        let changed = foreground != next
        foreground = next
        guard active, var session = state.session else { return }
        session.lastSeen = max(date, session.startedAt)
        session.timestamp = GameAlgoEventBatchUploader.isoTimestamp(session.lastSeen)
        session.createdLocalAt = GameAlgoEventBatchUploader.localTimestamp(session.lastSeen)
        if changed && next {
            session.open = true
            session.nextEventId = UUID().uuidString
        } else if changed {
            merge(end(session, reason: "background", at: session.lastSeen, recovered: false))
            session.open = false
            session.hasEnd = true
        }
        state.session = session
        persist()
    }

    /// Memory only. Every tick supplies live UIKit state; notifications never
    /// leave this clock waiting for a matching resume callback.
    func sample(foreground: Bool, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        sampleLocked(foreground: foreground, at: date)
    }

    func duration(sessionId: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let session = state.session, active, session.event.sessionId == sessionId else { return 0 }
        return (session.durationMs ?? 0).rounded(.down)
    }

    private func sampleLocked(foreground: Bool, at date: Date) {
        guard active, let previous = sampleAt else { return }
        if foreground && sampleForeground {
            let duration = (state.session?.durationMs ?? 0) + min(1000, max(0, date.timeIntervalSince(previous) * 1000))
            state.session?.durationMs = duration
        }
        if foreground {
            let observed = max(date, state.session?.startedAt ?? date)
            state.session?.lastSeen = observed
        }
        sampleAt = date
        sampleForeground = foreground
    }

    func bind(sessionId: String, contextId: String) {
        lock.lock(); defer { lock.unlock() }
        for index in state.events.indices where state.events[index].sessionId == sessionId && state.events[index].contextId.isEmpty {
            state.events[index].contextId = contextId
        }
        state.configRequests.removeValue(forKey: sessionId)
        persist()
    }

    func retainConfig(sessionId: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        state.configRequests[sessionId] = String(decoding: body, as: UTF8.self)
        persist()
    }
    func unboundConfigs() -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Data] = [:]
        for event in state.events where event.contextId.isEmpty {
            if let body = state.configRequests[event.sessionId] { result[event.sessionId] = Data(body.utf8) }
        }
        return result
    }

    func pending() -> [GameAlgoEvent] { lock.lock(); defer { lock.unlock() }; return state.events }
    func isDurable() -> Bool { lock.lock(); defer { lock.unlock() }; return durable }
    func hasEnd(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.session?.event.sessionId == sessionId && state.session?.hasEnd == true
    }
    func mergePending(_ events: [GameAlgoEvent]) {
        lock.lock(); defer { lock.unlock() }
        for event in events { merge(event) }
        persist()
    }
    func acknowledge(_ events: [GameAlgoEvent]) {
        lock.lock(); defer { lock.unlock() }
        let ids = Set(events.compactMap(\.eventId))
        state.events.removeAll { ids.contains($0.eventId ?? "") }
        persist()
    }
    private func merge(_ event: GameAlgoEvent) {
        if let index = state.events.firstIndex(where: { $0.eventId == event.eventId }) { state.events[index] = event }
        else { state.events.append(event) }
    }
    private func end(_ session: Session, reason: String, at date: Date, recovered: Bool) -> GameAlgoEvent {
        var event = session.event
        event.eventId = session.nextEventId
        event.timestamp = recovered ? session.timestamp : GameAlgoEventBatchUploader.isoTimestamp(date)
        event.createdLocalAt = recovered ? session.createdLocalAt : GameAlgoEventBatchUploader.localTimestamp(date)
        event.payload = ["reason": .string(reason), "recovered": .bool(recovered), "endTimeEstimated": .bool(recovered),
                         "sessionDurationMs": .number((session.durationMs ?? max(0, session.lastSeen.timeIntervalSince(session.startedAt) * 1000)).rounded(.down))]
        return event
    }
    private func persist() {
        if state.events.count > queueLimit { state.events.removeFirst(state.events.count - queueLimit) }
        let sessions = Set(state.events.map(\.sessionId)).union(state.session.map { [$0.event.sessionId] } ?? [])
        state.configRequests = state.configRequests.filter { sessions.contains($0.key) }
        durable = false
        guard let storage, let key else { return }
        do {
            if let lastSeen = state.session?.lastSeen {
                state.session?.timestamp = GameAlgoEventBatchUploader.isoTimestamp(lastSeen)
                state.session?.createdLocalAt = GameAlgoEventBatchUploader.localTimestamp(lastSeen)
            }
            let data = try JSONEncoder().encode(state)
            try storage.saveValue(String(decoding: data, as: UTF8.self), cacheKey: key)
            durable = true
        } catch { /* Retain all in-memory events for the next persistence/upload attempt. */ }
    }
}
