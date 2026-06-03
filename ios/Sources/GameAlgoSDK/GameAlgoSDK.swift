import Foundation
#if canImport(UIKit)
import UIKit
#endif

public actor GameAlgoSDK {
    public static let defaultSDKVersion = "1.0.0"

    private let gameKey: String
    private let baseURL: URL
    private let defaultPlatform: GameAlgoPlatform
    private let defaultSDKVersion: String
    private let defaultAppVersion: String?
    private let httpClient: any GameAlgoHTTPClient
    private let scriptRuntime: any GameAlgoScriptRuntime
    private let cacheStorage: (any GameAlgoCacheStorage)?
    private let userIdentityStore: GameAlgoUserIdentityStore
    private let snapshotCacheKey: String
    private let now: @Sendable () -> Date
    private let logger: GameAlgoLogHandler?
    private let snapshotStore: GameAlgoSnapshotStore
    private let eventUploader: any GameAlgoEventBatchUploading
    private let readyTaskStore = GameAlgoReadyTaskStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public nonisolated let config: GameAlgoConfigReader
    public nonisolated let tracker: GameAlgoEventTracker

    private var cachedConfig: CachedConfig?
    private var didLogUserId = false

    public init(
        gameKey: String,
        baseURL: URL,
        sdkVersion: String = GameAlgoSDK.defaultSDKVersion,
        appVersion: String? = nil,
        platform: GameAlgoPlatform = .ios,
        httpClient: any GameAlgoHTTPClient = URLSessionGameAlgoHTTPClient(),
        scriptRuntime: any GameAlgoScriptRuntime = JavaScriptCoreGameAlgoScriptRuntime(),
        cacheStorage: (any GameAlgoCacheStorage)? = GameAlgoUserDefaultsCacheStorage(),
        userIdentityStore: GameAlgoUserIdentityStore = GameAlgoUserIdentityStore(),
        cacheKey: String? = nil,
        isDebug: Bool = false,
        eventFlushInterval: TimeInterval = 30,
        eventMaxBatchSize: Int = 100,
        eventQueueLimit: Int = 1000,
        logger: GameAlgoLogHandler? = GameAlgoLoggers.console,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let snapshotStore = GameAlgoSnapshotStore()
        let initialIdentity = userIdentityStore.identity(now: now())
        let eventUploader = GameAlgoEventBatchUploader(
            gameKey: gameKey,
            baseURL: baseURL,
            defaultPlatform: platform,
            defaultSDKVersion: sdkVersion,
            defaultAppVersion: appVersion,
            httpClient: httpClient,
            now: now
        )
        self.gameKey = gameKey
        self.baseURL = baseURL
        self.defaultSDKVersion = sdkVersion
        self.defaultAppVersion = appVersion
        self.defaultPlatform = platform
        self.httpClient = httpClient
        self.scriptRuntime = scriptRuntime
        self.cacheStorage = cacheStorage
        self.userIdentityStore = userIdentityStore
        self.snapshotCacheKey = cacheKey ?? "gamealgo:v1:snapshot:\(baseURL.absoluteString):\(gameKey.prefix(16))"
        self.now = now
        self.logger = logger
        self.snapshotStore = snapshotStore
        self.eventUploader = eventUploader
        self.config = GameAlgoConfigReader(store: snapshotStore)
        self.tracker = GameAlgoEventTracker(
            uploader: eventUploader,
            maxBatchSize: eventMaxBatchSize,
            queueLimit: eventQueueLimit,
            flushInterval: eventFlushInterval,
            isDebug: isDebug,
            initialIdentity: initialIdentity,
            logger: logger,
            now: now
        )
    }

    public nonisolated var userIdentity: GameAlgoUserIdentity {
        userIdentityStore.identity(now: now())
    }

    public nonisolated var userId: String {
        userIdentity.userId
    }

    public nonisolated func executor(_ key: String) -> GameAlgoExperimentExecutor {
        GameAlgoExperimentExecutor(key: key, store: snapshotStore, scriptRuntime: scriptRuntime, logger: logger)
    }

    public nonisolated func snapshotValue() -> GameAlgoSnapshot {
        snapshotStore.snapshot()
    }

    @discardableResult
    public nonisolated func start(
        userId: String? = nil,
        sessionId: String? = nil,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        deviceId: String? = nil,
        timezone: String? = nil,
        device: [String: JSONValue] = [:],
        preloadConfigFiles: GameAlgoConfigFilePreload = .all
    ) -> Task<Void, Error> {
        let identity = userIdentityStore.identity(userId: userId, now: now())
        let task = Task {
            await self.logUserId(identity.userId)
            await self.tracker.identify(
                userId: identity.userId,
                sessionId: sessionId,
                platform: platform ?? self.defaultPlatform,
                sdkVersion: sdkVersion ?? self.defaultSDKVersion,
                appVersion: appVersion ?? self.defaultAppVersion,
                timezone: timezone,
                userCreatedAt: identity.userCreatedAt
            )
            await self.tracker.markSessionStarted()
            await self.loadCachedSnapshot()
            do {
                try await self.refresh(
                    userId: identity.userId,
                    sessionId: sessionId,
                    platform: platform,
                    sdkVersion: sdkVersion,
                    appVersion: appVersion,
                    deviceId: deviceId,
                    timezone: timezone,
                    device: device,
                    preloadConfigFiles: preloadConfigFiles
                )
            } catch {
                if self.snapshotValue().config == nil {
                    await self.log("config fetch failed: \(error)")
                    throw error
                }
                await self.log("config fetch failed, using cached snapshot: \(error)")
            }
        }
        readyTaskStore.set(task)
        return task
    }

    public nonisolated func waitForReady(timeout: TimeInterval = 5.0) async -> Bool {
        guard let readyTask = readyTaskStore.get() else {
            return snapshotStore.snapshot().config != nil
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await readyTask.value
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    public func fetchConfig(
        userId: String? = nil,
        sessionId: String? = nil,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        deviceId: String? = nil,
        timezone: String? = nil,
        device: [String: JSONValue] = [:],
        forceRefresh: Bool = false
    ) async throws -> GameAlgoConfigResponse {
        let identity = userIdentityStore.identity(userId: userId, now: now())
        logUserId(identity.userId)
        let resolvedUserCreatedAt = identity.userCreatedAt
        let resolvedPlatform = platform ?? defaultPlatform
        let resolvedSDKVersion = sdkVersion ?? defaultSDKVersion
        let resolvedAppVersion = appVersion ?? defaultAppVersion
        await tracker.identify(
            userId: identity.userId,
            sessionId: sessionId,
            platform: resolvedPlatform,
            sdkVersion: resolvedSDKVersion,
            appVersion: resolvedAppVersion,
            timezone: timezone,
            userCreatedAt: identity.userCreatedAt
        )
        let resolvedSessionId = await tracker.currentSessionId()
        let resolvedTimezone = clean(timezone) ?? TimeZone.current.identifier
        var resolvedDevice = defaultDeviceContext()
        for (key, value) in device {
            resolvedDevice[key] = value
        }
        if let deviceId = clean(deviceId) {
            resolvedDevice["deviceId"] = .string(deviceId)
        }
        let cacheKey = ConfigCacheKey(
            userId: identity.userId,
            userCreatedAt: resolvedUserCreatedAt,
            sessionId: resolvedSessionId,
            platform: resolvedPlatform,
            sdkVersion: resolvedSDKVersion,
            appVersion: resolvedAppVersion,
            timezone: resolvedTimezone,
            device: resolvedDevice
        )

        if !forceRefresh,
           let cachedConfig,
           cachedConfig.key == cacheKey,
           cachedConfig.expiresAt > now() {
            log("config cache hit: \(cachedConfig.value.configVersion)")
            return cachedConfig.value
        }

        do {
            log("fetching config: userId=\(identity.userId), platform=\(resolvedPlatform.rawValue)")
            let requestBody = ConfigRequest(
                userId: identity.userId,
                userCreatedAt: resolvedUserCreatedAt,
                sessionId: resolvedSessionId,
                platform: resolvedPlatform,
                sdkVersion: resolvedSDKVersion,
                appVersion: resolvedAppVersion,
                timezone: resolvedTimezone,
                device: resolvedDevice
            )

            let response: GameAlgoConfigResponse = try await requestJSON(
                GameAlgoHTTPRequest(
                    url: try endpoint("/v1/config"),
                    method: .post,
                    headers: ["content-type": "application/json"],
                    body: try encode(requestBody)
                )
            )
            cachedConfig = CachedConfig(
                key: cacheKey,
                value: response,
                expiresAt: now().addingTimeInterval(TimeInterval(max(response.ttlSeconds, 0)))
            )
            snapshotStore.updateConfig(response, updatedAt: now(), userId: identity.userId)
            await tracker.setContextId(response.contextId)
            await tracker.setAssignments(response.experiments)
            persistSnapshot()
            log("config fetched: version=\(response.configVersion), experiments=\(response.experiments.count), configFiles=\(response.configFiles.count), ttl=\(response.ttlSeconds)s")
            logAssignments(response.experiments, prefix: "config ready")
            return response
        } catch {
            if let cachedConfig, cachedConfig.key == cacheKey {
                log("config fetch failed, using cached config: \(error)")
                return cachedConfig.value
            }
            log("config fetch failed: \(error)")
            throw error
        }
    }

    public func fetchConfigFile(_ name: String) async throws -> GameAlgoConfigFile {
        let safeName = try normalizeFileName(name)
        guard let encodedName = safeName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw GameAlgoError.invalidConfigFileName(name)
        }

        let response = try await request(
            GameAlgoHTTPRequest(
                url: try endpoint("/v1/config-files/\(encodedName)"),
                method: .get
            )
        )

        guard let content = String(data: response.body, encoding: .utf8) else {
            throw GameAlgoError.decodingFailed("Config file is not valid UTF-8")
        }

        let file = GameAlgoConfigFile(
            name: safeName,
            content: content,
            contentType: response.header("content-type") ?? "application/octet-stream",
            etag: response.header("etag")
        )
        snapshotStore.updateConfigFile(file, updatedAt: now())
        persistSnapshot()
        log("config file loaded: \(file.name) (\(file.contentType))")
        return file
    }

    public func uploadEvents(_ events: [GameAlgoEvent]) async throws -> GameAlgoEventBatchResponse {
        try await eventUploader.uploadEvents(events)
    }

    public func clearConfigCache() {
        cachedConfig = nil
    }

    private func refresh(
        userId: String,
        sessionId: String?,
        platform: GameAlgoPlatform?,
        sdkVersion: String?,
        appVersion: String?,
        deviceId: String?,
        timezone: String?,
        device: [String: JSONValue],
        preloadConfigFiles: GameAlgoConfigFilePreload
    ) async throws {
        let config = try await fetchConfig(
            userId: userId,
            sessionId: sessionId,
            platform: platform,
            sdkVersion: sdkVersion,
            appVersion: appVersion,
            deviceId: deviceId,
            timezone: timezone,
            device: device,
            forceRefresh: true
        )

        let names: [String]
        switch preloadConfigFiles {
        case .all:
            names = Array(Set(config.configFiles.map(\.name) + config.experiments.compactMap { $0.script?.name }))
        case .none:
            names = []
        case let .names(selected):
            names = selected
        }

        if names.isEmpty {
            log("no config files to preload")
        } else {
            log("preloading config files: \(names.sorted().joined(separator: ", "))")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask {
                    _ = try await self.fetchConfigFile(name)
                }
            }
            try await group.waitForAll()
        }
        let loadedFiles = Set(snapshotStore.snapshot().configFiles.keys)
        for assignment in config.experiments {
            if let script = assignment.script, loadedFiles.contains(script.name) {
                log("script loaded: \(assignment.key) -> \(script.name)")
            }
        }
        if !names.isEmpty {
            log("all config files loaded")
        }
        await tracker.setAssignments(config.experiments)
        logAssignments(config.experiments, prefix: "experiment")
        _ = await tracker.trackConfigLoaded()
        log("config_loaded queued")
    }

    private func loadCachedSnapshot() {
        guard let cacheStorage, let snapshot = try? cacheStorage.loadSnapshot(cacheKey: snapshotCacheKey) else {
            return
        }
        snapshotStore.replace(snapshot)
        log("cached snapshot loaded")
    }

    private func persistSnapshot() {
        guard let cacheStorage else { return }
        try? cacheStorage.saveSnapshot(snapshotStore.snapshot(), cacheKey: snapshotCacheKey)
    }

    private func requestJSON<T: Decodable>(_ request: GameAlgoHTTPRequest) async throws -> T {
        let response = try await self.request(request)
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw GameAlgoError.decodingFailed(error.localizedDescription)
        }
    }

    private func request(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse {
        var request = request
        request.headers["X-GameAlgo-Key"] = gameKey
        request.headers["Accept"] = "application/json"

        let response = try await httpClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw apiError(from: response)
        }
        return response
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw GameAlgoError.encodingFailed(error.localizedDescription)
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw GameAlgoError.invalidURL(path)
        }
        return url
    }

    private func normalizeFileName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = trimmed.startIndex..<trimmed.endIndex
        let match = trimmed.range(
            of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$",
            options: .regularExpression
        )
        guard match == fullRange, !trimmed.contains("..") else {
            throw GameAlgoError.invalidConfigFileName(name)
        }
        return trimmed
    }

    private func apiError(from response: GameAlgoHTTPResponse) -> GameAlgoError {
        let fallback = "GameAlgo API returned \(response.statusCode)"
        if let payload = try? decoder.decode(APIErrorPayload.self, from: response.body) {
            return .apiError(
                statusCode: response.statusCode,
                code: payload.error,
                message: payload.message ?? payload.error ?? fallback
            )
        }
        return .apiError(statusCode: response.statusCode, code: nil, message: fallback)
    }

    private func logUserId(_ userId: String) {
        guard !didLogUserId else { return }
        didLogUserId = true
        log("userId: \(userId)")
    }

    private func logAssignments(_ assignments: [GameAlgoExperimentAssignment], prefix: String) {
        for assignment in assignments {
            log("\(prefix): \(assignment.key) -> \(assignment.variant)")
        }
    }

    private func log(_ message: String) {
        logger?("[GameAlgoSDK] \(message)")
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func defaultDeviceContext() -> [String: JSONValue] {
        var device: [String: JSONValue] = [
            "runtime": .string("ios"),
            "locale": .string(Locale.current.identifier),
        ]
        #if canImport(UIKit)
        let currentDevice = UIDevice.current
        device["osName"] = .string(currentDevice.systemName)
        device["osVersion"] = .string(currentDevice.systemVersion)
        device["model"] = .string(currentDevice.model)
        let screen = UIScreen.main
        device["screenWidth"] = .number(Double(screen.bounds.size.width))
        device["screenHeight"] = .number(Double(screen.bounds.size.height))
        device["screenScale"] = .number(Double(screen.scale))
        #else
        device["osName"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
        #endif
        return device
    }

}

private struct ConfigCacheKey: Sendable, Equatable {
    let userId: String
    let userCreatedAt: String
    let sessionId: String
    let platform: GameAlgoPlatform
    let sdkVersion: String
    let appVersion: String?
    let timezone: String
    let device: [String: JSONValue]
}

private struct ConfigRequest: Encodable {
    let userId: String
    let userCreatedAt: String
    let sessionId: String
    let platform: GameAlgoPlatform
    let sdkVersion: String
    let appVersion: String?
    let timezone: String
    let device: [String: JSONValue]
}

private struct CachedConfig: Sendable {
    let key: ConfigCacheKey
    let value: GameAlgoConfigResponse
    let expiresAt: Date
}

private final class GameAlgoReadyTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?

    func set(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func get() -> Task<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}

private struct APIErrorPayload: Decodable {
    let error: String?
    let message: String?
}
