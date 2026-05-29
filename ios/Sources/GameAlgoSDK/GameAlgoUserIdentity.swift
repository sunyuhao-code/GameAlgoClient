import Foundation

public struct GameAlgoUserIdentity: Sendable, Equatable {
    public let userId: String
    public let userCreatedAt: String

    public init(userId: String, userCreatedAt: String) {
        self.userId = userId
        self.userCreatedAt = userCreatedAt
    }
}

public final class GameAlgoUserIdentityStore: @unchecked Sendable {
    public static let legacyUserIdKey = "gamealgo_user_id"
    public static let legacyUserCreatedAtKey = "gamealgo_user_created_at"

    private let userDefaults: UserDefaults
    private let userIdKey: String
    private let userCreatedAtKey: String
    private let lock = NSLock()

    public init(
        userDefaults: UserDefaults = .standard,
        userIdKey: String = GameAlgoUserIdentityStore.legacyUserIdKey,
        userCreatedAtKey: String = GameAlgoUserIdentityStore.legacyUserCreatedAtKey
    ) {
        self.userDefaults = userDefaults
        self.userIdKey = userIdKey
        self.userCreatedAtKey = userCreatedAtKey
    }

    public func identity(userId explicitUserId: String? = nil, now: Date = Date()) -> GameAlgoUserIdentity {
        if let explicitUserId = clean(explicitUserId) {
            return GameAlgoUserIdentity(userId: explicitUserId, userCreatedAt: "")
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = clean(userDefaults.string(forKey: userIdKey)) {
            return GameAlgoUserIdentity(
                userId: existing,
                userCreatedAt: userDefaults.string(forKey: userCreatedAtKey) ?? ""
            )
        }

        let newId = UUID().uuidString
        let createdAt = GameAlgoEventBatchUploader.isoTimestamp(now)
        userDefaults.set(newId, forKey: userIdKey)
        userDefaults.set(createdAt, forKey: userCreatedAtKey)
        return GameAlgoUserIdentity(userId: newId, userCreatedAt: createdAt)
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
