import XCTest
@testable import SpotifyLyrics

final class LyricsEditorContractTests: XCTestCase {
    func testLineMutationsAndHistory() throws {
        let track = Track(id: "track-editor", title: "编辑测试", artist: "Test", album: "Album", duration: 120)
        var editor = LyricsEditorDraft(
            identity: TrackIdentity(track: track),
            title: "编辑测试",
            artist: "Test",
            album: "Album",
            duration: 120,
            lines: [
                LyricsEditorLineDraft(originalText: "第一句", startTime: 1),
                LyricsEditorLineDraft(originalText: "第二句", startTime: 3)
            ],
            sourceVersionID: UUID(),
            sourceContentHash: "source-hash",
            source: .lrclib
        )

        let firstID = try XCTUnwrap(editor.lines.first?.id)
        try editor.split(lineID: firstID, at: 2)
        XCTAssertEqual(editor.lines.map(\.originalText), ["第一", "句", "第二句"])
        try editor.merge(lineID: editor.lines[0].id, with: editor.lines[1].id)
        XCTAssertEqual(editor.lines.map(\.originalText), ["第一句", "第二句"])
        editor.insertBlank(after: editor.lines[0].id)
        XCTAssertEqual(editor.lines.count, 3)
        XCTAssertEqual(editor.lines[1].originalText, "")
        editor.move(lineID: editor.lines[2].id, offset: -2)
        XCTAssertEqual(editor.lines.map(\.originalText), ["第二句", "第一句", ""])
        try editor.delete(lineID: editor.lines[2].id)
        XCTAssertEqual(editor.lines.map(\.originalText), ["第二句", "第一句"])
        try editor.undo()
        XCTAssertEqual(editor.lines.map(\.originalText), ["第二句", "第一句", ""])
        try editor.redo()
        XCTAssertEqual(editor.lines.map(\.originalText), ["第二句", "第一句"])
    }

    func testTimelineValidation() throws {
        let valid = LyricsTimelineValidator.validate(
            lines: [
                LyricsEditorLineDraft(originalText: "A", startTime: 0, endTime: 2),
                LyricsEditorLineDraft(originalText: "B", startTime: 2, endTime: 5)
            ],
            duration: 5
        )
        XCTAssertTrue(valid.isSaveAllowed)
        XCTAssertTrue(valid.isSynchronized)
        XCTAssertTrue(valid.warnings.isEmpty)

        let duplicate = LyricsTimelineValidator.validate(
            lines: [
                LyricsEditorLineDraft(originalText: "A", startTime: 1),
                LyricsEditorLineDraft(originalText: "B", startTime: 1)
            ],
            duration: 5
        )
        XCTAssertTrue(duplicate.isSaveAllowed)
        XCTAssertTrue(duplicate.isSynchronized)
        XCTAssertFalse(duplicate.warnings.isEmpty)

        let invalid = LyricsTimelineValidator.validate(
            lines: [
                LyricsEditorLineDraft(originalText: "A", startTime: 4),
                LyricsEditorLineDraft(originalText: "B", startTime: 2)
            ],
            duration: 5
        )
        XCTAssertFalse(invalid.isSaveAllowed)

        let plain = LyricsTimelineValidator.validate(
            lines: [
                LyricsEditorLineDraft(originalText: "A"),
                LyricsEditorLineDraft(originalText: "")
            ],
            duration: 5
        )
        XCTAssertTrue(plain.isSaveAllowed)
        XCTAssertFalse(plain.isSynchronized)

        let plainDocument = LyricsDocument(
            identity: TrackIdentity(track: Track(title: "纯文本", artist: "Test", album: "", duration: 30)),
            lines: [LyricLine(timestamp: 0, originalText: "没有时间")],
            isSynchronized: false,
            source: .qqExperimental
        )
        let plainDraft = LyricsEditorDraft(document: plainDocument, sourceVersionID: UUID(), sourceContentHash: "plain")
        XCTAssertNil(plainDraft.lines[0].startTime, "Plain lyric zero placeholder stays untimed")
    }

    func testLRCImportAndExport() throws {
        let source = """
        [ti:恋風]
        [ar:Lilas]
        [al:Single]
        [length:03:02]
        [00:01.20][00:02.345]第一行
        [00:05.00]第二行
        """
        let imported = try LRCImportParser.parse(source)
        XCTAssertEqual(imported.metadata.title, "恋風")
        XCTAssertEqual(imported.metadata.artist, "Lilas")
        XCTAssertEqual(imported.lines.count, 3)
        XCTAssertEqual(imported.lines[0].startTime ?? -1, 1.2, accuracy: 0.0001)
        XCTAssertEqual(imported.lines[1].startTime ?? -1, 2.345, accuracy: 0.0001)
        XCTAssertTrue(imported.isSynchronized)

        let track = Track(title: "恋風", artist: "Lilas", album: "Single", duration: 182)
        let identity = TrackIdentity(track: track)
        let document = imported.document(identity: identity, track: track)
        let exported = LRCExporter.original(document: document, source: "manualImport", locked: true)
        let reparsed = try LRCImportParser.parse(exported)
        XCTAssertEqual(reparsed.lines.count, document.lines.count)
        XCTAssertEqual(reparsed.lines.map(\.startTime), document.lines.map { Optional($0.timestamp) })

        let plain = try LRCImportParser.parse("第一行\n\n第二行\n")
        XCTAssertFalse(plain.isSynchronized)
        XCTAssertEqual(plain.lines.count, 3)

        let translationExport = LRCExporter.translation(
            document: document,
            translations: ["第一行译文", "第二行译文", ""],
            targetLanguage: "zh-Hans",
            source: "manualEdit",
            locked: true
        )
        let translated = try LRCImportParser.parse(translationExport)
        XCTAssertEqual(translated.metadata.language, "zh-Hans")

        let mismatched = LRCImportMatcher.compare(
            metadata: imported.metadata,
            track: Track(title: "别的歌", artist: "别的艺人", album: "", duration: 20)
        )
        XCTAssertTrue(mismatched.isMismatchWarning)
    }
}
