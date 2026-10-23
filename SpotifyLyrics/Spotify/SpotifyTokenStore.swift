import Foundation
import Security

public struct SpotifyTokenRecord: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpiringSoon: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

public protocol SpotifyTokenStore: Sendable {
    func load() throws -> SpotifyTokenRecord?
    func save(_ record: SpotifyTokenRecord) throws
    func delete() throws
}

public enum SpotifyTokenStoreError: Error, Equatable, Sendable, LocalizedError {
    case encodingFailed
    case keychain(OSStatus)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Spotify 授权凭据编码失败"
        case .keychain(let status): return "Spotify 授权凭据访问失败（Keychain \(status)）"
        case .invalidStoredValue: return "Spotify Keychain 凭据无效"
        }
    }
}

/// Stores the complete token record as one login-keychain item. Neither access
/// nor refresh tokens are written to UserDefaults, logs, screenshots, or files.
public final class KeychainSpotifyTokenStore: SpotifyTokenStore, @unchecked Sendable {
    // The data protection keychain needs an application-identifier
    // entitlement, which this local Debug signing does not carry: SecItemAdd
    // returns errSecMissingEntitlement while the login keychain accepts the
    // item. Save, load and delete must all use that same namespace. Writing
    // through a fallback but reading only the data protection keychain made
    // every relaunch look signed out.
    public static let service = "com.spotifylyrics.spotify-oauth.v3"
    public static let account = "spotify-token-record"

    private let service: String
    private let account: String

    public init(
        service: String = KeychainSpotifyTokenStore.service,
        account: String = KeychainSpotifyTokenStore.account
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> SpotifyTokenRecord? {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return nil }
#endif
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Startup must never block on a system prompt. An item that cannot be
        // read without interaction is reported as a normal authorization
        // failure; the user can authorize again from Settings.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if Self.unavailableStatuses.contains(status) { return nil }
        guard status == errSecSuccess else { throw SpotifyTokenStoreError.keychain(status) }
        guard let data = result as? Data else { throw SpotifyTokenStoreError.invalidStoredValue }
        return try decode(data)
    }

    public func save(_ record: SpotifyTokenRecord) throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { throw SpotifyTokenStoreError.keychain(errSecInteractionNotAllowed) }
#endif
        guard let data = try? JSONEncoder().encode(record) else {
            throw SpotifyTokenStoreError.encodingFailed
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SpotifyTokenStoreError.keychain(updateStatus)
        }

        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrAccess as String] = try trustedApplicationAccess()
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SpotifyTokenStoreError.keychain(addStatus)
        }
    }

    public func delete() throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpotifyTokenStoreError.keychain(status)
        }
    }

    private static let unavailableStatuses: Set<OSStatus> = [
        errSecItemNotFound,
        errSecInteractionNotAllowed,
        errSecAuthFailed
    ]

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func decode(_ data: Data) throws -> SpotifyTokenRecord {
        do {
            return try JSONDecoder().decode(SpotifyTokenRecord.self, from: data)
        } catch {
            throw SpotifyTokenStoreError.invalidStoredValue
        }
    }

    private func trustedApplicationAccess() throws -> SecAccess {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw SpotifyTokenStoreError.keychain(trustedStatus)
        }

        let trustedList: CFArray = [trustedApplication] as NSArray
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "SpotifyLyrics Spotify OAuth" as CFString,
            trustedList,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw SpotifyTokenStoreError.keychain(accessStatus)
        }
        return access
    }
}

#if DEBUG
public final class InMemorySpotifyTokenStore: SpotifyTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: SpotifyTokenRecord?

    public init(record: SpotifyTokenRecord? = nil) {
        self.record = record
    }

    public func load() throws -> SpotifyTokenRecord? {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    public func save(_ record: SpotifyTokenRecord) throws {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        record = nil
    }
}
#endif
