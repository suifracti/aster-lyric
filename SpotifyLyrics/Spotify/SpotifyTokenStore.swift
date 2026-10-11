import Foundation
import LocalAuthentication
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
        case .keychain(let status): return "Spotify 授权凭据存储失败（Keychain \(status)）"
        case .invalidStoredValue: return "Spotify Keychain 凭据无效"
        }
    }
}

/// Stores the complete token record as one Keychain item. Neither access nor
/// refresh tokens are written to UserDefaults, logs, screenshots, or files.
public final class KeychainSpotifyTokenStore: SpotifyTokenStore, @unchecked Sendable {
    // The v2 service deliberately does not reuse the legacy item created by
    // earlier ad-hoc builds. Reusing that item is what caused macOS to ask for
    // the login keychain password on every new code signature.
    // A new service namespace is intentionally used for the first app build
    // that contains the non-interactive fallback. The old namespace may have
    // an ACL tied to an earlier ad-hoc code signature; probing it can summon a
    // login-keychain password dialog before the app has a chance to recover.
    public static let service = "com.spotifylyrics.spotify-oauth.v3"
    public static let account = "spotify-token-record"
    public static let usesDataProtectionKeychain = true

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
        // A Keychain ACL created by an older ad-hoc build may otherwise put
        // the SwiftUI app's MainActor into a system password prompt during
        // launch. Startup must never block Spotify Desktop or the editor on
        // interactive Keychain UI; an unavailable item is reported as a
        // normal authorization failure instead.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Do not probe the legacy login-keychain item during startup. Some
        // older ad-hoc builds created an ACL that ignores the non-interactive
        // hint and blocks here for a password dialog. The v3 data-protection
        // namespace is the only automatic read path; users can authorize
        // again if an old token is not available.
        if service == Self.service && account == Self.account &&
            (status == errSecItemNotFound || status == errSecMissingEntitlement || status == errSecInteractionNotAllowed) {
            return nil
        }
        if status == errSecItemNotFound || status == errSecMissingEntitlement || status == errSecInteractionNotAllowed {
            // Contract fixtures and explicitly injected stores may use a
            // private service namespace. Keep their legacy compatibility
            // path, while the production v3 namespace never probes the old
            // ACL-bound item during application launch.
            var legacyQuery = legacyBaseQuery(interactionNotAllowed: true)
            legacyQuery[kSecReturnData as String] = true
            legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            result = nil
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
            if legacyStatus == errSecItemNotFound || legacyStatus == errSecInteractionNotAllowed {
                return nil
            }
            guard legacyStatus == errSecSuccess else {
                throw SpotifyTokenStoreError.keychain(legacyStatus)
            }
            guard let data = result as? Data else {
                throw SpotifyTokenStoreError.invalidStoredValue
            }
            return try decode(data)
        }
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
        guard updateStatus == errSecItemNotFound || updateStatus == errSecMissingEntitlement else {
            throw SpotifyTokenStoreError.keychain(updateStatus)
        }

        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecMissingEntitlement else {
            throw SpotifyTokenStoreError.keychain(addStatus)
        }

        try saveLegacy(data)
    }

    public func delete() throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw SpotifyTokenStoreError.keychain(status)
        }
        let legacyStatus = SecItemDelete(legacyBaseQuery(interactionNotAllowed: true) as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound || legacyStatus == errSecInteractionNotAllowed else {
            throw SpotifyTokenStoreError.keychain(legacyStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func decode(_ data: Data) throws -> SpotifyTokenRecord {
        do {
            return try JSONDecoder().decode(SpotifyTokenRecord.self, from: data)
        } catch {
            throw SpotifyTokenStoreError.invalidStoredValue
        }
    }

    private func legacyBaseQuery(interactionNotAllowed: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if interactionNotAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    private func saveLegacy(_ data: Data) throws {
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            legacyBaseQuery(interactionNotAllowed: false) as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SpotifyTokenStoreError.keychain(updateStatus)
        }

        var item = legacyBaseQuery(interactionNotAllowed: false)
        item[kSecValueData as String] = data
        item[kSecAttrAccess as String] = try trustedApplicationAccess()
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw SpotifyTokenStoreError.keychain(addStatus)
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
