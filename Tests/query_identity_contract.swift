import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func candidate(
    identity: TrackIdentity,
    title: String,
    artist: String,
    album: String,
    duration: TimeInterval,
    spotifyTrackID: String? = nil,
    isrc: String? = nil
) -> LyricsCandidate {
    LyricsCandidate(
        id: UUID().uuidString,
        identity: identity,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        lines: [LyricLine(timestamp: 0, originalText: "line")],
        source: .lrclib,
        confidence: 0.95,
        providerSourceID: nil,
        spotifyTrackID: spotifyTrackID,
        isrc: isrc
    )
}

@main
struct QueryIdentityContract {
    static func main() {
        // Artist tokenization must keep the primary artist separate from
        // featured artists without relying on substring containment.
        let artistTokens = TrackTextNormalizer.artistTokens(
            "MOSAIC.TUNE feat.初音ミク、Hatsune Miku"
        )
        require(artistTokens.primary == "MOSAIC.TUNE", "primary artist token")
        require(artistTokens.featured.count == 2, "featured artist token count")
        require(artistTokens.featured.contains("初音ミク"), "Japanese featured artist")
        require(artistTokens.featured.contains("Hatsune Miku"), "Latin featured artist")
        require(
            TrackTextNormalizer.artistTokens("VILLSHANA, Mahiru").primary == "VILLSHANA",
            "comma separated primary artist"
        )

        let versionTags = Set(TrackTextNormalizer.extractVersionTags(
            fromTitle: "春を告げる - From THE FIRST TAKE (Remastered)"
        ))
        require(versionTags.contains(.firstTake), "first take trait")
        require(versionTags.contains(.remaster), "remaster trait")
        require(TrackTextNormalizer.extractVersionTags(fromTitle: "体面 - Live").contains(.live), "live trait")
        require(TrackTextNormalizer.extractVersionTags(fromTitle: "夜の歌 (Remix)").contains(.remix), "remix trait")
        require(TrackTextNormalizer.extractVersionTags(fromTitle: "夜の歌 (Instrumental)").contains(.instrumental), "instrumental trait")
        require(TrackTextNormalizer.extractVersionTags(fromTitle: "夜の歌 (Cover)").contains(.cover), "cover trait")

        let featuredTitleTrack = Track(title: "sentiment (feat. inkya)", artist: "SHAGZ", album: "sentiment", duration: 180)
        let featuredTitleMetadata = TrackMetadata.bootstrap(from: featuredTitleTrack)
        let completeFeatured = candidate(identity: TrackIdentity(track: featuredTitleTrack),
            title: featuredTitleTrack.title, artist: "SHAGZ, inkya", album: "sentiment", duration: 180)
        let featuredTitleDecision = LyricsSafeMatcher.decide(candidate: completeFeatured, metadata: featuredTitleMetadata)
        require(featuredTitleDecision.tier == .autoHigh || featuredTitleDecision.tier == .autoMedium,
            "explicit title featured artist must not force manual choice when primary/title/album/time match")
        require(!featuredTitleDecision.reasons.contains("extraFeaturedArtist"), "declared featured artist is not extra")
        let undeclaredFeatured = candidate(identity: TrackIdentity(track: featuredTitleTrack),
            title: featuredTitleTrack.title, artist: "SHAGZ, someone else", album: "sentiment", duration: 180)
        let undeclaredDecision = LyricsSafeMatcher.decide(candidate: undeclaredFeatured, metadata: featuredTitleMetadata)
        require(undeclaredDecision.tier == .candidates, "undeclared featured artist remains unsafe for automatic adoption")
        let wrongFeaturedRecording = candidate(identity: TrackIdentity(track: featuredTitleTrack),
            title: featuredTitleTrack.title + " - Live", artist: "SHAGZ, inkya", album: "sentiment", duration: 180)
        let wrongFeaturedDecision = LyricsSafeMatcher.decide(candidate: wrongFeaturedRecording, metadata: featuredTitleMetadata)
        require(wrongFeaturedDecision.tier == .candidates, "title feat recognition must not bypass recording conflict")

        let localizedGuestTrack = Track(title: "0 (feat. haku)", artist: "hisui", album: "", duration: 136)
        let localizedGuestCandidate = candidate(identity: TrackIdentity(track: localizedGuestTrack), title: "0 (feat. 柏)", artist: "hisui, 柏", album: "", duration: 136)
        let localizedGuestDecision = LyricsSafeMatcher.decide(candidate: localizedGuestCandidate, metadata: TrackMetadata.bootstrap(from: localizedGuestTrack))
        require(localizedGuestDecision.tier == .autoMedium, "featured-title spelling variation should automatically choose a provisional matching version")
        require(localizedGuestDecision.reasons.contains("featuredNameUnverified"), "automatic provisional choice must retain uncertainty")
        // Spotify's localized display can be Latin while the source has the Japanese title.
        // Provider query echoes remain insufficient: prove the complete reading and primary artist.
        let romanizedTrack = Track(title: "Uta o Oshietekureta Anata e", artist: "ミセカイ", album: "Artrium", duration: 253.677, spotifyId: "7eqgj3zza04nswadcvqnyk")
        let romanizedMeta = TrackMetadata.bootstrap(from: romanizedTrack)
        let japaneseTitle = candidate(identity: romanizedMeta.identity, title: "唄を教えてくれたあなたへ", artist: "ミセカイ", album: "Artrium", duration: 254)
        let romanizedDecision = LyricsSafeMatcher.decide(candidate: japaneseTitle, metadata: romanizedMeta)
        require(romanizedDecision.tier == .autoMedium, "complete Japanese reading matching localized Latin title must auto-select instead of titleMismatch")
        require(romanizedDecision.reasons.contains("titleReadingExact") && !romanizedDecision.reasons.contains("titleMismatch"), "retain observed transliteration evidence without pretending literal title equality")
        let reverseTrack = Track(title: "唄を教えてくれたあなたへ", artist: "ミセカイ", album: "Artrium", duration: 254)
        require(LyricsSafeMatcher.decide(candidate: candidate(identity: TrackIdentity(track: reverseTrack), title: "Uta o Oshietekureta Anata e", artist: "ミセカイ", album: "Artrium", duration: 254), metadata: TrackMetadata.bootstrap(from: reverseTrack)).tier == .autoMedium, "title reading works in both localization directions")
        let kanaTrack = Track(title: "Aoiharu", artist: "ミセカイ", album: "Artrium", duration: 180)
        require(LyricsSafeMatcher.decide(candidate: candidate(identity: TrackIdentity(track: kanaTrack), title: "アオイハル", artist: "ミセカイ", album: "Artrium", duration: 180), metadata: TrackMetadata.bootstrap(from: kanaTrack)).tier == .autoMedium, "kana title must match Latin display without needing a stored alias")
        let unrelated = LyricsSafeMatcher.decide(candidate: candidate(identity: romanizedMeta.identity, title: "アオイハル", artist: "ミセカイ", album: "Artrium", duration: 254), metadata: romanizedMeta)
        require(unrelated.tier != .autoHigh && unrelated.tier != .autoMedium, "same artist/album/duration alone must not invent a title match")
        let wrongRomanizedID = LyricsSafeMatcher.decide(candidate: candidate(identity: romanizedMeta.identity, title: japaneseTitle.title, artist: "ミセカイ", album: "Artrium", duration: 254, spotifyTrackID: "different-song"), metadata: romanizedMeta)
        require(wrongRomanizedID.tier == .reject && wrongRomanizedID.hardReject, "reading equivalence cannot override independent track ID conflict")
        let liveJapanese = LyricsSafeMatcher.decide(candidate: candidate(identity: romanizedMeta.identity, title: japaneseTitle.title + " - Live", artist: "ミセカイ", album: "Artrium", duration: 254), metadata: romanizedMeta)
        require(liveJapanese.tier != .autoHigh && liveJapanese.tier != .autoMedium && liveJapanese.versionConflict, "reading equivalence cannot override a different recording")
        let typographyTrack = Track(title: "Something without form - Another ver.", artist: "Nemo_Suzumi", album: "Something without form (Another ver.)", duration: 183.913, spotifyId: "5M2kd1tO6wlFp7uDtn3YKG")
        let typographyMeta = TrackMetadata.bootstrap(from: typographyTrack)
        let typographyCandidate = candidate(identity: typographyMeta.identity, title: "Something Without Form (Another ver.)", artist: "Nemo_Suzumi", album: typographyTrack.album, duration: 184)
        let typographyDecision = LyricsSafeMatcher.decide(candidate: typographyCandidate, metadata: typographyMeta)
        require(typographyDecision.tier == .autoMedium && typographyDecision.reasons.contains("titleTypographyExact"), "whole title and version words match despite spaced dash versus parentheses; must auto-select")
        for changedTitle in ["Something Without Form", "Something Without Form (Original ver.)", "Something Without Form (Another ver.) - Live"] {
            let decision = LyricsSafeMatcher.decide(candidate: candidate(identity: typographyMeta.identity, title: changedTitle, artist: typographyTrack.artist, album: typographyTrack.album, duration: 184), metadata: typographyMeta)
            require(decision.tier != .autoHigh && decision.tier != .autoMedium, "typography equivalence must preserve version words and recording barriers")
        }
        let wordBoundaryTrack = Track(title: "Re-cover - Another ver.", artist: "Nemo_Suzumi", album: "", duration: 184)
        let boundaryDecision = LyricsSafeMatcher.decide(candidate: candidate(identity: TrackIdentity(track: wordBoundaryTrack), title: "Recover (Another ver.)", artist: wordBoundaryTrack.artist, album: "", duration: 184), metadata: TrackMetadata.bootstrap(from: wordBoundaryTrack))
        require(boundaryDecision.tier != .autoHigh && boundaryDecision.tier != .autoMedium, "embedded lexical hyphens must not be removed as a spaced separator")
        require(LyricsSafeMatcher.decide(candidate: candidate(identity: typographyMeta.identity, title: typographyCandidate.title, artist: typographyTrack.artist, album: typographyTrack.album, duration: 184, spotifyTrackID: "other-song"), metadata: typographyMeta).hardReject, "typography equivalence cannot override track ID conflicts")
        let firstTakeTrack = Track(
            title: "春を告げる - From THE FIRST TAKE",
            artist: "yama",
            album: "春を告げる - From THE FIRST TAKE",
            duration: 300.8
        )
        let firstTakeDecision = LyricsSafeMatcher.decide(
            candidate: candidate(
                identity: TrackIdentity(track: firstTakeTrack),
                title: "春を告げる",
                artist: "yama",
                album: "春を告げる",
                duration: 300.8
            ),
            metadata: TrackMetadata.bootstrap(from: firstTakeTrack)
        )
        require(firstTakeDecision.versionConflict, "first take/studio conflict")
        require(firstTakeDecision.tier != .autoHigh && firstTakeDecision.tier != .autoMedium, "first take conflict never auto adopts")

        let multiTrack = Track(
            title: "Forever（Official）",
            artist: "VILLSHANA, Mahiru",
            album: "KILL is LOVE",
            duration: 168.75,
            spotifyId: "2cLlZmf690vuBEyA4EMm3g"
        )
        let multiMetadata = TrackMetadata.bootstrap(from: multiTrack)
        let plan = LyricsQueryPlanner.plan(for: multiMetadata)
        require(plan.first?.strategy == .primaryOriginal, "exact full artist is first")
        require(plan.first?.queryKind == .exactTitleFullArtist, "query kind is retained")
        require(
            plan.contains {
                $0.strategy == .primaryArtist &&
                $0.queryKind == .exactTitlePrimaryArtist &&
                $0.artistQuery == "VILLSHANA"
            },
            "exact primary artist query"
        )
        require(
            plan.contains { $0.queryKind == .normalizedTitleFullArtist },
            "normalized full artist query"
        )
        require(
            plan.contains { $0.queryKind == .normalizedTitlePrimaryArtist },
            "normalized primary artist query"
        )
        require(plan.last?.queryKind == .titleOnlyLoose, "title-only is last")
        require(Set(plan.map(\.id)).count == plan.count, "query IDs are unique")
        require(plan.map(\.rank) == Array(1...plan.count), "query ranks are ordered")

        let liveTrack = Track(
            title: "体面 - Live",
            artist: "Kelly Yu",
            album: "剧好听的歌 第10期",
            duration: 281.295,
            spotifyId: "47NmE3V5KYuRBmFJIdhEBu"
        )
        let liveMetadata = TrackMetadata.bootstrap(from: liveTrack)
        let liveBaseCandidate = candidate(
            identity: TrackIdentity(track: liveTrack),
            title: "体面",
            artist: "Kelly Yu",
            album: "体面",
            duration: 281.295
        )
        let liveBaseDecision = LyricsSafeMatcher.decide(
            candidate: liveBaseCandidate,
            metadata: liveMetadata,
            queryVariant: LyricsQueryVariant(
                rank: 6,
                strategy: .titleOnlyLoose,
                queryKind: .titleOnlyLoose,
                titleQuery: "体面",
                artistQuery: nil
            )
        )
        require(liveBaseDecision.versionConflict, "studio candidate conflicts with live track")
        require(liveBaseDecision.tier != .autoHigh && liveBaseDecision.tier != .autoMedium, "live conflict never auto adopts")
        require(liveBaseDecision.explanation.contains { $0.contains("liveConflict") }, "live conflict explanation")

        let plainTrack = Track(
            title: "Lemon",
            artist: "Kenshi Yonezu",
            album: "STRAY SHEEP",
            duration: 255.826
        )
        let plainMetadata = TrackMetadata.bootstrap(from: plainTrack)
        let liveCandidate = candidate(
            identity: TrackIdentity(track: plainTrack),
            title: "Lemon (Live)",
            artist: "Kenshi Yonezu",
            album: "Live",
            duration: 255.826
        )
        let plainLiveDecision = LyricsSafeMatcher.decide(candidate: liveCandidate, metadata: plainMetadata)
        require(plainLiveDecision.versionConflict, "live candidate conflicts with studio track")
        require(plainLiveDecision.tier != .autoHigh && plainLiveDecision.tier != .autoMedium, "studio track rejects live candidate")

        let instrumentalCandidate = candidate(
            identity: TrackIdentity(track: plainTrack),
            title: "Lemon (Instrumental)",
            artist: "Kenshi Yonezu",
            album: "STRAY SHEEP",
            duration: 255.826
        )
        let instrumentalDecision = LyricsSafeMatcher.decide(candidate: instrumentalCandidate, metadata: plainMetadata)
        require(instrumentalDecision.versionConflict, "instrumental candidate conflicts with vocal track")
        require(instrumentalDecision.tier == .reject || instrumentalDecision.tier == .candidates, "instrumental is not auto")

        let foreverCandidate = candidate(
            identity: TrackIdentity(track: multiTrack),
            title: "Forever",
            artist: "VILLSHANA",
            album: "KILL is LOVE",
            duration: 168.75
        )
        let foreverDecision = LyricsSafeMatcher.decide(candidate: foreverCandidate, metadata: multiMetadata)
        require(foreverDecision.tier == .candidates || foreverDecision.tier == .reject, "Forever stays candidate or reject")
        require(foreverDecision.tier != .autoHigh && foreverDecision.tier != .autoMedium, "Forever does not auto adopt incomplete artists")
        require(foreverDecision.explanation.contains { $0.contains("missingFeaturedArtist") }, "Forever explains missing featured artist")

        let wrongPrimary = candidate(
            identity: TrackIdentity(track: multiTrack),
            title: "Forever",
            artist: "Someone Else",
            album: "KILL is LOVE",
            duration: 168.75
        )
        let wrongPrimaryDecision = LyricsSafeMatcher.decide(candidate: wrongPrimary, metadata: multiMetadata)
        require(wrongPrimaryDecision.tier == .reject, "primary artist conflict is hard reject")
        require(wrongPrimaryDecision.explanation.contains { $0.contains("primaryArtistConflict") }, "primary conflict explanation")

        let featuredOnlyCandidate = candidate(
            identity: TrackIdentity(track: multiTrack),
            title: "Forever（Official）",
            artist: "Mahiru",
            album: "KILL is LOVE",
            duration: 168.75
        )
        let featuredOnlyDecision = LyricsSafeMatcher.decide(candidate: featuredOnlyCandidate, metadata: multiMetadata)
        require(featuredOnlyDecision.tier == .candidates, "featured-only artist is selectable, not automatic")
        require(featuredOnlyDecision.explanation.contains { $0.contains("featuredArtistOnly") }, "featured-only explanation")

        let looseStrongCandidate = candidate(
            identity: TrackIdentity(track: plainTrack),
            title: "Lemon",
            artist: "Kenshi Yonezu",
            album: "STRAY SHEEP",
            duration: 255.826
        )
        let looseDecision = LyricsSafeMatcher.decide(
            candidate: looseStrongCandidate,
            metadata: plainMetadata,
            queryVariant: LyricsQueryVariant(
                rank: 9,
                strategy: .titleOnlyLoose,
                queryKind: .titleOnlyLoose,
                titleQuery: "Lemon",
                artistQuery: nil
            )
        )
        require(looseDecision.tier == .candidates || looseDecision.tier == .reject, "loose query cannot auto adopt without identity evidence")
        require(looseDecision.explanation.contains { $0.contains("looseQuery") }, "loose query explanation")
        require(looseDecision.queryKind == .titleOnlyLoose, "decision keeps loose query kind")

        let exactIdentityCandidate = candidate(
            identity: TrackIdentity(track: plainTrack),
            title: "Lemon",
            artist: "Kenshi Yonezu",
            album: "STRAY SHEEP",
            duration: 255.826,
            spotifyTrackID: "spotify:track:trusted-id",
            isrc: "JP-TEST-00001"
        )
        let exactIdentityTrack = Track(
            title: "Lemon",
            artist: "Kenshi Yonezu",
            album: "STRAY SHEEP",
            duration: 255.826,
            isrc: "JP-TEST-00001",
            spotifyId: "trusted-id"
        )
        let exactIdentityMetadata = TrackMetadata.bootstrap(from: exactIdentityTrack)
        let exactIdentityDecision = LyricsSafeMatcher.decide(
            candidate: exactIdentityCandidate,
            metadata: exactIdentityMetadata,
            aliasUsed: nil
        )
        require(exactIdentityDecision.explanation.contains { $0.contains("spotifyIDExact") }, "Spotify ID evidence")
        require(exactIdentityDecision.explanation.contains { $0.contains("isrcExact") }, "ISRC evidence")
        require(exactIdentityDecision.tier == .autoHigh, "strong identity can auto adopt")

        print("query identity contract passed")
    }
}
