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
    func execute(script: String, input: GameAlgoScriptInput) throws -> JSONValue
}

public final class RustGameAlgoScriptRuntime: GameAlgoScriptRuntime, @unchecked Sendable {
    public init() {}

    public func execute(script: String, input: GameAlgoScriptInput) throws -> JSONValue {
        let request = RuntimeRequest(script: script, input: input.jsonValue)
        let encoded = try JSONEncoder().encode(request)
        guard let requestString = String(data: encoded, encoding: .utf8) else {
            throw GameAlgoError.decodingFailed("Failed to encode script runtime request")
        }
        let responsePointer = requestString.withCString { gamealgo_runtime_execute($0) }
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
}

private struct RuntimeRequest: Encodable {
    let script: String
    let input: JSONValue
}

private struct RuntimeResponse: Decodable {
    let status: String
    let result: JSONValue?
    let message: String?
}

enum GameAlgoSHA256 {
    static func hash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
