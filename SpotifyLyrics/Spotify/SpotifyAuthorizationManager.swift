import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

public enum SpotifyAuthorizationState: Equatable, Sendable {
    case notConfigured
    case signedOut
    case authorizing
    case authorized(Date)
    case failed(String)

    public var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }

    public var userFacingMessage: String {
        switch self {
        case .notConfigured: return "需要 Spotify Client ID"
        case .signedOut: return "未授权 Spotify 在线曲库"
        case .authorizing: return "正在等待 Spotify 授权…"
        case .authorized: return "Spotify 在线曲库已授权"
        case .failed(let message): return message.isEmpty ? "Spotify 授权失败" : "Spotify 授权失败：\(message)"
        }
    }
}

public enum SpotifyAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case notAuthorized
    case stateMismatch
    case invalidCallback
    case denied(String)
    case tokenExchange(SpotifyCatalogError)
    case tokenStore(String)
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置 Spotify Client ID"
        case .notAuthorized: return "尚未授权 Spotify 在线曲库"
        case .stateMismatch: return "Spotify 授权回调 state 校验失败"
        case .invalidCallback: return "Spotify 授权回调无效"
        case .denied(let message): return message.isEmpty ? "用户取消了 Spotify 授权" : "Spotify 授权被拒绝：\(message)"
        case .tokenExchange(let error): return error.localizedDescription
        case .tokenStore(let message): return message
        case .randomGenerationFailed: return "无法生成安全授权参数"
        }
    }
}

/// Main-actor owner of the browser OAuth flow and token lifecycle. The actual
/// token bytes remain inside KeychainSpotifyTokenStore and are never published.
@MainActor
public final class SpotifyAuthorizationManager: ObservableObject {
    @Published public private(set) var state: SpotifyAuthorizationState
    @Published public private(set) var clientID: String?
    @Published public private(set) var localRedirectURI: String?

    public let dashboardRedirectURI = SpotifyOAuthConfiguration.dashboardRedirectURI

    private let tokenStore: any SpotifyTokenStore
    private let catalogService: SpotifyCatalogService
    private var pendingFlow: PendingFlow?
    // Keychain reads can show system authorization UI. Keep one result (or
    // one failure) for the lifetime of this manager so a search burst cannot
    // enqueue the same prompt several times.
    private var hasLoadedToken = false
    private var cachedToken: SpotifyTokenRecord?
    private var cachedTokenLoadError: SpotifyAuthorizationError?
#if DEBUG
    // A one-shot local acceptance hook. It exercises the real Spotify refresh
    // endpoint without exposing token material or adding a production UI.
    private var didPerformForcedRefresh = false
#endif

    private struct PendingFlow: Sendable {
        let state: String
        let codeVerifier: String
        let redirectURI: String
    }

    private var callbackServer: SpotifyLoopbackCallbackServer?

    public init(
        configuration: SpotifyOAuthConfiguration = .resolved(),
        tokenStore: any SpotifyTokenStore = KeychainSpotifyTokenStore(),
        catalogService: SpotifyCatalogService = SpotifyCatalogService()
    ) {
        self.clientID = configuration.clientID
        self.tokenStore = tokenStore
        self.catalogService = catalogService
        self.localRedirectURI = nil

        if configuration.clientID == nil {
            self.state = .notConfigured
        } else {
            do {
                cachedToken = try tokenStore.load()
                hasLoadedToken = true
                if let token = cachedToken {
                    self.state = .authorized(token.expiresAt)
                } else {
                    self.state = .signedOut
                }
            } catch {
                hasLoadedToken = true
                cachedTokenLoadError = .tokenStore("无法读取 Spotify 授权凭据")
                self.state = .failed(cachedTokenLoadError?.localizedDescription ?? "Spotify 授权失败")
            }
        }
    }

    public var isConfigured: Bool { clientID != nil }

    /// Compatibility accessor for callers that used the old single URI field.
    /// It never claims that the Dashboard must register a dynamic port.
    public var redirectURI: String {
        localRedirectURI ?? dashboardRedirectURI
    }

    public func updateClientID(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : trimmed
        clientID = next
        if let next {
            UserDefaults.lyricsQ.set(next, forKey: "spotify.clientID")
            hasLoadedToken = false
            cachedToken = nil
            cachedTokenLoadError = nil
            if !state.isAuthorized { state = .signedOut }
        } else {
            UserDefaults.lyricsQ.removeObject(forKey: "spotify.clientID")
            hasLoadedToken = false
            cachedToken = nil
            cachedTokenLoadError = nil
            state = .notConfigured
        }
    }

    /// Opens the system browser. The callback is delivered to a short-lived
    /// 127.0.0.1 loopback receiver. Its port is allocated dynamically and the
    /// same runtime URI is used for authorization and token exchange.
    public func authorize() {
        guard let clientID else {
            state = .notConfigured
            return
        }

        do {
            let verifier = try Self.randomURLSafeString(length: 64)
            let oauthState = try Self.randomURLSafeString(length: 32)
            callbackServer?.cancel()
            localRedirectURI = nil
            let server = try SpotifyLoopbackCallbackServer { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.handleCallback(url)
                }
            }
            callbackServer = server
            state = .authorizing
            server.start { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let port):
                        do {
                            guard let port = UInt16(exactly: port), port > 0 else {
                                self.pendingFlow = nil
                                self.callbackServer?.cancel()
                                self.callbackServer = nil
                                self.localRedirectURI = nil
                                self.state = .failed("无法确定本机授权回调端口")
                                return
                            }
                            let redirectURI = SpotifyOAuthConfiguration.redirectURI(port: port)
                            self.localRedirectURI = redirectURI
                            let url = try self.catalogService.authorizationURL(
                                clientID: clientID,
                                state: oauthState,
                                codeChallenge: Self.codeChallenge(for: verifier),
                                redirectURI: redirectURI
                            )
                            self.pendingFlow = PendingFlow(
                                state: oauthState,
                                codeVerifier: verifier,
                                redirectURI: redirectURI
                            )
                            guard NSWorkspace.shared.open(url) else {
                                self.pendingFlow = nil
                                self.callbackServer?.cancel()
                                self.callbackServer = nil
                                self.localRedirectURI = nil
                                self.state = .failed("无法打开系统浏览器")
                                return
                            }
                        } catch {
                            self.pendingFlow = nil
                            self.callbackServer?.cancel()
                            self.callbackServer = nil
                            self.localRedirectURI = nil
                            self.state = .failed(error.localizedDescription)
                        }
                    case .failure:
                        self.pendingFlow = nil
                        self.callbackServer = nil
                        self.localRedirectURI = nil
                        self.state = .failed("无法启动本机授权回调")
                    }
                }
            }
        } catch {
            pendingFlow = nil
            localRedirectURI = nil
            state = .failed(error.localizedDescription)
        }
    }

    public func handleCallback(_ url: URL) {
        Task { @MainActor [weak self] in
            await self?.completeCallback(url)
        }
    }

    public func disconnect() {
        do {
            try tokenStore.delete()
            hasLoadedToken = true
            cachedToken = nil
            cachedTokenLoadError = nil
            pendingFlow = nil
            callbackServer?.cancel()
            callbackServer = nil
            localRedirectURI = nil
            state = clientID == nil ? .notConfigured : .signedOut
        } catch {
            state = .failed("无法删除 Spotify 授权凭据")
        }
    }

    /// Re-reads the existing Keychain record on explicit user request. This
    /// is intentionally not called by every search, because Keychain access
    /// may present a system prompt for an ad-hoc build.
    public func refreshAuthorizationState() {
        guard clientID != nil else {
            state = .notConfigured
            return
        }
        hasLoadedToken = false
        cachedToken = nil
        cachedTokenLoadError = nil
        do {
            let token = try tokenStore.load()
            hasLoadedToken = true
            cachedToken = token
            state = token.map { .authorized($0.expiresAt) } ?? .signedOut
        } catch {
            hasLoadedToken = true
            cachedTokenLoadError = .tokenStore("无法读取 Spotify 授权凭据")
            state = .failed(cachedTokenLoadError?.localizedDescription ?? "Spotify 授权失败")
        }
    }

    /// Returns a valid access token, refreshing when it is within one minute of
    /// expiry. Callers must not persist or log the returned value.
    public func accessToken() async throws -> String {
        guard clientID != nil else {
            state = .notConfigured
            throw SpotifyAuthorizationError.notConfigured
        }
        guard let token = try loadToken() else {
            state = .signedOut
            throw SpotifyAuthorizationError.notAuthorized
        }
#if DEBUG
        let forceRefreshForAcceptance = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_FORCE_TOKEN_REFRESH"] == "1"
            || UserDefaults.lyricsQ.bool(forKey: "spotify.forceTokenRefreshForAcceptance")
        if forceRefreshForAcceptance,
           !didPerformForcedRefresh {
            didPerformForcedRefresh = true
            UserDefaults.lyricsQ.removeObject(forKey: "spotify.forceTokenRefreshForAcceptance")
            do {
                let refreshed = try await refreshNow()
                LyricsE2ELog.log("SPOTIFY refresh success")
                return refreshed.accessToken
            } catch {
                LyricsE2ELog.log("SPOTIFY refresh failed")
                throw error
            }
        }
#endif
        guard token.isExpiringSoon else {
            state = .authorized(token.expiresAt)
            return token.accessToken
        }
        let refreshed = try await refreshNow()
        return refreshed.accessToken
    }

    /// Used once after an API 401. A single caller can refresh; the next
    /// request is then retried by SpotifySearchProvider.
    public func refreshNow() async throws -> SpotifyTokenRecord {
        guard let clientID else {
            state = .notConfigured
            throw SpotifyAuthorizationError.notConfigured
        }
        guard let existing = try loadToken(), let refreshToken = existing.refreshToken else {
            state = .signedOut
            throw SpotifyAuthorizationError.notAuthorized
        }

        do {
            let response = try await catalogService.refresh(
                clientID: clientID,
                refreshToken: refreshToken
            )
            let record = SpotifyTokenRecord(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
                scope: response.scope ?? existing.scope
            )
            try saveToken(record)
            state = .authorized(record.expiresAt)
            return record
        } catch let error as SpotifyCatalogError {
            if error == .unauthorized {
                try? tokenStore.delete()
                state = .signedOut
            }
            throw SpotifyAuthorizationError.tokenExchange(error)
        } catch {
            throw SpotifyAuthorizationError.tokenStore("Spotify 刷新凭据失败")
        }
    }

    private func completeCallback(_ url: URL) async {
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "127.0.0.1",
              url.path == "/callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            state = .failed(SpotifyAuthorizationError.invalidCallback.localizedDescription)
            return
        }

        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let pending = pendingFlow else {
            state = .failed("Spotify 授权会话已过期，请重新授权")
            return
        }
        guard let expectedPort = URL(string: pending.redirectURI)?.port,
              url.port == expectedPort else {
            pendingFlow = nil
            callbackServer?.cancel()
            callbackServer = nil
            localRedirectURI = nil
            state = .failed(SpotifyAuthorizationError.invalidCallback.localizedDescription)
            return
        }
        guard values["state"] == pending.state else {
            pendingFlow = nil
            state = .failed(SpotifyAuthorizationError.stateMismatch.localizedDescription)
            return
        }
        pendingFlow = nil
        callbackServer?.cancel()
        callbackServer = nil
        localRedirectURI = nil

        if let error = values["error"] {
            state = .failed(SpotifyAuthorizationError.denied(error).localizedDescription)
            return
        }
        guard let code = values["code"], !code.isEmpty, let clientID else {
            state = .failed(SpotifyAuthorizationError.invalidCallback.localizedDescription)
            return
        }

        do {
            let response = try await catalogService.exchangeAuthorizationCode(
                clientID: clientID,
                code: code,
                codeVerifier: pending.codeVerifier,
                redirectURI: pending.redirectURI
            )
            let record = SpotifyTokenRecord(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
                scope: response.scope
            )
            try saveToken(record)
            state = .authorized(record.expiresAt)
        } catch let error as SpotifyCatalogError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed("无法保存 Spotify 授权凭据")
        }
    }

    private func loadToken() throws -> SpotifyTokenRecord? {
        if hasLoadedToken {
            if let cachedTokenLoadError {
                throw cachedTokenLoadError
            }
            return cachedToken
        }

        do {
            let token = try tokenStore.load()
            hasLoadedToken = true
            cachedToken = token
            cachedTokenLoadError = nil
            return token
        } catch {
            let authError = SpotifyAuthorizationError.tokenStore("无法读取 Spotify 授权凭据")
            hasLoadedToken = true
            cachedTokenLoadError = authError
            throw authError
        }
    }

    private func saveToken(_ record: SpotifyTokenRecord) throws {
        do {
            try tokenStore.save(record)
            hasLoadedToken = true
            cachedToken = record
            cachedTokenLoadError = nil
        } catch {
            throw SpotifyAuthorizationError.tokenStore("无法保存 Spotify 授权凭据")
        }
    }

    private static func randomURLSafeString(length: Int) throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SpotifyAuthorizationError.randomGenerationFailed
        }
        return bytes.map { alphabet[Int($0) % alphabet.count] }.map(String.init).joined()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A short-lived loopback HTTP receiver. Binding is restricted to the local
/// endpoint and local-only connections. The operating system allocates a free
/// port; the resulting runtime callback URI is kept with the pending PKCE flow.
private final class SpotifyLoopbackCallbackServer: @unchecked Sendable {
    typealias Callback = @Sendable (URL) -> Void
    typealias Completion = @Sendable (Result<Int, Error>) -> Void

    private let listener: NWListener
    private let callback: Callback
    private let queue = DispatchQueue(label: "com.spotifylyrics.spotify-oauth-loopback")
    private let lock = NSLock()
    private var completion: Completion?
    private var didComplete = false

    init(callback: @escaping Callback) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        parameters.acceptLocalOnly = true
        self.listener = try NWListener(using: parameters, on: .any)
        self.callback = callback
    }

    func start(completion: @escaping Completion) {
        lock.lock()
        self.completion = completion
        lock.unlock()

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else {
                    self.finish(.failure(CallbackServerError.noPort))
                    return
                }
                self.finish(.success(Int(port)))
            case .failed:
                self.finish(.failure(CallbackServerError.listenerFailed))
            case .cancelled:
                self.finish(.failure(CallbackServerError.cancelled))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }

    private func finish(_ result: Result<Int, Error>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(result)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, _ in
            guard let self, let connection else { return }
            var combined = buffer
            if let data { combined.append(data) }

            if combined.range(of: Data("\r\n\r\n".utf8)) != nil {
                let target = Self.requestTarget(from: combined)
                self.respond(to: connection)
                if let target,
                   let port = self.listener.port?.rawValue,
                   let url = URL(string: "http://127.0.0.1:\(port)\(target)") {
                    self.callback(url)
                }
                return
            }

            guard !isComplete, combined.count < 64 * 1024 else {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: combined)
        }
    }

    private func respond(to connection: NWConnection) {
        let body = "<html><body>SpotifyLyrics 授权完成，可以返回应用。</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func requestTarget(from data: Data) -> String? {
        guard let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first else { return nil }
        let components = line.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "GET" else { return nil }
        return String(components[1])
    }

    private enum CallbackServerError: Error {
        case noPort
        case listenerFailed
        case cancelled
    }
}
