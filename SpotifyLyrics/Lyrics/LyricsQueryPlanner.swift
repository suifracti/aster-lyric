import Foundation

/// Compatibility strategy names kept for diagnostics and older callers.
/// `queryKind` is the authoritative evidence-strength label used by
/// LyricsSafeMatcher.
public enum LyricsQueryStrategy: String, Codable, Sendable, CaseIterable {
    case primaryOriginal
    case primaryArtist
    case normalizedPrimary
    case normalizedArtist
    case normalizedVersionFullArtist
    case normalizedVersionPrimaryArtist
    case kanaTitleArtist
    case romajiTitleArtist
    case officialEnglish
    case knownAliases
    case manualOverride
    case titleOnlyLoose
}

/// Query material is deliberately tagged. A result found through a loose
/// title-only query must not receive the same confidence as an exact query.
public enum LyricsQueryKind: String, Codable, Sendable, CaseIterable {
    case exactTitleFullArtist
    case exactTitlePrimaryArtist
    case normalizedTitleFullArtist
    case normalizedTitlePrimaryArtist
    case normalizedVersionTitleFullArtist
    case normalizedVersionTitlePrimaryArtist
    case kanaAlias
    case romajiAlias
    case officialEnglishAlias
    case confirmedAlias
    case manualOverride
    case titleOnlyLoose

    public var displayName: String {
        switch self {
        case .exactTitleFullArtist: return "精确标题 + 完整艺人"
        case .exactTitlePrimaryArtist: return "精确标题 + 主艺人"
        case .normalizedTitleFullArtist: return "规范化标题 + 完整艺人"
        case .normalizedTitlePrimaryArtist: return "规范化标题 + 主艺人"
        case .normalizedVersionTitleFullArtist: return "去版本标记标题 + 完整艺人"
        case .normalizedVersionTitlePrimaryArtist: return "去版本标记标题 + 主艺人"
        case .kanaAlias: return "假名别名"
        case .romajiAlias: return "罗马音别名"
        case .officialEnglishAlias: return "官方英文别名"
        case .confirmedAlias: return "已确认别名"
        case .manualOverride: return "手动搜索词"
        case .titleOnlyLoose: return "宽松标题查询"
        }
    }

    public var isLoose: Bool {
        self == .titleOnlyLoose
    }

    public var isAlias: Bool {
        switch self {
        case .kanaAlias, .romajiAlias, .officialEnglishAlias, .confirmedAlias:
            return true
        case .exactTitleFullArtist, .exactTitlePrimaryArtist,
             .normalizedTitleFullArtist, .normalizedTitlePrimaryArtist,
             .normalizedVersionTitleFullArtist, .normalizedVersionTitlePrimaryArtist,
             .manualOverride,
             .titleOnlyLoose:
            return false
        }
    }
}

public struct LyricsQueryVariant: Equatable, Identifiable, Sendable {
    public var id: String { "\(rank)-\(queryKind.rawValue)-\(strategy.rawValue)" }
    public let rank: Int
    public let strategy: LyricsQueryStrategy
    public let queryKind: LyricsQueryKind
    public let titleQuery: String
    public let artistQuery: String?
    public let aliasIDs: [String]

    /// Source-compatible initializer used by older contracts.
    public init(
        rank: Int,
        strategy: LyricsQueryStrategy,
        titleQuery: String,
        artistQuery: String?,
        aliasIDs: [String] = []
    ) {
        self.init(
            rank: rank,
            strategy: strategy,
            queryKind: Self.defaultKind(for: strategy),
            titleQuery: titleQuery,
            artistQuery: artistQuery,
            aliasIDs: aliasIDs
        )
    }

    public init(
        rank: Int,
        strategy: LyricsQueryStrategy,
        queryKind: LyricsQueryKind,
        titleQuery: String,
        artistQuery: String?,
        aliasIDs: [String] = []
    ) {
        self.rank = rank
        self.strategy = strategy
        self.queryKind = queryKind
        self.titleQuery = titleQuery
        self.artistQuery = artistQuery
        self.aliasIDs = aliasIDs
    }

    private static func defaultKind(for strategy: LyricsQueryStrategy) -> LyricsQueryKind {
        switch strategy {
        case .primaryOriginal: return .exactTitleFullArtist
        case .primaryArtist: return .exactTitlePrimaryArtist
        case .normalizedPrimary: return .normalizedTitleFullArtist
        case .normalizedArtist: return .normalizedTitlePrimaryArtist
        case .normalizedVersionFullArtist: return .normalizedVersionTitleFullArtist
        case .normalizedVersionPrimaryArtist: return .normalizedVersionTitlePrimaryArtist
        case .kanaTitleArtist: return .kanaAlias
        case .romajiTitleArtist: return .romajiAlias
        case .officialEnglish: return .officialEnglishAlias
        case .knownAliases: return .confirmedAlias
        case .manualOverride: return .manualOverride
        case .titleOnlyLoose: return .titleOnlyLoose
        }
    }
}

public enum LyricsQueryPlanner {
    public static func plan(
        for metadata: TrackMetadata,
        manualQuery: String? = nil
    ) -> [LyricsQueryVariant] {
        var built: [LyricsQueryVariant] = []
        var seenMaterial = Set<String>()

        func add(
            _ strategy: LyricsQueryStrategy,
            kind: LyricsQueryKind,
            title: String,
            artist: String?,
            aliasIDs: [String] = []
        ) {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { return }
            let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep raw query material in the de-duplication key. A case,
            // width, or punctuation-folded variant is intentionally retained
            // as a separate query kind so the matcher can see how it was
            // obtained and apply the appropriate evidence penalty.
            let materialKey = (kind == .manualOverride ? kind.rawValue + "|" : "")
                + trimmedTitle.precomposedStringWithCanonicalMapping
                + "|"
                + (trimmedArtist ?? "").precomposedStringWithCanonicalMapping
            guard !materialKey.isEmpty, seenMaterial.insert(materialKey).inserted else { return }

            built.append(
                LyricsQueryVariant(
                    rank: built.count + 1,
                    strategy: strategy,
                    queryKind: kind,
                    titleQuery: trimmedTitle,
                    artistQuery: (trimmedArtist?.isEmpty == false) ? trimmedArtist : nil,
                    aliasIDs: aliasIDs
                )
            )
        }

        let originalTitle = metadata.track.title
        let fullArtist = metadata.track.artist
        let primaryArtist = TrackTextNormalizer.artistTokens(fullArtist).primary
        let normalizedTitle = TrackTextNormalizer.normalize(originalTitle)
        let normalizedFullArtist = TrackTextNormalizer.normalize(fullArtist)
        let normalizedPrimaryArtist = TrackTextNormalizer.normalize(primaryArtist)
        let versionStrippedTitle = TrackTextNormalizer.stripVersionMarkers(fromTitle: originalTitle)
        let normalizedVersionTitle = TrackTextNormalizer.normalize(versionStrippedTitle)

        // A user-provided search term is a controlled first probe. It never
        // changes TrackIdentity and remains subject to SafeMatcher evidence.
        if let manualQuery {
            add(
                .manualOverride,
                kind: .manualOverride,
                title: manualQuery,
                artist: fullArtist
            )
            add(
                .manualOverride,
                kind: .manualOverride,
                title: manualQuery,
                artist: nil
            )
        }

        func differsBeyondCaseAndWidth(_ original: String, _ normalized: String) -> Bool {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            let foldedOriginal = original.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
            let foldedNormalized = normalized.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
            return foldedOriginal != foldedNormalized
        }

        // 1–4: strict identity evidence, from exact to normalized material.
        add(
            .primaryOriginal,
            kind: .exactTitleFullArtist,
            title: originalTitle,
            artist: fullArtist
        )
        add(
            .primaryArtist,
            kind: .exactTitlePrimaryArtist,
            title: originalTitle,
            artist: primaryArtist
        )
        if differsBeyondCaseAndWidth(originalTitle, normalizedTitle)
            || differsBeyondCaseAndWidth(fullArtist, normalizedFullArtist) {
            add(
                .normalizedPrimary,
                kind: .normalizedTitleFullArtist,
                title: normalizedTitle,
                artist: normalizedFullArtist
            )
        }
        if differsBeyondCaseAndWidth(originalTitle, normalizedTitle)
            || differsBeyondCaseAndWidth(primaryArtist, normalizedPrimaryArtist) {
            add(
                .normalizedArtist,
                kind: .normalizedTitlePrimaryArtist,
                title: normalizedTitle,
                artist: normalizedPrimaryArtist
            )
        }

        // Remove version markers only for a controlled fallback query. The
        // original version traits remain in metadata, so SafeMatcher still
        // blocks Live/Remix/Cover/Instrumental conflicts.
        if !normalizedVersionTitle.isEmpty,
           normalizedVersionTitle != normalizedTitle {
            // Preserve Japanese spelling for providers that do not fold kana width.
            add(
                .normalizedVersionFullArtist,
                kind: .normalizedVersionTitleFullArtist,
                title: versionStrippedTitle,
                artist: fullArtist
            )
            add(
                .normalizedVersionFullArtist,
                kind: .normalizedVersionTitleFullArtist,
                title: normalizedVersionTitle,
                artist: normalizedFullArtist
            )
            add(
                .normalizedVersionPrimaryArtist,
                kind: .normalizedVersionTitlePrimaryArtist,
                title: normalizedVersionTitle,
                artist: normalizedPrimaryArtist
            )
        }

        // 5: provider/user/official aliases. Alias source and confidence are
        // retained in aliasIDs; SafeMatcher applies their evidence ceiling.
        let kanaTitles = metadata.aliases(for: .title, kind: .kana)
        let kanaArtists = metadata.aliases(for: .artist, kind: .kana)
        for titleAlias in kanaTitles {
            let artist = kanaArtists.first?.value ?? primaryArtist
            let ids = [titleAlias.id] + (kanaArtists.first.map { [$0.id] } ?? [])
            add(.kanaTitleArtist, kind: .kanaAlias, title: titleAlias.value, artist: artist, aliasIDs: ids)
        }

        let romajiTitles = metadata.aliases(for: .title, kind: .romaji)
        let romajiArtists = metadata.aliases(for: .artist, kind: .romaji)
        if romajiTitles.isEmpty,
           let generatedTitle = JapaneseRomanizer.romanizeIfMostlyKana(originalTitle) {
            let generatedArtist = romajiArtists.first?.value
                ?? JapaneseRomanizer.romanizeIfMostlyKana(primaryArtist)
                ?? primaryArtist
            add(.romajiTitleArtist, kind: .romajiAlias, title: generatedTitle, artist: generatedArtist)
        } else {
            for titleAlias in romajiTitles {
                let artist = romajiArtists.first?.value
                    ?? JapaneseRomanizer.romanizeIfMostlyKana(primaryArtist)
                    ?? primaryArtist
                let ids = [titleAlias.id] + (romajiArtists.first.map { [$0.id] } ?? [])
                add(.romajiTitleArtist, kind: .romajiAlias, title: titleAlias.value, artist: artist, aliasIDs: ids)
            }
        }

        let officialEnglishTitles = metadata.aliases(for: .title, kind: .officialEnglish)
            .filter { $0.isOfficial || $0.source == .spotifyMetadata }
        for titleAlias in officialEnglishTitles {
            add(
                .officialEnglish,
                kind: .officialEnglishAlias,
                title: titleAlias.value,
                artist: fullArtist,
                aliasIDs: [titleAlias.id]
            )
        }

        let knownKinds: [TrackAliasKind] = [.alternativeTitle, .localizedTitle, .providerAlias, .userAlias]
        for titleAlias in metadata.aliases
            where titleAlias.field == .title && knownKinds.contains(titleAlias.kind) {
            add(
                .knownAliases,
                kind: .confirmedAlias,
                title: titleAlias.value,
                artist: fullArtist,
                aliasIDs: [titleAlias.id]
            )
        }

        // Spotify's exact-track entity can expose the canonical localized
        // title and every credited artist while Desktop shows one localized
        // artist spelling. Query a small title/artist cross-product so sources
        // such as NetEase can find the same recording without title-specific
        // lookup rules. Keep these queries artist-scoped and bounded.
        let officialSpotifyArtists = metadata.aliases
            .filter { $0.field == .artist && $0.source == .spotifyMetadata && $0.isOfficial }
            .prefix(3)
        let officialSpotifyTitles = metadata.aliases
            .filter { $0.field == .title && $0.source == .spotifyMetadata && $0.isOfficial }
        for artistAlias in officialSpotifyArtists {
            add(.primaryArtist, kind: .exactTitlePrimaryArtist, title: originalTitle,
                artist: artistAlias.value, aliasIDs: [artistAlias.id])
        }
        var officialAliasPairs = 0
        for titleAlias in officialSpotifyTitles {
            for artistAlias in officialSpotifyArtists {
                guard officialAliasPairs < 4 else { break }
                officialAliasPairs += 1
                add(.knownAliases, kind: .confirmedAlias, title: titleAlias.value,
                    artist: artistAlias.value, aliasIDs: [titleAlias.id, artistAlias.id])
            }
            if officialAliasPairs >= 4 { break }
        }

        // 6: only at the end may a version-stripped title be searched without
        // an artist. This is deliberately marked loose so it cannot auto
        // adopt a same-title Live/remix/cover result.
        add(.titleOnlyLoose, kind: .titleOnlyLoose, title: originalTitle, artist: nil)
        let baseTitle = TrackTextNormalizer.stripVersionMarkers(fromTitle: originalTitle)
        add(.titleOnlyLoose, kind: .titleOnlyLoose, title: baseTitle, artist: nil)
        if differsBeyondCaseAndWidth(originalTitle, normalizedTitle) {
            add(.titleOnlyLoose, kind: .titleOnlyLoose, title: normalizedTitle, artist: nil)
        }
        if let firstRomaji = romajiTitles.first {
            add(.titleOnlyLoose, kind: .titleOnlyLoose, title: firstRomaji.value, artist: nil, aliasIDs: [firstRomaji.id])
        } else if let generated = JapaneseRomanizer.romanizeIfMostlyKana(originalTitle) {
            add(.titleOnlyLoose, kind: .titleOnlyLoose, title: generated, artist: nil)
        }

        return built.enumerated().map { index, variant in
            LyricsQueryVariant(
                rank: index + 1,
                strategy: variant.strategy,
                queryKind: variant.queryKind,
                titleQuery: variant.titleQuery,
                artistQuery: variant.artistQuery,
                aliasIDs: variant.aliasIDs
            )
        }
    }
}
