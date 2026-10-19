import Foundation

private actor QueryCount {
    var value = 0
    func record() { value += 1 }
}
private struct SourceFixture: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    let queries: QueryCount
    var delay: UInt64 = 0
    let executionLane: LyricsProviderExecutionLane = .network
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await queries.record()
        do { try await Task.sleep(nanoseconds: delay) }
        catch { return .failed(.cancelled) }
        return result
    }
}

@main struct SearchTranslationCompanionContract {
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ reason: String) {
            print("\(condition ? "PASS" : "FAIL") \(reason)")
            if !condition { failures += 1 }
        }
        let track = Track(title: "Fixture song", artist: "Fixture artist", album: "Fixture album", duration: 180,
            spotifyId: "fixture-recording")
        let metadata = TrackMetadata.bootstrap(from: track)
        let lines = [
            LyricLine(timestamp: 1, originalText: "Line one", endTime: 2, translationText: "Keep my translation",
                timedSpans: [TimedTextSpan(id: 0, text: "Line one", startTime: 1, endTime: 2, utf16Start: 0, utf16Length: 8)]),
            LyricLine(timestamp: 3, originalText: "Line two", endTime: 4),
            LyricLine(timestamp: 5, originalText: ""),
            LyricLine(timestamp: 7, originalText: "Line three", endTime: 8)
        ]
        let timingID = UUID()
        let selected = LyricsDocument(identity: metadata.identity, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, lines: lines, source: .lrclib,
            providerSourceID: "selected-source", spotifyTrackID: track.spotifyId,
            explicitlyTimedLineIndices: [0, 1, 3], timingVersionID: timingID)
        let donorLines = [
            LyricLine(timestamp: 50, originalText: "Line one", translationText: "Donor one"),
            LyricLine(timestamp: 60, originalText: "Line two", translationText: "Donor two"),
            LyricLine(timestamp: 70, originalText: "Line three", translationText: "Donor three")
        ]
        func donor(title: String? = nil, artist: String? = nil, duration: Double = 180,
                   words: [LyricLine]? = nil, spotifyID: String? = nil) -> LyricsCandidate {
            LyricsCandidate(id: "translated-source", identity: metadata.identity,
                title: title ?? track.title, artist: artist ?? track.artist, album: track.album,
                duration: duration, lines: words ?? donorLines, source: .neteaseExperimental,
                confidence: 0.9, providerSourceID: "translated-source", spotifyTrackID: spotifyID)
        }
        let expectedTranslations: [String?] = ["Keep my translation", "Donor two", nil, "Donor three"]
        let merged = LyricsSearchManager.mergingTranslationCompanion(donor(), into: selected, metadata: metadata)
        expect(merged?.lines.map(\.translationText) == expectedTranslations,
            "ordinary recording fills missing translations across blank rows")
        expect(merged?.replacingLines(lines) == selected,
            "merge preserves selected IDs, timing, spans, source and recording metadata")
        for (label, item) in [
            ("different artist", donor(artist: "Another artist")),
            ("different recording", donor(spotifyID: "another-recording")),
            ("different duration", donor(duration: 205)),
            ("different arrangement", donor(title: "Fixture song (Live)")),
            ("different verse", donor(words: [donorLines[0], LyricLine(timestamp: 60, originalText: "Other verse", translationText: "Wrong"), donorLines[2]])),
            ("reordered verses", donor(words: donorLines.reversed())),
            ("extra verse", donor(words: donorLines + [LyricLine(timestamp: 80, originalText: "Extra verse", translationText: "Extra")] ))
        ] {
            expect(LyricsSearchManager.mergingTranslationCompanion(item, into: selected, metadata: metadata) == nil,
                "do not borrow translations from \(label)")
        }

        let queries = QueryCount()
        let providers: [LyricsProvider] = [
            SourceFixture(name: "Selected timing", result: .match(selected), queries: queries, delay: 30_000_000),
            SourceFixture(name: "Available translations", result: .candidates([donor()]), queries: queries)
        ]
        let start = Date()
        let outcome = await LyricsSearchManager(providers: providers).search(track: track, identity: metadata.identity)
        if case .match(let document) = outcome.result {
            expect(document.lines.map(\.translationText) == expectedTranslations,
                "automatic adoption actually attaches the already returned translation source")
            expect(document.replacingLines(lines) == selected,
                "automatic adoption keeps the preferred timing document")
        } else { expect(false, "automatic adoption returns the preferred recording") }
        let count = await queries.value
        expect(count == 2 && Date().timeIntervalSince(start) < 0.5,
            "no extra provider probes or waiting for optional translation")
        expect(outcome.diagnostics.contains { $0.provider == "Available translations@translation-companion" },
            "translation donor remains traceable in search diagnostics")

        let browse = await LyricsSearchManager(providers: providers).search(track: track,
            identity: metadata.identity, collectCandidatesOnly: true)
        if case .candidates(let candidates) = browse.result {
            expect(candidates.first { $0.providerSourceID == "selected-source" }?.lines == lines
                && browse.automaticDecision == nil, "version browsing preserves each original source")
        } else { expect(false, "version browsing remains manual") }
        print("TRANSLATION_COMPANION_FAILURES=\(failures)")
        if failures > 0 { exit(1) }
    }
}
