import Foundation

@main
struct PlainLyricsCompanionMergerContract {
    static func main() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let primary = "source one\nsource two"
        let lines = [
            LyricLine(id: firstID, timestamp: 0, originalText: "source one"),
            LyricLine(id: secondID, timestamp: 0, originalText: "source two")
        ]

        let translated = PlainLyricsCompanionMerger.merge(
            "translated one\ntranslated two",
            original: primary,
            into: lines,
            layer: .translation
        )
        expect(translated.map(\.translationText) == ["translated one", "translated two"], "equal plain rows should pair by order")
        expect(translated.map(\.id) == lines.map(\.id), "merging must preserve line IDs")
        expect(translated.map(\.originalText) == lines.map(\.originalText), "merging must preserve original text")
        expect(translated.map(\.timestamp) == lines.map(\.timestamp), "merging must preserve timestamps")
        expect(translated.map(\.endTime) == lines.map(\.endTime), "merging must preserve end times")

        let romanized = PlainLyricsCompanionMerger.merge(
            "romaji one\nromaji two",
            original: primary,
            into: lines,
            layer: .romaji
        )
        expect(romanized.map(\.romajiText) == ["romaji one", "romaji two"], "equal plain rows should pair romaji by order")

        let mismatchedCount = PlainLyricsCompanionMerger.merge(
            "only one companion row",
            original: primary,
            into: lines,
            layer: .translation
        )
        expect(mismatchedCount == lines, "different row counts must remain unmerged")

        let timedOriginal = PlainLyricsCompanionMerger.merge(
            "translated one\ntranslated two",
            original: "[00:01.00]source one\nsource two",
            into: lines,
            layer: .translation
        )
        expect(timedOriginal == lines, "a timestamp in the original must prevent plain row pairing")

        let timedCompanion = PlainLyricsCompanionMerger.merge(
            "[00:01.00]translated one\ntranslated two",
            original: primary,
            into: lines,
            layer: .translation
        )
        expect(timedCompanion == lines, "a timestamp in the companion must prevent plain row pairing")

        let timedLines = [
            LyricLine(timestamp: 1, originalText: "timed one"),
            LyricLine(timestamp: 2, originalText: "timed two")
        ]
        let existingTimedMerge = TimedLyricsCompanionMerger.merge(
            "[00:01.10]translation one\n[00:02.10]translation two",
            into: timedLines,
            layer: .translation
        )
        expect(existingTimedMerge.map(\.translationText) == ["translation one", "translation two"], "existing timed merge behavior must remain intact")

        print("plain lyrics companion merger contract passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
