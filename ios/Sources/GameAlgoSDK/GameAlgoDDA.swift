import Foundation

public enum GameAlgoDDAAdjustment: String, Sendable, Codable {
    case increase
    case keep
    case decrease
}

public struct GameAlgoDDADecision: Sendable, Equatable {
    public let adjustment: GameAlgoDDAAdjustment
    public let payload: JSONValue
    public let diagnostics: JSONValue
    public let assignment: GameAlgoExperimentAssignment?
    public let isFallback: Bool
}

public protocol GameAlgoDDAStorage: Sendable {
    func load(key: String) throws -> Data?
    func save(_ data: Data, key: String) throws
    func remove(key: String) throws
}

public final class GameAlgoUserDefaultsDDAStorage: GameAlgoDDAStorage, @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load(key: String) throws -> Data? {
        userDefaults.data(forKey: key)
    }

    public func save(_ data: Data, key: String) throws {
        userDefaults.set(data, forKey: key)
    }

    public func remove(key: String) throws {
        userDefaults.removeObject(forKey: key)
    }
}

private struct GameAlgoDDAStoredStep: Codable {
    var stepId: String?
    var behaviors: [String: Double]
}

private struct GameAlgoDDAStoredState: Codable {
    var schemaVersion = 1
    var current: [String: Double] = [:]
    var lifetime: [String: Double] = [:]
    var recentSteps: [GameAlgoDDAStoredStep] = []
    var completedSteps = 0
}

public final class GameAlgoDDAController: @unchecked Sendable {
    private let executor: GameAlgoExperimentExecutor
    private let storage: (any GameAlgoDDAStorage)?
    private let storageKey: String
    private let recentWindowSize: Int
    private let logger: GameAlgoLogHandler?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var state: GameAlgoDDAStoredState

    init(
        executor: GameAlgoExperimentExecutor,
        storage: (any GameAlgoDDAStorage)?,
        storageKey: String,
        recentWindowSize: Int,
        logger: GameAlgoLogHandler?
    ) {
        precondition((1...100).contains(recentWindowSize), "recentWindowSize must be between 1 and 100")
        self.executor = executor
        self.storage = storage
        self.storageKey = storageKey
        self.recentWindowSize = recentWindowSize
        self.logger = logger
        if let storage,
           let data = try? storage.load(key: storageKey),
           let decoded = try? decoder.decode(GameAlgoDDAStoredState.self, from: data) {
            var restored = decoded
            if restored.recentSteps.count > recentWindowSize {
                restored.recentSteps.removeFirst(restored.recentSteps.count - recentWindowSize)
            }
            self.state = restored
        } else {
            self.state = GameAlgoDDAStoredState()
        }
    }

    public func recordBehavior(_ type: String, amount: Double = 1) throws {
        let behaviorType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !behaviorType.isEmpty else { throw GameAlgoError.invalidDDA("behavior type is required") }
        guard behaviorType.count <= 128 else { throw GameAlgoError.invalidDDA("behavior type must be at most 128 characters") }
        guard amount.isFinite, amount > 0 else { throw GameAlgoError.invalidDDA("behavior amount must be greater than 0") }
        lock.lock()
        state.current[behaviorType, default: 0] += amount
        state.lifetime[behaviorType, default: 0] += amount
        persistLocked()
        lock.unlock()
    }

    public func completeStep(_ stepId: String? = nil) {
        lock.lock()
        state.recentSteps.append(GameAlgoDDAStoredStep(
            stepId: stepId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            behaviors: state.current
        ))
        if state.recentSteps.count > recentWindowSize {
            state.recentSteps.removeFirst(state.recentSteps.count - recentWindowSize)
        }
        state.current = [:]
        state.completedSteps += 1
        persistLocked()
        lock.unlock()
    }

    public func reset(_ scope: String = "all") throws {
        lock.lock()
        defer { lock.unlock() }
        switch scope {
        case "all": state = GameAlgoDDAStoredState()
        case "current": state.current = [:]
        case "recent": state.recentSteps = []
        default: throw GameAlgoError.invalidDDA("unsupported reset scope: \(scope)")
        }
        persistLocked()
    }

    public func snapshot(context: JSONValue = .object([:])) -> JSONValue {
        lock.lock()
        let state = self.state
        lock.unlock()
        var recent: [String: Double] = [:]
        state.recentSteps.forEach { step in
            step.behaviors.forEach { recent[$0.key, default: 0] += $0.value }
        }
        return .object([
            "context": context,
            "behavior": .object([
                "current": countsJSON(state.current),
                "recent": countsJSON(recent),
                "lifetime": countsJSON(state.lifetime),
                "recentSteps": .array(state.recentSteps.map { step in
                    var object: [String: JSONValue] = ["behaviors": countsJSON(step.behaviors)]
                    if let stepId = step.stepId { object["stepId"] = .string(stepId) }
                    return .object(object)
                }),
                "completedSteps": .number(Double(state.completedSteps)),
                "windowSize": .number(Double(recentWindowSize)),
            ]),
        ])
    }

    public func decide(context: JSONValue = .object([:])) -> GameAlgoDDADecision {
        guard let execution = executor.execute(snapshot(context: context)) else {
            return fallback(reason: "executor_not_ready")
        }
        guard let rawAdjustment = execution.payload["adjustment"]?.stringValue,
              let adjustment = GameAlgoDDAAdjustment(rawValue: rawAdjustment) else {
            return fallback(reason: "invalid_adjustment", assignment: execution.assignment)
        }
        return GameAlgoDDADecision(
            adjustment: adjustment,
            payload: execution.payload,
            diagnostics: execution.diagnostics,
            assignment: execution.assignment,
            isFallback: false
        )
    }

    private func persistLocked() {
        guard let storage else { return }
        do {
            try storage.save(encoder.encode(state), key: storageKey)
        } catch {
            logger?("[GameAlgoSDK] DDA state save failed: \(error)")
        }
    }

    private func fallback(reason: String, assignment: GameAlgoExperimentAssignment? = nil) -> GameAlgoDDADecision {
        GameAlgoDDADecision(
            adjustment: .keep,
            payload: .object(["adjustment": .string("keep")]),
            diagnostics: .object(["fallback": .bool(true), "reason": .string(reason)]),
            assignment: assignment,
            isFallback: true
        )
    }
}

final class GameAlgoDDAControllerStore: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: (any GameAlgoDDAStorage)?
    private let storagePrefix: String
    private let logger: GameAlgoLogHandler?
    private var controllers: [String: GameAlgoDDAController] = [:]

    init(storage: (any GameAlgoDDAStorage)?, storagePrefix: String, logger: GameAlgoLogHandler?) {
        self.storage = storage
        self.storagePrefix = storagePrefix
        self.logger = logger
    }

    func controller(key: String, executor: GameAlgoExperimentExecutor, recentWindowSize: Int) -> GameAlgoDDAController {
        lock.lock()
        defer { lock.unlock() }
        if let existing = controllers[key] { return existing }
        let controller = GameAlgoDDAController(
            executor: executor,
            storage: storage,
            storageKey: "\(storagePrefix):\(key)",
            recentWindowSize: recentWindowSize,
            logger: logger
        )
        controllers[key] = controller
        return controller
    }
}

private func countsJSON(_ counts: [String: Double]) -> JSONValue {
    .object(counts.mapValues(JSONValue.number))
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
