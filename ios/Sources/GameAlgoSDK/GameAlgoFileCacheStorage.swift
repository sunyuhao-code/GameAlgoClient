import Foundation

/// Atomic, synchronously committed files; the former UserDefaults cache remains
/// a read fallback so upgrading preserves existing cached state.
public final class GameAlgoFileCacheStorage: GameAlgoCacheStorage, @unchecked Sendable {
    private let directory: URL
    private let fallback: (any GameAlgoCacheStorage)?
    private let lock = NSLock()

    public init(directory: URL? = nil, fallback: (any GameAlgoCacheStorage)? = GameAlgoUserDefaultsCacheStorage()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameAlgoSDK/cache-v1", isDirectory: true)
        self.fallback = fallback
    }
    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(GameAlgoSHA256.hash(key).replacingOccurrences(of: "sha256:", with: "") + ".json")
    }
    public func loadValue(cacheKey: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let url = file(cacheKey)
        if FileManager.default.fileExists(atPath: url.path) { return try String(contentsOf: url, encoding: .utf8) }
        return try fallback?.loadValue(cacheKey: cacheKey)
    }
    public func saveValue(_ value: String, cacheKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(cacheKey)
        #if canImport(UIKit)
        try Data(value.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data(value.utf8).write(to: url, options: .atomic)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { handle.closeFile() }
        handle.synchronizeFile()
    }
    public func removeValue(cacheKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        let url = file(cacheKey)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try fallback?.removeValue(cacheKey: cacheKey)
    }
    public func loadSnapshot(cacheKey: String) throws -> GameAlgoSnapshot? {
        if let raw = try loadValue(cacheKey: cacheKey), let data = raw.data(using: .utf8) {
            return try JSONDecoder().decode(GameAlgoSnapshot.self, from: data)
        }
        return try fallback?.loadSnapshot(cacheKey: cacheKey)
    }
    public func saveSnapshot(_ snapshot: GameAlgoSnapshot, cacheKey: String) throws {
        try saveValue(String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self), cacheKey: cacheKey)
    }
    public func removeSnapshot(cacheKey: String) throws {
        try removeValue(cacheKey: cacheKey)
        try fallback?.removeSnapshot(cacheKey: cacheKey)
    }
}
