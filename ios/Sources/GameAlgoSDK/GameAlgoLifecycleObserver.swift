#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class GameAlgoLifecycleObserver {
    private let journal: GameAlgoLifecycleJournal
    private weak var tracker: GameAlgoEventTracker?
    private let now: @Sendable () -> Date
    private var tokens: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    private var foreground: Bool
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var upload: Task<Void, Never>?
    private var generation = 0

    init(journal: GameAlgoLifecycleJournal, tracker: GameAlgoEventTracker, now: @escaping @Sendable () -> Date) {
        self.journal = journal
        self.tracker = tracker
        self.now = now
        foreground = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.background() }
        })
        tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.resume() }
        })
        tokens.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.background() }
        })
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.foreground else { return }
                self.journal.observe(foreground: true, at: self.now())
            }
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
        journal.observe(foreground: foreground, at: now())
    }

    private func resume() {
        foreground = true
        journal.observe(foreground: true, at: now())
    }

    private func background() {
        foreground = false
        // The durable end exists before scheduling any actor or network work.
        journal.observe(foreground: false, at: now())
        finishUpload()
        generation += 1
        let current = generation
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GameAlgo session end") { [weak self] in
            Task { @MainActor in self?.finishUpload(generation: current) }
        }
        upload = Task { [weak self] in
            guard let self else { return }
            await self.tracker?.flush()
            self.finishUpload(generation: current)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finishUpload(generation: current) }
    }

    private func finishUpload(generation expected: Int? = nil) {
        if let expected, expected != generation { return }
        upload?.cancel()
        upload = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        heartbeat?.invalidate()
        heartbeat = nil
        finishUpload()
    }
}
#endif
