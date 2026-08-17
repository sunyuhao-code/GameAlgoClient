import Foundation

public protocol GameAlgoCacheStorage: Sendable {
    func loadSnapshot(cacheKey: String) throws -> GameAlgoSnapshot?
    func saveSnapshot(_ snapshot: GameAlgoSnapshot, cacheKey: String) throws
    func removeSnapshot(cacheKey: String) throws
    func loadValue(cacheKey: String) throws -> String?
    func saveValue(_ value: String, cacheKey: String) throws
    func removeValue(cacheKey: String) throws
}

public extension GameAlgoCacheStorage {
    func loadValue(cacheKey: String) throws -> String? { nil }
    func saveValue(_ value: String, cacheKey: String) throws {}
    func removeValue(cacheKey: String) throws {}
}

public final class GameAlgoUserDefaultsCacheStorage: GameAlgoCacheStorage, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadSnapshot(cacheKey: String) throws -> GameAlgoSnapshot? {
        guard let data = userDefaults.data(forKey: cacheKey) else { return nil }
        return try decoder.decode(GameAlgoSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: GameAlgoSnapshot, cacheKey: String) throws {
        userDefaults.set(try encoder.encode(snapshot), forKey: cacheKey)
    }

    public func removeSnapshot(cacheKey: String) throws {
        userDefaults.removeObject(forKey: cacheKey)
    }

    public func loadValue(cacheKey: String) throws -> String? {
        userDefaults.string(forKey: cacheKey)
    }

    public func saveValue(_ value: String, cacheKey: String) throws {
        userDefaults.set(value, forKey: cacheKey)
    }

    public func removeValue(cacheKey: String) throws {
        userDefaults.removeObject(forKey: cacheKey)
    }
}
