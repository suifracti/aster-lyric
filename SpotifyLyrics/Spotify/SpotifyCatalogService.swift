import Foundation

public enum SpotifyCatalogError: Error, Equatable, Sendable, LocalizedError {
    case unauthorized
    case forbidden
    case badRequest
    case notFound
    case rateLimited(TimeInterval?)
    case networkUnavailable
    case timedOut
    case serverError(Int)
    case parseFailure
    case cancelled
    case invalidURL
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Spotify 在线曲库未授权"
        case .forbidden: return "Spotify 拒绝了目录请求"
        case .badRequest: return "Spotify 搜索请求无效"
        case .notFound: return "Spotify 曲目不存在"
        case .rateLimited: return "Spotify 搜索服务限流"
        case .networkUnavailable: return "Spotify 网络不可用"
        case .timedOut: return "Spotify 搜索请求超时"
        case .serverError(let status): return "Spotify 服务错误（HTTP \(status)）"
        case .parseFailure: return "Spotify 响应解析失败"
        case .cancelled: return "Spotify 搜索已取消"
        case .invalidURL: return "Spotify 请求 URL 无效"
        case .unknown(let value): return value.isEmpty ? "Spotify 未知错误" : value
        }
    }
}

public struct SpotifyOAuthConfiguration: Equatable, Sendable {
    /// Register this portless loopback URI once in the Spotify Dashboard.
    /// The local callback listener adds its dynamically allocated port at
    /// authorization time; Spotify's loopback redirect rules deliberately do
    /// not require every possible local port to be registered.
    public static let dashboardRedirectURI = "http://127.0.0.1/callback"

    public static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/callback"
    }

    public static let authorizationEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    public static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    public static let libraryScopes: Set<String> = ["user-library-read", "user-library-modify"]

    public static let playbackScopes: Set<String> = ["user-read-playback-state"]
    public static let playbackWriteScopes: Set<String> = ["user-modify-playback-state"]
    public static let playlistScopes: Set<String> = [
        "playlist-read-private", "playlist-read-collaborative",
        "playlist-modify-private", "playlist-modify-public"
    ]
    public static let authorizationScopes = libraryScopes
        .union(playbackScopes)
        .union(playbackWriteScopes)
        .union(playlistScopes)

    public static let apiBaseURL = URL(string: "https://api.spotify.com/v1")!

    public let clientID: String?

    public init(clientID: String?) {
        let value = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = value?.isEmpty == false ? value : nil
    }

    public static func resolved() -> SpotifyOAuthConfiguration {
        let defaults = UserDefaults.lyricsQ.string(forKey: "spotify.clientID")
        let environment = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"]
        return SpotifyOAuthConfiguration(clientID: defaults ?? environment)
    }
}

/// HTTP boundary for Spotify Web API and OAuth token exchange. It never logs
/// Authorization headers or token response bodies.
public final class SpotifyCatalogService: @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let authorizationEndpoint: URL
    private let tokenEndpoint: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = SpotifyOAuthConfiguration.apiBaseURL,
        authorizationEndpoint: URL = SpotifyOAuthConfiguration.authorizationEndpoint,
        tokenEndpoint: URL = SpotifyOAuthConfiguration.tokenEndpoint
    ) {
        self.session = session
        self.baseURL = baseURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    func authorizationURL(
        clientID: String,
        state: String,
        codeChallenge: String,
        redirectURI: String = SpotifyOAuthConfiguration.dashboardRedirectURI
    ) throws -> URL {
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw SpotifyCatalogError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "scope", value: SpotifyOAuthConfiguration.authorizationScopes.sorted().joined(separator: " "))
        ]
        guard let url = components.url else { throw SpotifyCatalogError.invalidURL }
        return url
    }

    func exchangeAuthorizationCode(
        clientID: String,
        code: String,
        codeVerifier: String,
        redirectURI: String = SpotifyOAuthConfiguration.dashboardRedirectURI
    ) async throws -> SpotifyTokenResponseDTO {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            ("client_id", clientID),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier)
        ])
        return try await sendTokenRequest(request)
    }

    func refresh(
        clientID: String,
        refreshToken: String
    ) async throws -> SpotifyTokenResponseDTO {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken)
        ])
        return try await sendTokenRequest(request)
    }

    func searchTracks(
        query: String,
        accessToken: String,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> SpotifySearchResponseDTO {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        ) else { throw SpotifyCatalogError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            // Spotify's current Search API caps this parameter at 10. Keep
            // the cap at the HTTP boundary so every caller remains valid.
            URLQueryItem(name: "limit", value: String(min(10, max(1, limit)))),
            URLQueryItem(name: "offset", value: String(max(0, offset)))
        ]
        guard let url = components.url else { throw SpotifyCatalogError.invalidURL }
        let data = try await sendAPIRequest(url: url, accessToken: accessToken)
        do {
            return try JSONDecoder().decode(SpotifySearchResponseDTO.self, from: data)
        } catch {
            throw SpotifyCatalogError.parseFailure
        }
    }

    func fetchTrack(id: String, accessToken: String) async throws -> SpotifyTrackDTO {
        let url = baseURL.appendingPathComponent("tracks").appendingPathComponent(id)
        let data = try await sendAPIRequest(url: url, accessToken: accessToken)
        do {
            return try JSONDecoder().decode(SpotifyTrackDTO.self, from: data)
        } catch {
            throw SpotifyCatalogError.parseFailure
        }
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> SpotifyTokenResponseDTO {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw SpotifyCatalogError.cancelled
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw SpotifyCatalogError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyCatalogError.unknown("Spotify 返回了无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(status: http.statusCode, data: data, response: http)
        }
        do {
            return try JSONDecoder().decode(SpotifyTokenResponseDTO.self, from: data)
        } catch {
            throw SpotifyCatalogError.parseFailure
        }
    }

    func playbackModes(accessToken: String) async throws -> PlayerPlaybackModes {
        let data = try await sendAPIRequest(url: baseURL.appendingPathComponent("me/player"), accessToken: accessToken)
        // 204 means no active playback, not "off".
        guard !data.isEmpty else { return PlayerPlaybackModes(shuffle: nil, repeatMode: nil) }
        struct State: Decodable {
            let shuffle_state: Bool?
            let repeat_state: String?
            let smart_shuffle: Bool?
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { throw SpotifyCatalogError.parseFailure }
        let mode: PlayerRepeatMode?
        switch state.repeat_state {
        case "off": mode = .off
        case "context": mode = .all
        case "track": mode = .one
        default: mode = nil
        }
        return PlayerPlaybackModes(shuffle: state.shuffle_state, repeatMode: mode, smartShuffle: state.smart_shuffle)
    }

    func setPlaybackModes(shuffle: Bool?, repeatMode: PlayerRepeatMode?, accessToken: String) async throws {
        let endpoint: String
        let value: String
        if let shuffle {
            endpoint = "shuffle"
            value = shuffle ? "true" : "false"
        } else if let repeatMode {
            endpoint = "repeat"
            switch repeatMode {
            case .off: value = "off"
            case .all: value = "context"
            case .one: value = "track"
            }
        } else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("me/player/" + endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: value)]
        guard let url = components.url else { throw SpotifyCatalogError.invalidURL }
        _ = try await sendAPIRequest(url: url, accessToken: accessToken, method: "PUT")
    }

    func isTrackSaved(id: String, accessToken: String) async throws -> Bool {
        let data = try await sendAPIRequest(url: libraryTrackURL(id: id, contains: true), accessToken: accessToken)
        guard let value = try JSONDecoder().decode([Bool].self, from: data).first else { throw SpotifyCatalogError.parseFailure }
        return value
    }

    func setTrackSaved(_ saved: Bool, id: String, accessToken: String) async throws {
        _ = try await sendAPIRequest(url: libraryTrackURL(id: id, contains: false), accessToken: accessToken,
                                    method: saved ? "PUT" : "DELETE")
    }

    /// One request for the row's count: a single item plus the page's total.
    func savedTracksTotal(accessToken: String) async throws -> Int {
        guard var parts = URLComponents(url: baseURL.appendingPathComponent("me/tracks"),
                                        resolvingAgainstBaseURL: false) else { throw SpotifyCatalogError.invalidURL }
        parts.queryItems = [URLQueryItem(name: "limit", value: "1")]
        guard let url = parts.url else { throw SpotifyCatalogError.invalidURL }
        let data = try await sendAPIRequest(url: url, accessToken: accessToken)
        struct Page: Decodable { let total: Int }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
            throw SpotifyCatalogError.parseFailure
        }
        return page.total
    }

    private func libraryTrackURL(id: String, contains: Bool) throws -> URL {
        guard let id = TrackIdentity.spotifyRequestTrackID(id),
              var parts = URLComponents(url: baseURL.appendingPathComponent(contains ? "me/library/contains" : "me/library"),
                                        resolvingAgainstBaseURL: false) else { throw SpotifyCatalogError.badRequest }
        parts.queryItems = [URLQueryItem(name: "uris", value: "spotify:track:" + id)]
        guard let url = parts.url else { throw SpotifyCatalogError.invalidURL }
        return url
    }

    // MARK: - Profile

    /// Best-effort account label for the settings status row. The endpoint
    /// answers with the granted scopes; a missing scope only costs the label,
    /// never the stored authorization.
    func currentUserDisplayName(accessToken: String) async throws -> String? {
        let data = try await sendAPIRequest(url: baseURL.appendingPathComponent("me"), accessToken: accessToken)
        struct Profile: Decodable {
            let displayName: String?
            let id: String?
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case id
            }
        }
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return nil }
        if let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return profile.id
    }

    // MARK: - Playlists

    func currentUserPlaylists(accessToken: String) async throws -> [SpotifyPlaylistDTO] {
        var playlists: [SpotifyPlaylistDTO] = []
        var offset = 0
        while true {
            guard var parts = URLComponents(url: baseURL.appendingPathComponent("me/playlists"),
                                            resolvingAgainstBaseURL: false) else {
                throw SpotifyCatalogError.invalidURL
            }
            parts.queryItems = [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            guard let url = parts.url else { throw SpotifyCatalogError.invalidURL }
            let data = try await sendAPIRequest(url: url, accessToken: accessToken)
            let page: SpotifyPlaylistPageDTO
            do { page = try JSONDecoder().decode(SpotifyPlaylistPageDTO.self, from: data) }
            catch { throw SpotifyCatalogError.parseFailure }
            playlists.append(contentsOf: page.items)
            offset += page.items.count
            guard page.next != nil, !page.items.isEmpty else { break }
        }
        return playlists
    }

    func createPrivatePlaylist(named name: String, accessToken: String) async throws -> SpotifyPlaylistDTO {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "public": false])
        let data = try await sendAPIRequest(url: baseURL.appendingPathComponent("me/playlists"),
                                            accessToken: accessToken, method: "POST", body: body)
        do { return try JSONDecoder().decode(SpotifyPlaylistDTO.self, from: data) }
        catch { throw SpotifyCatalogError.parseFailure }
    }

    func playlistTrackIDs(_ playlistID: String, accessToken: String) async throws -> [String] {
        var ids: [String] = []
        var offset = 0
        while true {
            guard var parts = URLComponents(
                url: baseURL.appendingPathComponent("playlists").appendingPathComponent(playlistID)
                    .appendingPathComponent("items"),
                resolvingAgainstBaseURL: false
            ) else { throw SpotifyCatalogError.invalidURL }
            parts.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            guard let url = parts.url else { throw SpotifyCatalogError.invalidURL }
            let data = try await sendAPIRequest(url: url, accessToken: accessToken)
            let page: SpotifyPlaylistItemPageDTO
            do { page = try JSONDecoder().decode(SpotifyPlaylistItemPageDTO.self, from: data) }
            catch { throw SpotifyCatalogError.parseFailure }
            ids.append(contentsOf: page.items.compactMap(\.trackID))
            offset += page.items.count
            guard page.next != nil, !page.items.isEmpty else { break }
        }
        return ids
    }

    func addTrack(_ trackID: String, toPlaylist playlistID: String, accessToken: String) async throws {
        guard let trackID = TrackIdentity.spotifyRequestTrackID(trackID) else { throw SpotifyCatalogError.badRequest }
        let body = try JSONSerialization.data(withJSONObject: ["uris": ["spotify:track:" + trackID]])
        _ = try await sendAPIRequest(url: playlistItemsURL(playlistID), accessToken: accessToken,
                                     method: "POST", body: body)
    }

    func removeTrack(_ trackID: String, fromPlaylist playlistID: String, accessToken: String) async throws {
        guard let trackID = TrackIdentity.spotifyRequestTrackID(trackID) else { throw SpotifyCatalogError.badRequest }
        let body = try JSONSerialization.data(withJSONObject: ["items": [["uri": "spotify:track:" + trackID]]])
        _ = try await sendAPIRequest(url: playlistItemsURL(playlistID), accessToken: accessToken,
                                     method: "DELETE", body: body)
    }

    private func playlistItemsURL(_ playlistID: String) -> URL {
        baseURL.appendingPathComponent("playlists")
            .appendingPathComponent(playlistID)
            .appendingPathComponent("items")
    }

    private func sendAPIRequest(url: URL, accessToken: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw SpotifyCatalogError.cancelled
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw SpotifyCatalogError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyCatalogError.unknown("Spotify 返回了无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(status: http.statusCode, data: data, response: http)
        }
        return data
    }

    private func mapHTTPError(status: Int, data: Data, response: HTTPURLResponse) -> SpotifyCatalogError {
        switch status {
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429:
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(seconds)
        case 500...599: return .serverError(status)
        default:
            if let body = try? JSONDecoder().decode(SpotifyAPIErrorEnvelope.self, from: data),
               let message = body.error.message {
                return .unknown(message)
            }
            return .serverError(status)
        }
    }

    private func mapURLError(_ error: URLError) -> SpotifyCatalogError {
        switch error.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed: return .networkUnavailable
        default: return .unknown(error.localizedDescription)
        }
    }

    private func formData(_ values: [(String, String)]) -> Data {
        let body = values.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
