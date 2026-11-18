import Foundation
import SQLite3
import XCTest
@testable import SpotifyLyrics

final class LibraryRevisionsContractTests: XCTestCase {
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
        let choices = try await repo.localRecordingChoices()
        let destination = try XCTUnwrap(choices.first { $0.stableKey == identity.stableKey })
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
        try await repo.markTranslationLocked(versionID: originalTranslation.record.id, locked: true)
        var translationDraft = LibraryTranslationRevisionDraft(track: track, lyricsSource: source, source: originalTranslation)
        translationDraft.lines[0] = "修订译一"
        let translationChildResult = try await repo.saveManualEdit(translationDraft.saveRequest())
        let translationChild = try XCTUnwrap(translationChildResult.translationVersion)
        XCTAssertEqual(translationChild.record.parentVersionID, originalTranslation.record.id)
        XCTAssertEqual(translationChild.record.lyricsVersionID, source.record.id)
        XCTAssertEqual(translationChild.record.sourceContentHash, source.sourceContentHash)
        XCTAssertTrue(translationChild.record.isManuallyEdited)
        XCTAssertFalse(translationChild.record.isLocked)
        let translationVersions = try await repo.loadTranslationVersions(
            lyricsVersionID: source.record.id, targetLanguage: "zh-Hans", sourceContentHash: source.sourceContentHash
        )
        let retainedTranslation = try XCTUnwrap(translationVersions.first { $0.record.id == originalTranslation.record.id })
        XCTAssertTrue(retainedTranslation.record.isLocked)
        XCTAssertEqual(retainedTranslation.lines, originalTranslation.lines)
        let reader = try await repo.readLibraryPassage(.init(trackKey: identity.stableKey, source: .translation(originalTranslation.record.id)))
        XCTAssertEqual(reader?.lines.map(\.original), ["Original first", "Original second"])
        XCTAssertEqual(reader?.lines.compactMap(\.translation), ["原译一", "原译二"], "Read the requested locked translation even after a revision")
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
