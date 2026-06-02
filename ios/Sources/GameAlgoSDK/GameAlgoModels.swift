import Foundation

public enum GameAlgoPlatform: String, Sendable, Equatable, Codable {
    case ios
    case android
    case rest
}

public enum GameAlgoEnvironment: String, Sendable, Equatable, Codable {
    case test
    case live
}

public struct GameAlgoExperimentAssignment: Sendable, Equatable, Codable {
    public let key: String
    public let experimentId: String
    public let variant: String
    public let config: JSONValue
    public let script: GameAlgoConfigFileRef?

    public init(
        key: String,
        experimentId: String,
        variant: String,
        config: JSONValue,
        script: GameAlgoConfigFileRef? = nil
    ) {
        self.key = key
        self.experimentId = experimentId
        self.variant = variant
        self.config = config
        self.script = script
    }
}

public struct GameAlgoConfigFileRef: Sendable, Equatable, Codable {
    public let name: String
    public let url: URL
    public let hash: String
    public let contentType: String?
    public let updatedAt: String?

    public init(
        name: String,
        url: URL,
        hash: String,
        contentType: String? = nil,
        updatedAt: String? = nil
    ) {
        self.name = name
        self.url = url
        self.hash = hash
        self.contentType = contentType
        self.updatedAt = updatedAt
    }
}

public struct GameAlgoConfigResponse: Sendable, Equatable, Codable {
    public let contextId: String
    public let gameId: String
    public let environment: GameAlgoEnvironment
    public let configVersion: String
    public let ttlSeconds: Int
    public let serverTime: String
    public let experiments: [GameAlgoExperimentAssignment]
    public let configFiles: [GameAlgoConfigFileRef]

    public init(
        contextId: String,
        gameId: String,
        environment: GameAlgoEnvironment,
        configVersion: String,
        ttlSeconds: Int,
        serverTime: String,
        experiments: [GameAlgoExperimentAssignment],
        configFiles: [GameAlgoConfigFileRef]
    ) {
        self.contextId = contextId
        self.gameId = gameId
        self.environment = environment
        self.configVersion = configVersion
        self.ttlSeconds = ttlSeconds
        self.serverTime = serverTime
        self.experiments = experiments
        self.configFiles = configFiles
    }
}

public struct GameAlgoConfigFile: Sendable, Equatable, Codable {
    public let name: String
    public let content: String
    public let contentType: String
    public let etag: String?

    public init(
        name: String,
        content: String,
        contentType: String,
        etag: String? = nil
    ) {
        self.name = name
        self.content = content
        self.contentType = contentType
        self.etag = etag
    }
}

public struct GameAlgoEvent: Sendable, Equatable, Codable {
    public var eventId: String?
    public var contextId: String
    public var userId: String
    public var sessionId: String
    public var eventType: String
    public var isDebug: Bool?
    public var timestamp: String?
    public var dimensions: [String: JSONValue]
    public var metrics: [GameAlgoEventMetric]

    public init(
        eventId: String? = nil,
        contextId: String,
        userId: String,
        sessionId: String,
        eventType: String,
        isDebug: Bool? = nil,
        timestamp: String? = nil,
        dimensions: [String: JSONValue] = [:],
        metrics: [GameAlgoEventMetric] = []
    ) {
        self.eventId = eventId
        self.contextId = contextId
        self.userId = userId
        self.sessionId = sessionId
        self.eventType = eventType
        self.isDebug = isDebug
        self.timestamp = timestamp
        self.dimensions = dimensions
        self.metrics = metrics
    }
}

public struct GameAlgoEventMetric: Sendable, Equatable, Codable {
    public var key: String
    public var value: Double

    public init(key: String, value: Double) {
        self.key = key
        self.value = value
    }
}

public struct GameAlgoEventBatchResponse: Sendable, Equatable, Codable {
    public let ok: Bool
    public let accepted: Int

    public init(ok: Bool, accepted: Int) {
        self.ok = ok
        self.accepted = accepted
    }
}

public struct GameAlgoExecutionResult: Sendable, Equatable {
    public let payload: JSONValue
    public let diagnostics: JSONValue
    public let assignment: GameAlgoExperimentAssignment

    public init(payload: JSONValue, diagnostics: JSONValue, assignment: GameAlgoExperimentAssignment) {
        self.payload = payload
        self.diagnostics = diagnostics
        self.assignment = assignment
    }
}
