import Foundation

/// Stable identity for a playback snapshot. The metadata fingerprint is always
/// included so a Track ID is never the sole comparison value.
public struct TrackIdentity: Hashable, Sendable, CustomStringConvertible {
    public let spotifyTrackID: String?
    public let spotifyURI: String?
    public let isrc: String?
    public let metadataFingerprint: String
    public let stableKey: String

    public init(track: Track) {
        // Spotify has historically reached this app in three shapes: a bare
        // base62 ID, a spotify:track URI, and an open.spotify.com URL.  Keep
        // one canonical representation at the identity boundary so those
        // shapes cannot create three physical Track identities.
        let normalizedID = Self.canonicalSpotifyTrackID(track.spotifyId)
            ?? Self.canonicalSpotifyTrackID(track.spotifyURL?.absoluteString)
        let normalizedURI = normalizedID.map { "spotify:track:\($0)" }
        let normalizedISRC = Self.normalizeIdentifier(track.isrc)

        self.spotifyTrackID = normalizedID
        self.spotifyURI = normalizedURI
        self.isrc = normalizedISRC
        self.metadataFingerprint = Self.metadataFingerprint(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration
        )

        let primary: String
        if let normalizedID {
            primary = "spotify-id:\(normalizedID)"
        } else if let normalizedURI {
            primary = "spotify-uri:\(normalizedURI)"
        } else if let normalizedISRC {
            primary = "isrc:\(normalizedISRC)"
        } else {
            primary = "metadata:\(metadataFingerprint)"
        }
        self.stableKey = "\(primary)|metadata:\(metadataFingerprint)"
    }

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        spotifyTrackID: String? = nil,
        spotifyURI: String? = nil,
        isrc: String? = nil
    ) {
        let track = Track(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            isrc: isrc,
            spotifyId: spotifyTrackID,
            spotifyURL: spotifyURI.flatMap(URL.init(string:))
        )
        self.init(track: track)
    }

    /// Keys used by read-only local lookup, ordered by identity strength.
    public var lookupKeys: [String] {
        var keys: [String] = []
        if let spotifyTrackID {
            keys.append("spotify-id:\(spotifyTrackID)")
        }
        if let spotifyURI {
            keys.append("spotify-uri:\(spotifyURI)")
        }
        if let isrc {
            keys.append("isrc:\(isrc)")
        }
        keys.append("metadata:\(metadataFingerprint)")
        return keys
    }

    public var description: String { stableKey }

    /// Playback bindings use the player's recording ID; search still uses the full metadata identity.
    public static func playbackID(for track: Track) -> String? {
        if let id = normalizeIdentifier(track.spotifyId), id.hasPrefix("applemusic:"), id.count > "applemusic:".count {
            return id
        }
        return (canonicalSpotifyTrackID(track.spotifyId) ?? canonicalSpotifyTrackID(track.spotifyURL?.absoluteString))
            .map { "spotify:track:\($0)" }
    }

    public static func normalizedComponent(_ value: String) -> String {
        let folded = value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        let scalars = folded.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    public static func normalizeIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Returns the canonical lower-case Spotify track ID for a bare ID,
    /// spotify:track URI, or open.spotify.com track URL.  This deliberately
    /// rejects album, artist, episode, and malformed URLs instead of treating
    /// them as opaque IDs.
    public static func canonicalSpotifyTrackID(_ value: String?) -> String? {
        spotifyRequestTrackID(value)?.lowercased()
    }

    /// Spotify request IDs retain their base62 case. Saved identity keys keep
    /// using canonicalSpotifyTrackID so existing lyric assets do not move.
    public static func spotifyRequestTrackID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("spotify:") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0].lowercased() == "spotify",
                  parts[1].lowercased() == "track" else {
                return nil
            }
            return bareSpotifyID(String(parts[2]))
        }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host == "open.spotify.com",
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 2,
                  components[0].lowercased() == "track" else {
                return nil
            }
            return bareSpotifyID(String(components[1]).removingPercentEncoding ?? "")
        }

        // A bare ID is kept intentionally permissive enough for existing
        // synthetic/test identities, while still rejecting whitespace,
        // punctuation, URI prefixes, and path-like strings. Hyphen and
        // underscore are accepted for historical synthetic IDs; real Spotify
        // IDs remain base62.
        return bareSpotifyID(trimmed)
    }

    /// Returns the canonical spotify:track URI for any accepted Spotify track
    /// identifier shape.
    public static func canonicalSpotifyURI(_ value: String?) -> String? {
        guard let id = canonicalSpotifyTrackID(value) else { return nil }
        return "spotify:track:\(id)"
    }

    public static func metadataFingerprint(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> String {
        let roundedDuration = max(0, Int(duration.rounded()))
        return [
            normalizedComponent(title),
            normalizedComponent(artist),
            normalizedComponent(album),
            String(roundedDuration)
        ].joined(separator: "|")
    }

    private static func bareSpotifyID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmed.utf8.count),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x30 && scalar.value <= 0x39 ||
                  scalar.value >= 0x41 && scalar.value <= 0x5A ||
                  scalar.value >= 0x61 && scalar.value <= 0x7A ||
                  scalar.value == 0x2D || scalar.value == 0x5F
              }) else {
            return nil
        }
        return trimmed
    }
}

public enum TrackIdentityRedirectError: Error, Equatable, Sendable, LocalizedError {
    case cycle([String])
    case maxDepthExceeded
    case missingTarget(source: String, target: String)

    public var errorDescription: String? {
        switch self {
        case .cycle(let keys):
            return "Track identity redirect cycle: \(keys.joined(separator: " -> "))"
        case .maxDepthExceeded:
            return "Track identity redirect chain exceeds the supported depth"
        case .missingTarget(let source, let target):
            return "Track identity redirect target is missing: \(source) -> \(target)"
        }
    }
}

/// Resolves persisted Track identity redirects without changing physical rows.
/// The resolver is deliberately immutable so reads in the repository cannot
/// silently mutate redirect state or overwrite a conflicting mapping.
public struct TrackIdentityRedirectResolver: Sendable, Equatable {
    public let redirects: [String: String]
    public let knownStableKeys: Set<String>
    public let maxDepth: Int

    public init(
        redirects: [String: String],
        knownStableKeys: Set<String>,
        maxDepth: Int = 32
    ) {
        self.redirects = redirects
        self.knownStableKeys = knownStableKeys
        self.maxDepth = max(1, maxDepth)
    }

    public func resolve(_ stableKey: String) throws -> String {
        var current = stableKey
        var visited: [String] = []

        for _ in 0..<maxDepth {
            if let cycleStart = visited.firstIndex(of: current) {
                throw TrackIdentityRedirectError.cycle(visited[cycleStart...] + [current])
            }
            visited.append(current)

            guard let next = redirects[current] else {
                return current
            }
            guard knownStableKeys.contains(next) else {
                throw TrackIdentityRedirectError.missingTarget(source: current, target: next)
            }
            current = next
        }

        throw TrackIdentityRedirectError.maxDepthExceeded
    }

    /// Returns the logical identity family with the final canonical key first.
    /// Physical source rows remain present and are only deduplicated in memory.
    public func identityFamily(for stableKey: String) throws -> [String] {
        let canonical = try resolve(stableKey)
        var family = Set([canonical, stableKey])
        for key in knownStableKeys where key != canonical {
            if try resolve(key) == canonical {
                family.insert(key)
            }
        }
        return [canonical] + family.filter { $0 != canonical }.sorted()
    }
}
