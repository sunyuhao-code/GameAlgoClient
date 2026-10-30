import XCTest
@testable import GameAlgoSDK

final class GameAlgoLifecycleTests: XCTestCase {
    private func storage() -> GameAlgoFileCacheStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gamealgo-lifecycle-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return GameAlgoFileCacheStorage(directory: directory, fallback: nil)
    }
    private func template(_ session: String, context: String = "ctx") -> GameAlgoEvent {
        GameAlgoEvent(eventId: "template", contextId: context, userId: "user", sessionId: session, eventType: "session_end")
    }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testRecoveryUsesLastHeartbeatAndAnIdempotentEvent() throws {
        let storage = storage()
        let first = GameAlgoLifecycleJournal(storage: storage, key: "journal")
        first.activate(template("old"), startedAt: date(1000), hasEnd: false, foreground: true, pending: [])
        for second in 1001...1010 { first.sample(foreground: true, at: date(Double(second))) }
        first.observe(foreground: true, at: date(1010))
        let second = GameAlgoLifecycleJournal(storage: storage, key: "journal")
        second.activate(template("new"), startedAt: date(9000), hasEnd: false, foreground: true, pending: [])
        let recovered = try XCTUnwrap(second.pending().first)
        XCTAssertEqual(recovered.sessionId, "old")
        XCTAssertEqual(recovered.payload["reason"], .string("process_restart"))
        XCTAssertEqual(recovered.payload["sessionDurationMs"], .number(10_000))
        XCTAssertEqual(recovered.payload["endTimeEstimated"], .bool(true))
        XCTAssertEqual(recovered.timestamp, GameAlgoEventBatchUploader.isoTimestamp(date(1010)))
        let third = GameAlgoLifecycleJournal(storage: storage, key: "journal")
        third.activate(template("third"), startedAt: date(10_000), hasEnd: false, foreground: true, pending: [])
        let old = third.pending().filter { $0.sessionId == "old" }
        XCTAssertEqual(old, [recovered])
        third.acknowledge(old)
        let fourth = GameAlgoLifecycleJournal(storage: storage, key: "journal")
        fourth.activate(template("fourth"), startedAt: date(11_000), hasEnd: false, foreground: true, pending: [])
        XCTAssertFalse(fourth.pending().contains { $0.sessionId == "old" })
    }

    func testBackgroundIsDurableBeforeUploadAndResumeKeepsIdentity() async throws {
        let storage = storage()
        let uploader = LifecycleUploader()
        let tracker = GameAlgoEventTracker(uploader: uploader, flushInterval: 0, storage: storage,
                                          persistenceKey: "queue", now: { Date(timeIntervalSince1970: 1000) })
        await tracker.identify(userId: "user", sessionId: "same-session")
        await tracker.setContextId("ctx")
        await tracker.enableLifecycle(foreground: true)
        for second in 1001...1003 { tracker.lifecycleJournal.sample(foreground: true, at: date(Double(second))) }
        tracker.lifecycleJournal.observe(foreground: false, at: date(1003))
        let raw = try XCTUnwrap(storage.loadValue(cacheKey: "queue:lifecycle"))
        XCTAssertTrue(raw.contains("session_end"), "UIKit commits the end synchronously before an actor task runs")
        await tracker.flush()
        tracker.lifecycleJournal.observe(foreground: true, at: date(1010))
        for second in 1011...1013 { tracker.lifecycleJournal.sample(foreground: true, at: date(Double(second))) }
        tracker.lifecycleJournal.observe(foreground: false, at: date(1013))
        await tracker.flush()
        let events = await uploader.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.sessionId), ["same-session", "same-session"])
        XCTAssertEqual(events.map { $0.payload["sessionDurationMs"] }, [.number(3000), .number(6000)])
        XCTAssertNotEqual(events[0].eventId, events[1].eventId)
        let current = await tracker.currentSessionId()
        XCTAssertEqual(current, "same-session")
        await tracker.newSession("explicit")
        await tracker.flush()
        let afterSwitch = await uploader.events
        XCTAssertEqual(afterSwitch.count, 2, "an already-backgrounded old session must not gain an extended end")
        let restart = GameAlgoLifecycleJournal(storage: storage, key: "queue:lifecycle")
        restart.activate(template("new"), startedAt: date(9000), hasEnd: false, foreground: true, pending: [])
        XCTAssertFalse(restart.pending().contains { $0.sessionId == "same-session" }, "normal background and ACK leave a closed old marker")
    }

    func testSamplesRecoverWithoutResumeAndDoNotWriteEverySecond() throws {
        let storage = storage()
        let journal = GameAlgoLifecycleJournal(storage: storage, key: "journal")
        journal.activate(template("same"), startedAt: date(1000), hasEnd: false, foreground: true, pending: [])
        let initial = try storage.loadValue(cacheKey: "journal")
        journal.sample(foreground: true, at: date(1001))
        journal.sample(foreground: true, at: date(1042)) // delayed callback, no catch-up
        XCTAssertEqual(journal.duration(sessionId: "same"), 2000)
        XCTAssertEqual(try storage.loadValue(cacheKey: "journal"), initial)
        journal.observe(foreground: false, at: date(1042))
        journal.sample(foreground: false, at: date(1100)) // native timer can run in background
        XCTAssertEqual(journal.duration(sessionId: "same"), 2000)
        journal.sample(foreground: true, at: date(1200)) // no foreground notification
        journal.sample(foreground: true, at: date(1201))
        XCTAssertEqual(journal.duration(sessionId: "same"), 3000)
        journal.observe(foreground: true, at: date(1201)) // checkpoint rearms recovery
        journal.sample(foreground: true, at: date(1202))
        let restored = GameAlgoLifecycleJournal(storage: storage, key: "journal")
        restored.activate(template("next"), startedAt: date(9000), hasEnd: false, foreground: true, pending: [])
        let recovered = try XCTUnwrap(restored.pending().first { $0.payload["reason"] == .string("process_restart") })
        XCTAssertEqual(recovered.payload["sessionDurationMs"], .number(3000), "only the last durable duration is recovered")
        journal.activate(template("same"), startedAt: date(1000), hasEnd: false, foreground: nil, pending: [])
        XCTAssertEqual(journal.duration(sessionId: "same"), 4000, "metadata refresh keeps duration")
        journal.activate(template("next"), startedAt: date(1202), hasEnd: false, foreground: nil, pending: [])
        XCTAssertEqual(journal.duration(sessionId: "next"), 0)
    }

    func testBackgroundDuringAnInflightUploadIsNotLostOrRemovedByItsAck() async throws {
        let uploader = LifecycleUploader(blockFirst: true)
        let tracker = GameAlgoEventTracker(uploader: uploader, flushInterval: 0, storage: storage(),
                                          persistenceKey: "queue", now: { Date(timeIntervalSince1970: 1000) })
        await tracker.identify(userId: "user", sessionId: "session")
        await tracker.setContextId("ctx")
        await tracker.enableLifecycle(foreground: true)
        _ = await tracker.trackLevelStart()
        let first = Task { await tracker.flush() }
        while !(await uploader.started) { await Task.yield() }
        tracker.lifecycleJournal.observe(foreground: false, at: date(1010))
        let background = Task { await tracker.flush() }
        XCTAssertEqual(tracker.lifecycleJournal.pending().count, 2, "both the in-flight row and new end are durable")
        await uploader.release()
        await first.value
        await background.value
        let events = await uploader.events
        XCTAssertEqual(events.map(\.eventType), ["level_start", "session_end"])
        XCTAssertTrue(tracker.lifecycleJournal.pending().isEmpty)
    }

    func testUnboundRecoveryRetainsTheOldConfigRequestAndContextOwnership() async throws {
        let storage = storage()
        let first = GameAlgoLifecycleJournal(storage: storage, key: "queue:lifecycle")
        first.activate(template("old", context: ""), startedAt: date(1000), hasEnd: false, foreground: true, pending: [])
        first.retainConfig(sessionId: "old", body: Data("{\"sessionId\":\"old\",\"userId\":\"user\"}".utf8))
        first.observe(foreground: true, at: date(1010))
        let uploader = LifecycleUploader()
        let tracker = GameAlgoEventTracker(uploader: uploader, flushInterval: 0, storage: storage,
                                          persistenceKey: "queue", now: { Date(timeIntervalSince1970: 9000) })
        await tracker.identify(userId: "user", sessionId: "new")
        await tracker.enableLifecycle(foreground: true)
        await tracker.setLifecycleContextRecovery { body in
            let request = try JSONSerialization.jsonObject(with: body) as! [String: String]
            XCTAssertEqual(request["sessionId"], "old")
            return "old-context"
        }
        await tracker.flush()
        let events = await uploader.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sessionId, "old")
        XCTAssertEqual(events[0].contextId, "old-context")
        let session = await tracker.currentSessionId()
        XCTAssertEqual(session, "new")
    }
}

private actor LifecycleUploader: GameAlgoEventBatchUploading {
    private(set) var events: [GameAlgoEvent] = []
    private(set) var started = false
    private var blockFirst: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }
    func uploadEvents(_ batch: [GameAlgoEvent]) async throws -> GameAlgoEventBatchResponse {
        started = true
        if blockFirst { blockFirst = false; await withCheckedContinuation { waiter = $0 } }
        events.append(contentsOf: batch)
        return GameAlgoEventBatchResponse(ok: true, accepted: batch.count)
    }
    func release() { waiter?.resume(); waiter = nil }
}
