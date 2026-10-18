import Foundation

public enum LyricsMatchTier: String, Codable, Sendable {
    case autoHigh
    case autoMedium
    case candidates
    case reject
}

public struct LyricsMatchEvidence: Equatable, Sendable {
    public let code: String
    public let delta: Double
    public let hardReject: Bool

    public init(code: String, delta: Double, hardReject: Bool = false) {
        self.code = code
        self.delta = delta
        self.hardReject = hardReject
    }

    /// Stable, human-readable evidence for diagnostics and regression logs.
    public var display: String {
        let value = String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), delta)
        return hardReject ? "\(code) \(value) reject" : "\(code) \(value)"
    }
}

public struct LyricsMatchDecision: Equatable, Sendable {
    public let tier: LyricsMatchTier
    public let score: Double
    public let versionConflict: Bool
    public let queryKind: LyricsQueryKind?
    public let reasons: [String]
    public let evidence: [LyricsMatchEvidence]
    public let hardReject: Bool

    public init(
        tier: LyricsMatchTier,
        score: Double,
        versionConflict: Bool,
        queryKind: LyricsQueryKind? = nil,
        reasons: [String] = [],
        evidence: [LyricsMatchEvidence] = [],
        hardReject: Bool = false
    ) {
        self.tier = tier
        self.score = score
        self.versionConflict = versionConflict
        self.queryKind = queryKind
        self.reasons = reasons
        self.evidence = evidence
        self.hardReject = hardReject
    }

    /// The report/logging surface must explain why a candidate was adopted,
    /// held for selection, or rejected. It never contains lyric text.
    public var explanation: [String] {
        if !evidence.isEmpty { return evidence.map(\.display) }
        return reasons
    }
}

public enum LyricsSafeMatcher {
    public static func evidenceCeiling(forAliasSource source: TrackAliasSource) -> LyricsMatchTier {
        switch source {
        case .machineGenerated:
            return .candidates
        case .deterministicTransliteration:
            return .autoMedium
        case .provider:
            return .autoMedium
        case .importedTable, .spotifyMetadata, .user:
            return .autoHigh
        }
    }

    public static func decide(
        candidate: LyricsCandidate,
        metadata: TrackMetadata,
        aliasUsed: TrackAlias? = nil,
        queryVariant: LyricsQueryVariant? = nil
    ) -> LyricsMatchDecision {
        // This endpoint returns only a lyric body. Query echoes are not identity evidence.
        if candidate.source == .lyricsOVH {
            let hasText = candidate.lines.contains { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return LyricsMatchDecision(
                tier: hasText ? .candidates : .reject,
                score: 0,
                versionConflict: false,
                queryKind: queryVariant?.queryKind,
                reasons: ["仅按搜索词返回，需人工核对"],
                evidence: [],
                hardReject: !hasText
            )
        }
        var score = 0.0
        var reasons: [String] = []
        var evidence: [LyricsMatchEvidence] = []
        var hardReject = false
        var versionConflict = false
        var incompleteArtistSet = false
        var hasStrongIndependentIdentity = false

        func add(_ code: String, _ delta: Double, hard: Bool = false) {
            score += delta
            reasons.append(code)
            evidence.append(LyricsMatchEvidence(code: code, delta: delta, hardReject: hard))
            if hard { hardReject = true }
        }

        let metadataTitle = TrackTextNormalizer.normalize(metadata.track.title)
        let candidateTitle = TrackTextNormalizer.normalize(candidate.title)
        let metadataFeaturedInTitle = declaredFeaturedArtists(in: metadata.track.title)
        let candidateFeaturedInTitle = declaredFeaturedArtists(in: candidate.title)
        let featuredTitleVariation = !metadataFeaturedInTitle.isEmpty
            && !candidateFeaturedInTitle.isEmpty
            && metadataTitle != candidateTitle
            && featuredBaseTitle(metadata.track.title) == featuredBaseTitle(candidate.title)
            && !featuredBaseTitle(candidate.title).isEmpty
        let declaredFeaturedMatches = !metadataFeaturedInTitle.isEmpty
            && Set(metadataFeaturedInTitle.map(TrackTextNormalizer.normalizeArtistToken)) == Set(candidateFeaturedInTitle.map(TrackTextNormalizer.normalizeArtistToken))
        let metadataBaseTitle = TrackTextNormalizer.normalize(TrackTextNormalizer.stripVersionMarkers(fromTitle: metadata.track.title))
        let candidateBaseTitle = TrackTextNormalizer.normalize(TrackTextNormalizer.stripVersionMarkers(fromTitle: candidate.title))
        let manualQueryTitle = queryVariant?.queryKind == .manualOverride
            ? TrackTextNormalizer.normalize(queryVariant?.titleQuery ?? "") : ""
        let manualTitleMatches = !manualQueryTitle.isEmpty && !candidateTitle.isEmpty
            && (candidateTitle.contains(manualQueryTitle) || manualQueryTitle.contains(candidateTitle))
        let titleAliases = metadata.aliases
            .filter { $0.field == .title }
            .map { (value: TrackTextNormalizer.normalize($0.value), alias: $0) }
        let exactSpotifyTitleAliasMatchesCandidate = metadata.aliases.contains { alias in
            alias.field == .title && alias.source == .spotifyMetadata && alias.isOfficial
                && (TrackTextNormalizer.normalize(alias.value) == candidateTitle
                    || titlesHaveSameTypography(alias.value, candidate.title))
        }

        // A trusted full-title alias explicitly binds its guest spelling to this recording.
        // If metadata and candidate titles have a syntax variation (e.g. feat. vs ft.)
        // but declare the exact same guest artist, that identity is confirmed.
        let hasConfirmedFeaturedAlias = featuredTitleVariation && (declaredFeaturedMatches || titleAliases.contains {
            $0.value == candidateTitle && $0.alias.confidence >= 0.9
                && [.user, .spotifyMetadata, .importedTable, .provider].contains($0.alias.source)
                && ($0.alias.isOfficial || $0.alias.source == .user)
        })

        if candidateTitle == metadataTitle, !candidateTitle.isEmpty {
            add("titleExact", 0.30)
        } else if titlesHaveSameTypography(candidate.title, metadata.track.title) {
            // Keep every word (including version labels); only a standalone
            // dash separator is equivalent to the existing bracket separators.
            add("titleTypographyExact", 0.28)
        } else if titlesHaveCompleteParallelForm(candidate.title, metadata.track.title) {
            // Both halves must be the same full reading, never a contained substring.
            add("titleParallelExact", 0.28)
        } else if latinSpacingKey(candidate.title) != nil,
                  latinSpacingKey(candidate.title) == latinSpacingKey(metadata.track.title) {
            add("titleLatinSpacingExact", 0.28)
        } else if featuredTitleVariation {
            add("titleFeaturedBaseExact", 0.24)
            add(hasConfirmedFeaturedAlias ? "featuredNameAliasConfirmed" : "featuredNameUnverified", 0)
        } else if candidate.declaredTitleAliases.contains(where: { TrackTextNormalizer.normalize($0) == metadataTitle }), !metadataTitle.isEmpty {
            add("titleProviderAliasConfirmed", 0.22)
        } else if let matchingAlias = titleAliases.first(where: {
            $0.value == candidateTitle || titlesHaveSameTypography($0.alias.value, candidate.title)
        }), !candidateTitle.isEmpty {
            let delta = matchingAlias.alias.isOfficial || matchingAlias.alias.source == .spotifyMetadata ? 0.22 : 0.16
            add("titleAliasConfirmed", delta)
        } else if let aliasUsed,
                  aliasUsed.field == .title,
                  (TrackTextNormalizer.normalize(aliasUsed.value) == candidateTitle
                      || titlesHaveSameTypography(aliasUsed.value, candidate.title)) {
            add("titleAliasQuery", 0.16)
        } else if let queryVariant,
                  queryVariant.queryKind.isAlias,
                  (TrackTextNormalizer.normalize(queryVariant.titleQuery) == candidateTitle
                      || titlesHaveSameTypography(queryVariant.titleQuery, candidate.title)) {
            // Generated aliases (most notably deterministic romaji) may not
            // have a persisted TrackAlias record. They still expand recall,
            // but receive less title evidence than a confirmed alias.
            add("titleAliasQuery", queryVariant.queryKind == .romajiAlias ? 0.10 : 0.12)
        } else if titlesHaveSameReading(candidate.title, metadata.track.title, minimumLatinLength: 2) {
            // Provider titles can remain Japanese while Spotify localizes to Latin.
            // This is a full local reading comparison, not an echo of our query.
            add("titleReadingExact", 0.28)
            if !titlesHaveSameReading(candidate.title, metadata.track.title) {
                add("shortTitleReading", 0)
            }
        } else if !candidateBaseTitle.isEmpty, candidateBaseTitle == metadataBaseTitle,
                  (TrackTextNormalizer.extractVersionTags(fromTitle: metadata.track.title).contains(.piano)
                   || TrackTextNormalizer.extractVersionTags(fromTitle: candidate.title).contains(.piano)) {
            // Same composition is useful for explicit recovery, not proof of the same recording.
            add("pianoBaseTitleExact", 0.24)
        } else if !candidateBaseTitle.isEmpty, candidateBaseTitle == metadataBaseTitle,
                  (TrackTextNormalizer.extractVersionTags(fromTitle: metadata.track.title).contains(.spedUp)
                   || TrackTextNormalizer.extractVersionTags(fromTitle: candidate.title).contains(.spedUp)) {
            add("tempoBaseTitleExact", 0.24)
        } else if manualTitleMatches {
            add("manualTitleMatch", 0.20)
        } else if !candidateTitle.isEmpty,
                  !metadataTitle.isEmpty,
                  (candidateTitle.contains(metadataTitle) || metadataTitle.contains(candidateTitle)) {
            add("titleFuzzy", 0.08)
        } else {
            add("titleMismatch", 0)
        }

        if isGenericTitle(candidateTitle) {
            add("genericTitle", -0.05)
        }

        let metadataArtists = artistGroups(for: metadata)
        if !metadata.verifiedSpotifyArtists.isEmpty { add("spotifyArtistsVerified", 0) }
        let candidateArtists = TrackTextNormalizer.artistTokens(candidate.artist)
        let candidatePrimary = TrackTextNormalizer.normalizeArtistToken(candidateArtists.primary)
        let metadataPrimaryReadingMatches = metadataArtists.contains {
            titlesHaveSameReading($0.primary, candidateArtists.primary)
        }
        let spotifyCreditedArtistReadingMatches = (metadata.verifiedSpotifyArtists + metadata.aliases
            .filter { $0.field == .artist && $0.source == .spotifyMetadata && $0.isOfficial }
            .map(\.value)).contains { artistsHaveSameReading($0, candidateArtists.primary) }
        let metadataPrimaryMatches = metadataArtists.contains {
            TrackTextNormalizer.normalizeArtistToken($0.primary) == candidatePrimary && !candidatePrimary.isEmpty
        }
        let metadataFeaturedArtists = Set(metadataArtists
            .flatMap(\.featured)
            .map(TrackTextNormalizer.normalizeArtistToken)
            .filter { !$0.isEmpty })
        let candidateAllArtists = Set(candidateArtists.all
            .map(TrackTextNormalizer.normalizeArtistToken)
            .filter { !$0.isEmpty })
        let candidateMatchesFeaturedArtist = !candidateAllArtists.isDisjoint(with: metadataFeaturedArtists)
        var featuredArtistOnly = false
        let artistAlias = matchingArtistAlias(candidatePrimary, metadata: metadata)

        if metadataPrimaryMatches {
            add("primaryArtistExact", 0.30)
        } else if metadataPrimaryReadingMatches || spotifyCreditedArtistReadingMatches {
            add("primaryArtistReadingExact", 0.28)
            if spotifyCreditedArtistReadingMatches && !metadataPrimaryReadingMatches {
                add("spotifyCreditedArtistReadingExact", 0)
            }
        } else if let artistAlias {
            let delta = artistAlias.isOfficial || artistAlias.source == .spotifyMetadata ? 0.24 : 0.16
            add("primaryArtistAlias", delta)
        } else if candidateMatchesFeaturedArtist {
            // Some providers expose only a featured artist (for example a
            // vocal-synth artist) even though Spotify's primary artist list
            // contains a producer/project first. This is useful evidence for
            // a user-selectable candidate, but never enough for unattended
            // adoption without an independent Spotify ID or ISRC.
            featuredArtistOnly = true
            incompleteArtistSet = true
            add("featuredArtistOnly", -0.18)
        } else if candidatePrimary.isEmpty {
            let isManual = queryVariant?.queryKind == .manualOverride
            add("primaryArtistMissing", -0.30, hard: !isManual)
            if isManual { incompleteArtistSet = true }
        } else {
            let isManual = queryVariant?.queryKind == .manualOverride
            add("primaryArtistConflict", -0.40, hard: !isManual)
            if isManual { incompleteArtistSet = true }
        }

        if metadataPrimaryMatches || matchingArtistAlias(candidatePrimary, metadata: metadata) != nil {
            let metadataGroup = metadataArtists.first {
                TrackTextNormalizer.normalizeArtistToken($0.primary) == candidatePrimary
            } ?? metadataArtists.first
            // Spotify may expose the primary artist alone and declare guests
            // in the title. Those explicit guests are not extra provider artists.
            // Similarly, providers may declare guests in candidate.title or candidate.artist.
            let titleGuests = declaredFeaturedArtists(in: metadata.track.title)
            let expectedFeatured = Set(((metadataGroup?.featured ?? []) + titleGuests)
                .map(TrackTextNormalizer.normalizeArtistToken).filter { !$0.isEmpty })
            let candidateTitleGuests = declaredFeaturedArtists(in: candidate.title)
            let actualFeatured = Set(((candidateArtists.featured) + candidateTitleGuests)
                .map(TrackTextNormalizer.normalizeArtistToken).filter { !$0.isEmpty })
            let missing = expectedFeatured.subtracting(actualFeatured)
            let extra = actualFeatured.subtracting(expectedFeatured)

            if missing.isEmpty && extra.isEmpty && !expectedFeatured.isEmpty {
                add("featuredArtistsExact", 0.06)
            } else if !metadata.verifiedSpotifyArtists.isEmpty && extra.isEmpty && !actualFeatured.isEmpty {
                // When official Spotify metadata confirms that all candidate featured
                // artists are verified collaborators on this recording, omitting a
                // secondary contributor from provider tags is not an adoption barrier.
                add("featuredArtistsVerifiedSubset", 0.03)
            } else {
                if !missing.isEmpty {
                    incompleteArtistSet = true
                    add("missingFeaturedArtist", -0.05)
                }
                if !extra.isEmpty {
                    incompleteArtistSet = true
                    add("extraFeaturedArtist", -0.02)
                }
            }
        }

        // Only independently verified identifiers count as strong identity
        // evidence. `candidate.identity == metadata.identity` is request
        // context and is intentionally not scored.
        if let candidateID = canonicalSpotifyTrackID(candidate.spotifyTrackID),
           let metadataID = canonicalSpotifyTrackID(metadata.track.spotifyId) {
            if candidateID == metadataID {
                hasStrongIndependentIdentity = true
                add("spotifyIDExact", 0.45)
            } else {
                add("spotifyIDConflict", -0.60, hard: true)
            }
        }
        if let candidateISRC = canonicalISRC(candidate.isrc),
           let metadataISRC = canonicalISRC(metadata.track.isrc) {
            if candidateISRC == metadataISRC {
                hasStrongIndependentIdentity = true
                add("isrcExact", 0.40)
            } else {
                add("isrcConflict", -0.50, hard: true)
            }
        }

        let metadataDuration = metadata.track.duration
        let candidateDuration = candidate.duration
        if metadataDuration > 0, candidateDuration > 0,
           metadataDuration.isFinite, candidateDuration.isFinite {
            let difference = abs(metadataDuration - candidateDuration)
            if difference <= 2 {
                add("durationClose", 0.12)
            } else if difference <= 5 {
                add("durationNear", 0.06)
            } else if difference <= 15 {
                add("durationQuestionable", -0.08)
            } else {
                add("durationFar", -0.20)
            }
        }

        let metadataAlbum = TrackTextNormalizer.normalize(metadata.track.album)
        let candidateAlbum = TrackTextNormalizer.normalize(candidate.album)
        if !metadataAlbum.isEmpty, metadataAlbum == candidateAlbum {
            add("albumExact", 0.08)
        } else if !metadataAlbum.isEmpty, !candidateAlbum.isEmpty {
            add("albumMismatch", -0.04)
        }

        let metadataTags = Set(metadata.versionTags)
            .union(TrackTextNormalizer.extractVersionTags(fromTitle: metadata.track.title))
        let candidateTags = Set(TrackTextNormalizer.extractVersionTags(fromTitle: candidate.title))
        let traitResult = compareVersionTraits(metadata: metadataTags, candidate: candidateTags)
        for item in traitResult.evidence {
            // Version conflicts are hard adoption barriers, but a useful
            // candidate may still be shown for explicit user confirmation.
            // Keep them out of the global identity hardReject flag.
            score += item.delta
            reasons.append(item.code)
            evidence.append(item)
        }
        versionConflict = traitResult.versionConflict
        // A tempo-only mismatch is useful as text for explicit inspection, not
        // as recording evidence. Duration differs by design; no global score
        // threshold is changed. IDs/ISRC/artist conflicts remain hard barriers.
        let tempoTextPreview = !hardReject && metadataPrimaryMatches
            && reasons.contains("tempoBaseTitleExact")
            && reasons.contains("spedUpConflict")
            && metadataTags.symmetricDifference(candidateTags).subtracting([.spedUp, .remaster]).isEmpty
            && candidate.lines.contains { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        func constrainSpotifyCreditedArtistReading(_ tier: LyricsMatchTier) -> LyricsMatchTier {
            guard reasons.contains("spotifyCreditedArtistReadingExact") else { return tier }
            let exactTitle = reasons.contains("titleExact") || reasons.contains("titleTypographyExact")
                || exactSpotifyTitleAliasMatchesCandidate
            guard exactTitle, reasons.contains("durationClose"), !versionConflict, !hardReject else {
                return Self.minTier(tier, .candidates)
            }
            return Self.minTier(tier, .autoMedium)
        }

        if let queryVariant {
            switch queryVariant.queryKind {
            case .titleOnlyLoose:
                add("looseQuery", -0.15)
            case .normalizedTitleFullArtist, .normalizedTitlePrimaryArtist:
                add("normalizedQuery", -0.01)
            case .normalizedVersionTitleFullArtist, .normalizedVersionTitlePrimaryArtist:
                add("versionStrippedQuery", -0.06)
            case .manualOverride:
                add("manualQuery", -0.03)
            case .exactTitleFullArtist, .exactTitlePrimaryArtist,
                 .kanaAlias, .romajiAlias, .officialEnglishAlias, .confirmedAlias:
                break
            }
        }

        if let aliasUsed {
            let ceiling = evidenceCeiling(forAliasSource: aliasUsed.source)
            if aliasUsed.source == .machineGenerated {
                reasons.append("machineAliasCeiling")
                evidence.append(LyricsMatchEvidence(code: "machineAliasCeiling", delta: 0))
            }

            let tierPrimaryMatch = metadataPrimaryMatches || metadataPrimaryReadingMatches || spotifyCreditedArtistReadingMatches
                || artistAlias != nil || (featuredArtistOnly && hasStrongIndependentIdentity)
            var tier = tierFor(score: score, primaryArtistMatches: tierPrimaryMatch, hardReject: hardReject)
            if hardReject {
                tier = .reject
            } else if reasons.contains("titleMismatch") && !hasStrongIndependentIdentity && queryVariant?.queryKind != .manualOverride {
                tier = .reject
            } else if tempoTextPreview {
                tier = .candidates
            } else if versionConflict {
                tier = minTier(tier, score >= 0.20 ? .candidates : .reject)
            } else if featuredArtistOnly && !hasStrongIndependentIdentity {
                // An exact title plus a known featured artist is enough to
                // surface a candidate even when provider album/duration
                // metadata is incomplete. It is deliberately never an
                // automatic tier.
                let titleEvidence = reasons.contains("titleExact")
                    || reasons.contains("titleAliasConfirmed")
                    || reasons.contains("titleAliasQuery")
                tier = minTier(tier, titleEvidence && score >= 0.10 ? .candidates : .reject)
            } else if queryVariant?.queryKind == .manualOverride {
                tier = minTier(tier, (score >= 0.10 || reasons.contains("manualTitleMatch")) ? .candidates : .reject)
            } else if featuredTitleVariation && !hasStrongIndependentIdentity && !hasConfirmedFeaturedAlias {
                tier = minTier(tier, .candidates)
            } else if incompleteArtistSet && !hasStrongIndependentIdentity && !hasConfirmedFeaturedAlias {
                tier = minTier(tier, score >= 0.25 ? .candidates : .reject)
            }
            if queryVariant?.queryKind == .titleOnlyLoose && !hasStrongIndependentIdentity {
                tier = minTier(tier, score >= 0.25 ? .candidates : .reject)
            }
            if reasons.contains("titleFuzzy") && !hasStrongIndependentIdentity {
                tier = minTier(tier, .candidates)
            }
            if reasons.contains("titleParallelExact") || reasons.contains("titleLatinSpacingExact") {
                tier = minTier(tier, metadataPrimaryMatches && reasons.contains("durationClose") ? .autoMedium : .candidates)
            }
            if reasons.contains("shortTitleReading") && !hasStrongIndependentIdentity {
                tier = minTier(tier, metadataPrimaryMatches && reasons.contains("durationClose") ? .autoMedium : .candidates)
            }
            tier = minTier(tier, ceiling)
            if reasons.contains("titleProviderAliasConfirmed") || metadataPrimaryReadingMatches || reasons.contains("titleReadingExact") || reasons.contains("titleTypographyExact") { tier = minTier(tier, .autoMedium) }
            tier = constrainSpotifyCreditedArtistReading(tier)
            return LyricsMatchDecision(
                tier: tier,
                score: clamp(score),
                versionConflict: versionConflict,
                queryKind: queryVariant?.queryKind,
                reasons: reasons,
                evidence: evidence,
                hardReject: hardReject
            )
        }

        var tier: LyricsMatchTier
        let tierPrimaryMatch = metadataPrimaryMatches || metadataPrimaryReadingMatches || spotifyCreditedArtistReadingMatches
            || artistAlias != nil || (featuredArtistOnly && hasStrongIndependentIdentity)
        if hardReject {
            tier = .reject
        } else if reasons.contains("titleMismatch") && !hasStrongIndependentIdentity && queryVariant?.queryKind != .manualOverride {
            tier = .reject
        } else if tempoTextPreview {
            tier = .candidates
        } else if versionConflict {
            tier = score >= 0.20 ? .candidates : .reject
        } else if featuredArtistOnly && !hasStrongIndependentIdentity {
            let titleEvidence = reasons.contains("titleExact")
                || reasons.contains("titleAliasConfirmed")
                || reasons.contains("titleAliasQuery")
            tier = titleEvidence && score >= 0.10 ? .candidates : .reject
        } else if queryVariant?.queryKind == .manualOverride {
            // Manual recovery may present a title-matching alternative even
            // when localized artist names differ. It never becomes automatic;
            // independent ID conflicts already take the hardReject branch.
            tier = (score >= 0.10 || manualTitleMatches) ? .candidates : .reject
        } else if featuredTitleVariation && !hasStrongIndependentIdentity && !hasConfirmedFeaturedAlias {
            tier = score >= 0.25 ? .candidates : .reject
        } else if featuredTitleVariation && metadataPrimaryMatches && !reasons.contains("durationFar")
                    && (hasStrongIndependentIdentity || hasConfirmedFeaturedAlias) {
            tier = .autoMedium
        } else if incompleteArtistSet && !hasStrongIndependentIdentity && !hasConfirmedFeaturedAlias {
            // A missing/extra featured artist is not proof of a different
            // song, but it is insufficient for unattended adoption.
            tier = score >= 0.25 ? .candidates : .reject
        } else if queryVariant?.queryKind == .titleOnlyLoose && !hasStrongIndependentIdentity {
            tier = score >= 0.25 ? .candidates : .reject
        } else {
            tier = tierFor(score: score, primaryArtistMatches: tierPrimaryMatch, hardReject: hardReject)
        }
        // A shorter title can omit an unrecognized version label (e.g.
        // "Another ver."). Substring containment is not whole-title identity.
        if reasons.contains("titleFuzzy") && !hasStrongIndependentIdentity {
            tier = minTier(tier, .candidates)
        }
        // A generated romaji query has no independent provider alias record
        // to carry a source/confidence ceiling. Keep deterministic
        // transliteration useful for recall, but never let it promote an
        // otherwise strong match to autoHigh by itself.
        if reasons.contains("titleProviderAliasConfirmed") || metadataPrimaryReadingMatches || reasons.contains("titleReadingExact") || reasons.contains("titleTypographyExact") || (aliasUsed == nil && queryVariant?.queryKind == .romajiAlias) {
            tier = minTier(tier, .autoMedium)
        }

        if reasons.contains("titleParallelExact") || reasons.contains("titleLatinSpacingExact") {
            tier = minTier(tier, metadataPrimaryMatches && reasons.contains("durationClose") ? .autoMedium : .candidates)
        }
        if reasons.contains("shortTitleReading") && !hasStrongIndependentIdentity {
            tier = minTier(tier, metadataPrimaryMatches && reasons.contains("durationClose") ? .autoMedium : .candidates)
        }
        tier = constrainSpotifyCreditedArtistReading(tier)
        return LyricsMatchDecision(
            tier: tier,
            score: clamp(score),
            versionConflict: versionConflict,
            queryKind: queryVariant?.queryKind,
            reasons: reasons,
            evidence: evidence,
            hardReject: hardReject
        )
    }

    /// Space/case folding only for an entire Latin title. Punctuation and
    /// added version words are not discarded; this is not fuzzy containment.
    private static func latinSpacingKey(_ raw: String) -> String? {
        let folded = raw.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard folded.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)) }) else { return nil }
        let key = String(String.UnicodeScalarView(folded.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }))
        return key.count >= 3 ? key : nil
    }

    /// A parallel title is accepted only when Japanese + Latin both express
    /// the whole title. A suffix such as Live/Another ver. fails this check;
    /// the existing recording/ID checks still run afterward.
    private static func titlesHaveCompleteParallelForm(_ lhs: String, _ rhs: String) -> Bool {
        func forms(_ raw: String) -> [String]? {
            let text = raw.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for pattern in [#"^(.+?)\s+[-–—]\s+(.+)$"#, #"^([^()]+?)\s*\(([^()]+)\)$"#] {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                let first = String(text[a]).trimmingCharacters(in: .whitespacesAndNewlines)
                let second = String(text[b]).trimmingCharacters(in: .whitespacesAndNewlines)
                // One whole Japanese reading and one Latin rendering, not two
                // arbitrary strings separated by a dash/bracket.
                guard (latinSpacingKey(first) != nil) != (latinSpacingKey(second) != nil),
                      titlesHaveSameReading(first, second) else { return nil }
                return [first, second]
            }
            return nil
        }
        let left = forms(lhs), right = forms(rhs)
        guard left != nil || right != nil else { return false }
        func same(_ a: String, _ b: String) -> Bool {
            if TrackTextNormalizer.normalize(a) == TrackTextNormalizer.normalize(b) { return true }
            if let latin = latinSpacingKey(a), latin == latinSpacingKey(b) { return true }
            return titlesHaveSameReading(a, b)
        }
        // Validate each complete form against every complete form on the
        // other side. No partial match or untranslated surplus is accepted.
        return (left ?? [lhs]).allSatisfy { a in (right ?? [rhs]).allSatisfy { same(a, $0) } }
    }

    private static func titlesHaveSameTypography(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ title: String) -> String {
            TrackTextNormalizer.normalize(title)
                .split(separator: " ")
                .filter { $0 != "-" }
                .joined(separator: " ")
        }
        let left = key(lhs)
        return !left.isEmpty && left == key(rhs)
    }

    private struct VersionTraitResult {
        let versionConflict: Bool
        let evidence: [LyricsMatchEvidence]
    }

    private static func compareVersionTraits(
        metadata: Set<VersionTag>,
        candidate: Set<VersionTag>
    ) -> VersionTraitResult {
        var evidence: [LyricsMatchEvidence] = []
        var conflict = false

        let hardTraits: [(VersionTag, String)] = [
            (.spedUp, "spedUpConflict"),
            (.live, "liveConflict"),
            (.acoustic, "acousticConflict"),
            (.remix, "remixConflict"),
            (.instrumental, "instrumentalVocalConflict"),
            (.karaoke, "karaokeConflict"),
            (.cover, "coverConflict"),
            (.radioEdit, "radioEditConflict"),
            (.demo, "demoConflict"),
            (.reRecord, "reRecordConflict"),
            (.firstTake, "firstTakeConflict"),
            (.movieVersion, "movieVersionConflict"),
            (.animeVersion, "animeVersionConflict"),
            (.shortVersion, "shortVersionConflict")
        ]

        for (tag, code) in hardTraits {
            let inMetadata = metadata.contains(tag)
            let inCandidate = candidate.contains(tag)
            guard inMetadata != inCandidate else { continue }
            conflict = true
            evidence.append(LyricsMatchEvidence(code: code, delta: -0.35, hardReject: true))
        }

        if metadata.contains(.piano) != candidate.contains(.piano) {
            conflict = true
            evidence.append(LyricsMatchEvidence(code: "pianoConflict", delta: -0.18, hardReject: true))
        }

        if metadata.contains(.remaster) != candidate.contains(.remaster) {
            evidence.append(LyricsMatchEvidence(code: "remasterDifference", delta: -0.03))
        }

        return VersionTraitResult(versionConflict: conflict, evidence: evidence)
    }

    // MeCab title readings are bounded, local, and cached; repeated provider
    // probes must not repeatedly start morphology processes for the same title.
    private final class TitleReadingCache: @unchecked Sendable {
        let values = NSCache<NSString, NSString>()
        init() { values.countLimit = 128 }
    }
    private static let titleReadings = TitleReadingCache()

    private static func titlesHaveSameReading(_ lhs: String, _ rhs: String, minimumLatinLength: Int = 3) -> Bool {
        func latinKey(_ value: String) -> String? {
            let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard folded.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
            let key = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let result = String(String.UnicodeScalarView(key))
            return result.count >= minimumLatinLength ? result : nil
        }
        func readingKey(_ japanese: String) -> String? {
            guard japanese.count <= 256,
                  japanese.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
            if let cached = titleReadings.values.object(forKey: japanese as NSString) {
                return cached.length >= minimumLatinLength ? cached as String : nil
            }
            let romanized: String
            if !JapaneseKanaGenerator.hasKanji(japanese) {
                romanized = JapaneseRomanizer.romanize(japanese)
            } else {
                let reading = JapaneseReadingPipeline.analyze(originalText: japanese)
                guard !reading.containsUnknown, reading.confidence >= 0.90,
                      let resolved = reading.romajiText else { return nil }
                romanized = resolved
            }
            guard let key = latinKey(romanized) else { return nil }
            titleReadings.values.setObject(key as NSString, forKey: japanese as NSString)
            return key
        }
        if let latin = latinKey(lhs), let japanese = readingKey(rhs) { return latin == japanese }
        if let latin = latinKey(rhs), let japanese = readingKey(lhs) { return latin == japanese }
        return false
    }

    /// Artist romanizations sometimes use opposite name order (Hikaru Utada /
    /// Utada Hikaru) and different long-vowel notation (Toko / Touko). Only
    /// compare this way against exact Spotify-credited artist names above, and
    /// require a complete Japanese reading with no unknown tokens.
    private static func artistsHaveSameReading(_ lhs: String, _ rhs: String) -> Bool {
        func normalizedTokens(_ text: String) -> [String]? {
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
            guard folded.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
            let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { return nil }
            return words.map { word in
                String(word)
                    .replacingOccurrences(of: "ou", with: "o")
                    .replacingOccurrences(of: "oo", with: "o")
                    .replacingOccurrences(of: "aa", with: "a")
                    .replacingOccurrences(of: "ii", with: "i")
                    .replacingOccurrences(of: "uu", with: "u")
                    .replacingOccurrences(of: "ee", with: "e")
            }.sorted()
        }

        func readingTokens(_ text: String) -> [String]? {
            guard text.count <= 256,
                  text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
            let reading = JapaneseReadingPipeline.analyze(originalText: text)
            guard !reading.containsUnknown else { return nil }
            let tokens = reading.tokens.compactMap(\.romaji)
            guard !tokens.isEmpty, tokens.count == reading.tokens.count else { return nil }
            return normalizedTokens(tokens.joined(separator: " "))
        }

        let left = readingTokens(lhs) ?? normalizedTokens(lhs)
        let right = readingTokens(rhs) ?? normalizedTokens(rhs)
        guard let left, let right, left.count == right.count, !left.isEmpty else { return false }
        return left == right
    }

    private static func featuredBaseTitle(_ title: String) -> String {
        let parenthesized = title.replacingOccurrences(of: #"[（(]\s*(?:feat\.?|ft\.?|featuring)\s+[^）)]+[）)]"#, with: "", options: [.regularExpression, .caseInsensitive])
        let stripped = parenthesized.replacingOccurrences(of: #"\s+(?:feat\.?|ft\.?|featuring)\s+[^()（）]+$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return TrackTextNormalizer.normalize(stripped)
    }

    private static func declaredFeaturedArtists(in title: String) -> [String] {
        let patterns = [
            #"[（(]\s*(?:feat\.?|ft\.?|featuring)\s+([^）)]+)[）)]"#,
            #"\s+(?:feat\.?|ft\.?|featuring)\s+([^()（）]+)$"#
        ]
        return patterns.flatMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [String]() }
            return regex.matches(in: title, range: NSRange(title.startIndex..., in: title)).flatMap { match in
                guard let range = Range(match.range(at: 1), in: title) else { return [String]() }
                return TrackTextNormalizer.artistTokens(String(title[range])).all
            }
        }
    }

    private static func artistGroups(for metadata: TrackMetadata) -> [TrackTextNormalizer.ArtistTokens] {
        var groups: [TrackTextNormalizer.ArtistTokens] = []
        if let primary = metadata.verifiedSpotifyArtists.first {
            groups.append(.init(primary: primary, featured: Array(metadata.verifiedSpotifyArtists.dropFirst())))
        }
        groups.append(TrackTextNormalizer.artistTokens(metadata.track.artist))
        groups.append(contentsOf: metadata.aliases
            .filter { $0.field == .artist }
            .map { TrackTextNormalizer.artistTokens($0.value) })
        return groups
    }

    private static func matchingArtistAlias(_ candidatePrimary: String, metadata: TrackMetadata) -> TrackAlias? {
        guard !candidatePrimary.isEmpty else { return nil }
        return metadata.aliases.first { alias in
            alias.field == .artist
                && TrackTextNormalizer.normalizeArtistToken(
                    TrackTextNormalizer.artistTokens(alias.value).primary
                ) == candidatePrimary
        }
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let key = TrackTextNormalizer.normalizeArtistToken(title)
        let generic: Set<String> = [
            "forever", "love", "lemon", "golden", "flowers", "cover",
            "home", "hello", "stay", "you", "tonight", "恋", "愛", "空"
        ]
        return generic.contains(key)
    }

    private static func canonicalSpotifyTrackID(_ value: String?) -> String? {
        guard let value else { return nil }
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("spotify:track:") {
            text = String(text.dropFirst("spotify:track:".count))
        } else if let range = text.range(of: "/track/") {
            text = String(text[range.upperBound...]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        }
        return text.isEmpty ? nil : text
    }

    private static func canonicalISRC(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let normalized = String(String.UnicodeScalarView(scalars))
        return normalized.isEmpty ? nil : normalized
    }

    private static func tierFor(
        score: Double,
        primaryArtistMatches: Bool,
        hardReject: Bool
    ) -> LyricsMatchTier {
        if hardReject || !primaryArtistMatches { return .reject }
        if score >= 0.78 { return .autoHigh }
        if score >= 0.58 { return .autoMedium }
        if score >= 0.25 { return .candidates }
        return .reject
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func minTier(_ a: LyricsMatchTier, _ b: LyricsMatchTier) -> LyricsMatchTier {
        let order: [LyricsMatchTier] = [.reject, .candidates, .autoMedium, .autoHigh]
        let ia = order.firstIndex(of: a) ?? 0
        let ib = order.firstIndex(of: b) ?? 0
        return order[min(ia, ib)]
    }
}
