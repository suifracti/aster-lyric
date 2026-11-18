import Foundation
import SQLite3
import XCTest
import PDFKit
@testable import SpotifyLyrics

final class LibraryRevisionsContractTests: XCTestCase {
    func testPersonalDataImportRollsBackEarlierSongsWhenALaterWriteFails() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let (first, second) = try await portableImportFixtures(at: root)
        let targetURL = root.appendingPathComponent("target.sqlite3")
        let target = SQLiteLyricsRepository(databaseURL: targetURL)
        try await target.prepare()
        try executeSQL("""
            CREATE TRIGGER reject_second_song BEFORE INSERT ON tracks WHEN NEW.title = 'Second recording'
            BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;
            """, at: targetURL)
        let data = PersonalDataPackage(tracks: [first, second])
        let preview = try await target.previewImportPersonalDataPackage(data)
        XCTAssertEqual(preview.totalNewAssets, 2)
        do {
            try await target.importPersonalDataPackage(data)
            XCTFail("The second recording should fail to write")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture write failure"))
        }
        let afterFailure = try await target.exportPersonalDataPackage()
        XCTAssertTrue(afterFailure.tracks.isEmpty, "An unsuccessful import must leave the earlier recording out as well")

        try executeSQL("DROP TRIGGER reject_second_song;", at: targetURL)
        try await target.importPersonalDataPackage(data)
        let restored = try await target.exportPersonalDataPackage()
        XCTAssertEqual(Set(restored.tracks.map(\.track.stableKey)), Set([first.track.stableKey, second.track.stableKey]))
    }

    func testPackagePreviewRejectsALyricsVersionAlreadyOwnedByAnotherRecording() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let (first, second) = try await portableImportFixtures(at: root)
        let target = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("target.sqlite3"))
        try await target.importPersonalLibraryPackage(first)
        let wrongRecording = PersonalLyricsLibraryPackage(track: second.track, lyricsVersions: first.lyricsVersions,
                                                          translationVersions: [], readingVersions: [], timingVersions: [])
        let preview = try await target.previewImportPersonalLibraryPackage(wrongRecording)
        XCTAssertTrue(preview.hasConflicts)
        XCTAssertEqual(preview.lyricsToSkip, 0)
        do {
            try await target.importPersonalLibraryPackage(wrongRecording)
            XCTFail("A shared version ID cannot be transferred to another recording")
        } catch {
            let restored = try await target.exportPersonalDataPackage()
            XCTAssertEqual(restored.tracks.map(\.track.stableKey), [first.track.stableKey])
        }
    }

    @MainActor
    func testPrivateFolderConfirmationRequiresTheSnapshotThatWasPreviewed() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let (first, second) = try await portableImportFixtures(at: root)
        let folder = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "lyricsq-import-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PersonalDataSyncStore.saveFolderReference(folder, defaults: defaults)
        let firstPackage = PersonalDataPackage(tracks: [first])
        try PersonalDataSyncStore.write(firstPackage, to: folder, replacing: nil)
        let firstSnapshot = try XCTUnwrap(PersonalDataSyncStore.snapshot(in: folder))
        let target = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("target.sqlite3"))
        let service = PersonalLyricsLibraryService(repository: target, defaults: defaults)

        func finishSync() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while service.isSyncing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(service.isSyncing)
        }

        service.syncNow()
        try await finishSync()
        XCTAssertEqual(service.dataImportPreview?.trackPreviews.first?.trackStableKey, first.track.stableKey)
        try PersonalDataSyncStore.write(.init(tracks: [second]), to: folder)
        XCTAssertThrowsError(try PersonalDataSyncStore.write(firstPackage, to: folder, replacing: firstSnapshot.revision)) {
            XCTAssertEqual($0 as? PersonalDataSyncStoreError, .packageChanged)
        }
        service.confirmPersonalDataImport()
        try await finishSync()
        XCTAssertEqual(service.personalDataNotice, PersonalDataSyncStoreError.packageChanged.localizedDescription)
        XCTAssertFalse(service.showDataImportPreviewSheet)
        let unchanged = try await target.exportPersonalDataPackage()
        XCTAssertTrue(unchanged.tracks.isEmpty)

        service.syncNow()
        try await finishSync()
        XCTAssertEqual(service.dataImportPreview?.trackPreviews.first?.trackStableKey, second.track.stableKey)
        service.confirmPersonalDataImport()
        try await finishSync()
        let local = try await target.exportPersonalDataPackage()
        let synced = try PersonalDataSyncStore.read(from: folder)
        XCTAssertEqual(local.tracks.map(\.track.stableKey), [second.track.stableKey])
        XCTAssertEqual(synced?.tracks.map(\.track.stableKey), [second.track.stableKey])
        XCTAssertEqual(service.personalDataNotice, "已导入资产并更新同步文件")
    }

    private func portableImportFixtures(at root: URL) async throws -> (PersonalLyricsLibraryPackage, PersonalLyricsLibraryPackage) {
        let source = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("source.sqlite3"))
        let file = try LocalLyricsFile(data: Data("[00:01.00]Fixture lyrics".utf8), kind: .lrc, preferredLanguage: "en")
        let first = try await source.importLyricFile(file, into: Track(title: "First recording", artist: "Test", album: "", duration: 180))
        let second = try await source.importLyricFile(file, into: Track(title: "Second recording", artist: "Test", album: "", duration: 180))
        return (try await source.exportPersonalLibraryPackage(stableKey: first.trackKey),
                try await source.exportPersonalLibraryPackage(stableKey: second.trackKey))
    }

    func testPortableSongbookRetainsRepeatedPassagesAndPrintsTheLastLine() throws {
        let version = UUID()
        let first = V3FavoriteLines.Entry(text: "回到这里", translation: "Here again", title: "慢车", artist: "南窗",
                                          trackKey: "one", lyricsVersionID: version, lineIndex: 2)
        var later = first
        later.id = UUID()
        later.lineIndex = 19
        var book = LyricBook(title: "旅途中读的歌", author: "星弦")
        let opening = book.add(.init(quote: first))
        XCTAssertEqual(book.add(.init(quote: first)), opening)
        let closing = book.add(.init(quote: later))
        XCTAssertNotEqual(opening, closing)
        book.move(closing, by: -1)
        XCTAssertEqual(book.chapters.map(\.origin.lineIndex), [19, 2])
        book.chapters[0].note = "写在返程"
        book.chapters[0].lines += (1...110).map { .init(original: "第\($0)行在路上") }
        book.chapters[0].lines.append(.init(original: "末页仍有整句"))
        let restored = try LyricBook(data: book.encoded())
        XCTAssertEqual(restored, book)
        let pdf = try XCTUnwrap(PDFDocument(data: try LyricBookPrint.data(for: restored)))
        XCTAssertGreaterThan(pdf.pageCount, 4)
        let printed = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        for text in ["旅途中读的歌", "写在返程", "末页仍有整句", "Here again"] { XCTAssertTrue(printed.contains(text), text) }
        XCTAssertEqual(pdf.page(at: 1)?.annotations.filter { $0.type == "Link" }.count, 2)
    }

    func testSongbookExcerptKeepsTheSecondChorusAndItsSavedEdition() async throws {
        let text = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="ja"><body><div>
        <p begin="1s" end="2s" ttm:agent="v1">また会える</p>
        <p begin="2s" end="3s" ttm:agent="v1">帰り道</p>
        <p begin="8s" end="9s" ttm:agent="v1">また会える<span ttm:role="x-translation" xml:lang="zh-Hans">还会再见</span></p>
        <p begin="8s" end="9s" ttm:agent="v2">また会える</p>
        <p begin="9s" end="10s" ttm:agent="v2">帰り道<span ttm:role="x-bg">小声</span></p>
        <p begin="10s" end="11s" ttm:agent="v1">この先へ</p></div></body></tt>
        """
        let file = try LocalLyricsFile(data: Data(text.utf8), kind: .ttml, preferredLanguage: "zh-Hans")
        let track = Track(title: "帰り道", artist: "Fixture", album: "", duration: 60)
        let repo = SQLiteLyricsRepository(databaseURL: NativeTestRuntime.root.appendingPathComponent("\(UUID()).sqlite3"))
        let target = try await repo.importLyricFile(file, into: track)
        let detail = try await repo.loadPersonalLibraryTrackDetail(stableKey: target.trackKey)
        let translation = try XCTUnwrap(detail?.translationVersions.first)
        let source = LibraryPassageSource.translation(translation.id)
        let loaded = try await repo.readLibraryPassage(.init(trackKey: target.trackKey, source: source))
        let page = try XCTUnwrap(loaded)
        let first = try XCTUnwrap(LyricBook.Chapter(page: page, source: source, range: 0...1))
        let second = try XCTUnwrap(LyricBook.Chapter(page: page, source: source, range: 2...4))
        XCTAssertEqual(first.lines.map(\.original), second.lines.map(\.original))
        XCTAssertEqual(second.readingRows.first?.voice, "合唱")
        XCTAssertEqual(second.lines.first?.translation, "还会再见")
        XCTAssertEqual(second.lines.last?.background, "小声")
        var book = LyricBook()
        XCTAssertNotEqual(book.add(first), book.add(second))
        XCTAssertEqual(book.add(second), second.id)
        let restored = try LyricBook(data: book.encoded())
        let saved = try XCTUnwrap(restored.chapters.last)
        XCTAssertEqual(saved.origin.source, source)
        XCTAssertEqual(saved.origin.excerptRange, 2...4)
        let reopened = try await repo.readLibraryPassage(saved.origin)
        XCTAssertEqual(reopened?.lines.first(where: { $0.id == saved.origin.lineIndex })?.startTime, 8)
        let pdf = try XCTUnwrap(PDFDocument(data: try LyricBookPrint.data(for: restored)))
        let printed = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(printed.contains("还会再见"))
        XCTAssertFalse(printed.contains("この先へ"))
    }

    func testMovingAndRepeatingStanzasKeepsBlankSpaceAndTimingLabels() throws {
        let text = "\r\n[00:01.00]第一段🌿\r\n下一行\r\n \t\r\n回来\r\n\r\n回来\r\n"
        let draft = LyricManuscript(text: text)
        XCTAssertEqual(try LyricManuscript(data: draft.data), draft)
        let arrangement = ManuscriptStanzas(text)
        XCTAssertEqual(arrangement.stanzas.map(\.firstOccurrence), [0, 1, 1])
        let moved = try XCTUnwrap(arrangement.moving(0, by: 1))
        XCTAssertEqual(moved, "\r\n回来\r\n \t\r\n[00:01.00]第一段🌿\r\n下一行\r\n\r\n回来\r\n")
        XCTAssertEqual(ManuscriptStanzas(moved).moving(1, by: -1), text)
        XCTAssertEqual(arrangement.repeatingAtEnd(1), text + "\r\n回来\r\n")
    }

    func testWritingAnOfflineManuscriptKeepsTheDraftAndItsVersionHistory() async throws {
        var draft = LyricManuscript(title: "留在纸上", artist: "本机", album: "书桌", text: "\n第一句\n\n还有一句\n")
        let parsed = try LyricManuscript(data: draft.data)
        XCTAssertEqual(parsed, draft)
        let file = try LocalLyricsFile(data: draft.data, kind: .manuscript, preferredLanguage: "zh")
        XCTAssertEqual(file.lines.map(\.originalText), ["第一句", "", "还有一句"])
        XCTAssertEqual(file.content.title, "留在纸上")
        let track = Track(title: draft.title, artist: draft.artist, album: draft.album, duration: 0)
        let repo = SQLiteLyricsRepository(databaseURL: NativeTestRuntime.root.appendingPathComponent("\(UUID()).sqlite3"))
        let first = try await repo.importLyricFile(file, into: track)
        draft.text = "[00:00.00]第一句\n第二句"
        let nextFile = try draft.lyricFile()
        let second = try await repo.importLyricFile(nextFile, into: track)
        let duplicate = try await repo.importLyricFile(nextFile, into: track)
        XCTAssertEqual(duplicate, second)
        draft.text = "[00:02.30]第一句\n第二句"
        let third = try await repo.importLyricFile(draft.lyricFile(), into: track)
        let detail = try await repo.loadPersonalLibraryTrackDetail(stableKey: first.trackKey)
        guard case let .original(parentID) = first.source, case let .original(childID) = second.source,
              case let .original(lastID) = third.source else { return XCTFail("需要三版手写原词") }
        XCTAssertEqual(detail?.lyricsVersions.count, 3)
        XCTAssertEqual(detail?.lyricsVersions.first { $0.id == childID }?.parentVersionID, parentID)
        XCTAssertEqual(detail?.lyricsVersions.first { $0.id == lastID }?.parentVersionID, childID)
        XCTAssertEqual(detail?.entry.activeLyricsVersionID, parentID)
        XCTAssertEqual(detail?.lyricsVersions.first?.source, "manualCreate")
        let last = try await repo.readLibraryPassage(third)
        XCTAssertEqual(last?.lines.map(\.startTime), [2.3, nil])
        draft.recordingKey = first.trackKey
        draft.filedVersionID = parentID
        draft.text = "从第一稿另写的结尾"
        let fork = try await repo.importLyricFile(draft.lyricFile(), into: track)
        guard case let .original(forkID) = fork.source else { return XCTFail("应当创建分稿") }
        let revised = try await repo.loadPersonalLibraryTrackDetail(stableKey: first.trackKey)
        XCTAssertEqual(revised?.lyricsVersions.first { $0.id == forkID }?.parentVersionID, parentID)
        let other = Track(title: draft.title, artist: "另一位", album: "", duration: 0)
        let unrelated = try await repo.importLyricFile(draft.lyricFile(), into: other)
        let separate = try await repo.loadPersonalLibraryTrackDetail(stableKey: unrelated.trackKey)
        XCTAssertNil(separate?.lyricsVersions.first?.parentVersionID)
    }

    func testWritingFromAnArchivedEditionFilesUnderTheExactBase() async throws {
        let track = Track(title: "还没写完", artist: "自习室", album: "书桌", duration: 90)
        let repo = SQLiteLyricsRepository(databaseURL: NativeTestRuntime.root.appendingPathComponent("\(UUID()).sqlite3"))
        let text = "[00:01.125]まだ書けない\n予備の句\n\n[01:00.000]まだ書けない"
        let originalFile = try LocalLyricsFile(data: Data(text.utf8), kind: .lrc, preferredLanguage: "ja")
        let adoptedFile = try LocalLyricsFile(data: Data("当前采用的歌词".utf8), kind: .txt, preferredLanguage: "zh")
        let base = try await repo.importLyricFile(originalFile, into: track)
        let adopted = try await repo.importLyricFile(adoptedFile, into: track)
        guard case let .original(baseID) = base.source, case let .original(adoptedID) = adopted.source else {
            return XCTFail("需要两份可读原词")
        }
        try await repo.adoptLyricsVersion(trackStableKey: base.trackKey, lyricsVersionID: adoptedID)
        let savedBase = try await repo.readLibraryPassage(base)
        var page = try XCTUnwrap(savedBase)
        var draft = try XCTUnwrap(LyricManuscript(copyingOriginal: page))
        XCTAssertEqual(try LyricManuscript(data: draft.data), draft)
        XCTAssertEqual(draft.text, text)
        XCTAssertEqual(draft.title, track.title)
        XCTAssertEqual(draft.artist, track.artist)
        XCTAssertEqual(draft.album, track.album)
        XCTAssertEqual(draft.recordingKey, base.trackKey)
        XCTAssertEqual(draft.filedVersionID, baseID)

        draft.text = draft.text.replacingOccurrences(of: "予備の句", with: "書き直した句")
        let filed = try await repo.importLyricFile(draft.lyricFile(), into: track)
        guard case let .original(childID) = filed.source else { return XCTFail("应当留下独立分稿") }
        let detail = try await repo.loadPersonalLibraryTrackDetail(stableKey: base.trackKey)
        XCTAssertEqual(detail?.entry.activeLyricsVersionID, adoptedID)
        XCTAssertEqual(detail?.lyricsVersions.first { $0.id == childID }?.parentVersionID, baseID)
        let newPage = try await repo.readLibraryPassage(filed)
        XCTAssertEqual(newPage?.lines.map(\.startTime), [1.125, nil, nil, 60])
        XCTAssertEqual(newPage?.lines.map(\.original), ["まだ書けない", "書き直した句", "", "まだ書けない"])
        let unchanged = try await repo.readLibraryPassage(base)
        XCTAssertEqual(unchanged?.lines, page.lines)

        let otherTrack = Track(title: track.title, artist: "另一位", album: "", duration: 90)
        let unrelated = try await repo.importLyricFile(draft.lyricFile(), into: otherTrack)
        let otherDetail = try await repo.loadPersonalLibraryTrackDetail(stableKey: unrelated.trackKey)
        XCTAssertNil(otherDetail?.lyricsVersions.first?.parentVersionID)
        page.matchesOriginalVersion = false
        XCTAssertNil(LyricManuscript(copyingOriginal: page))
    }

    func testPortableTTMLPreservesSourceLanguagesAndExportsTheExactArchivedTranslation() async throws {
        let text = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="ja"><body><div>
        <p begin="0s" end="2.5s" ttm:agent="v1">「<span begin="0.125s" end="1s">風</span> &amp; 海」
        <span ttm:role="x-translation" xml:lang="en">wind &amp; sea</span><span ttm:role="x-translation" xml:lang="zh-Hans">风与海</span><span ttm:role="x-roman">kaze to umi</span></p>
        <p ttm:agent="v2">間奏<span ttm:role="x-bg">（小声）</span></p></div></body></tt>
        """
        let file = try LocalLyricsFile(data: Data(text.utf8), kind: .ttml, preferredLanguage: "en")
        let track = Track(title: "潮 & 汐", artist: "一 < 二", album: "纸上的歌", duration: 9)
        let edition = PortableLyricsEdition(document: file.document(for: track), title: track.title, translationLanguage: "en")
        let copy = try LocalLyricsFile(data: Data(edition.contents(.ttml).utf8), kind: .ttml, preferredLanguage: "zh-Hans")
        XCTAssertEqual(copy.translationLanguages, ["en", "zh-Hans"])
        XCTAssertEqual(copy.content.title, track.title)
        XCTAssertEqual(copy.content.artist, track.artist)
        XCTAssertEqual(copy.lines.map(\.originalText), file.lines.map(\.originalText))
        XCTAssertEqual(copy.lines.map(\.timedSpans), file.lines.map(\.timedSpans))
        XCTAssertEqual(copy.content.explicitlyTimedLineIndices, [0])
        XCTAssertEqual(copy.lines.map(\.performerID), ["v1", "v2"])
        XCTAssertEqual(copy.lines.map(\.backgroundText), [nil, "小声"])
        XCTAssertEqual(copy.lines.map(\.romajiText), ["kaze to umi", nil])

        let repo = SQLiteLyricsRepository(databaseURL: NativeTestRuntime.root.appendingPathComponent("\(UUID()).sqlite3"))
        let target = try await repo.importLyricFile(file, into: track)
        let detail = try await repo.loadPersonalLibraryTrackDetail(stableKey: target.trackKey)
        let zh = try XCTUnwrap(detail?.translationVersions.first { $0.targetLanguage == "zh-Hans" })
        let loaded = try await repo.readLibraryPassage(.init(trackKey: target.trackKey, source: .translation(zh.id)))
        let page = try XCTUnwrap(loaded).portableEdition
        let exported = try LocalLyricsFile(data: Data(page.contents(.ttml).utf8), kind: .ttml, preferredLanguage: "en")
        XCTAssertEqual(exported.translationLanguages, ["zh-Hans"])
        XCTAssertEqual(exported.lines.map(\.translationText), ["风与海", nil])
        XCTAssertEqual(exported.lines.map(\.performerID), copy.lines.map(\.performerID))
        XCTAssertEqual(exported.lines.map(\.timedSpans), copy.lines.map(\.timedSpans))
        XCTAssertTrue(page.contents(.translationLRC).contains("[00:00.000]风与海"))
        XCTAssertTrue(page.contents(.readingText).contains("（小声）"))
    }

    func testLineOnlyDuetSurvivesFilingAndMovingTheArchive() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("first.sqlite3"))
        let track = Track(title: "两个人的信", artist: "测试", album: "", duration: 0)
        let identity = TrackIdentity(track: track)
        let text = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p ttm:agent="v1">寄出<span ttm:role="x-bg">（回声）</span></p>
        <p ttm:agent="v2">收到</p></div></body></tt>
        """
        let file = try LocalLyricsFile(data: Data(text.utf8), kind: .ttml, preferredLanguage: "zh")
        let target = try await repo.importLyricFile(file, into: track)
        let fromDisk = try await repo.readLibraryPassage(target)
        XCTAssertEqual(fromDisk?.lines.first?.background, file.lines.first?.backgroundText)
        let detail = try await repo.loadPersonalLibraryTrackDetail(stableKey: target.trackKey)
        XCTAssertEqual(detail?.timingVersions.count, 0)
        let packed = try await repo.exportPersonalLibraryPackage(stableKey: target.trackKey)
        let restored = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("second.sqlite3"))
        try await restored.importPersonalLibraryPackage(packed)
        let held = try await restored.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(held?.document.lines.map(\.performerID), ["v1", "v2"])
        XCTAssertEqual(held?.document.lines.first?.backgroundText, file.lines.first?.backgroundText)
        XCTAssertEqual(held?.document.hasTimedSpans, false)

        let url = root.appendingPathComponent("second.sqlite3")
        try executeSQL("""
            ALTER TABLE lyric_lines DROP COLUMN performer_id;
            ALTER TABLE lyric_lines DROP COLUMN background_text;
            DELETE FROM schema_migrations WHERE version = 14;
            PRAGMA user_version = 13;
            """, at: url)
        let upgraded = SQLiteLyricsRepository(databaseURL: url)
        let prior = try await upgraded.readLibraryPassage(target)
        XCTAssertEqual(prior?.lines.map(\.original), ["寄出", "收到"])
        XCTAssertNil(prior?.lines.first?.background)
        let recovered = try await upgraded.importLyricFile(file, into: track)
        XCTAssertEqual(recovered, target)
        let voices = try await upgraded.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(voices?.document.lines.map(\.performerID), ["v1", "v2"])
        XCTAssertEqual(voices?.document.lines.first?.backgroundText, "回声")
    }

    func testOfflineDuetKeepsItsSourceRowsAndSingsTheRepriseAgain() async throws {
        let ttml = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p begin="1s" end="2s" ttm:agent="v1">海边的信</p>
        <p begin="3s" end="4s" ttm:agent="v2">读到这里</p>
        <p begin="6s" end="8s" ttm:agent="v1">等风来</p>
        <p begin="6.05s" end="8s" ttm:agent="v2">等风来</p>
        <p begin="6.10s" end="8s" ttm:agent="v1">等风来<span ttm:role="x-bg">（风声）</span></p>
        <p begin="12s" end="14s" ttm:agent="v2">等风来</p>
        </div></body></tt>
        """
        let file = try LocalLyricsFile(data: Data(ttml.utf8), kind: .ttml, preferredLanguage: "zh-Hans")
        let track = Track(title: "两个人的信", artist: "合声", album: "", duration: 16)
        let repo = SQLiteLyricsRepository(databaseURL: NativeTestRuntime.root.appendingPathComponent("\(UUID()).sqlite3"))
        let target = try await repo.importLyricFile(file, into: track)
        let stored = try await repo.readLibraryPassage(target)
        let page = try XCTUnwrap(stored)
        let voice = PassageVoicePresentation(lines: page.lines)
        XCTAssertEqual(page.lines.map(\.performerID), ["v1", "v2", "v1", "v2", "v1", "v2"])
        XCTAssertEqual(voice.visibleID(for: 3), 2)
        XCTAssertEqual(voice.visibleLines(in: page.lines).map(\.id), [0, 1, 2, 4, 5])
        XCTAssertEqual(page.lines.indices.map(voice.label(for:)), ["声部 1", "声部 2", "合唱", "合唱", "合唱", "声部 2"])
        XCTAssertEqual(page.lines[4].background, "风声")
        let untimed = page.lines.map { row in
            var row = row
            row.startTime = nil
            return row
        }
        XCTAssertTrue(PassageVoicePresentation(lines: untimed).aliases.isEmpty)

        var book = LyricBook(title: "留在纸上的合声")
        book.add(.init(page: page, source: target.source))
        book.add(.init(page: page, source: target.source, excerpt: page.lines[3]))
        let restored = try LyricBook(data: book.encoded())
        XCTAssertEqual(restored.chapters[0].readingRows.map(\.id), [0, 1, 2, 4, 5])
        XCTAssertEqual(restored.chapters[1].readingRows.first?.voice, "合唱")
        XCTAssertEqual(restored.chapters[1].origin.lineIndex, 3)
        let pdf = try XCTUnwrap(PDFDocument(data: try LyricBookPrint.data(for: restored)))
        let printed = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        for word in ["声部", "合唱", "风声"] { XCTAssertTrue(printed.contains(word), word) }

        var switched = page.lines
        switched[5].performerID = "v1"
        let comparison = LibraryVersionComparison.align(page.lines, switched, translations: false, sameOriginal: false)
        XCTAssertEqual(comparison.last?.change, .voice)
        XCTAssertEqual(comparison.last?.baseVoice, "声部 2")
        XCTAssertEqual(comparison.last?.referenceVoice, "声部 1")
    }

    func testLocalFileReadsUTF16AndKeepsUntimedLRCLinesInPlace() throws {
        let ttml = #"<?xml version="1.0" encoding="UTF-16"?><tt><body><div><p>纸上</p></div></body></tt>"#
        let utf16 = Data([0xff, 0xfe]) + (try XCTUnwrap(ttml.data(using: .utf16LittleEndian)))
        let xml = try LocalLyricsFile(data: utf16, kind: .ttml, preferredLanguage: "zh-Hans")
        XCTAssertEqual(xml.lines.map(\.originalText), ["纸上"])

        let lrc = "[ti:纸上]\n[language:zh]\n前言\n[00:00.00]第一行\n间记\n[00:12.50]后一行"
        let file = try LocalLyricsFile(data: Data(lrc.utf8), kind: .lrc, preferredLanguage: "zh-Hans")
        XCTAssertEqual(file.content.language, "zh")
        XCTAssertEqual(file.lines.map(\.originalText), ["前言", "第一行", "间记", "后一行"])
        XCTAssertEqual(file.content.explicitlyTimedLineIndices, [1, 3])
        let exported = LRCExporter.original(document: file.content, source: "manualImport", locked: false)
        let roundTrip = try LRCImportParser.parse(exported)
        XCTAssertEqual(roundTrip.lines.map(\.startTime), [nil, 0, nil, 12.5])
    }

    func testMultilingualFileKeepsSparseLanguagesOnOneOriginalAcrossImports() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("archive.sqlite3"),
                                          alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        let data = Data("""
        <tt xmlns:ttm="urn:ttm" xmlns:itunes="urn:itunes" xml:lang="ja"><head><metadata>
        <translations><translation xml:lang="zh-Hant"><text for="A">第一個夢</text></translation></translations>
        </metadata></head><body><div>
        <p begin="3s">風<span ttm:role="x-translation" xml:lang="zh-Hans">风</span></p>
        <p begin="1s" itunes:key="A">夢<span ttm:role="x-translation" xml:lang="en">dream</span><span ttm:role="x-translation" xml:lang="zh-Hans">第一个梦</span></p>
        </div></body></tt>
        """.utf8)
        let track = Track(title: "夢", artist: "测试", album: "", duration: 9)
        let key = TrackIdentity(track: track).stableKey
        let english = try LocalLyricsFile(data: data, kind: .ttml, preferredLanguage: "en-GB")
        let chinese = try LocalLyricsFile(data: data, kind: .ttml, preferredLanguage: "zh-TW")
        XCTAssertEqual(english.lines.map(\.translationText), ["dream", nil])
        XCTAssertEqual(chinese.lines.map(\.translationText), ["第一個夢", nil])
        XCTAssertEqual(english.lines[0].replacingID(UUID()).sourceTranslations, english.lines[0].sourceTranslations)
        XCTAssertEqual(english.viewing("zh-Hans").lines.map(\.translationText), ["第一个梦", "风"])
        let first = try await repo.importLyricFile(english, into: track)
        let second = try await repo.importLyricFile(chinese, into: track)
        XCTAssertEqual(first, second)
        let found = try await repo.loadPersonalLibraryTrackDetail(stableKey: key)
        let detail = try XCTUnwrap(found)
        XCTAssertEqual(detail.lyricsVersions.count, 1)
        XCTAssertEqual(Set(detail.translationVersions.map(\.targetLanguage)), ["en", "zh-Hant", "zh-Hans"])
        let chosenLanguage = "zh-Hant"
        let filePosition = LibraryPassageTarget.ReadingPosition(find: "第一個夢", lineIndex: 0, topLineIndex: nil)
        let continued = try await repo.continueFiledLyricReading(first, file: english.viewing(chosenLanguage), position: filePosition)
        let expectedTranslation = try XCTUnwrap(detail.translationVersions.first { $0.targetLanguage == chosenLanguage })
        XCTAssertEqual(continued.trackKey, key)
        XCTAssertEqual(continued.source, .translation(expectedTranslation.id))
        XCTAssertEqual(continued.readingPosition, filePosition)
        let continuedPage = try await repo.readLibraryPassage(continued)
        XCTAssertEqual(continuedPage?.lines.map(\.translation), ["第一個夢", ""])
        let sameTitle = try await repo.searchLibraryPassages("夢")
        XCTAssertEqual(sameTitle.first?.matchesMetadata, true)
        XCTAssertNotNil(sameTitle.first?.source)
        let searched = try await repo.searchLibraryPassages("第一个梦")
        let targetID = try XCTUnwrap(detail.translationVersions.first { $0.targetLanguage == "zh-Hans" }?.id)
        XCTAssertEqual(searched.first?.source, .translation(targetID))
        XCTAssertEqual(searched.first?.excerpt, "第一个梦")
        let original = try XCTUnwrap(detail.lyricsVersions.first)
        let editable = try await repo.loadEditableVersion(versionID: original.id, track: track, identity: TrackIdentity(track: track))
        let hash = try XCTUnwrap(editable?.sourceContentHash)
        try await repo.preserveEmbeddedTranslation(lyricsVersionID: original.id, sourceContentHash: hash)
        let languages = try await repo.loadTranslationVersions(lyricsVersionID: original.id, targetLanguage: "zh-TW", sourceContentHash: hash)
        XCTAssertEqual(languages.count, 3)
        XCTAssertEqual(StoredTranslationVersion.preferredEmbedded(in: languages, language: "zh-TW")?.record.targetLanguage, "zh-Hant")
        XCTAssertEqual(StoredTranslationVersion.preferredEmbedded(in: languages, language: "en-GB")?.record.targetLanguage, "en")
        for item in detail.translationVersions {
            let page = try await repo.readLibraryPassage(.init(trackKey: key, source: .translation(item.id)))
            let expected: [String?] = item.targetLanguage == "en" ? ["dream", nil]
                : item.targetLanguage == "zh-Hant" ? ["第一個夢", nil] : ["第一个梦", "风"]
            XCTAssertEqual(page?.lines.map { ($0.translation?.isEmpty == false) ? $0.translation : nil }, expected)
        }

        let opened = try await repo.readLibraryPassage(.init(trackKey: key, source: .translation(targetID)), includeEditions: true)
        let page = try XCTUnwrap(opened)
        let englishID = try XCTUnwrap(detail.translationVersions.first { $0.targetLanguage == "en" }?.id)
        let edition = try XCTUnwrap(page.editions.first { $0.source == .translation(englishID) })
        let position = LibraryPassageTarget.ReadingPosition(find: "夢", lineIndex: 0, topLineIndex: nil)
        let switched = edition.readingTarget(from: page, position: position)
        XCTAssertEqual(switched.trackKey, key)
        XCTAssertEqual(switched.readingPosition, position)
        let otherTranslation = try await repo.readLibraryPassage(switched)
        XCTAssertEqual(otherTranslation?.lines.first?.translation, "dream")
        let afterReading = try await repo.loadPersonalLibraryTrackDetail(stableKey: key)
        XCTAssertEqual(afterReading?.entry.activeTranslationVersionID, detail.entry.activeTranslationVersionID)
    }

    func testLocalFileCanBeReadAndFiledBesideLockedLyricsWithoutPlaying() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("files.sqlite3"),
                                         alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let track = Track(title: "海岸", artist: "样例", album: "現場", duration: 90, spotifyId: "recordingA")
        let identity = TrackIdentity(track: track)
        let original = LyricsDocument(identity: identity, lines: [.init(timestamp: 1, originalText: "已有手稿")],
                                      source: .manualEdit)
        let saved = try await repo.save(track: track, identity: identity, document: original)
        let locked = try XCTUnwrap(saved.versionID)
        try await repo.markLocked(versionID: locked, locked: true)
        let ttml = #"<tt xml:lang="ja" xmlns:ttm="urn:ttm"><body><div><p begin="1s"><span begin="1s" end="2s">海</span><span ttm:role="x-bg">声</span><span ttm:role="x-translation" xml:lang="zh">海边</span></p><p begin="4s">風</p></div></body></tt>"#
        let file = try LocalLyricsFile(data: Data(ttml.utf8), kind: .ttml, preferredLanguage: "zh-Hans")
        XCTAssertEqual(file.lines.map(\.originalText), ["海", "風"])
        let laterMetadata = Track(title: track.title, artist: track.artist, album: track.album, duration: 91,
                                  spotifyId: track.spotifyId)
        let choices = try await repo.localRecordingChoices(preferredRecording: TrackIdentity(track: laterMetadata).stableKey)
        let destination = try XCTUnwrap(choices.preferred)
        XCTAssertEqual(destination.stableKey, identity.stableKey)
        XCTAssertEqual(choices.records.filter { $0.stableKey == destination.stableKey }, [destination])
        let imported = try await repo.importLyricFile(file, into: destination.libraryTrack, archiveKey: destination.stableKey)
        let duplicate = try await repo.importLyricFile(file, into: track)
        XCTAssertEqual(duplicate, imported)
        let page = try await repo.readLibraryPassage(imported)
        XCTAssertEqual(page?.lines.first?.background, "声")
        XCTAssertEqual(page?.lines.first?.translation, "海边")
        let stored = try await repo.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(stored?.versionID, locked)
        let detail = try await repo.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey)
        XCTAssertEqual(detail?.lyricsVersions.count, 2)
        XCTAssertEqual(detail?.translationVersions.count, 1)
        let plain = try LocalLyricsFile(data: Data(ttml.replacingOccurrences(of: " xml:lang=\"zh\"", with: "").utf8),
                                       kind: .ttml, preferredLanguage: "en")
        let plainTrack = Track(title: "未标语言", artist: "样例", album: "", duration: 5)
        let plainID = TrackIdentity(track: plainTrack)
        let target = try await repo.importLyricFile(plain, into: plainTrack)
        guard case let .original(plainVersionID) = target.source else { return XCTFail("缺少原词") }
        let tagged = try await repo.loadEditableVersion(versionID: plainVersionID, track: plainTrack, identity: plainID)
        let plainSource = try XCTUnwrap(tagged)
        let legacy = try await repo.loadTranslationVersions(lyricsVersionID: plainVersionID, targetLanguage: "zh-Hans", sourceContentHash: plainSource.sourceContentHash)
        var edit = LibraryTranslationRevisionDraft(track: plainTrack, lyricsSource: plainSource, source: try XCTUnwrap(legacy.first), preferredLanguage: "en-GB")
        XCTAssertEqual(edit.targetLanguage, "en-GB")
        edit.targetLanguage = "en"
        edit.lines[0] = "shore"
        let savedEdit = try await repo.saveManualEdit(edit.saveRequest())
        XCTAssertEqual(savedEdit.translationVersion?.record.targetLanguage, "en")
        XCTAssertEqual(savedEdit.translationVersion?.record.parentVersionID, legacy.first?.record.id)
        let localTrack = Track(title: "海岸", artist: "另一录音", album: "", duration: 0)
        let local = try await repo.importLyricFile(file, into: localTrack)
        XCTAssertNotEqual(imported.trackKey, local.trackKey)
        let newRecording = try await repo.loadBestStored(track: localTrack, identity: TrackIdentity(track: localTrack))
        XCTAssertEqual(newRecording?.document.lines.first?.originalText, "海")
    }

    func testClearingCacheRetainsLockedLyricsAndTheirTranslation() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("local.sqlite3"),
                                         alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let track = Track(title: "本地手稿", artist: "Fixture", album: "", duration: 100)
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist, duration: 100,
            lines: [.init(timestamp: 1, originalText: "保留这句")], isSynchronized: true, source: .manualCreate, confidence: 1)
        let saved = try await repo.save(track: track, identity: identity, document: document)
        let version = try XCTUnwrap(saved.versionID), hash = try XCTUnwrap(saved.sourceContentHash)
        try await repo.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: version)
        try await repo.markLocked(versionID: version, locked: true)
        let translation = try await repo.saveTranslation(lyricsVersionID: version, sourceContentHash: hash,
            originalLines: ["保留这句"], draft: .init(lines: [.init(index: 0, translation: "A saved line")],
                targetLanguage: "en", model: "", baseURLHost: "", promptHash: "", sourceContentHash: hash,
                sourceKind: .manualImport, isMachineGenerated: false, isManuallyEdited: true), forceNewVersion: false)
        let maintenance: any LyricsRepository = repo
        try await maintenance.clearLyricsCache()
        let restored = try await repo.loadBestStored(track: track, identity: identity)
        let translations = try await repo.loadTranslationVersions(lyricsVersionID: version, targetLanguage: "en", sourceContentHash: hash)
        XCTAssertEqual(restored?.versionID, version)
        XCTAssertEqual(restored?.document.lines.first?.originalText, "保留这句")
        XCTAssertEqual(translations.first?.record.id, translation.record.id)
    }

    func testConcurrentLibraryStartupOnlyBacksUpAnExistingSchemaOnce() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("lyrics.sqlite3")
        try Data().write(to: url)

        let first = SQLiteLyricsRepository(databaseURL: url)
        let second = SQLiteLyricsRepository(databaseURL: url)
        async let initializeFirst: Void = first.prepare()
        async let initializeSecond: Void = second.prepare()
        _ = try await (initializeFirst, initializeSecond)
        let fresh = try await first.statistics()
        XCTAssertTrue(fresh.backups.isEmpty)

        let track = Track(title: "Saved before upgrade", artist: "Fixture", album: "", duration: 120)
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist, duration: 120,
            lines: [.init(timestamp: 0, originalText: "saved line")], isSynchronized: true, source: .local, confidence: 1)
        let saved = try await first.save(track: track, identity: identity, document: document)
        try executeSQL("""
            ALTER TABLE lyric_lines DROP COLUMN performer_id;
            ALTER TABLE lyric_lines DROP COLUMN background_text;
            DELETE FROM schema_migrations WHERE version = 14;
            PRAGMA user_version = 13;
            """, at: url)

        let upgrade = SQLiteLyricsRepository(databaseURL: url)
        let otherWindow = SQLiteLyricsRepository(databaseURL: url)
        async let upgradeFirst: Void = upgrade.prepare()
        async let upgradeSecond: Void = otherWindow.prepare()
        _ = try await (upgradeFirst, upgradeSecond)

        let stats = try await upgrade.statistics()
        XCTAssertEqual(stats.backups.count, 1)
        let backup = try XCTUnwrap(stats.backups.first?.url)
        var snapshot: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backup.path, &snapshot, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(snapshot) }
        var schema: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(snapshot, "PRAGMA user_version;", -1, &schema, nil), SQLITE_OK)
        defer { sqlite3_finalize(schema) }
        XCTAssertEqual(sqlite3_step(schema), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(schema, 0), 13)
        let recovered = try await otherWindow.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(recovered?.versionID, saved.versionID)
        XCTAssertEqual(recovered?.document.lines.first?.originalText, "saved line")
    }

    func testManualBackupIncludesWALWritesWhileAnotherWindowReads() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("live.sqlite3")
        let repo = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "PRAGMA journal_mode=WAL; BEGIN; SELECT count(*) FROM tracks;", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(reader, "ROLLBACK;", nil, nil, nil) }
        let track = Track(title: "刚保存的歌词", artist: "Fixture", album: "", duration: 120)
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist, duration: 120,
            lines: [.init(timestamp: 0, originalText: "newly committed")], isSynchronized: true, source: .local, confidence: 1)
        let live = try await repo.save(track: track, identity: identity, document: document)
        let version = try XCTUnwrap(live.versionID)
        let maintenance: any LyricsRepository = repo
        let backup = try await maintenance.createBackup()
        try Data("keep".utf8).write(to: root.appendingPathComponent("live.backup-not-a-snapshot.sqlite3"))
        let stats = try await maintenance.statistics()
        XCTAssertEqual(stats.backups.map { $0.url.resolvingSymlinksInPath().path }, [backup.resolvingSymlinksInPath().path])
        XCTAssertGreaterThan(stats.backups.first?.bytes ?? 0, 0)
        XCTAssertGreaterThan(stats.journalBytes, 0)
        let copy = SQLiteLyricsRepository(databaseURL: backup, alignmentProvenanceDirectory: root.appendingPathComponent("copied-provenance"))
        try await copy.prepare()
        let recovered = try await copy.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(recovered?.versionID, version)
        XCTAssertEqual(recovered?.document.lines.first?.originalText, "newly committed")
    }

    func testRecallStartsAtTheKeptOccurrenceAndRevealsOneFollowingOriginal() throws {
        let lines = [
            LibraryPassagePage.Line(id: 0, original: "副歌"),
            .init(id: 1, original: "第一次"),
            .init(id: 2, original: "副歌"),
            .init(id: 3, original: " ", translation: "独立译文"),
            .init(id: 4, original: "第二次", translation: "译文", reading: "读音", background: "和声"),
            .init(id: 5, original: "结尾")
        ]
        var session = try XCTUnwrap(LyricRecallSession(lines: lines, anchor: 2))
        XCTAssertEqual(session.cue.id, 2)
        XCTAssertNil(session.revealedAnswer)
        session.reveal()
        XCTAssertEqual(session.revealedAnswer?.id, 4)
        XCTAssertEqual(session.revealedAnswer?.translation, "译文")
        session.advance()
        XCTAssertEqual(session.cue.id, 4)
        XCTAssertNil(session.revealedAnswer)
        session.reveal()
        XCTAssertFalse(session.canAdvance)
        XCTAssertEqual(session.revealedAnswer?.id, 5)
        XCTAssertNil(LyricRecallSession(lines: lines, anchor: 5))
        XCTAssertNil(LyricRecallSession(lines: lines, anchor: 98))
    }

    func testYouAndIdolNewDurationKeyRedirectsToSelectedLyrics() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("identity.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let old = Track(title: "YOU & IDOL", artist: "相対性理論", album: "TOWN AGE", duration: 201,
                        spotifyId: "4YlXzUxQGF2K8TTqaE7fuZ")
        let identity = TrackIdentity(track: old)
        let document = LyricsDocument(identity: identity, title: old.title, artist: old.artist, album: old.album,
            duration: 229, lines: [LyricLine(timestamp: 1, originalText: "已选歌词")],
            isSynchronized: true, source: .qqExperimental, confidence: 1)
        let saved = try await repo.save(track: old, identity: identity, document: document)
        let version = try XCTUnwrap(saved.versionID)
        try await repo.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: version)
        let playing = Track(title: old.title, artist: old.artist, album: old.album, duration: 229, spotifyId: old.spotifyId)
        let newIdentity = TrackIdentity(track: playing)
        let before = try await repo.redirectCount()
        let loaded = try await repo.loadBestStored(track: playing, identity: newIdentity)
        XCTAssertEqual(loaded?.versionID, version)
        XCTAssertEqual(loaded?.document.lines.first?.originalText, "已选歌词")
        let after = try await repo.redirectCount()
        XCTAssertEqual(after, before + 1)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(repo.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM track_identity_merge_audit WHERE action = 'redirect-only';", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        let canonical = try await repo.resolveStableKey(newIdentity.stableKey)
        XCTAssertEqual(canonical, identity.stableKey)
        let library = await PersonalLyricsLibraryService(repository: repo)
        let isPlayingEntry = try await library.isCurrentTrack(stableKey: identity.stableKey,
            playbackIdentity: newIdentity)
        XCTAssertTrue(isPlayingEntry, "Version adoption must recognize the playing song through its redirect")
        let reopened = SQLiteLyricsRepository(databaseURL: repo.databaseURL,
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        let again = try await reopened.loadBestStored(track: playing, identity: newIdentity)
        XCTAssertEqual(again?.versionID, version)
    }

    /// 君とコーヒー: Spotify first gave "Islet, Sando Aoi", later "Islet"
    /// alone. The player's and the library's repositories share one
    /// database; once one had written the redirect for the new key, the
    /// other tried again, hit the unique key and the song showed no lyrics.
    func testSecondRepositoryReadsARedirectTheFirstAlreadyWrote() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("two.sqlite3")
        let provenance = root.appendingPathComponent("provenance")
        let player = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        let library = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await player.prepare()
        try await library.prepare()
        let first = Track(title: "君とコーヒー (feat. Sando Aoi)", artist: "Islet, Sando Aoi", album: "CYANIDE",
                          duration: 241.5, spotifyId: "3nk3dJRFygCzyo6YZwIGul")
        let identity = TrackIdentity(track: first)
        let document = LyricsDocument(identity: identity, title: first.title, artist: first.artist, album: first.album,
            duration: 241.5, lines: [LyricLine(timestamp: 1, originalText: "已选歌词")],
            isSynchronized: true, source: .lrclib, confidence: 1)
        let saved = try await player.save(track: first, identity: identity, document: document)
        let version = try XCTUnwrap(saved.versionID)
        try await player.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: version)
        let later = Track(title: first.title, artist: "Islet", album: first.album, duration: 241.5, spotifyId: first.spotifyId)
        let laterIdentity = TrackIdentity(track: later)
        XCTAssertNotEqual(laterIdentity.stableKey, identity.stableKey)
        // The library writes the redirect first; the player's cache has not seen it.
        _ = try await library.loadBestStored(track: later, identity: laterIdentity)
        let revoked = try await player.isLyricsSelectionRevoked(identity: laterIdentity)
        XCTAssertFalse(revoked)
        let loaded = try await player.loadBestStored(track: later, identity: laterIdentity)
        XCTAssertEqual(loaded?.versionID, version)
        XCTAssertEqual(loaded?.document.lines.first?.originalText, "已选歌词")
    }

    func testReceivedTranslationSurvivesRecordingMetadataChange() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("translation.sqlite3"),
                                         alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let stored = Track(title: "些細な幸福だけで灯っていた。", artist: "kyiku", album: "やどり",
                           duration: 246, spotifyId: "4cTnxwbzLd90onQ9bKm9V6")
        let playing = Track(title: "Light source", artist: "kyiku", album: "Even if it was a small prayer",
                            duration: 246, spotifyId: stored.spotifyId)
        let document = LyricsDocument(identity: TrackIdentity(track: stored), title: stored.title,
            artist: stored.artist, album: stored.album, duration: 246,
            lines: [LyricLine(timestamp: 0, originalText: "原词保持不变")],
            isSynchronized: true, source: .lrclib, confidence: 1)
        let source = try await repo.save(track: stored, identity: document.identity, document: document)
        let version = try XCTUnwrap(source.versionID), hash = try XCTUnwrap(source.sourceContentHash)
        let configuration = AITranslationConfiguration(model: "fixture", engineID: TranslationEngineID.codexChatGPT.rawValue)
        let context = TranslationCompletionContext(identity: TrackIdentity(track: playing), lyricsVersionID: version,
            sourceContentHash: hash, originalLines: document.lines.map(\.originalText), targetLanguage: "zh-Hans",
            providerCacheIdentity: configuration.providerCacheIdentity, configurationPromptHash: configuration.promptHash,
            engineID: configuration.engineID, allowsAppleFallback: false)
        let key = try context.requestKey()
        var request = try await repo.beginTranslationRequest(key: key, explicitRetry: false)
        request.phase = .dispatching
        try await repo.updateTranslationRequest(request)
        request.phase = .received
        request.result = AITranslationDraft(lines: [AITranslationLine(index: 0, translation: "已收到的翻译")],
            targetLanguage: "zh-Hans", model: "fixture", baseURLHost: "fixture", promptHash: "fixture",
            sourceContentHash: hash, engineID: configuration.engineID)
        try await repo.updateTranslationRequest(request)
        let saved = try await repo.completeTranslationRequest(key: key, attemptID: request.attemptID, context: context)
        XCTAssertEqual(saved.record.lyricsVersionID, version)
        XCTAssertEqual(saved.lines.first?.translatedText, "已收到的翻译")
        let ledger = try await repo.loadTranslationRequest(key: key)
        XCTAssertEqual(ledger?.phase, .saved)
        XCTAssertEqual(ledger?.attemptID, request.attemptID)
    }

    @MainActor
    func testLibraryRevisionsPreserveLineageAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-revisions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("test.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await repo.prepare()
        let track = Track(title: "Revision fixture", artist: "Test", album: "Test", duration: 100, spotifyId: "revision-test")
        let identity = TrackIdentity(track: track)
        let original = LyricsDocument(identity: identity, title: track.title, artist: track.artist, album: track.album, duration: 100, lines: [
            LyricLine(timestamp: 1, originalText: "Original first"),
            LyricLine(timestamp: 4, originalText: "Original second")
        ], isSynchronized: true, source: .lrclib, confidence: 0.9, providerSourceID: "fixture")
        let saved = try await repo.save(track: track, identity: identity, document: original)
        let sourceVersionID = try XCTUnwrap(saved.versionID)
        let loadedSource = try await repo.loadEditableVersion(versionID: sourceVersionID, track: track, identity: identity)
        let source = try XCTUnwrap(loadedSource)

        let originalTranslation = try await repo.saveTranslation(
            lyricsVersionID: source.record.id,
            sourceContentHash: source.sourceContentHash,
            originalLines: source.document.lines.map(\.originalText),
            draft: AITranslationDraft(
                lines: [AITranslationLine(index: 0, translation: "原译一"), AITranslationLine(index: 1, translation: "原译二")],
                targetLanguage: "zh-Hans", model: "fixture", baseURLHost: "", promptHash: "fixture",
                sourceContentHash: source.sourceContentHash, sourceKind: .manualImport,
                isMachineGenerated: false, isManuallyEdited: true, engineID: "fixture"
            ),
            forceNewVersion: true
        )
        var translationDraft = LibraryTranslationRevisionDraft(track: track, lyricsSource: source, source: originalTranslation)
        translationDraft.lines[0] = "修订译一"
        let translationChildResult = try await repo.saveManualEdit(translationDraft.saveRequest())
        let translationChild = try XCTUnwrap(translationChildResult.translationVersion)
        XCTAssertEqual(translationChild.record.parentVersionID, originalTranslation.record.id)
        XCTAssertEqual(translationChild.record.lyricsVersionID, source.record.id)
        XCTAssertEqual(translationChild.record.sourceContentHash, source.sourceContentHash)
        XCTAssertTrue(translationChild.record.isManuallyEdited)
        XCTAssertFalse(translationChild.record.isLocked)
        XCTAssertTrue(translationChild.record.isDraft)
        let beforeAdoption = try await repo.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey)
        XCTAssertEqual(beforeAdoption?.entry.activeTranslationVersionID, originalTranslation.record.id)
        XCTAssertEqual(beforeAdoption?.translationVersions.first(where: { $0.isCurrent })?.id, originalTranslation.record.id)
        let draftPage = try await repo.readLibraryPassage(.init(trackKey: identity.stableKey, source: .translation(translationChild.record.id)))
        XCTAssertEqual(draftPage?.lines.first?.translation, "修订译一")
        try await repo.adoptTranslation(versionID: translationChild.record.id)
        let afterAdoption = try await repo.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey)
        XCTAssertEqual(afterAdoption?.entry.activeTranslationVersionID, translationChild.record.id)
        XCTAssertEqual(afterAdoption?.translationVersions.first(where: { $0.isCurrent })?.id, translationChild.record.id)
        try await repo.markTranslationLocked(versionID: originalTranslation.record.id, locked: true)
        let translationVersions = try await repo.loadTranslationVersions(
            lyricsVersionID: source.record.id, targetLanguage: "zh-Hans", sourceContentHash: source.sourceContentHash
        )
        let retainedTranslation = try XCTUnwrap(translationVersions.first { $0.record.id == originalTranslation.record.id })
        XCTAssertTrue(retainedTranslation.record.isLocked)
        XCTAssertEqual(retainedTranslation.lines, originalTranslation.lines)
        let reader = try await repo.readLibraryPassage(.init(trackKey: identity.stableKey, source: .translation(originalTranslation.record.id)))
        XCTAssertEqual(reader?.lines.map(\.original), ["Original first", "Original second"])
        XCTAssertEqual(reader?.lines.compactMap(\.translation), ["原译一", "原译二"], "Read the requested locked translation even after a revision")
        let quote = V3FavoriteLines.Entry(text: "Original first", translation: "原译一", title: track.title,
            artist: track.artist, trackKey: identity.stableKey, lyricsVersionID: source.record.id, lineIndex: 0,
            translationVersionID: originalTranslation.record.id)
        let favoritesURL = root.appendingPathComponent("favorite-lines.json")
        XCTAssertTrue(V3FavoriteLines(fileURL: favoritesURL).toggle(quote))
        let reopenedQuote = try XCTUnwrap(V3FavoriteLines(fileURL: favoritesURL).entries.first)
        let reopenedPage = try await repo.readLibraryPassage(reopenedQuote.passage)
        XCTAssertEqual(reopenedPage?.translationVersionID, originalTranslation.record.id)
        XCTAssertEqual(reopenedPage?.lines.compactMap(\.translation), ["原译一", "原译二"])
        let chapter = LyricBook.Chapter(quote: reopenedQuote)
        XCTAssertEqual(chapter.origin.source, .translation(originalTranslation.record.id))
        let editionPage = try XCTUnwrap(reopenedPage)
        XCTAssertEqual(LyricBook.Chapter(page: editionPage, source: .selected).origin.source,
                       .translation(originalTranslation.record.id))

        var missingEdition = reopenedQuote
        missingEdition.translationVersionID = UUID()
        let recovered = try await repo.readLibraryPassage(missingEdition.passage)
        XCTAssertEqual(recovered?.originalVersionID, source.record.id)
        XCTAssertEqual(recovered?.lines.first?.translation, "原译一")

        XCTAssertEqual(
            translationVersions.first { $0.record.id == translationChild.record.id }?.lines.map(\.translatedText),
            ["修订译一", "原译二"]
        )

        let sparseTranslation = try await repo.saveTranslation(
            lyricsVersionID: source.record.id,
            sourceContentHash: source.sourceContentHash,
            originalLines: source.document.lines.map(\.originalText),
            draft: AITranslationDraft(
                lines: [AITranslationLine(index: 0, translation: "已有译文"), AITranslationLine(index: 1, translation: "")],
                targetLanguage: "zh-Hans", model: "fixture", baseURLHost: "", promptHash: "embedded",
                sourceContentHash: source.sourceContentHash, sourceKind: .providerEmbedded,
                isMachineGenerated: false, isManuallyEdited: false, engineID: "provider-embedded"
            ),
            forceNewVersion: true
        )
        var sparseDraft = LibraryTranslationRevisionDraft(track: track, lyricsSource: source, source: sparseTranslation)
        XCTAssertEqual(sparseDraft.lines, ["已有译文", ""], "An embedded blank line remains editable as an empty row")
        sparseDraft.lines[0] = "改过的已有译文"
        let sparseChildResult = try await repo.saveManualEdit(sparseDraft.saveRequest())
        let sparseChild = try XCTUnwrap(sparseChildResult.translationVersion)
        XCTAssertEqual(sparseChild.record.parentVersionID, sparseTranslation.record.id)
        XCTAssertEqual(sparseChild.record.lyricsVersionID, source.record.id)
        XCTAssertEqual(sparseChild.record.sourceContentHash, source.sourceContentHash)
        XCTAssertEqual(sparseChild.lines.map(\.translatedText), ["改过的已有译文", ""])
        var assembled = LibraryTranslationRevisionDraft(track: track, lyricsSource: source, source: originalTranslation)
        try assembled.takeLines([0], from: sparseChild)
        let picked = try XCTUnwrap(try assembled.saveRequest().translation)
        XCTAssertEqual(picked.lines, ["改过的已有译文", "原译二"])
        XCTAssertEqual(picked.parentVersionID, originalTranslation.record.id)
        XCTAssertEqual(originalTranslation.lines.first?.translatedText, "原译一")
        let sparseVersions = try await repo.loadTranslationVersions(
            lyricsVersionID: source.record.id, targetLanguage: "zh-Hans", sourceContentHash: source.sourceContentHash
        )
        XCTAssertEqual(
            sparseVersions.first { $0.record.id == sparseChild.record.id }?.lines.map(\.translatedText),
            ["改过的已有译文", ""],
            "A sparse manual child remains visible after reloading the library"
        )
        let browser = PersonalLyricsLibraryService(repository: repo, defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let compared = try await browser.playingComparison(identity: identity, lyricsID: source.record.id,
            selected: sparseTranslation.record.id, versions: [sparseTranslation, sparseChild])
        let live = try XCTUnwrap(compared)
        XCTAssertEqual(live.base.id, sparseTranslation.record.id)
        XCTAssertEqual(live.references.map(\.id), [sparseChild.record.id])
        let scope = try XCTUnwrap(live.playing)
        XCTAssertEqual(scope.adoptable, Set([sparseTranslation.record.id, sparseChild.record.id]))
        XCTAssertTrue(scope.matches(identity: identity, lyricsID: source.record.id, preview: false))
        XCTAssertFalse(scope.matches(identity: identity, lyricsID: source.record.id, preview: true))
        XCTAssertFalse(scope.matches(identity: identity, lyricsID: UUID(), preview: false))
        let pair = try await browser.compare(trackKey: live.entry.trackStableKey, base: live.references[0], with: live.base)
        XCTAssertTrue(pair.canPickTranslationLines)
        XCTAssertEqual(pair.rows.filter { $0.change != .same }.count, 1)
        let sparseParentAfter = sparseVersions.first { $0.record.id == sparseTranslation.record.id }
        XCTAssertEqual(sparseParentAfter?.lines, sparseTranslation.lines, "Editing the child must retain the sparse parent")

        var emptyManualDraft = LibraryTranslationRevisionDraft(track: track, lyricsSource: source, source: sparseTranslation)
        emptyManualDraft.lines = ["", ""]
        do {
            _ = try await repo.saveManualEdit(emptyManualDraft.saveRequest())
            XCTFail("All-empty manual translation revision accepted")
        } catch LyricsEditingRepositoryError.invalidTranslation(_) {
        } catch {
            XCTFail("Unexpected error for all-empty manual translation: \(error)")
        }

        do {
            _ = try await repo.saveTranslation(
                lyricsVersionID: source.record.id,
                sourceContentHash: source.sourceContentHash,
                originalLines: source.document.lines.map(\.originalText),
                draft: AITranslationDraft(
                    lines: [AITranslationLine(index: 0, translation: "AI译文"), AITranslationLine(index: 1, translation: "")],
                    targetLanguage: "zh-Hans", model: "fixture", baseURLHost: "", promptHash: "ai-partial",
                    sourceContentHash: source.sourceContentHash
                ),
                forceNewVersion: true
            )
            XCTFail("Sparse AI translation accepted")
        } catch TranslationRepositoryError.invalidLines(_) {
        } catch {
            XCTFail("Unexpected error for sparse AI translation: \(error)")
        }

        let originalReadingLines = source.document.lines.enumerated().map {
            ReadingLineResult(lineIndex: $0.offset, originalText: $0.element.originalText,
                              readingText: "reading-\($0.offset)", language: .latin, tokens: [], confidence: 0.8)
        }
        let readingNow = Date()
        let originalReadingRecord = ReadingVersionRecord(
            id: UUID(), lyricsVersionID: source.record.id, sourceContentHash: source.sourceContentHash,
            engineID: "fixture-reading", representationID: ReadingRepresentationID.romaji.rawValue,
            sourceKind: .generated, language: .latin, createdAt: readingNow, updatedAt: readingNow,
            isMachineGenerated: true, isManuallyEdited: false, isCurrent: true, isLocked: false,
            isArchived: false, parentVersionID: nil, confidence: 0.8, warningMetadata: [], contextHash: "fixture"
        )
        let originalReading = try await repo.saveReadingVersion(
            ReadingVersionSaveRequest(record: originalReadingRecord, lines: originalReadingLines)
        )
        try await repo.markReadingLocked(versionID: originalReading.record.id, locked: true)
        var readingDraft = LibraryReadingRevisionDraft(track: track, lyricsSource: source, source: originalReading)
        readingDraft.lines[0] = "manual-reading"
        let readingChild = try await repo.saveReadingVersion(readingDraft.saveRequest())
        XCTAssertEqual(readingChild.record.parentVersionID, originalReading.record.id)
        XCTAssertEqual(readingChild.record.lyricsVersionID, source.record.id)
        XCTAssertEqual(readingChild.record.sourceContentHash, source.sourceContentHash)
        XCTAssertTrue(readingChild.record.isManuallyEdited)
        XCTAssertFalse(readingChild.record.isLocked)
        let readingVersions = try await repo.loadReadingVersions(
            lyricsVersionID: source.record.id, representationID: ReadingRepresentationID.romaji.rawValue,
            sourceContentHash: source.sourceContentHash
        )
        let retainedReading = try XCTUnwrap(readingVersions.first { $0.record.id == originalReading.record.id })
        XCTAssertTrue(retainedReading.record.isLocked)
        XCTAssertEqual(retainedReading.lines, originalReading.lines)
        XCTAssertEqual(
            readingVersions.first { $0.record.id == readingChild.record.id }?.lines.first?.readingText,
            "manual-reading"
        )
        let sourcePage = try await repo.readLibraryPassage(.init(trackKey: identity.stableKey, source: .original(source.record.id)))
        XCTAssertEqual(sourcePage?.lines.first?.reading, "reading-0", "The default reading follows the library's locked version")

        let timingTrack = Track(title: "Timing fixture", artist: "Test", album: "Test", duration: 100, spotifyId: "timing-revision-test")
        let timingIdentity = TrackIdentity(track: timingTrack)
        let timingDocument = LyricsDocument(
            identity: timingIdentity, title: timingTrack.title, artist: timingTrack.artist, album: timingTrack.album, duration: 100,
            lines: [LyricLine(timestamp: 1, originalText: "Timed words", endTime: 3, timedSpans: [
                TimedTextSpan(id: 0, text: "Timed", trailingWhitespace: " ", startTime: 1.1, endTime: 1.7, utf16Start: 0, utf16Length: 5, granularity: .word),
                TimedTextSpan(id: 1, text: "words", startTime: 1.8, endTime: 2.4, utf16Start: 6, utf16Length: 5, granularity: .word)
            ], backgroundText: "echo")],
            isSynchronized: true, source: .lrclib, confidence: 0.9, providerSourceID: "timing-fixture"
        )
        let savedTimingLyrics = try await repo.save(track: timingTrack, identity: timingIdentity, document: timingDocument)
        let timingVersionID = try XCTUnwrap(savedTimingLyrics.versionID)
        let loadedTimingSource = try await repo.loadEditableVersion(versionID: timingVersionID, track: timingTrack, identity: timingIdentity)
        let timingSource = try XCTUnwrap(loadedTimingSource)
        let timingVersionIDFromDocument = try XCTUnwrap(timingSource.document.timingVersionID)
        let loadedOriginalTiming = try await repo.loadPersonalLibraryTimingVersion(id: timingVersionIDFromDocument)
        let originalTiming = try XCTUnwrap(loadedOriginalTiming)
        var timingDraft = try XCTUnwrap(LibraryTimingRevisionDraft(track: timingTrack, lyricsSource: timingSource, source: originalTiming))
        timingDraft.lines[0].spans[0].startTime += 0.1
        let timingChild = try await repo.savePersonalLibraryTimingRevision(timingDraft.saveRequest())
        XCTAssertNotEqual(timingChild.id, originalTiming.id)
        XCTAssertEqual(timingChild.lyricsVersionID, timingSource.record.id)
        XCTAssertEqual(timingChild.sourceContentHash, timingSource.sourceContentHash)
        let retainedTiming = try await repo.loadPersonalLibraryTimingVersion(id: originalTiming.id)
        XCTAssertEqual(retainedTiming, originalTiming)
        let editedTimingSource = try await repo.loadEditableVersion(versionID: timingSource.record.id, track: timingTrack, identity: timingIdentity)
        XCTAssertEqual(editedTimingSource?.document.timingVersionID, timingChild.id)
        XCTAssertEqual(editedTimingSource?.document.lines.first?.backgroundText, "echo", "Editing a word time keeps the backing vocal")
        let roundTripped = timingSource.document.lines.first.map { LyricsEditorLineDraft(line: $0).asLyricLine() }
        XCTAssertEqual(roundTripped?.backgroundText, "echo", "Opening a saved line in the editor keeps the backing vocal")
        let timingPage = try await repo.readLibraryPassage(.init(trackKey: timingIdentity.stableKey, source: .original(timingVersionID)))
        XCTAssertEqual(timingPage?.lines.first?.background, "echo")
        XCTAssertEqual(timingPage?.lines.first?.matches("ECHO"), true)
        let editedStartTime = editedTimingSource?.document.lines[0].timedSpans?.first?.startTime ?? 0
        XCTAssertEqual(editedStartTime, 1.2, accuracy: 0.0001)
        _ = try await repo.adoptPersonalLibraryTimingVersion(id: originalTiming.id, trackStableKey: timingIdentity.stableKey)
        let selectedTimingSource = try await repo.loadEditableVersion(versionID: timingSource.record.id, track: timingTrack, identity: timingIdentity)
        XCTAssertEqual(selectedTimingSource?.document.timingVersionID, originalTiming.id)
        let selectedTimingDetail = try await repo.loadPersonalLibraryTrackDetail(stableKey: timingIdentity.stableKey)
        XCTAssertEqual(selectedTimingDetail?.timingVersions.count, 2)
        XCTAssertEqual(selectedTimingDetail?.timingVersions.first(where: \.isCurrent)?.id, originalTiming.id)


        let request = LyricsEditSaveRequest(
            track: track, identity: identity, sourceVersionID: source.record.id,
            sourceContentHash: LyricsSourceContentHasher.hash(isSynchronized: source.record.isSynced, lines: source.lines),
            document: original, createLyricsVersion: true, lockLyricsVersion: true
        )
        let higherResult = try await repo.saveManualEdit(request)
        let higher = try XCTUnwrap(higherResult.lyricsVersion)
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: source.record.id)
        let selected = try await repo.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(selected?.versionID, source.record.id, "Explicit original selection must beat locked/high-confidence newer versions")
        XCTAssertNotEqual(higher.record.id, source.record.id)

        var revisionDraft = LibraryLyricsRevisionDraft(track: track, source: higher)
        do {
            _ = try revisionDraft.saveRequest()
            XCTFail("No-op revision accepted")
        } catch LyricsEditingRepositoryError.noChanges {
        } catch {
            XCTFail("Unexpected error for no-op revision: \(error)")
        }
        revisionDraft.lines[0].originalText = "Revised first"
        let library = PersonalLyricsLibraryService(repository: repo)
        library.saveRevision(revisionDraft)
        for _ in 0..<200 {
            if !library.revisionBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(library.revisionBusy)
        XCTAssertNil(library.revisionError)
        let versions = try await repo.loadEditableVersions(track: track, identity: identity)
        let revision = try XCTUnwrap(versions.first { $0.record.parentVersionID == higher.record.id })
        XCTAssertNotEqual(revision.record.id, source.record.id)
        XCTAssertNotEqual(revision.record.id, higher.record.id)
        XCTAssertEqual(revision.record.parentVersionID, higher.record.id)
        XCTAssertEqual(revision.document.lines.map(\.originalText), ["Revised first", "Original second"])
        XCTAssertEqual(revision.document.lines.map(\.timestamp), [1, 4])

        let originalAfter = try await repo.loadEditableVersion(versionID: source.record.id, track: track, identity: identity)
        let lockedAfter = try await repo.loadEditableVersion(versionID: higher.record.id, track: track, identity: identity)
        XCTAssertEqual(originalAfter?.record, source.record)
        XCTAssertEqual(originalAfter?.lines, source.lines)
        XCTAssertEqual(lockedAfter?.record, higher.record)
        XCTAssertEqual(lockedAfter?.lines, higher.lines)
        let stillSelected = try await repo.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(stillSelected?.versionID, revision.record.id, "Saving a library revision must adopt the new version")
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: revision.record.id)
        let newSelected = try await repo.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(newSelected?.versionID, revision.record.id)
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: source.record.id)

        let reopened = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("test.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await reopened.prepare()
        let restored = try await reopened.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(restored?.versionID, source.record.id)
        let detail = try await reopened.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey)
        XCTAssertEqual(detail?.lyricsVersions.count, 3)
        XCTAssertEqual(detail?.lyricsVersions.first(where: \.isCurrent)?.id, source.record.id)

        do {
            try await repo.setPersonalLibraryActiveLyrics(trackStableKey: "wrong-track", lyricsVersionID: source.record.id)
            XCTFail("Cross-track selection accepted")
        } catch LyricsEditingRepositoryError.identityMismatch {
        } catch {
            XCTFail("Unexpected error for cross-track selection: \(error)")
        }
        let retained = try await repo.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(retained?.versionID, source.record.id)

        var normal = LibraryLyricsRevisionDraft(track: track, source: revision)
        normal.lines[0].originalText = "Normal editor revision"
        let prepared = try normal.saveRequest()
        let normalRequest = LyricsEditSaveRequest(
            track: track, identity: identity, sourceVersionID: revision.record.id,
            sourceContentHash: prepared.sourceContentHash, document: prepared.document, createLyricsVersion: true
        )
        let normalSavedResult = try await repo.saveManualEdit(normalRequest)
        let normalSaved = try XCTUnwrap(normalSavedResult.lyricsVersion)
        let normalSelected = try await repo.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(normalSelected?.versionID, normalSaved.record.id)

        var retimed = LibraryLyricsRevisionDraft(track: track, source: revision)
        retimed.lines[0].startTime = nil
        let partialRequest = try retimed.saveRequest()
        XCTAssertNil(partialRequest.document.lines[0].endTime)
        _ = try await repo.saveManualEdit(partialRequest)

        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: source.record.id)
        let package = try await repo.exportPersonalLibraryPackage(stableKey: identity.stableKey)
        XCTAssertEqual(package.preferredLyricsVersionID, source.record.id)
        let decoded = try JSONDecoder().decode(PersonalLyricsLibraryPackage.self, from: JSONEncoder().encode(package))
        let imported = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("import.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("import-provenance")
        )
        try await imported.importPersonalLibraryPackage(decoded)
        let importedSelected = try await imported.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(importedSelected?.versionID, source.record.id)
        let importedRevision = try await imported.loadEditableVersion(versionID: revision.record.id, track: track, identity: identity)
        XCTAssertEqual(importedRevision?.record.parentVersionID, higher.record.id)
        try await imported.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: revision.record.id)
        try await imported.importPersonalLibraryPackage(decoded)
        let localWins = try await imported.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(localWins?.versionID, revision.record.id)

        try executeSQL(
            "INSERT INTO track_identity_redirects VALUES ('historical-fixture', '\(identity.stableKey.replacingOccurrences(of: "'", with: "''"))', 'fixture', 'fixture', 'fixture', 1);",
            at: root.appendingPathComponent("import.sqlite3")
        )
        var oldKeyJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        var oldTrack = try XCTUnwrap(oldKeyJSON["track"] as? [String: Any])
        oldTrack["stableKey"] = "historical-fixture"
        oldKeyJSON["track"] = oldTrack
        let oldKeyPackage = try JSONDecoder().decode(
            PersonalLyricsLibraryPackage.self,
            from: JSONSerialization.data(withJSONObject: oldKeyJSON)
        )
        let redirected = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("import.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("redirect-provenance")
        )
        try await redirected.importPersonalLibraryPackage(oldKeyPackage)
        let redirectSelected = try await redirected.loadBestStored(track: track, identity: identity)
        XCTAssertEqual(redirectSelected?.versionID, revision.record.id, "Historical-key import must preserve canonical local choice")
    }

    private func executeSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LibraryRevisionsContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open temporary SQLite database"])
        }
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite statement failed"
            sqlite3_free(error)
            throw NSError(domain: "LibraryRevisionsContractTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
