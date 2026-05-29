import Foundation

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
    private let snapshotStore: GameAlgoSnapshotStore
    private let eventUploader: any GameAlgoEventBatchUploading
    private let readyTaskStore = GameAlgoReadyTaskStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public nonisolated let config: GameAlgoConfigReader
    public nonisolated let tracker: GameAlgoEventTracker

    private var cachedConfig: CachedConfig?

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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let snapshotStore = GameAlgoSnapshotStore()
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
        self.snapshotStore = snapshotStore
        self.eventUploader = eventUploader
        self.config = GameAlgoConfigReader(store: snapshotStore)
        self.tracker = GameAlgoEventTracker(
            uploader: eventUploader,
            maxBatchSize: eventMaxBatchSize,
            queueLimit: eventQueueLimit,
            flushInterval: eventFlushInterval,
            isDebug: isDebug,
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
        GameAlgoExperimentExecutor(key: key, store: snapshotStore, scriptRuntime: scriptRuntime)
    }

    public nonisolated func snapshotValue() -> GameAlgoSnapshot {
        snapshotStore.snapshot()
    }

    @discardableResult
    public nonisolated func start(
        userId: String? = nil,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        deviceId: String? = nil,
        preloadConfigFiles: GameAlgoConfigFilePreload = .all
    ) -> Task<Void, Error> {
        let identity = userIdentityStore.identity(userId: userId, now: now())
        let task = Task {
            await self.tracker.identify(
                userId: identity.userId,
                platform: platform ?? self.defaultPlatform,
                sdkVersion: sdkVersion ?? self.defaultSDKVersion,
                appVersion: appVersion ?? self.defaultAppVersion,
                userCreatedAt: identity.userCreatedAt
            )
            await self.loadCachedSnapshot()
            do {
                try await self.refresh(
                    userId: identity.userId,
                    platform: platform,
                    sdkVersion: sdkVersion,
                    appVersion: appVersion,
                    deviceId: deviceId,
                    preloadConfigFiles: preloadConfigFiles
                )
            } catch {
                if self.snapshotValue().config == nil {
                    throw error
                }
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
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        deviceId: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> GameAlgoConfigResponse {
        let identity = userIdentityStore.identity(userId: userId, now: now())
        let resolvedPlatform = platform ?? defaultPlatform
        let resolvedSDKVersion = sdkVersion ?? defaultSDKVersion
        let resolvedAppVersion = appVersion ?? defaultAppVersion
        await tracker.identify(
            userId: identity.userId,
            platform: resolvedPlatform,
            sdkVersion: resolvedSDKVersion,
            appVersion: resolvedAppVersion,
            userCreatedAt: identity.userCreatedAt
        )
        let cacheKey = ConfigCacheKey(
            userId: identity.userId,
            platform: resolvedPlatform,
            sdkVersion: resolvedSDKVersion,
            appVersion: resolvedAppVersion,
            deviceId: deviceId
        )

        if !forceRefresh,
           let cachedConfig,
           cachedConfig.key == cacheKey,
           cachedConfig.expiresAt > now() {
            return cachedConfig.value
        }

        do {
            var components = URLComponents(
                url: try endpoint("/v1/config"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "userId", value: identity.userId),
                URLQueryItem(name: "platform", value: resolvedPlatform.rawValue),
                URLQueryItem(name: "sdkVersion", value: resolvedSDKVersion),
            ]
            if let resolvedAppVersion {
                components?.queryItems?.append(URLQueryItem(name: "appVersion", value: resolvedAppVersion))
            }
            if let deviceId {
                components?.queryItems?.append(URLQueryItem(name: "deviceId", value: deviceId))
            }
            guard let url = components?.url else {
                throw GameAlgoError.invalidURL("/v1/config")
            }

            let response: GameAlgoConfigResponse = try await requestJSON(
                GameAlgoHTTPRequest(url: url, method: .get)
            )
            cachedConfig = CachedConfig(
                key: cacheKey,
                value: response,
                expiresAt: now().addingTimeInterval(TimeInterval(max(response.ttlSeconds, 0)))
            )
            snapshotStore.updateConfig(response, updatedAt: now(), userId: identity.userId)
            persistSnapshot()
            return response
        } catch {
            if let cachedConfig, cachedConfig.key == cacheKey {
                return cachedConfig.value
            }
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
        platform: GameAlgoPlatform?,
        sdkVersion: String?,
        appVersion: String?,
        deviceId: String?,
        preloadConfigFiles: GameAlgoConfigFilePreload
    ) async throws {
        let config = try await fetchConfig(
            userId: userId,
            platform: platform,
            sdkVersion: sdkVersion,
            appVersion: appVersion,
            deviceId: deviceId,
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

        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask {
                    _ = try await self.fetchConfigFile(name)
                }
            }
            try await group.waitForAll()
        }
    }

    private func loadCachedSnapshot() {
        guard let cacheStorage, let snapshot = try? cacheStorage.loadSnapshot(cacheKey: snapshotCacheKey) else {
            return
        }
        snapshotStore.replace(snapshot)
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

}

private struct ConfigCacheKey: Sendable, Equatable {
    let userId: String
    let platform: GameAlgoPlatform
    let sdkVersion: String
    let appVersion: String?
    let deviceId: String?
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
