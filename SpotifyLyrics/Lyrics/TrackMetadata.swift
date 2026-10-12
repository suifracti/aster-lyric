import Foundation

/// Enrichment envelope around a playback `Track` snapshot.
/// Aliases never mutate `track.title` / identity stableKey.
public struct TrackMetadata: Equatable, Sendable {
    public let identity: TrackIdentity
    public let track: Track
    public var aliases: [TrackAlias]
    public var versionTags: [VersionTag]

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
