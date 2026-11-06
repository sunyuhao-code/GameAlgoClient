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
        var version = 2
        var journalSequence: UInt64?
        var events: [GameAlgoEvent] = []
        var session: Session?
        var configRequests: [String: String] = [:]
    }
    private struct Operation: Codable {
        let journalSequence: UInt64
        let put: [GameAlgoEvent]
        let remove: [String]
        let session: Session?
        let configRequests: [String: String]?
    }
    private var eventIndex: [String: Int] = [:]
    private var dirtyEvents = Set<String>()
    private var removedEvents = Set<String>()
    private var configsDirty = false
    private var journalReady = true
    private var sequence: UInt64 = 0
    private var operations = 0
    private var formattedAt: Date?
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
    private var foregroundTimeMs: Double = 0
    private var sessionForegroundStartMs: Double = 0

    init(storage: (any GameAlgoCacheStorage)?, key: String?, queueLimit: Int = 1000) {
        self.storage = storage
        self.key = key
        self.queueLimit = max(1, queueLimit)
        do {
            if let key, let raw = try storage?.loadValue(cacheKey: key) {
                state = try JSONDecoder().decode(State.self, from: Data(raw.utf8))
            }
        } catch {
            // Preserve unread durable state instead of replacing it on enqueue.
            journalReady = false
        }
        rebuildIndex()
        if journalReady, let key, let journal = storage as? any GameAlgoJournalStorage {
            do {
                for raw in try journal.loadJournalRecords(cacheKey: key) {
                    let operation = try JSONDecoder().decode(Operation.self, from: Data(raw.utf8))
                    guard operation.journalSequence > (state.journalSequence ?? 0) else { continue }
                    for event in operation.put { merge(event) }
                    let removed = Set(operation.remove)
                    state.events.removeAll { removed.contains($0.eventId ?? "") }
                    rebuildIndex()
                    if let session = operation.session { state.session = session }
                    if let configs = operation.configRequests { state.configRequests = configs }
                    state.journalSequence = operation.journalSequence
                    operations += 1
                }
            } catch { journalReady = false }
        }
        sequence = state.journalSequence ?? 0
        dirtyEvents.removeAll(); removedEvents.removeAll()
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
            sessionForegroundStartMs = foregroundTimeMs.rounded(.down)
            sampleAt = startedAt
            if !active { sampleForeground = foreground }
        } else {
            state.session?.event = template
            if state.session?.startedAt != startedAt {
                state.session?.durationMs = 0
                sessionForegroundStartMs = foregroundTimeMs.rounded(.down)
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
        return max(0, foregroundTimeMs.rounded(.down) - sessionForegroundStartMs)
    }

    func getForegroundTimeMs() -> Double {
        lock.lock(); defer { lock.unlock() }
        return foregroundTimeMs.rounded(.down)
    }

    private func sampleLocked(foreground: Bool, at date: Date) {
        guard active, let previous = sampleAt else { return }
        if foreground && sampleForeground {
            foregroundTimeMs += min(1000, max(0, date.timeIntervalSince(previous) * 1000))
        }
        state.session?.durationMs = max(0, foregroundTimeMs.rounded(.down) - sessionForegroundStartMs)
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
            dirtyEvents.insert(state.events[index].eventId ?? "")
        }
        configsDirty = state.configRequests.removeValue(forKey: sessionId) != nil || configsDirty
        persist()
    }

    func retainConfig(sessionId: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        state.configRequests[sessionId] = String(decoding: body, as: UTF8.self)
        configsDirty = true
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
        removedEvents.formUnion(ids); dirtyEvents.subtract(ids)
        rebuildIndex()
        persist()
    }
    private func rebuildIndex() {
        eventIndex = Dictionary(state.events.enumerated().map { ($0.element.eventId ?? "", $0.offset) }, uniquingKeysWith: { _, last in last })
    }
    private func merge(_ event: GameAlgoEvent) {
        let id = event.eventId ?? ""
        if let index = eventIndex[id] {
            if state.events[index] == event { return }
            state.events[index] = event
        } else {
            eventIndex[id] = state.events.count
            state.events.append(event)
        }
        dirtyEvents.insert(id); removedEvents.remove(id)
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
        if state.events.count > queueLimit {
            let removed = state.events.prefix(state.events.count - queueLimit).compactMap(\.eventId)
            removedEvents.formUnion(removed); dirtyEvents.subtract(removed)
            state.events.removeFirst(state.events.count - queueLimit)
            rebuildIndex()
        }
        if !removedEvents.isEmpty {
            let sessions = Set(state.events.map(\.sessionId)).union(state.session.map { [$0.event.sessionId] } ?? [])
            let retained = state.configRequests.filter { sessions.contains($0.key) }
            configsDirty = retained != state.configRequests || configsDirty
            state.configRequests = retained
        }
        durable = false
        guard let storage, let key, journalReady else { return }
        do {
            if let lastSeen = state.session?.lastSeen, formattedAt != lastSeen {
                state.session?.timestamp = GameAlgoEventBatchUploader.isoTimestamp(lastSeen)
                state.session?.createdLocalAt = GameAlgoEventBatchUploader.localTimestamp(lastSeen)
                formattedAt = lastSeen
            }
            if let journal = storage as? any GameAlgoJournalStorage {
                sequence += 1
                state.journalSequence = sequence
                let changed = dirtyEvents.compactMap { eventIndex[$0] }.sorted().map { state.events[$0] }
                let operation = Operation(journalSequence: sequence, put: changed, remove: Array(removedEvents),
                                          session: state.session, configRequests: configsDirty ? state.configRequests : nil)
                try journal.appendJournalRecord(String(decoding: JSONEncoder().encode(operation), as: UTF8.self), sequence: sequence, cacheKey: key)
                operations += 1
                if operations >= 256 {
                    operations = 0
                    do {
                        try journal.compactJournal(String(decoding: JSONEncoder().encode(state), as: UTF8.self), cacheKey: key)
                    } catch { /* The incremental record is already committed. */ }
                }
            } else {
                try storage.saveValue(String(decoding: JSONEncoder().encode(state), as: UTF8.self), cacheKey: key)
            }
            dirtyEvents.removeAll(); removedEvents.removeAll(); configsDirty = false
            durable = true
        } catch { /* Retry all uncommitted changes on the next persistence attempt. */ }
    }
}
