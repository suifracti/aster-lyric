import Foundation
import Security

/// The user's own Apple Music `media-user-token`, pasted in Settings and kept
/// in the Keychain. Apple serves word-by-word (syllable) lyrics only to a
/// subscriber, so without it this source does nothing.
enum AppleMusicLyricsCredential {
    static let service = "com.spotifylyrics.applemusic-lyrics.v1"
    static let account = "media-user-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return nil }
#endif
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    static var isSet: Bool { load() != nil }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(query as CFDictionary, update) == errSecSuccess { return true }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var trusted: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, let trusted {
            var access: SecAccess?
            if SecAccessCreate("Aster Lyric Apple Music lyrics" as CFString, [trusted] as NSArray as CFArray, &access) == errSecSuccess,
               let access { item[kSecAttrAccess as String] = access }
        }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Apple Music's own lyrics: word-by-word with the singer of each line (TTML
/// `ttm:agent`), the same files the Music app shows. The catalog is read with
/// the public token Apple's web player ships in its script; lyrics also need
/// the user's subscription token. Undocumented for third parties; failures
/// are isolated like the other experimental sources.
public final class AppleMusicLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "Apple Music"
    public let timeoutInterval: TimeInterval = 8
    private let session: URLSession
    private let tokenLock = NSLock()
    private var developerToken: (value: String, expires: Date)?
    private var storefront: String?

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        guard let userToken = AppleMusicLyricsCredential.load() else { return .noMatch }
        do {
            let token = try await webToken()
            let storefront = try await userStorefront(token: token, userToken: userToken)
            let songs = try await findSongs(track: track, storefront: storefront, token: token)
            var candidates: [LyricsCandidate] = []
            for song in songs.prefix(3) {
                if Task.isCancelled { return .failed(.cancelled) }
                guard let ttml = try await lyrics(songID: song.id, storefront: storefront, token: token, userToken: userToken),
                      let document = TTMLParser.parse(ttml, identity: identity, source: .appleMusicCatalog),
                      !document.lines.isEmpty else { continue }
                candidates.append(LyricsCandidate(
                    id: "applemusic:\(song.id)", identity: identity, title: song.title, artist: song.artist,
                    album: song.album, duration: song.duration, lines: document.lines,
                    isSynchronized: document.isSynchronized, source: .appleMusicCatalog, confidence: 0.6,
                    providerSourceID: "applemusic:\(song.id)", isrc: song.isrc, providerName: name))
            }
            LyricsE2ELog.log("APPLEMUSIC songs=\(songs.count) lyrics=\(candidates.count) storefront=\(storefront)")
            return candidates.isEmpty ? .noMatch : .candidates(candidates)
        } catch let failure as LyricsFailure {
            return .failed(failure)
        } catch {
            if Task.isCancelled { return .failed(.cancelled) }
            return .failed(.unknown(error.localizedDescription))
        }
    }

    // MARK: Requests

    private func request(_ url: URL, token: String, userToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let userToken { request.setValue(userToken, forHTTPHeaderField: "media-user-token") }
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        if http.statusCode == 401 || http.statusCode == 403 { throw LyricsFailure.unknown("Apple Music 令牌无效或订阅不可用（\(http.statusCode)）") }
        guard (200..<300).contains(http.statusCode) else { throw LyricsFailure.serverError(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsFailure.parseFailure }
        return object
    }

    /// The token Apple's web player uses, read from its script; the newest
    /// one that has not expired. Kept until it expires.
    private func webToken() async throws -> String {
        if let cached = tokenLock.withLock({ developerToken }), cached.expires > Date().addingTimeInterval(600) {
            return cached.value
        }
        var page = URLRequest(url: URL(string: "https://music.apple.com/us/browse")!, timeoutInterval: timeoutInterval)
        page.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (html, _) = try await session.data(for: page)
        let text = String(decoding: html, as: UTF8.self)
        let scripts = text.matches(of: /\/assets\/index[^"'<>\s]*?\.js/).map { String($0.output) }
            .filter { !$0.contains("legacy") }
        for path in scripts {
            guard let url = URL(string: "https://music.apple.com" + path) else { continue }
            var script = URLRequest(url: url, timeoutInterval: timeoutInterval)
            script.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: script)
            let body = String(decoding: data, as: UTF8.self)
            let best = body.matches(of: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)
                .compactMap { match -> (String, Date)? in
                    let token = String(match.output)
                    guard let expiry = Self.expiry(of: token), expiry > Date() else { return nil }
                    return (token, expiry)
                }
                .max { $0.1 < $1.1 }
            if let best {
                tokenLock.withLock { developerToken = (best.0, best.1) }
                return best.0
            }
        }
        throw LyricsFailure.unknown("没有找到 Apple Music 网页令牌")
    }

    static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func userStorefront(token: String, userToken: String) async throws -> String {
        if let storefront = tokenLock.withLock({ storefront }) { return storefront }
        let object = try await json(request(URL(string: "https://amp-api.music.apple.com/v1/me/storefront")!,
                                            token: token, userToken: userToken))
        let id = ((object["data"] as? [[String: Any]])?.first?["id"] as? String) ?? "us"
        tokenLock.withLock { storefront = id }
        return id
    }

    struct Song { let id: String; let title: String; let artist: String; let album: String; let duration: TimeInterval; let isrc: String? }

    static func songs(from object: [String: Any]) -> [Song] {
        let list = ((object["results"] as? [String: Any])?["songs"] as? [String: Any])?["data"] as? [[String: Any]]
            ?? object["data"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any],
                  let title = attributes["name"] as? String else { return nil }
            return Song(id: id, title: title, artist: attributes["artistName"] as? String ?? "",
                        album: attributes["albumName"] as? String ?? "",
                        duration: (attributes["durationInMillis"] as? Double ?? 0) / 1000,
                        isrc: attributes["isrc"] as? String)
        }
    }

    /// By ISRC when the track has one, else by title and artist; songs far
    /// from the track's length are not asked for lyrics.
    private func findSongs(track: Track, storefront: String, token: String) async throws -> [Song] {
        var parts = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs")!
        if let isrc = track.isrc, !isrc.isEmpty {
            parts.queryItems = [URLQueryItem(name: "filter[isrc]", value: isrc)]
            let found = Self.songs(from: try await json(request(parts.url!, token: token)))
            if !found.isEmpty { return found }
        }
        parts = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        let artist = TrackTextNormalizer.artistTokens(track.artist).primary
        parts.queryItems = [URLQueryItem(name: "term", value: "\(track.title) \(artist)"),
                            URLQueryItem(name: "types", value: "songs"), URLQueryItem(name: "limit", value: "8")]
        let found = Self.songs(from: try await json(request(parts.url!, token: token)))
        guard track.duration > 0 else { return found }
        return found.filter { $0.duration <= 0 || abs($0.duration - track.duration) <= 4 }
    }

    /// Syllable lyrics when Apple has them, else line lyrics.
    private func lyrics(songID: String, storefront: String, token: String, userToken: String) async throws -> String? {
        var parts = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(songID)")!
        parts.queryItems = [URLQueryItem(name: "include[songs]", value: "syllable-lyrics,lyrics"),
                            URLQueryItem(name: "l", value: "zh-Hans-CN")]
        let object = try await json(request(parts.url!, token: token, userToken: userToken))
        guard let song = (object["data"] as? [[String: Any]])?.first,
              let relationships = song["relationships"] as? [String: Any] else { return nil }
        for key in ["syllable-lyrics", "lyrics"] {
            if let entry = ((relationships[key] as? [String: Any])?["data"] as? [[String: Any]])?.first,
               let ttml = (entry["attributes"] as? [String: Any])?["ttml"] as? String, !ttml.isEmpty {
                return ttml
            }
        }
        return nil
    }
}
