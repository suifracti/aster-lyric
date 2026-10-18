import Foundation

/// Enrichment envelope around a playback `Track` snapshot.
/// Aliases never mutate `track.title` / identity stableKey.
public struct TrackMetadata: Equatable, Sendable {
    public let identity: TrackIdentity
    public let track: Track
    public var aliases: [TrackAlias]
    public var versionTags: [VersionTag]
    /// Complete artists verified against Spotify's exact track ID, title and duration.
    /// Playback identity and the original display metadata remain unchanged.
    public var verifiedSpotifyArtists: [String] = []

    public init(
        identity: TrackIdentity,
        track: Track,
        aliases: [TrackAlias] = [],
        versionTags: [VersionTag] = []
    ) {
        self.identity = identity
        self.track = track
        self.aliases = aliases
        self.versionTags = versionTags
    }

    public static func bootstrap(from track: Track) -> TrackMetadata {
        let identity = TrackIdentity(track: track)
        var aliases: [TrackAlias] = [
            TrackAlias(
                id: "orig-title",
                field: .title,
                kind: .original,
                value: track.title,
                language: ScriptDetector.guessLanguage(track.title),
                script: ScriptDetector.detect(track.title),
                source: .spotifyMetadata,
                confidence: 1,
                isOfficial: true
            ),
            TrackAlias(
                id: "orig-artist",
                field: .artist,
                kind: .original,
                value: track.artist,
                language: ScriptDetector.guessLanguage(track.artist),
                script: ScriptDetector.detect(track.artist),
                source: .spotifyMetadata,
                confidence: 1,
                isOfficial: true
            )
        ]

        if let titleRomaji = JapaneseRomanizer.romanizeIfMostlyKana(track.title) {
            aliases.append(
                TrackAlias(
                    id: "romaji-title",
                    field: .title,
                    kind: .romaji,
                    value: titleRomaji,
                    language: "ja-Latn",
                    script: .latin,
                    source: .deterministicTransliteration,
                    confidence: 0.72,
                    isOfficial: false
                )
            )
        }
        if let artistRomaji = JapaneseRomanizer.romanizeIfMostlyKana(track.artist) {
            aliases.append(
                TrackAlias(
                    id: "romaji-artist",
                    field: .artist,
                    kind: .romaji,
                    value: artistRomaji,
                    language: "ja-Latn",
                    script: .latin,
                    source: .deterministicTransliteration,
                    confidence: 0.72,
                    isOfficial: false
                )
            )
        }

        aliases.append(contentsOf: verifiedLocalizedTitleAliases(for: track, identity: identity))
        let tags = TrackTextNormalizer.extractVersionTags(fromTitle: track.title)
        return TrackMetadata(identity: identity, track: track, aliases: aliases, versionTags: tags)
    }

    /// One publisher-declared localized title, scoped to its exact Spotify recording.
    /// Verified 2026-10-09: https://linkco.re/Sbs3VHBC?lang=ja and ?lang=en.
    /// The publisher's Spotify link redirects to album 76hqFIJHX8epoaSztfSr1Z;
    /// Spotify declares the requested recording as its only track. The NetEase
    /// link is merely a search URL: it is NOT an independent source-ID/ISRC map.
    /// This adds title evidence only; artist, recording and version barriers stay intact.
    private static func verifiedLocalizedTitleAliases(for track: Track, identity: TrackIdentity) -> [TrackAlias] {
        let declaredTitles = ["The day i became a star", "星になった日"].map(TrackTextNormalizer.normalize)
        let declaredArtists = ["HIBANA", "ヒバナ"].map(TrackTextNormalizer.normalize)
        guard identity.spotifyTrackID == "2flmegp9ci94sx8u7gpseo",
              declaredTitles.contains(TrackTextNormalizer.normalize(track.title)),
              declaredArtists.contains(TrackTextNormalizer.normalize(track.artist)),
              declaredTitles.contains(TrackTextNormalizer.normalize(track.album)) else { return [] }
        return [TrackAlias(
            id: "tunecore:Sbs3VHBC:title:ja",
            field: .title,
            kind: .localizedTitle,
            value: "星になった日",
            language: "ja",
            script: .kanjiHiraganaKatakana,
            source: .provider,
            confidence: 1,
            isOfficial: true
        )]
    }

    public func aliases(for field: TrackAliasField, kind: TrackAliasKind? = nil) -> [TrackAlias] {
        aliases.filter { $0.field == field && (kind == nil || $0.kind == kind) }
    }
}

/// Credential-free, bounded enrichment for incomplete Desktop artist metadata.
/// Only Spotify's exact track entity is read; lyric-provider names never attest identity.
public actor SpotifyTrackArtistResolver {
    public static let shared = SpotifyTrackArtistResolver()

    private struct TrackArtists: Sendable {
        let title: String
        let duration: TimeInterval
        let names: [String]

        func matches(_ track: Track) -> Bool {
            guard TrackTextNormalizer.normalize(title) == TrackTextNormalizer.normalize(track.title),
                  track.duration.isFinite, track.duration > 0, abs(duration - track.duration) <= 2,
                  let primary = names.first else { return false }
            let known = TrackTextNormalizer.artistTokens(track.artist)
            let official = Set(names.map(TrackTextNormalizer.normalizeArtistToken))
            let expected = Set(known.all.map(TrackTextNormalizer.normalizeArtistToken).filter { !$0.isEmpty })
            return !expected.isEmpty && expected.isSubset(of: official)
                && TrackTextNormalizer.normalizeArtistToken(known.primary) == TrackTextNormalizer.normalizeArtistToken(primary)
        }
    }

    private struct Cached: Sendable {
        let value: TrackArtists?
        let expires: Date
    }

    private let session: URLSession
    private var cache: [String: Cached] = [:]
    private var inFlight: [String: Task<TrackArtists?, Never>] = [:]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 6
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func artists(for track: Track) async -> [String]? {
        guard let result = await metadata(for: track), result.matches(track) else { return nil }
        return result.names
    }

    /// Exact Spotify entity identity and duration can establish localized names
    /// even when Desktop and the lyric source use different scripts. Provider
    /// candidate names are never used to manufacture these aliases.
    public func aliases(for track: Track) async -> [TrackAlias] {
        guard let result = await metadata(for: track), track.duration.isFinite,
              track.duration > 0, abs(result.duration - track.duration) <= 2 else { return [] }
        let title = TrackAlias(id: "spotify-entity-title", field: .title, kind: .localizedTitle,
            value: result.title, script: ScriptDetector.detect(result.title), source: .spotifyMetadata,
            confidence: 1, isOfficial: true)
        let artists = result.names.enumerated().map { index, name in
            TrackAlias(id: "spotify-entity-artist-\(index)", field: .artist, kind: .localizedTitle,
                value: name, script: ScriptDetector.detect(name), source: .spotifyMetadata,
                confidence: 1, isOfficial: true)
        }
        return [title] + artists
    }

    private func metadata(for track: Track) async -> TrackArtists? {
        guard !Task.isCancelled, let id = Self.exactTrackID(track) else { return nil }
        if let cached = cache[id], cached.expires > Date() {
            return cached.value
        }
        let task: Task<TrackArtists?, Never>
        if let pending = inFlight[id] {
            task = pending
        } else {
            task = Task { [session] in await Self.fetch(id: id, session: session) }
            inFlight[id] = task
        }
        let result = await task.value
        inFlight.removeValue(forKey: id)
        cache = cache.filter { $0.value.expires > Date() }
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[id] = Cached(value: result, expires: Date().addingTimeInterval(result == nil ? 60 : 3600))
        guard !Task.isCancelled else { return nil }
        return result
    }

    private static func exactTrackID(_ track: Track) -> String? {
        func extract(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let id: String
            if value.hasPrefix("spotify:track:") {
                id = String(value.dropFirst("spotify:track:".count))
            } else if let url = URL(string: value), url.scheme == "https", url.host == "open.spotify.com" {
                let parts = url.path.split(separator: "/")
                guard parts.count == 2, parts[0] == "track" else { return nil }
                id = String(parts[1])
            } else {
                id = value
            }
            guard id.count == 22, id.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { return nil }
            return id
        }
        let fromID = track.spotifyId.flatMap(extract)
        let fromURL = track.spotifyURL.flatMap { extract($0.absoluteString) }
        if let fromID, let fromURL, fromID != fromURL { return nil }
        return fromID ?? fromURL
    }

    private static func fetch(id: String, session: URLSession) async -> TrackArtists? {
        guard let url = URL(string: "https://open.spotify.com/embed/track/\(id)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url == url, data.count <= 524_288,
                  let html = String(data: data, encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*\bid=["']__NEXT_DATA__["'][^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let root = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any],
                  let props = root["props"] as? [String: Any],
                  let page = props["pageProps"] as? [String: Any],
                  let state = page["state"] as? [String: Any],
                  let content = state["data"] as? [String: Any],
                  let entity = content["entity"] as? [String: Any],
                  entity["type"] as? String == "track", entity["id"] as? String == id,
                  entity["uri"] as? String == "spotify:track:\(id)",
                  let title = entity["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let milliseconds = entity["duration"] as? Double, milliseconds.isFinite, milliseconds > 0,
                  let artists = entity["artists"] as? [[String: Any]], !artists.isEmpty, artists.count <= 16 else { return nil }
            let names = artists.compactMap { artist -> String? in
                guard let name = artist["name"] as? String,
                      let uri = artist["uri"] as? String, uri.hasPrefix("spotify:artist:") else { return nil }
                let nameValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let artistID = String(uri.dropFirst("spotify:artist:".count))
                guard !nameValue.isEmpty, artistID.count == 22,
                      artistID.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { return nil }
                return nameValue
            }
            guard names.count == artists.count else { return nil }
            return TrackArtists(title: title, duration: milliseconds / 1000, names: names)
        } catch {
            return nil
        }
    }
}

enum ScriptDetector {
    static func detect(_ text: String) -> TrackAliasScript {
        var hasJP = false
        var hasLatin = false
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                hasJP = true
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                hasLatin = true
            }
        }
        switch (hasJP, hasLatin) {
        case (true, true): return .mixed
        case (true, false): return .kanjiHiraganaKatakana
        case (false, true): return .latin
        default: return .unknown
        }
    }

    static func guessLanguage(_ text: String) -> String? {
        switch detect(text) {
        case .kanjiHiraganaKatakana: return "ja"
        case .latin: return "und"
        case .mixed: return "ja"
        case .unknown: return nil
        }
    }
}
