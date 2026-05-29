import CryptoKit
import Foundation
import JavaScriptCore

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

public final class JavaScriptCoreGameAlgoScriptRuntime: GameAlgoScriptRuntime, @unchecked Sendable {
    public init() {}

    public func execute(script: String, input: GameAlgoScriptInput) throws -> JSONValue {
        guard let context = JSContext() else {
            throw GameAlgoError.scriptExecutionFailed("Failed to create JSContext")
        }

        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }

        let jsonInput = input.jsonValue
        context.setObject(jsonInput.foundationValue, forKeyedSubscript: "__gameAlgoInput" as NSString)
        context.evaluateScript(script)
        if let exceptionMessage {
            throw GameAlgoError.scriptExecutionFailed(exceptionMessage)
        }

        guard let execute = context.objectForKeyedSubscript("execute"), !execute.isUndefined else {
            throw GameAlgoError.scriptExecutionFailed("Script must define execute(input)")
        }
        guard let result = execute.call(withArguments: [jsonInput.foundationValue]) else {
            throw GameAlgoError.scriptExecutionFailed("execute(input) returned nil")
        }
        if let exceptionMessage {
            throw GameAlgoError.scriptExecutionFailed(exceptionMessage)
        }

        context.setObject(result, forKeyedSubscript: "__gameAlgoResult" as NSString)
        guard let json = context.evaluateScript("JSON.stringify(__gameAlgoResult)")?.toString(),
              json != "undefined",
              !json.isEmpty
        else {
            throw GameAlgoError.decodingFailed("Script result is not JSON serializable")
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}

enum GameAlgoSHA256 {
    static func hash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
