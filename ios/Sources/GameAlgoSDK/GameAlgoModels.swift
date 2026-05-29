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
    public let gameId: String
    public let environment: GameAlgoEnvironment
    public let configVersion: String
    public let ttlSeconds: Int
    public let serverTime: String
    public let experiments: [GameAlgoExperimentAssignment]
    public let configFiles: [GameAlgoConfigFileRef]

    public init(
        gameId: String,
        environment: GameAlgoEnvironment,
        configVersion: String,
        ttlSeconds: Int,
        serverTime: String,
        experiments: [GameAlgoExperimentAssignment],
        configFiles: [GameAlgoConfigFileRef]
    ) {
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
    public var userId: String
    public var sessionId: String
    public var eventType: String
    public var platform: GameAlgoPlatform?
    public var sdkVersion: String?
    public var appVersion: String?
    public var timezone: String?
    public var isDebug: Bool?
    public var timestamp: String?
    public var payload: JSONValue

    public init(
        eventId: String? = nil,
        userId: String,
        sessionId: String,
        eventType: String,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        timezone: String? = TimeZone.current.identifier,
        isDebug: Bool? = nil,
        timestamp: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.eventId = eventId
        self.userId = userId
        self.sessionId = sessionId
        self.eventType = eventType
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
        self.timezone = timezone ?? TimeZone.current.identifier
        self.isDebug = isDebug
        self.timestamp = timestamp
        self.payload = payload
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
