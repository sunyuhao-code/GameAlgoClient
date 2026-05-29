import Foundation

public struct GameAlgoSnapshot: Sendable, Equatable, Codable {
    public let config: GameAlgoConfigResponse?
    public let configFiles: [String: GameAlgoConfigFile]
    public let updatedAt: Date?
    public let userId: String?

    public init(
        config: GameAlgoConfigResponse? = nil,
        configFiles: [String: GameAlgoConfigFile] = [:],
        updatedAt: Date? = nil,
        userId: String? = nil
    ) {
        self.config = config
        self.configFiles = configFiles
        self.updatedAt = updatedAt
        self.userId = userId
    }
}

public enum GameAlgoConfigFilePreload: Sendable, Equatable {
    case all
    case none
    case names([String])
}

final class GameAlgoSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current = GameAlgoSnapshot()

    func snapshot() -> GameAlgoSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func replace(_ snapshot: GameAlgoSnapshot) {
        lock.lock()
        current = snapshot
        lock.unlock()
    }

    func updateConfig(_ config: GameAlgoConfigResponse, updatedAt: Date, userId: String) {
        lock.lock()
        current = GameAlgoSnapshot(
            config: config,
            configFiles: current.configFiles,
            updatedAt: updatedAt,
            userId: userId
        )
        lock.unlock()
    }

    func updateConfigFile(_ file: GameAlgoConfigFile, updatedAt: Date) {
        lock.lock()
        var files = current.configFiles
        files[file.name] = file
        current = GameAlgoSnapshot(
            config: current.config,
            configFiles: files,
            updatedAt: updatedAt,
            userId: current.userId
        )
        lock.unlock()
    }
}

public final class GameAlgoExperimentExecutor: @unchecked Sendable {
    private let key: String
    private let store: GameAlgoSnapshotStore
    private let scriptRuntime: any GameAlgoScriptRuntime

    init(key: String, store: GameAlgoSnapshotStore, scriptRuntime: any GameAlgoScriptRuntime) {
        self.key = key
        self.store = store
        self.scriptRuntime = scriptRuntime
    }

    public var isReady: Bool {
        assignment() != nil
    }

    public func assignment() -> GameAlgoExperimentAssignment? {
        store.snapshot().config?.experiments.first { $0.key == key }
    }

    public func variant(default defaultValue: String = "control") -> String {
        assignment()?.variant ?? defaultValue
    }

    public func config(default defaultValue: JSONValue = .object([:])) -> JSONValue {
        assignment()?.config ?? defaultValue
    }

    public func value(_ path: String, default defaultValue: JSONValue = .null) -> JSONValue {
        guard let config = assignment()?.config else { return defaultValue }
        return config.value(at: path) ?? defaultValue
    }

    public func string(_ path: String, default defaultValue: String = "") -> String {
        value(path).stringValue ?? defaultValue
    }

    public func int(_ path: String, default defaultValue: Int = 0) -> Int {
        value(path).intValue ?? defaultValue
    }

    public func double(_ path: String, default defaultValue: Double = 0) -> Double {
        value(path).doubleValue ?? defaultValue
    }

    public func bool(_ path: String, default defaultValue: Bool = false) -> Bool {
        value(path).boolValue ?? defaultValue
    }

    public func execute(_ state: JSONValue) -> GameAlgoExecutionResult? {
        let snapshot = store.snapshot()
        guard let config = snapshot.config, let assignment = assignment() else { return nil }
        guard let script = assignment.script else {
            return GameAlgoExecutionResult(
                payload: assignment.config,
                diagnostics: .object(["mode": .string("config-only")]),
                assignment: assignment
            )
        }
        guard let file = snapshot.configFiles[script.name] else { return nil }
        guard Self.sha256(file.content) == script.hash else { return nil }

        let input = GameAlgoScriptInput(
            state: state,
            config: assignment.config,
            meta: GameAlgoScriptInput.Meta(
                gameId: config.gameId,
                userId: snapshot.userId ?? "",
                environment: config.environment,
                strategy: assignment.key,
                experimentId: assignment.experimentId,
                variant: assignment.variant
            )
        )
        guard
            let output = try? scriptRuntime.execute(script: file.content, input: input),
            let object = output.objectValue,
            let payload = object["payload"]
        else {
            return nil
        }
        return GameAlgoExecutionResult(
            payload: payload,
            diagnostics: object["diagnostics"] ?? .object([:]),
            assignment: assignment
        )
    }

    private static func sha256(_ content: String) -> String {
        GameAlgoSHA256.hash(content)
    }
}

public final class GameAlgoConfigReader: @unchecked Sendable {
    private let store: GameAlgoSnapshotStore

    init(store: GameAlgoSnapshotStore) {
        self.store = store
    }

    public func file(_ name: String) -> GameAlgoConfigFile? {
        store.snapshot().configFiles[name]
    }

    public func jsonFile(_ name: String, default defaultValue: JSONValue = .object([:])) -> JSONValue {
        guard let file = file(name) else { return defaultValue }
        return Self.decodeJSON(file.content) ?? defaultValue
    }

    public func value(_ path: String, default defaultValue: JSONValue = .null, fileName: String? = nil) -> JSONValue {
        guard let source = jsonSource(fileName: fileName) else { return defaultValue }
        return source.value(at: path) ?? defaultValue
    }

    public func string(_ path: String, default defaultValue: String = "", fileName: String? = nil) -> String {
        value(path, fileName: fileName).stringValue ?? defaultValue
    }

    public func int(_ path: String, default defaultValue: Int = 0, fileName: String? = nil) -> Int {
        value(path, fileName: fileName).intValue ?? defaultValue
    }

    public func double(_ path: String, default defaultValue: Double = 0, fileName: String? = nil) -> Double {
        value(path, fileName: fileName).doubleValue ?? defaultValue
    }

    public func bool(_ path: String, default defaultValue: Bool = false, fileName: String? = nil) -> Bool {
        value(path, fileName: fileName).boolValue ?? defaultValue
    }

    private func jsonSource(fileName: String?) -> JSONValue? {
        let snapshot = store.snapshot()
        if let fileName {
            guard let file = snapshot.configFiles[fileName] else { return nil }
            return Self.decodeJSON(file.content)
        }

        let jsonFiles = snapshot.configFiles.values.filter {
            $0.contentType.contains("application/json") || $0.name.hasSuffix(".json")
        }
        guard jsonFiles.count == 1, let file = jsonFiles.first else { return nil }
        return Self.decodeJSON(file.content)
    }

    private static func decodeJSON(_ content: String) -> JSONValue? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

private extension JSONValue {
    func value(at path: String) -> JSONValue? {
        if path.isEmpty { return self }

        var current: JSONValue? = self
        for segment in path.split(separator: ".").map(String.init) {
            guard let value = current else { return nil }
            switch value {
            case let .object(object):
                current = object[segment]
            case let .array(array):
                guard let index = Int(segment), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }
}
