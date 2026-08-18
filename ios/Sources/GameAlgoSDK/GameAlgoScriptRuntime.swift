import CryptoKit
import Foundation
import GameAlgoScriptRuntime

public struct GameAlgoScriptInput: Sendable, Equatable {
    public struct Meta: Sendable, Equatable {
        public let gameId: String
        public let userId: String
        public let environment: GameAlgoEnvironment
        public let strategy: String
        public let experimentId: String
        public let variant: String

        public init(
            gameId: String,
            userId: String,
            environment: GameAlgoEnvironment,
            strategy: String,
            experimentId: String,
            variant: String
        ) {
            self.gameId = gameId
            self.userId = userId
            self.environment = environment
            self.strategy = strategy
            self.experimentId = experimentId
            self.variant = variant
        }
    }

    public let state: JSONValue
    public let config: JSONValue
    public let meta: Meta

    var jsonValue: JSONValue {
        .object([
            "state": state,
            "config": config,
            "meta": .object([
                "gameId": .string(meta.gameId),
                "userId": .string(meta.userId),
                "environment": .string(meta.environment.rawValue),
                "strategy": .string(meta.strategy),
                "experimentId": .string(meta.experimentId),
                "variant": .string(meta.variant),
            ]),
        ])
    }
}

public protocol GameAlgoScriptRuntime: Sendable {
    func prepare(script: String) throws
    func execute(script: String, input: GameAlgoScriptInput) throws -> JSONValue
}

public extension GameAlgoScriptRuntime {
    func prepare(script: String) throws {}
}

public final class RustGameAlgoScriptRuntime: GameAlgoScriptRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var preparedScript: String?
    private var preparedHandle: UnsafeMutableRawPointer?

    public init() {}

    deinit {
        if let preparedHandle {
            gamealgo_runtime_release(preparedHandle)
        }
    }

    public func prepare(script: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareLocked(script: script)
    }

    public func execute(script: String, input: GameAlgoScriptInput) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        try prepareLocked(script: script)
        let encoded = try JSONEncoder().encode(input.jsonValue)
        guard let requestString = String(data: encoded, encoding: .utf8) else {
            throw GameAlgoError.decodingFailed("Failed to encode script runtime request")
        }
        guard let preparedHandle else {
            throw GameAlgoError.scriptExecutionFailed("Rust runtime script is not prepared")
        }
        let responsePointer = requestString.withCString {
            gamealgo_runtime_execute_prepared(preparedHandle, $0)
        }
        guard let responsePointer else {
            throw GameAlgoError.scriptExecutionFailed("Rust runtime returned no response")
        }
        defer { gamealgo_runtime_free(responsePointer) }
        let responseData = Data(String(cString: responsePointer).utf8)
        let response = try JSONDecoder().decode(RuntimeResponse.self, from: responseData)
        guard response.status == "ok", let result = response.result else {
            throw GameAlgoError.scriptExecutionFailed(response.message ?? "Script execution failed")
        }
        return result
    }

    private func prepareLocked(script: String) throws {
        if preparedScript == script, preparedHandle != nil {
            return
        }
        let responsePointer = script.withCString { gamealgo_runtime_prepare($0) }
        guard let responsePointer else {
            throw GameAlgoError.scriptExecutionFailed("Rust runtime returned no prepare response")
        }
        defer { gamealgo_runtime_free(responsePointer) }
        let responseData = Data(String(cString: responsePointer).utf8)
        let response = try JSONDecoder().decode(PrepareRuntimeResponse.self, from: responseData)
        guard response.status == "ok", let handle = response.handle,
              let nextHandle = UnsafeMutableRawPointer(bitPattern: UInt(handle)) else {
            throw GameAlgoError.scriptExecutionFailed(response.message ?? "Script preparation failed")
        }
        if let preparedHandle {
            gamealgo_runtime_release(preparedHandle)
        }
        preparedHandle = nextHandle
        preparedScript = script
    }
}

private struct RuntimeResponse: Decodable {
    let status: String
    let result: JSONValue?
    let message: String?
}

private struct PrepareRuntimeResponse: Decodable {
    let status: String
    let handle: UInt64?
    let message: String?
}

enum GameAlgoSHA256 {
    static func hash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
