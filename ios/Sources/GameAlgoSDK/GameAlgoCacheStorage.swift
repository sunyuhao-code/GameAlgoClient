import Foundation

public protocol GameAlgoCacheStorage: Sendable {
    func loadSnapshot(cacheKey: String) throws -> GameAlgoSnapshot?
    func saveSnapshot(_ snapshot: GameAlgoSnapshot, cacheKey: String) throws
    func removeSnapshot(cacheKey: String) throws
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
}
