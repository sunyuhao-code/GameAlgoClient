import Foundation

public struct GameAlgoUserIdentity: Sendable, Equatable {
    public let userId: String
    public let userCreatedAt: String
    public let userCreatedLocalAt: String

    public init(userId: String, userCreatedAt: String, userCreatedLocalAt: String) {
        self.userId = userId
        self.userCreatedAt = userCreatedAt
        self.userCreatedLocalAt = userCreatedLocalAt
    }

    public init(userId: String, userCreatedAt: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: userCreatedAt) ?? Date()
        self.init(
            userId: userId,
            userCreatedAt: userCreatedAt,
            userCreatedLocalAt: GameAlgoEventBatchUploader.localTimestamp(date)
        )
    }
}

public final class GameAlgoUserIdentityStore: @unchecked Sendable {
    public static let legacyUserIdKey = "gamealgo_user_id"
    public static let legacyUserCreatedAtKey = "gamealgo_user_created_at"
    public static let userCreatedLocalAtKey = "gamealgo_user_created_local_at"

    private let userDefaults: UserDefaults
    private let userIdKey: String
    private let userCreatedAtKey: String
    private let userCreatedLocalAtKey: String
    private let lock = NSLock()

    public init(
        userDefaults: UserDefaults = .standard,
        userIdKey: String = GameAlgoUserIdentityStore.legacyUserIdKey,
        userCreatedAtKey: String = GameAlgoUserIdentityStore.legacyUserCreatedAtKey,
        userCreatedLocalAtKey: String = GameAlgoUserIdentityStore.userCreatedLocalAtKey
    ) {
        self.userDefaults = userDefaults
        self.userIdKey = userIdKey
        self.userCreatedAtKey = userCreatedAtKey
        self.userCreatedLocalAtKey = userCreatedLocalAtKey
    }

    public func identity(userId explicitUserId: String? = nil, now: Date = Date()) -> GameAlgoUserIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let explicitUserId = clean(explicitUserId) {
            let existingUserId = clean(userDefaults.string(forKey: userIdKey))
            let existingCreatedAt = clean(userDefaults.string(forKey: userCreatedAtKey))
            let existingCreatedLocalAt = clean(userDefaults.string(forKey: userCreatedLocalAtKey))
            if existingUserId == explicitUserId, let existingCreatedAt {
                let localAt = existingCreatedLocalAt ?? localTimestamp(for: existingCreatedAt, fallback: now)
                userDefaults.set(localAt, forKey: userCreatedLocalAtKey)
                return GameAlgoUserIdentity(userId: explicitUserId, userCreatedAt: existingCreatedAt, userCreatedLocalAt: localAt)
            }

            let createdAt = GameAlgoEventBatchUploader.isoTimestamp(now)
            let createdLocalAt = GameAlgoEventBatchUploader.localTimestamp(now)
            userDefaults.set(explicitUserId, forKey: userIdKey)
            userDefaults.set(createdAt, forKey: userCreatedAtKey)
            userDefaults.set(createdLocalAt, forKey: userCreatedLocalAtKey)
            return GameAlgoUserIdentity(userId: explicitUserId, userCreatedAt: createdAt, userCreatedLocalAt: createdLocalAt)
        }

        if let existing = clean(userDefaults.string(forKey: userIdKey)) {
            let createdAt = clean(userDefaults.string(forKey: userCreatedAtKey)) ?? GameAlgoEventBatchUploader.isoTimestamp(now)
            let createdLocalAt = clean(userDefaults.string(forKey: userCreatedLocalAtKey)) ?? localTimestamp(for: createdAt, fallback: now)
            userDefaults.set(createdAt, forKey: userCreatedAtKey)
            userDefaults.set(createdLocalAt, forKey: userCreatedLocalAtKey)
            return GameAlgoUserIdentity(
                userId: existing,
                userCreatedAt: createdAt,
                userCreatedLocalAt: createdLocalAt
            )
        }

        let newId = UUID().uuidString
        let createdAt = GameAlgoEventBatchUploader.isoTimestamp(now)
        let createdLocalAt = GameAlgoEventBatchUploader.localTimestamp(now)
        userDefaults.set(newId, forKey: userIdKey)
        userDefaults.set(createdAt, forKey: userCreatedAtKey)
        userDefaults.set(createdLocalAt, forKey: userCreatedLocalAtKey)
        return GameAlgoUserIdentity(userId: newId, userCreatedAt: createdAt, userCreatedLocalAt: createdLocalAt)
    }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return clean(userDefaults.string(forKey: key))
    }

    func setString(_ value: String, forKey key: String) {
        lock.lock()
        userDefaults.set(value, forKey: key)
        lock.unlock()
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func localTimestamp(for utcTimestamp: String, fallback: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: utcTimestamp) ?? fallback
        return GameAlgoEventBatchUploader.localTimestamp(date)
    }
}
