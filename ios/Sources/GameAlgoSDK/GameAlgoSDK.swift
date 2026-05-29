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
    private let snapshotCacheKey: String
    private let now: @Sendable () -> Date
    private let snapshotStore: GameAlgoSnapshotStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public nonisolated let config: GameAlgoConfigReader

    private var cachedConfig: CachedConfig?
    private var readyTask: Task<Void, Error>?

    public init(
        gameKey: String,
        baseURL: URL,
        sdkVersion: String = GameAlgoSDK.defaultSDKVersion,
        appVersion: String? = nil,
        platform: GameAlgoPlatform = .ios,
        httpClient: any GameAlgoHTTPClient = URLSessionGameAlgoHTTPClient(),
        scriptRuntime: any GameAlgoScriptRuntime = JavaScriptCoreGameAlgoScriptRuntime(),
        cacheStorage: (any GameAlgoCacheStorage)? = GameAlgoUserDefaultsCacheStorage(),
        cacheKey: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let snapshotStore = GameAlgoSnapshotStore()
        self.gameKey = gameKey
        self.baseURL = baseURL
        self.defaultSDKVersion = sdkVersion
        self.defaultAppVersion = appVersion
        self.defaultPlatform = platform
        self.httpClient = httpClient
        self.scriptRuntime = scriptRuntime
        self.cacheStorage = cacheStorage
        self.snapshotCacheKey = cacheKey ?? "gamealgo:v1:snapshot:\(baseURL.absoluteString):\(gameKey.prefix(16))"
        self.now = now
        self.snapshotStore = snapshotStore
        self.config = GameAlgoConfigReader(store: snapshotStore)
    }

    public nonisolated func executor(_ key: String) -> GameAlgoExperimentExecutor {
        GameAlgoExperimentExecutor(key: key, store: snapshotStore, scriptRuntime: scriptRuntime)
    }

    public nonisolated func snapshotValue() -> GameAlgoSnapshot {
        snapshotStore.snapshot()
    }

    @discardableResult
    public func start(
        userId: String,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        deviceId: String? = nil,
        preloadConfigFiles: GameAlgoConfigFilePreload = .all
    ) -> Task<Void, Error> {
        let task = Task {
            self.loadCachedSnapshot()
            do {
                try await self.refresh(
                    userId: userId,
                    platform: platform,
                    sdkVersion: sdkVersion,
                    appVersion: appVersion,
                    deviceId: deviceId,
                    preloadConfigFiles: preloadConfigFiles
                )
            } catch {
                if self.snapshotStore.snapshot().config == nil {
                    throw error
                }
            }
        }
        readyTask = task
        return task
    }

    public func waitForReady(timeout: TimeInterval = 5.0) async -> Bool {
        guard let readyTask else {
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
        userId: String,
        platform: GameAlgoPlatform? = nil,
        sdkVersion: String? = nil,
        appVersion: String? = nil,
        deviceId: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> GameAlgoConfigResponse {
        let resolvedPlatform = platform ?? defaultPlatform
        let resolvedSDKVersion = sdkVersion ?? defaultSDKVersion
        let resolvedAppVersion = appVersion ?? defaultAppVersion
        let cacheKey = ConfigCacheKey(
            userId: userId,
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
                URLQueryItem(name: "userId", value: userId),
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
            snapshotStore.updateConfig(response, updatedAt: now(), userId: userId)
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
        guard !events.isEmpty else {
            throw GameAlgoError.invalidEvents("events must be a non-empty array")
        }
        guard events.count <= 100 else {
            throw GameAlgoError.invalidEvents("Maximum 100 events per batch")
        }

        let timestamp = Self.isoTimestamp(now())
        let normalizedEvents = events.map { event in
            var normalized = event
            if normalized.eventId?.isEmpty ?? true {
                normalized.eventId = UUID().uuidString
            }
            if normalized.platform == nil {
                normalized.platform = defaultPlatform
            }
            if normalized.sdkVersion?.isEmpty ?? true {
                normalized.sdkVersion = defaultSDKVersion
            }
            if normalized.appVersion == nil {
                normalized.appVersion = defaultAppVersion
            }
            if normalized.isDebug == nil {
                normalized.isDebug = false
            }
            if normalized.timestamp?.isEmpty ?? true {
                normalized.timestamp = timestamp
            }
            return normalized
        }

        let body = try encode(EventBatchRequest(events: normalizedEvents))
        return try await requestJSON(
            GameAlgoHTTPRequest(
                url: try endpoint("/v1/events/batch"),
                method: .post,
                headers: ["content-type": "application/json"],
                body: body
            )
        )
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

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

private struct EventBatchRequest: Encodable {
    let events: [GameAlgoEvent]
}

private struct APIErrorPayload: Decodable {
    let error: String?
    let message: String?
}
