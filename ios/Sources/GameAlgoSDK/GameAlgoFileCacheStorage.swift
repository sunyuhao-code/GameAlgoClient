import Foundation

/// Atomic, synchronously committed files; the former UserDefaults cache remains
/// a read fallback so upgrading preserves existing cached state.
public final class GameAlgoFileCacheStorage: GameAlgoJournalStorage, @unchecked Sendable {
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
        try write(value, to: file(cacheKey))
    }
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(UIKit)
        try Data(value.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data(value.utf8).write(to: url, options: .atomic)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { handle.closeFile() }
        handle.synchronizeFile()
    }
    private func journal(_ key: String) -> URL { file(key).appendingPathExtension("journal") }
    func loadJournalRecords(cacheKey: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let path = journal(cacheKey)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }
    func appendJournalRecord(_ value: String, sequence: UInt64, cacheKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        try write(value, to: journal(cacheKey).appendingPathComponent(String(format: "%020llu.json", sequence)))
    }
    func compactJournal(_ value: String, cacheKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        try write(value, to: file(cacheKey))
        let path = journal(cacheKey)
        let retired = path.appendingPathExtension("retired.\(UUID())")
        if (try? FileManager.default.moveItem(at: path, to: retired)) != nil {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: retired) }
        }
    }
    public func removeValue(cacheKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        let url = file(cacheKey)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let journal = journal(cacheKey)
        let retired = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for path in [journal] + retired.filter({ $0.lastPathComponent.hasPrefix(journal.lastPathComponent + ".retired.") }) {
            try? FileManager.default.removeItem(at: path)
            if FileManager.default.fileExists(atPath: path.path) { throw CocoaError(.fileWriteUnknown) }
        }
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
