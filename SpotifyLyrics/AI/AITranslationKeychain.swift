import Foundation
import Security

public protocol AITranslationKeychainTransport: Sendable {
    func read(service: String, account: String) -> String?
    func save(service: String, account: String, key: String) throws
    func delete(service: String, account: String) throws
}

public struct SecurityAITranslationKeychainTransport: AITranslationKeychainTransport, Sendable {
    public init() {}

    public func read(service: String, account: String) -> String? {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return nil }
#endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public func save(service: String, account: String, key: String) throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { throw AITranslationKeychainError.status(-1) }
#endif
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw AITranslationKeychainError.status(status) }
        } else if updateStatus != errSecSuccess {
            throw AITranslationKeychainError.status(updateStatus)
        }
    }

    public func delete(service: String, account: String) throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AITranslationKeychainError.status(status)
        }
    }
}

public protocol AITranslationAPIKeyStore: Sendable {
    func read() -> String?
    func save(_ key: String) throws
    func delete() throws
    func invalidateCache()
}

public extension AITranslationAPIKeyStore {
    func invalidateCache() {}
}

public final class KeychainAITranslationAPIKeyStore: AITranslationAPIKeyStore, @unchecked Sendable {
    public static let service = "com.spotifylyrics.ai-translation"
    private let account: String
    private let transport: any AITranslationKeychainTransport
    private let lock = NSLock()
    private var cachedKey: String?
    private var hasLoadedCache = false

    public init(
        account: String = "default",
        transport: any AITranslationKeychainTransport = SecurityAITranslationKeychainTransport()
    ) {
        self.account = account
        self.transport = transport
    }

    public func read() -> String? {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return nil }
#endif
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }

        if hasLoadedCache {
            return cachedKey
        }

        let resolvedKey = transport.read(service: Self.service, account: account)
        self.cachedKey = resolvedKey
        self.hasLoadedCache = true
        return resolvedKey
    }

    public func save(_ key: String) throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { throw AITranslationKeychainError.status(-1) }
#endif
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" {
            lock.lock()
            self.cachedKey = key
            self.hasLoadedCache = true
            lock.unlock()
            return
        }

        try transport.save(service: Self.service, account: account, key: key)

        lock.lock()
        self.cachedKey = key
        self.hasLoadedCache = true
        lock.unlock()
    }

    public func delete() throws {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" {
            lock.lock()
            self.cachedKey = nil
            self.hasLoadedCache = true
            lock.unlock()
            return
        }

        try transport.delete(service: Self.service, account: account)

        lock.lock()
        self.cachedKey = nil
        self.hasLoadedCache = true
        lock.unlock()
    }

    public func invalidateCache() {
        lock.lock()
        self.cachedKey = nil
        self.hasLoadedCache = false
        lock.unlock()
    }
}

public final class InMemoryAITranslationAPIKeyStore: AITranslationAPIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    public func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.key = key
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        self.key = nil
    }

    public func invalidateCache() {}
}

public final class DisabledAITranslationAPIKeyStore: AITranslationAPIKeyStore, @unchecked Sendable {
    public init() {}
    public func read() -> String? { nil }
    public func save(_ key: String) throws { throw AITranslationKeychainError.status(-1) }
    public func delete() throws {}
    public func invalidateCache() {}
}

public enum AITranslationKeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
}
