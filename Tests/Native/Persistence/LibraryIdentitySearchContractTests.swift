import AppKit
import Foundation
import SQLite3
import XCTest
@testable import SpotifyLyrics

final class LibraryIdentitySearchContractTests: XCTestCase {
    @MainActor
    func testLibrarySearchOnlyExposesResultsForTheRequestedQuery() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("library.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let library = PersonalLyricsLibraryService(repository: repository)
        let first = Track(title: "窗边的回信", artist: "南窗", album: "", duration: 170)
        let second = Track(title: "海边的回信", artist: "南窗", album: "", duration: 190)
        for track in [first, second] {
            try await (repository as any LyricsRepository).saveTrackMetadata(.bootstrap(from: track))
        }

        func waitForLoad() async throws {
            for _ in 0..<100 {
                if !library.isLoading { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The lyric library query did not finish")
        }

        library.search("窗边", immediately: true)
        try await waitForLoad()
        XCTAssertEqual(library.entries(for: " 窗边 ").map(\.title), [first.title])
        XCTAssertTrue(library.entries(for: "海边").isEmpty)

        library.search("没有这首歌")
        library.search("海边")
        XCTAssertTrue(library.entries(for: "海边").isEmpty, "The next query must not offer the previous song for batch completion")
        try await waitForLoad()
        let results = library.entries(for: "海边")
        XCTAssertEqual(results.map(\.title), [second.title])
        XCTAssertTrue(library.entries(for: "窗边").isEmpty)
        let entry = try XCTUnwrap(results.first)
        XCTAssertTrue(PersonalLibraryFilter.missing.includes(entry, currentTrackKey: nil))
        XCTAssertFalse(PersonalLibraryFilter.locked.includes(entry, currentTrackKey: nil))
        XCTAssertNil(library.matchingPassage(for: entry.id, in: "海边"))
    }

    @MainActor
    func testLibrarySearchOpensMatchedHistoricalTranslation() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("search.sqlite3"))
        let library = PersonalLyricsLibraryService(repository: repository)
        let track = Track(title: "返程", artist: "南窗", album: "", duration: 60)
        let originalFile = try LocalLyricsFile(data: Data("""
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="ja"><body><div>
        <p begin="1s" end="2s">ただいま</p>
        <p begin="8s" end="9s">ただいま<span ttm:role="x-translation" xml:lang="zh-Hans">檐下还有雨声</span></p>
        </div></body></tt>
        """.utf8), kind: .ttml, preferredLanguage: "zh-Hans")
        let original = try await repository.importLyricFile(originalFile, into: track)
        let libraryDetail = try await repository.loadPersonalLibraryTrackDetail(stableKey: original.trackKey)
        let translated = try XCTUnwrap(libraryDetail?.translationVersions.first)
        let currentFile = try LocalLyricsFile(data: Data("回来了".utf8), kind: .txt, preferredLanguage: "zh-Hans")
        let current = try await repository.importLyricFile(currentFile, into: track)
        let currentID = try XCTUnwrap(current.source.versionID)
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey: original.trackKey, lyricsVersionID: currentID)

        library.search("雨声", immediately: true)
        for _ in 0..<100 {
            if !library.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.entries(for: "雨声").map(\.id), [original.trackKey])
        let match = try XCTUnwrap(library.matchingPassage(for: original.trackKey, in: "雨声"))
        XCTAssertEqual(match.target.source, .translation(translated.id))
        XCTAssertEqual(match.excerpt, "檐下还有雨声")
        let opened = try await library.readPassage(match.target, recordOpening: false)
        XCTAssertEqual(opened?.lines.filter { $0.matches(match.target.find) }.map(\.id), [1])
        XCTAssertEqual(opened?.originalVersionID, original.source.versionID)
        let adopted = try await repository.loadPersonalLibraryTrackDetail(stableKey: original.trackKey)
        XCTAssertEqual(adopted?.entry.activeLyricsVersionID, currentID)
        XCTAssertNil(library.matchingPassage(for: original.trackKey, in: "回来了"))
    }

    func testMusicRecordingsWithIdenticalTitlesAndLengthsKeepIndependentLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aster-music-identities-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("library.sqlite3")
        let repo = SQLiteLyricsRepository(databaseURL: db)
        try await repo.prepare()
        let legacy = Track(title: "窗边", artist: "南窗", album: "卷一", duration: 180)
        let legacyKey = TrackIdentity(track: legacy).stableKey
        let legacyPage = try await repo.save(track: legacy, identity: TrackIdentity(track: legacy),
            document: LyricsDocument(identity: TrackIdentity(track: legacy), lines: [
                LyricLine(timestamp: 0, originalText: "第一首的原稿")
            ], source: .manualImport, confidence: 1))
        let legacyID = try XCTUnwrap(legacyPage.versionID)
        try executeSQL("UPDATE tracks SET spotify_id='applemusic:ABCDEF0123456789';", at: db)
        try await repo.adoptLyricsVersion(trackStableKey: legacyKey, lyricsVersionID: legacyID)

        let refreshed = Track(title: "窗边（重整资料）", artist: "南窗", album: "卷一", duration: 181, spotifyId: "applemusic:abcdef0123456789")
        let sameMetadata = Track(title: legacy.title, artist: legacy.artist, album: legacy.album, duration: legacy.duration,
                                 spotifyId: "applemusic:ABCDEF012345678A")
        let secondIdentity = TrackIdentity(track: sameMetadata)
        XCTAssertNotEqual(secondIdentity.stableKey, legacyKey)
        let firstRead = try await repo.loadBestStored(track: refreshed, identity: TrackIdentity(track: refreshed))
        let secondBeforeSave = try await repo.loadBestStored(track: sameMetadata, identity: secondIdentity)
        XCTAssertEqual(firstRead?.versionID, legacyID)
        XCTAssertNil(secondBeforeSave)

        let second = try await repo.save(track: sameMetadata, identity: secondIdentity,
            document: LyricsDocument(identity: secondIdentity, lines: [LyricLine(timestamp: 0, originalText: "另一份录音")],
                                     source: .manualImport, confidence: 1))
        let reopened = SQLiteLyricsRepository(databaseURL: db)
        try await reopened.prepare()
        let firstAgain = try await reopened.loadBestStored(track: refreshed, identity: TrackIdentity(track: refreshed))
        let secondAgain = try await reopened.loadBestStored(track: sameMetadata, identity: secondIdentity)
        XCTAssertEqual(firstAgain?.versionID, legacyID)
        XCTAssertEqual(secondAgain?.versionID, second.versionID)
        XCTAssertEqual(secondAgain?.document.lines.first?.originalText, "另一份录音")
        let retainedKey = try await reopened.resolveStableKey(TrackIdentity(track: refreshed).stableKey)
        XCTAssertEqual(retainedKey, legacyKey)
        let renamedSecond = Track(title: "窗边（改名）", artist: "南窗", album: "卷一", duration: 183, spotifyId: sameMetadata.spotifyId)
        let renamedRead = try await reopened.loadBestStored(track: renamedSecond, identity: TrackIdentity(track: renamedSecond))
        XCTAssertEqual(renamedRead?.versionID, second.versionID)
    }

    @MainActor
    func testContinueReadingKeepsTheOpenedEditionAfterAdoptingAnother() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("reading.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let suite = "aster-reading-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = PersonalLyricsLibraryService(repository: repository, defaults: defaults)
        let track = Track(title: "窗边", artist: "南窗", album: "卷一", duration: 180)
        let identity = TrackIdentity(track: track)
        let first = LyricsDocument(identity: identity, lines: [
            LyricLine(timestamp: 1, originalText: "回声"),
            LyricLine(timestamp: 4, originalText: "转角"),
            LyricLine(timestamp: 8, originalText: "回声"),
        ], source: .manualImport, confidence: 1)
        let original = try await repository.save(track: track, identity: identity, document: first)
        let originalID = try XCTUnwrap(original.versionID)
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: originalID)

        let target = LibraryPassageTarget(trackKey: identity.stableKey)
        let loaded = try await library.readPassage(target)
        let opened = try XCTUnwrap(loaded)
        XCTAssertEqual(opened.originalVersionID, originalID)
        let secondChorus = LibraryPassageTarget.ReadingPosition(find: "回声", lineIndex: 2, topLineIndex: 1)
        library.rememberReading(opened, openedFrom: target, position: secondChorus)
        let replacement = try await repository.save(track: track, identity: identity,
            document: LyricsDocument(identity: identity, lines: [LyricLine(timestamp: 2, originalText: "另一份原稿")],
                                     source: .manualImport, confidence: 1))
        let replacementID = try XCTUnwrap(replacement.versionID)
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: replacementID)

        let saved = try XCTUnwrap(defaults.data(forKey: LastOpenedLyricsRecord.defaultsKey))
        let record = try JSONDecoder().decode(LastOpenedLyricsRecord.self, from: saved)
        let resume = try XCTUnwrap(record.passage)
        XCTAssertEqual(resume.source, .original(originalID))
        XCTAssertEqual(resume.readingPosition, secondChorus)
        let resumed = try await library.readPassage(resume)
        XCTAssertEqual(resumed?.originalVersionID, originalID)
        let selected = try await repository.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey)
        XCTAssertEqual(selected?.entry.activeLyricsVersionID, replacementID)

        let detail = try XCTUnwrap(selected)
        let archive = opened.archiveTarget(from: target, position: secondChorus)
        library.presentComparison(.original(originalID), detail: detail, reading: archive)
        let request = try XCTUnwrap(library.versionSearch?.initialComparison)
        XCTAssertEqual(request.base.id, originalID)
        XCTAssertEqual(request.firstReference, replacementID)
        let line = try XCTUnwrap(request.readingLine(for: originalID))
        XCTAssertEqual(line, 2)
        let alternatePage = try await library.readPassage(.init(trackKey: identity.stableKey, source: .original(replacementID)),
                                                          recordOpening: false)
        let alternate = try XCTUnwrap(alternatePage)
        for (column, editions) in [[opened.lines, alternate.lines], [alternate.lines, opened.lines]].enumerated() {
            let rows = LibraryOriginalComparison(editions: editions, alignment: .text).rows
            let focus = rows.first { $0.lines[column].contains { $0.id == line } }?.lines[column].first { $0.id == line }
            XCTAssertEqual(focus?.startTime, opened.lines[line].startTime)
        }

        let bookHits = try await library.bookSources(matching: "回声")
        let hit = try XCTUnwrap(bookHits.first)
        XCTAssertEqual(hit.source, .original(originalID))
        let matchPage = try await library.readPassage(hit.readingTarget(for: "回声"), recordOpening: false)
        let edition = try XCTUnwrap(matchPage)
        let voice = PassageVoicePresentation(lines: edition.lines)
        let hits = voice.visibleLines(in: edition.lines).filter { $0.matches("回声") }
        XCTAssertEqual(hits.map(\.id), [0, 2])
        let excerpt = LyricBook.Chapter(page: edition, source: .original(originalID), excerpt: hits[1])
        let book = try LyricBook(data: LyricBook(chapters: [excerpt]).encoded())
        XCTAssertEqual(book.chapters.first?.lines.map(\.original), ["回声"])
        let collected = try XCTUnwrap(book.chapters.first?.origin)
        XCTAssertEqual(collected.lineIndex, 2)
        XCTAssertEqual(collected.source, .original(originalID))
        let readBack = try await library.readPassage(collected, recordOpening: false)
        XCTAssertEqual(readBack?.originalOccurrence(of: collected.find, preferred: collected.lineIndex), 2)

        let bookmark = LibraryPassageTarget(trackKey: identity.stableKey, source: .original(originalID),
            find: "回声", lineIndex: 0, savedQuote: .init(originalVersionID: originalID, translation: "收藏的译文"))
        let quoted = try await library.readPassage(bookmark)
        library.rememberReading(try XCTUnwrap(quoted), openedFrom: bookmark, position: secondChorus)
        let bookmarkData = try XCTUnwrap(defaults.data(forKey: LastOpenedLyricsRecord.defaultsKey))
        let bookmarkResume = try XCTUnwrap(JSONDecoder().decode(LastOpenedLyricsRecord.self, from: bookmarkData).passage)
        let bookmarkPage = try await library.readPassage(bookmarkResume)
        XCTAssertEqual(bookmarkResume.readingPosition, secondChorus)
        XCTAssertEqual(bookmarkPage?.lines.first?.translation, "收藏的译文")
        XCTAssertNil(bookmarkPage?.lines.last?.translation)

        var oldBookmark = bookmark
        oldBookmark.source = .translation(UUID())
        var history = SettingsHistory()
        history.open(.init(reading: oldBookmark))
        let resolvedBookmark = try await library.readPassage(oldBookmark, recordOpening: false)
        let archiveTarget = try XCTUnwrap(resolvedBookmark).archiveTarget(from: oldBookmark, position: secondChorus)
        history.openArchive(fromReading: archiveTarget)
        XCTAssertEqual(history.current.archivePassage?.source, .original(originalID))
        XCTAssertEqual(history.current.archivePassage?.readingPosition, secondChorus)
        history.back()
        XCTAssertEqual(history.current.passage, archiveTarget)
        let returnedPage = try await library.readPassage(archiveTarget, recordOpening: false)
        XCTAssertEqual(returnedPage?.lines.first?.translation, "收藏的译文")
        XCTAssertNil(returnedPage?.lines.last?.translation)

        let other = try await library.readPassage(.init(trackKey: identity.stableKey, source: .original(replacementID)))
        XCTAssertEqual(other?.originalVersionID, replacementID)
        let recentData = try XCTUnwrap(defaults.data(forKey: RecentLyricsReadings.defaultsKey))
        let recent = RecentLyricsReadings.records(from: recentData, legacy: nil)
        XCTAssertEqual(recent.map { $0.passage?.source }, [.original(replacementID), .original(originalID)])
        XCTAssertEqual(recent.last?.passage?.readingPosition, secondChorus)
        let otherArchive = LastOpenedLyricsRecord(trackKey: "separate-recording", title: "另一首歌", artist: "")
        let suggestions = WorkspaceLookupRow.suggestions(readings: recent, lastOpened: otherArchive, favorites: [])
        XCTAssertEqual(suggestions.prefix(2).map(\.location.passage?.source), recent.map { $0.passage?.source })
        XCTAssertEqual(suggestions[2].location.trackKey, otherArchive.trackKey)

        let oldReaderData = Data(#"{"find":"回声","lineIndex":2}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LibraryPassageTarget.ReadingPosition.self, from: oldReaderData).topLineIndex)
    }

    @MainActor
    func testQuickFindUsesTheOfferedSelectionAndOpensTheExactSavedLine() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("  记得这句话  ", forType: .string)
        let service = QuickFindLauncher()
        var opened = 0
        service.connect { opened += 1 }
        var issue: NSString?
        service.findLyrics(board, userData: nil, error: &issue)
        XCTAssertNil(issue)
        XCTAssertEqual(service.request.query, "记得这句话")
        XCTAssertEqual(opened, 1)
        let version = UUID()
        let favorite = V3FavoriteLines.Entry(text: "记得这句话", title: "一首歌", artist: "歌手",
            trackKey: "recording", lyricsVersionID: version, lineIndex: 9)
        let rows = WorkspaceLookupRow.matches(service.request.query, songs: [], favorites: [favorite])
        XCTAssertEqual(rows.first?.location.passage?.source, .original(version))
        XCTAssertEqual(rows.first?.location.passage?.lineIndex, 9)
        let row = try XCTUnwrap(rows.first)
        var history = SettingsHistory()
        history.search(service.request.query)
        history.rememberSearchResult(row.id)
        history.open(row.location)
        history.back()
        XCTAssertEqual(history.current.query, service.request.query)
        XCTAssertEqual(history.current.resultID, row.id)
        XCTAssertTrue(WorkspaceLookupRow.matches("刘海", songs: [], favorites: []).contains {
            $0.location.page == .appearance && $0.location.appearanceSurface == .island
        })
    }

    func testVersionComparisonKeepsTheSecondChorusAfterAnInsertionAndFindsTimingChanges() {
        func line(_ id: Int, _ text: String, _ time: Double) -> LibraryPassagePage.Line {
            .init(id: id, original: text, startTime: time)
        }
        let left = [line(0, "门", 1), line(1, "回声", 4), line(2, "雪", 7), line(3, "回声", 12)]
        let right = [line(0, "门", 1), line(1, "回声", 4), line(2, "灯", 5), line(3, "雪", 7), line(4, "回声", 13)]
        let rows = LibraryVersionComparison.align(left, right, translations: false, sameOriginal: false)
        XCTAssertEqual(rows.map(\.change), [.same, .same, .onlyReference, .same, .timing])
        XCTAssertEqual(rows.last?.base?.id, 3)
        XCTAssertEqual(rows.last?.reference?.id, 4)

        let first = [LibraryPassagePage.Line(id: 0, original: "回声", translation: "先"),
                     .init(id: 1, original: "回声", translation: "后")]
        let second = [LibraryPassagePage.Line(id: 0, original: "回声", translation: "先"),
                      .init(id: 1, original: "回声", translation: "末")]
        let compared = LibraryVersionComparison.align(first, second, translations: true, sameOriginal: true)
        XCTAssertEqual(compared.map(\.change), [.same, .text])
        XCTAssertEqual(compared.last?.reference?.translation, "末")
        XCTAssertEqual(LibraryVersionComparison.changedCharacters(in: "👩🏽‍🎨把信搁在窗边。", comparedWith: "👩🏽‍🎨把信放在窗边。"), [3])
    }

    func testVersionComparisonLetsTheReaderChooseHowToAlignExtraLines() {
        let base: [LibraryPassagePage.Line] = [
            .init(id: 0, original: "夜的天空", startTime: 0),
            .init(id: 1, original: "你还是会来", startTime: 2),
            .init(id: 2, original: "下一个路口再见", startTime: 5)
        ]
        let peer: [LibraryPassagePage.Line] = [
            .init(id: 0, original: "作词：某人", startTime: 0),
            .init(id: 1, original: "你一定会来", startTime: 2.2),
            .init(id: 2, original: "下一个路口再见", startTime: 5)
        ]
        let text = LibraryVersionComparison.align(base, peer, translations: false, sameOriginal: false)
        XCTAssertEqual(text.map(\.change), [.onlyBase, .onlyReference, .text, .same])
        let time = LibraryVersionComparison.align(base, peer, translations: false, sameOriginal: false, alignment: .time)
        XCTAssertEqual(time.map(\.change), text.map(\.change))
        let line = LibraryVersionComparison.align(base, peer, translations: false, sameOriginal: false, alignment: .line)
        XCTAssertEqual(line.map(\.change), [.text, .text, .same])
    }

    func testMultipleVersionsShareOneGridAndCompareTimingSeparatelyFromText() {
        typealias Line = LibraryPassagePage.Line
        let base = [Line(id: 0, original: "天亮了", startTime: 1),
                    Line(id: 1, original: "再见", startTime: 7)]
        let next = [Line(id: 0, original: "天亮了", translation: "Dawn", startTime: 1.5),
                    Line(id: 1, original: "等一下", startTime: 3),
                    Line(id: 2, original: "再见", startTime: 7)]
        let third = [Line(id: 0, original: "天亮了", startTime: 1),
                     Line(id: 1, original: "等一下", startTime: 3),
                     Line(id: 2, original: "再见", startTime: 7)]
        let rows = LibraryOriginalComparison(editions: [base, next, third], alignment: .text).rows
        XCTAssertEqual(rows.map { $0.lines.map { $0.map(\.id) } }, [[[0], [0], [0]], [[], [1], [1]], [[1], [2], [2]]])
        XCTAssertTrue(rows[0].differs(in: [.timing, .layers]))
        XCTAssertTrue(rows[0].differs(in: [.timing]))
        XCTAssertFalse(rows[0].differs(in: [.text]))
        XCTAssertTrue(rows[1].differs(in: [.text]))
    }

    func testOriginalComparisonAlignsCreditRolesAndSplitPhrasesAcrossThreeVersions() {
        typealias Line = LibraryPassagePage.Line
        let base = [Line(id: 0, original: "作曲：山田 太郎", startTime: 0.325),
                    Line(id: 1, original: "君のいる夜が当たり前じゃない", startTime: 10),
                    Line(id: 2, original: "窓を開ける", startTime: 15)]
        let word = [Line(id: 0, original: "曲：Taro Yamada", startTime: 0.666),
                    Line(id: 1, original: "編曲：山田", startTime: 0.675),
                    Line(id: 2, original: "君のいる夜が", startTime: 9.96),
                    Line(id: 3, original: "当たり前じゃない", startTime: 13),
                    Line(id: 4, original: "窓を開ける", startTime: 14.94)]
        let plain = [Line(id: 0, original: "君のいる"),
                    Line(id: 1, original: "夜が当たり前じゃない"),
                    Line(id: 2, original: "窓を開ける。")]
        let rows = LibraryOriginalComparison(editions: [base, word, plain], alignment: .text).rows
        XCTAssertEqual(rows.map { $0.lines.map { $0.map(\.id) } },
                       [[[0], [0], []], [[], [1], []], [[1], [2, 3], [0, 1]], [[2], [4], [2]]])
    }

    func testIdentityGroupingSearchExportAndCrossKeySelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-identity-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("test.sqlite3")
        let repo = SQLiteLyricsRepository(
            databaseURL: databaseURL,
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await repo.prepare()
        func save(_ track: Track, text: String) async throws -> UUID {
            let identity = TrackIdentity(track: track)
            let document = LyricsDocument(
                identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
                lines: [LyricLine(timestamp: 1, originalText: text, translationText: "legacytranslation", romajiText: "legacyromaji", kanaText: "れがしーかな")],
                isSynchronized: true, source: .lrclib, confidence: 0.95, providerSourceID: text
            )
            let saved = try await repo.save(track: track, identity: identity, document: document)
            return try XCTUnwrap(saved.versionID)
        }

        let a = Track(title: "Family fixture", artist: "Singer", album: "Album", duration: 170, spotifyId: "family-song")
        let b = Track(title: a.title, artist: a.artist, album: a.album, duration: 170.72, spotifyId: "family-song")
        let unrelated = Track(title: a.title, artist: a.artist, album: a.album, duration: 170, spotifyId: "different-song")
        let conflict = Track(title: a.title, artist: "Different singer", album: a.album, duration: 170, spotifyId: "family-song")
        let aID = try await save(a, text: "原版独有歌词")
        let bID = try await save(b, text: "新版独有歌词")
        let unrelatedID = try await save(unrelated, text: "unrelated")
        let conflictID = try await save(conflict, text: "conflict")
        let historical = Track(title: "Historical metadata", artist: "Historical singer", album: "Old album", duration: 99, spotifyId: "historical-id")
        let historicalID = try await save(historical, text: "historical-only")
        _ = try await save(Track(title: "Duration conflict", artist: "Singer", album: "Album", duration: 100, spotifyId: "duration-conflict"), text: "short recording")
        _ = try await save(Track(title: "Duration conflict", artist: "Singer", album: "Album", duration: 130, spotifyId: "duration-conflict"), text: "long recording")
        _ = try await save(Track(title: a.title, artist: a.artist, album: a.album, duration: a.duration), text: "metadata-only")

        let readingID = UUID()
        let translationID = UUID()
        let fixtureSQL = """
        INSERT INTO track_identity_redirects VALUES ('\(TrackIdentity(track: historical).stableKey)', '\(TrackIdentity(track: a).stableKey)', 'fixture', 'fixture', 'fixture', 1);
        INSERT INTO reading_versions(id,lyrics_version_id,source_content_hash,engine_id,representation_id,created_at,updated_at)
        VALUES ('\(readingID)','\(bID)','fixture','fixture','readingRepresentation.kana',1,1);
        INSERT INTO reading_lines(reading_version_id,line_index,original_text,reading_text)
        VALUES ('\(readingID)',0,'新版独有歌词','からだ savedreadingneedle');
        INSERT INTO translation_versions(id,lyrics_version_id,source_kind,target_language,source_content_hash,created_at,updated_at,status)
        VALUES ('\(translationID)','\(aID)','manualEdit','zh','fixture',1,1,'complete');
        INSERT INTO translation_lines VALUES ('\(translationID)',0,'保存译文独有词');
        INSERT INTO track_aliases(track_stable_key,field,kind,value,script,source,confidence,is_official)
        VALUES ('\(TrackIdentity(track: a).stableKey)','title','userAlias','Alternative title','latin','user',1,0);
        """
        try executeSQL(fixtureSQL, at: databaseURL)

        let entries = try await repo.loadPersonalLibraryEntries()
        XCTAssertEqual(entries.count, 4, "One Spotify ID stays one song across artist and duration changes; different IDs and metadata-only tracks stay separate")
        let family = try XCTUnwrap(entries.first { $0.lyricsVersionCount == 4 })
        let loadedDetail = try await repo.loadPersonalLibraryTrackDetail(stableKey: family.trackStableKey)
        let detail = try XCTUnwrap(loadedDetail)
        XCTAssertEqual(Set(detail.lyricsVersions.map(\.id)), Set([aID, bID, conflictID, historicalID]), "Grouping must retain both physical keys' versions")
        XCTAssertTrue(detail.readingVersions.contains { $0.id == readingID })
        XCTAssertTrue(detail.translationVersions.contains { $0.id == translationID })
        let oldDetailResult = try await repo.loadPersonalLibraryTrackDetail(stableKey: TrackIdentity(track: b).stableKey)
        let oldDetail = try XCTUnwrap(oldDetailResult)
        XCTAssertEqual(oldDetail.entry.trackStableKey, family.trackStableKey)
        XCTAssertEqual(oldDetail.lyricsVersions.count, 4)

        for query in ["原版独有", "新版独有", "historical-only", "SAVEDREADINGNEEDLE", "SÁVEDREADINGNEEDLE", "karada", "ＫＡＲＡＤＡ", "保存译文独有", "Alternative title"] {
            let found = try await repo.loadPersonalLibraryEntries(searchQuery: query)
            XCTAssertEqual(found.map(\.trackStableKey), [family.trackStableKey], "Search must cover all versions and aliases: \(query)")
        }
        for query in ["legacyromaji", "れがしーかな", "legacytranslation", "Singer", "Album"] {
            let found = try await repo.loadPersonalLibraryEntries(searchQuery: query)
            XCTAssertTrue(found.contains { $0.trackStableKey == family.trackStableKey }, "Search must include legacy fields: \(query)")
        }
        let injection = try await repo.loadPersonalLibraryEntries(searchQuery: "' OR 1=1 --")
        XCTAssertTrue(injection.isEmpty)

        let passages = try await repo.searchLibraryPassages("原版独有歌词")
        let passage = try XCTUnwrap(passages.first)
        XCTAssertEqual(passage.source, .original(aID))
        let archivedPage = try await repo.readLibraryPassage(.init(trackKey: family.trackStableKey, source: .original(aID)))
        XCTAssertEqual(archivedPage?.lines.first?.original, "原版独有歌词")
        let translations = try await repo.searchLibraryPassages("保存译文独有")
        XCTAssertEqual(translations.first?.source, .translation(translationID))
        let searchTarget = try XCTUnwrap(translations.first).readingTarget(for: "保存译文独有")
        XCTAssertEqual(searchTarget.trackKey, family.trackStableKey)
        XCTAssertEqual(searchTarget.find, "保存译文独有")
        let translatedPage = try await repo.readLibraryPassage(searchTarget)
        XCTAssertEqual(translatedPage?.lines.first?.translation, "保存译文独有词")
        XCTAssertEqual(translatedPage?.lines.first?.original, "", "An old child with a different text hash must stay readable on its own")
        let wrongSong = try await repo.readLibraryPassage(.init(trackKey: TrackIdentity(track: unrelated).stableKey, source: .original(aID)))
        XCTAssertNil(wrongSong, "The same title on a different recording must not open this lyric version")

        let package = try await repo.exportPersonalLibraryPackage(stableKey: family.trackStableKey)
        XCTAssertEqual(Set(package.lyricsVersions.map(\.id)), Set([aID, bID, conflictID, historicalID]), "Export must not lose versions hidden by grouping")
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: family.trackStableKey, lyricsVersionID: bID)
        let best = try await repo.loadBestStored(track: a, identity: TrackIdentity(track: a))
        XCTAssertEqual(best?.versionID, bID, "Selecting a sibling-key version must affect playback")
        let editable = try await repo.loadEditableVersion(versionID: bID, track: a, identity: TrackIdentity(track: a))
        XCTAssertEqual(editable?.record.id, bID, "Sibling-key versions must remain editable")

        let reopened = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("reopened"))
        let reopenedEntries = try await reopened.loadPersonalLibraryEntries()
        XCTAssertEqual(reopenedEntries.count, 4)
        let redirects = try await reopened.redirectCount()
        XCTAssertEqual(redirects, 4, "New Spotify keys persist redirects; explicit historical redirects are retained")
        let beforeNormalization = await repo.searchNormalizationCounts()
        _ = try await save(a, text: "newly-saved-cache-needle")
        let updatedSearch = try await repo.loadPersonalLibraryEntries(searchQuery: "NEWLY-SAVED-CACHE-NEEDLE")
        XCTAssertEqual(updatedSearch.map(\.trackStableKey), [family.trackStableKey])
        let afterNormalization = await repo.searchNormalizationCounts()
        for (key, count) in beforeNormalization where key != family.trackStableKey {
            XCTAssertEqual(afterNormalization[key], count, "An edit must leave other songs' cached versions intact")
        }
        XCTAssertGreaterThan(afterNormalization[family.trackStableKey] ?? 0, beforeNormalization[family.trackStableKey] ?? 0)
        _ = try await repo.loadPersonalLibraryEntries(searchQuery: "another search")
        let repeatedNormalization = await repo.searchNormalizationCounts()
        XCTAssertEqual(repeatedNormalization, afterNormalization, "Search itself only matches substrings")
        try await reopened.toggleLyricsLocked(versionID: unrelatedID, locked: true)
        let externallyChanged = try await repo.loadPersonalLibraryEntries(searchQuery: "unrelated")
        XCTAssertEqual(externallyChanged.first?.hasLockedLyrics, true, "Edits from the library's separate connection invalidate its song")


    }

    /// 2026-11-15: 110 songs had plain text only and 「全部补全」 skipped them.
    func testPlainTextOnlyIsMarkedWithoutTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-synced-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"),
                                          alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let track = Track(title: "Plain fixture", artist: "Singer", album: "Album", duration: 200, spotifyId: "plain-song")
        let identity = TrackIdentity(track: track)
        func document(synced: Bool, text: String) -> LyricsDocument {
            LyricsDocument(identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
                lines: [LyricLine(timestamp: synced ? 12 : 0, originalText: text)],
                isSynchronized: synced, source: .lrclib, confidence: 0.9, providerSourceID: text)
        }
        _ = try await repo.save(track: track, identity: identity, document: document(synced: false, text: "plain words"))
        let plain = try await repo.loadPersonalLibraryEntries()
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain.first?.hasSyncedLyrics, false)
        _ = try await repo.save(track: track, identity: identity, document: document(synced: true, text: "timed words"))
        let timed = try await repo.loadPersonalLibraryEntries()
        XCTAssertEqual(timed.first?.hasSyncedLyrics, true)
    }

    func testSameSpotifyTrackReadsItsSavedLyricsWhateverLengthThePlayerReports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("same-spotify-id-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("test.sqlite3")
        let repo = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let id = "4tqLygfzhk4lEQQuLWPykj"
        // NetEase's timed lyrics saved when Spotify reported two artists, 166.168 s.
        let saved = Track(title: "ラヴイットベイビー", artist: "はてなぷれいりすと, Nqsi", album: "ラヴイットベイビー",
                          duration: 166.168, spotifyId: id)
        let savedIdentity = TrackIdentity(track: saved)
        _ = try await repo.save(track: saved, identity: savedIdentity, document: LyricsDocument(
            identity: savedIdentity, title: saved.title, artist: saved.artist, album: saved.album, duration: saved.duration,
            lines: [LyricLine(timestamp: 12, originalText: "らぶいっと")], isSynchronized: true,
            source: .neteaseExperimental, confidence: 0.95, providerSourceID: "netease:3360385286"))

        // The real database also holds an empty row from 10-26, when Spotify
        // reported one artist and 141.29 s, written without the ID columns
        // and so never redirected. Plus a row from a skip: same ID, another title.
        let replay = Track(title: "ラヴイットベイビー", artist: "はてなぷれいりすと", album: "ラヴイットベイビー",
                           duration: 141.29, spotifyId: id)
        let replayIdentity = TrackIdentity(track: replay)
        let otherTitle = Track(title: "別の歌", artist: "はてなぷれいりすと", album: "", duration: 150.5, spotifyId: id)
        let otherIdentity = TrackIdentity(track: otherTitle)
        let beforeMetadata = try await repo.loadBestStored(track: otherTitle, identity: otherIdentity)
        XCTAssertNil(beforeMetadata, "A borrowed ID must not load the previous song even before a physical row exists")
        let redirects = try await repo.redirectCount()
        XCTAssertEqual(redirects, 0, "A transient snapshot must not persist a redirect to another title")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        for (key, track) in [(replayIdentity.stableKey, replay), (otherIdentity.stableKey, otherTitle)] {
            let sql = "INSERT INTO tracks(stable_key, title, artist_display, album, duration, created_at, updated_at) VALUES ('\(key)', '\(track.title)', '\(track.artist)', '\(track.album)', \(track.duration), 0, 0);"
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(handle)

        let reopened = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("reopened"))
        try await reopened.prepare()
        let stored = try await reopened.loadBestStored(track: replay, identity: replayIdentity)
        XCTAssertEqual(stored?.document.lines.first?.originalText, "らぶいっと")
        XCTAssertEqual(stored?.document.identity, replayIdentity)
        let none = try await reopened.loadBestStored(track: otherTitle, identity: otherIdentity)
        XCTAssertNil(none, "the same ID under another title is a mis-read during a skip")
    }

    func testRowsWithAWrongLengthOrBorrowedIDAreNotListedAsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-ghost-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("test.sqlite3")
        let repo = SQLiteLyricsRepository(databaseURL: databaseURL,
                                          alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        func saveTimed(_ track: Track) async throws {
            let identity = TrackIdentity(track: track)
            _ = try await repo.save(track: track, identity: identity, document: LyricsDocument(
                identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
                lines: [LyricLine(timestamp: 12, originalText: track.title + " words")],
                isSynchronized: true, source: .qqExperimental, confidence: 0.9, providerSourceID: track.title))
        }
        // Rows Spotify reported for a moment during a track change: no
        // lyrics, a wrong length, sometimes the previous song's ID.
        func insertBare(_ track: Track) throws {
            let key = TrackIdentity(track: track).stableKey.replacingOccurrences(of: "'", with: "''")
            try executeSQL("""
                INSERT INTO tracks(stable_key, spotify_id, spotify_uri, isrc, title, artist_display, album, duration, artwork_url, created_at, updated_at)
                VALUES ('\(key)', NULL, NULL, NULL, '\(track.title)', '\(track.artist)', '\(track.album)', \(track.duration), NULL, 1, 1);
                """, at: databaseURL)
        }
        try await saveTimed(Track(title: "shion", artist: "angelize", album: "shion", duration: 168.0, spotifyId: "0t5DDnfp0dkgeSnokvbIQY"))
        try insertBare(Track(title: "shion", artist: "angelize", album: "shion", duration: 150.8, spotifyId: "0t5DDnfp0dkgeSnokvbIQY"))
        try await saveTimed(Track(title: "幽霊になって", artist: "Be my Girl", album: "幽霊になって", duration: 267.923, spotifyId: "2o9gqgea9s465s7vwkjadx"))
        try await saveTimed(Track(title: "WAITING AT 3AM", artist: "Toh", album: "WAITING AT 3AM", duration: 171.44, spotifyId: "4qxveeiqym7hi9lcuoal6p"))
        try insertBare(Track(title: "幽霊になって", artist: "Be my Girl", album: "幽霊になって", duration: 240.0, spotifyId: "5o45jo2byhtyah2flz9ti0"))
        try insertBare(Track(title: "WAITING AT 3AM", artist: "Toh", album: "WAITING AT 3AM", duration: 240.0, spotifyId: "5o45jo2byhtyah2flz9ti0"))
        // Two recordings with the same title: the Korean version has lyrics,
        // the original does not and must stay on the list.
        try await saveTimed(Track(title: "GIJIKOI", artist: "Haruki Hamano", album: "GIJIKOI (Korean ver.)", duration: 216.875, spotifyId: "0zlwh8kzv299erleomelad"))
        try insertBare(Track(title: "GIJIKOI", artist: "Haruki Hamano", album: "meaning of tears", duration: 234.659, spotifyId: "5sfohzecupaxj580g4zjmg"))
        try insertBare(Track(title: "Lonely fixture", artist: "Singer", album: "Album", duration: 200, spotifyId: "lonelyfixtureid"))

        let entries = try await repo.loadPersonalLibraryEntries(includeMissingLyrics: true)
        let missing = entries.filter(\.needsLyrics).map { "\($0.title)@\($0.duration)" }.sorted()
        XCTAssertEqual(missing, ["GIJIKOI@234.659", "Lonely fixture@200.0"])
        XCTAssertEqual(entries.filter { $0.title == "WAITING AT 3AM" }.count, 2, "rows stay in the library; only the missing list skips them")
    }

    func testPlainTextRowIsCoveredOnlyByTimedLyricsOfTheSameSong() {
        func entry(_ key: String, title: String = "Song", versions: Int, synced: Bool) -> PersonalLyricsLibraryEntry {
            PersonalLyricsLibraryEntry(trackStableKey: key, spotifyTrackID: nil, title: title, artist: "Singer", album: nil,
                artworkURL: nil, lyricsVersionCount: versions, translationVersionCount: 0, readingVersionCount: 0,
                timingVersionCount: 0, hasLockedLyrics: false, hasLockedTranslation: false, hasManualLyrics: false,
                hasManualTranslation: false, hasReading: false, hasFineTiming: false, lastModifiedAt: Date(),
                activeLyricsVersionID: nil, activeTranslationVersionID: nil, hasSyncedLyrics: synced)
        }
        let plainGhost = entry("spotify-id:abc|metadata:song|singer|song|151", versions: 1, synced: false)
        let plainOther = entry("spotify-id:abc|metadata:song|singer|song|168", versions: 1, synced: false)
        let timedOther = entry("spotify-id:abc|metadata:song|singer|song|168", versions: 1, synced: true)
        XCTAssertTrue(PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere([plainGhost], among: [plainGhost, plainOther])[0].needsLyrics)
        XCTAssertFalse(PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere([plainGhost], among: [plainGhost, timedOther])[0].needsLyrics)
        let noID = entry("metadata:song|singer|song|151", versions: 0, synced: false)
        XCTAssertTrue(PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere([noID], among: [noID, timedOther])[0].needsLyrics,
                      "without an ID the same title alone proves nothing")
    }

    private func executeSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LibraryIdentitySearchContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open temporary SQLite database"])
        }
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite fixture statement failed"
            sqlite3_free(error)
            throw NSError(domain: "LibraryIdentitySearchContractTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
