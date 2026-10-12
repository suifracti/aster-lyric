import Foundation
import Darwin
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class AppSettingsStore: @unchecked Sendable {
    public static let shared = AppSettingsStore()
    public let translationProfiles = TranslationProfileStore(defaults: UserDefaults(suiteName: "t2-lossless-\(UUID().uuidString)")!)
    private init() {}
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = "FAIL: \(message)" }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ContractFailure(message) }
}

@MainActor
private func waitUntil(
    _ description: String,
    attempts: Int = 300,
    condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ContractFailure(description)
}

private struct Fixture {
    let track: Track
    let identity: TrackIdentity
    let document: LyricsDocument
    let spans: [TimedTextSpan]
}

private struct DatabaseCounts: Equatable {
    let tracks: Int
    let versions: Int
    let lines: Int
    let timings: Int
    let translations: Int
    let readingLayers: Int
}

private final class ReadOnlyProbe {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error \(result)"
            if let opened { sqlite3_close(opened) }
            throw ContractFailure("read-only probe failed: \(message)")
        }
        handle = opened
    }

    deinit { sqlite3_close(handle) }

    func dataVersion() throws -> Int { try scalar("PRAGMA data_version;") }

    func counts() throws -> DatabaseCounts {
        DatabaseCounts(
            tracks: try scalar("SELECT COUNT(*) FROM tracks;"),
            versions: try scalar("SELECT COUNT(*) FROM lyrics_versions;"),
            lines: try scalar("SELECT COUNT(*) FROM lyric_lines;"),
            timings: try scalar("SELECT COUNT(*) FROM lyrics_timing_versions;"),
            translations: try scalar("SELECT COUNT(*) FROM translation_versions;"),
            readingLayers: try scalar("SELECT COUNT(*) FROM lyric_reading_layers;")
        )
    }

    private func scalar(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure("prepare \(sql)") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("step \(sql)") }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func failure(_ operation: String) -> ContractFailure {
        ContractFailure("\(operation) failed: \(String(cString: sqlite3_errmsg(handle)))")
    }
}

@MainActor
private final class TimingConfirmationRecorder {
    var summary: LyricsTimingLossSummary?
    var allow = false
}

@main
struct T2LosslessEditingTimingContract {
    static func main() async {
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        do {
            if selected == "editor" || selected == "all" { try await editorCopyRoundTrip() }
            if selected == "library" || selected == "all" { try await libraryRevisionRoundTrip() }
            if selected == "loss" || selected == "all" { try await incompatibleEditConfirmation() }
            if selected == "time" || selected == "all" { try await libraryTimeChangeConfirmation() }
            if selected == "translation" || selected == "all" { try await translationOnlySave() }
            if selected == "transaction" || selected == "all" { try await attachmentFailureRollsBack() }
            if selected == "invalid" || selected == "all" { try await invalidAttachmentIsRejected() }
            guard ["editor", "library", "loss", "time", "translation", "transaction", "invalid", "all"].contains(selected) else {
                throw ContractFailure("unknown case \(selected)")
            }
            print("T2 lossless editing/timing contract passed (\(selected))")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func makeTrack(_ label: String) -> Track {
        Track(title: "T2 \(label)", artist: "Core Integrity", album: "Fixture", duration: 30, spotifyId: "t2-\(label.lowercased())")
    }

    private static func ttmlFixture(track: Track, identity: TrackIdentity) throws -> Fixture {
        let xml = """
        <tt timing="Word"><body>
          <p begin="0s" end="2s" ttm:agent="v1"><span begin="0s" end="0.4s">今日</span><span begin="0.4s" end="0.8s">🌸</span><span begin="0.8s" end="1.2s">今日</span></p>
          <p begin="4s" end="6s">untimed row</p>
        </body></tt>
        """
        guard let parsed = TTMLParser.parse(xml, identity: identity) else {
            throw ContractFailure("TTML fixture failed to parse")
        }
        let document = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: parsed.lines,
            isSynchronized: true,
            source: .amll,
            confidence: 1,
            providerSourceID: "t2-ttml-provider",
            language: "ja"
        )
        guard let spans = document.lines.first?.timedSpans, !spans.isEmpty else {
            throw ContractFailure("TTML fixture did not contain actual timed spans")
        }
        return Fixture(track: track, identity: identity, document: document, spans: spans)
    }

    private static func yrcFixture(track: Track, identity: TrackIdentity) throws -> Fixture {
        let yrc = """
        [0,3000](0,500,0)今日(500,500,0)🌸(1000,500,0)今日
        [4000,2000]untimed row
        """
        guard let parsed = YRCParser.parse(yrc, identity: identity), parsed.lines.count == 2,
              let spans = parsed.lines[0].timedSpans, !spans.isEmpty else {
            throw ContractFailure("YRC fixture did not contain expected line and word timing")
        }
        // Represent the second line as an unset partial-timeline placeholder while
        // retaining the parser-produced spans and an explicit, valid zero start.
        let lines = [
            parsed.lines[0],
            LyricLine(timestamp: 0, originalText: parsed.lines[1].originalText)
        ]
        let document = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: lines,
            isSynchronized: false,
            source: .neteaseExperimental,
            confidence: 1,
            providerSourceID: "t2-yrc-provider",
            language: "zh-Hans",
            explicitlyTimedLineIndices: [0]
        )
        return Fixture(track: track, identity: identity, document: document, spans: spans)
    }

    private static func editorCopyRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("editor.sqlite3")
        let track = makeTrack("Editor")
        let identity = TrackIdentity(track: track)
        let fixture = try ttmlFixture(track: track, identity: identity)

        let savedIDs: (parent: UUID, child: UUID, parentTiming: UUID?, draftSpansRetained: Bool) = try await makeEditorCopy(
            fixture: fixture,
            databaseURL: dbURL,
            root: root
        )
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        guard let selected = try await reopened.loadBestStored(track: track, identity: identity),
              let child = try await reopened.loadEditableVersion(versionID: savedIDs.child, track: track, identity: identity),
              let parent = try await reopened.loadEditableVersion(versionID: savedIDs.parent, track: track, identity: identity) else {
            throw ContractFailure("editor child/parent did not reopen from SQLite")
        }
        let reopenedSpans = child.document.lines.first?.timedSpans ?? []
        try require(savedIDs.draftSpansRetained, "editor draft projection dropped TTML spans before the repository save")
        try require(selected.versionID == savedIDs.child, "editor copy was not the selected document after reopen")
        try require(reopenedSpans == fixture.spans, "editor copy lost or changed TTML spans after save/reopen")
        try require(child.document.timingVersionID != nil && child.document.timingVersionID != savedIDs.parentTiming,
                    "child timing attachment did not get an independent identity")
        try require(parent.document.timingVersionID == savedIDs.parentTiming && parent.document.lines.first?.timedSpans == fixture.spans,
                    "editor copy changed its parent attachment or source spans")
        try require(child.document.language == "ja" && child.document.lines.first?.performerID == "v1",
                    "editor copy lost language or performer metadata")
        try require(child.document.lines.map(\.timestamp) == parent.document.lines.map(\.timestamp) &&
                    child.document.lines.map(\.endTime) == parent.document.lines.map(\.endTime),
                    "editor copy lost row start or end times")
        try require(child.lockedReadingLayers.count == 1 && child.document.lines.first?.kanaText == "こんにち" &&
                    child.document.lines.first?.romajiText == "konnichi",
                    "editor copy lost an existing locked-reading overlay")
        try require(child.sourceContentHash == LyricsSourceContentHasher.hash(isSynchronized: child.record.isSynced, lines: child.lines),
                    "child canonical hash was not computed from stored source rows")
        let parentRender = renderInput(parent.document.lines[0])
        let childRender = renderInput(child.document.lines[0])
        try require(childRender == parentRender && childRender.count > 1, "renderer input differs after editor copy/reopen")
        print("T2 editor copy observed parent=\(savedIDs.parent) child=\(savedIDs.child) spans=\(reopenedSpans.count) timing=\(child.document.timingVersionID?.uuidString ?? "none")")
    }

    private static func makeEditorCopy(
        fixture: Fixture,
        databaseURL: URL,
        root: URL
    ) async throws -> (parent: UUID, child: UUID, parentTiming: UUID?, draftSpansRetained: Bool) {
        let repository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let result = try await repository.save(track: fixture.track, identity: fixture.identity, document: fixture.document)
        guard let parentID = result.versionID,
              let source = try await repository.loadEditableVersion(versionID: parentID, track: fixture.track, identity: fixture.identity) else {
            throw ContractFailure("provider TTML version failed to load")
        }
        try insertLockedReading(databaseURL: databaseURL, lyricsVersionID: parentID)
        guard let sourceWithReading = try await repository.loadEditableVersion(versionID: parentID, track: fixture.track, identity: fixture.identity) else {
            throw ContractFailure("provider source failed to reload with a locked reading")
        }
        let parentTimingID = source.document.timingVersionID
        let editor = await MainActor.run { () -> LyricsEditorSessionController in
            let controller = LyricsEditorSessionController(repository: repository)
            controller.begin(
                track: fixture.track,
                identity: fixture.identity,
                document: sourceWithReading.document,
                lyricsVersionID: parentID,
                sourceContentHash: source.sourceContentHash,
                revision: 0,
                translations: [],
                selectedTranslation: nil,
                configuration: AITranslationConfiguration()
            )
            return controller
        }
        try await waitUntil("editor did not load source version") { editor.availableVersions.contains(where: { $0.record.id == parentID }) }
        let draftSpansRetained = try await MainActor.run { () -> Bool in
            guard let draftDocument = editor.draft?.document() else { throw ContractFailure("editor draft could not project a document") }
            let retained = draftDocument.lines.first?.timedSpans == fixture.spans
            editor.save(forceCopy: true)
            return retained
        }
        try await waitUntil("editor copy did not finish saving") { editor.state == .saved && editor.draft?.sourceVersionID != parentID }
        guard let childID = await MainActor.run(body: { editor.draft?.sourceVersionID }) else {
            throw ContractFailure("editor did not adopt saved child")
        }
        return (parentID, childID, parentTimingID, draftSpansRetained)
    }

    private static func libraryRevisionRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("library.sqlite3")
        let track = makeTrack("Library")
        let identity = TrackIdentity(track: track)
        let fixture = try yrcFixture(track: track, identity: identity)
        let result: (parent: UUID, child: UUID, parentTiming: UUID?, draftSpansRetained: Bool) = try await makeLibraryRevision(
            fixture: fixture,
            databaseURL: dbURL,
            root: root
        )
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        guard let child = try await reopened.loadEditableVersion(versionID: result.child, track: track, identity: identity),
              let parent = try await reopened.loadEditableVersion(versionID: result.parent, track: track, identity: identity) else {
            throw ContractFailure("library revision did not reopen from SQLite")
        }
        try require(child.document.lines.first?.timedSpans == fixture.spans, "library revision lost or changed YRC spans after save/reopen")
        try require(result.draftSpansRetained, "library draft projection dropped YRC spans before the repository save")
        try require(child.document.timingVersionID != nil && child.document.timingVersionID != result.parentTiming,
                    "library revision reused its parent attachment identity")
        try require(parent.document.timingVersionID == result.parentTiming && parent.document.lines.first?.timedSpans == fixture.spans,
                    "library revision changed its parent attachment or source spans")
        try require(child.document.explicitlyTimedLineIndices == Set([0]) && child.document.lineHasExplicitTiming(0) && !child.document.lineHasExplicitTiming(1),
                    "library revision lost partial timeline mask or explicit zero")
        try require(child.document.language == "zh-Hans", "library revision lost source language")
        try require(renderInput(child.document.lines[0]) == renderInput(parent.document.lines[0]), "renderer input differs after library revision/reopen")
        print("T2 library revision observed parent=\(result.parent) child=\(result.child) spans=\(child.document.lines.first?.timedSpans?.count ?? 0) timing=\(child.document.timingVersionID?.uuidString ?? "none")")
    }

    private static func makeLibraryRevision(
        fixture: Fixture,
        databaseURL: URL,
        root: URL
    ) async throws -> (parent: UUID, child: UUID, parentTiming: UUID?, draftSpansRetained: Bool) {
        let repository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let result = try await repository.save(track: fixture.track, identity: fixture.identity, document: fixture.document)
        guard let parentID = result.versionID,
              let source = try await repository.loadEditableVersion(versionID: parentID, track: fixture.track, identity: fixture.identity) else {
            throw ContractFailure("provider YRC version failed to load")
        }
        var draft = LibraryLyricsRevisionDraft(track: fixture.track, source: source)
        draft.lines.append(LyricsEditorLineDraft(originalText: "appended untimed row"))
        let request = try draft.saveRequest()
        let draftSpansRetained = request.document.lines.first?.timedSpans == fixture.spans
        let saved = try await repository.saveManualEdit(request)
        guard let child = saved.lyricsVersion else { throw ContractFailure("library revision did not create a child version") }
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey: fixture.identity.stableKey, lyricsVersionID: child.record.id)
        return (parentID, child.record.id, source.document.timingVersionID, draftSpansRetained)
    }

    private static func incompatibleEditConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-loss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("loss.sqlite3")
        let track = makeTrack("TextLoss")
        let identity = TrackIdentity(track: track)
        let fixture = try ttmlFixture(track: track, identity: identity)
        let saved = try await prepareEditorForTextEdit(fixture: fixture, databaseURL: dbURL, root: root)
        let probe = try ReadOnlyProbe(url: dbURL)
        let beforeCounts = try probe.counts()
        let beforeDataVersion = try probe.dataVersion()
        let recorder = await MainActor.run { TimingConfirmationRecorder() }
        let editor = try await makeTextEditingSession(fixture: fixture, databaseURL: dbURL, root: root, recorder: recorder)

        await MainActor.run {
            guard let first = editor.draft?.lines.first else { return }
            editor.updateLine(first.id) { $0.originalText = "明日🌸今日" }
            editor.save(forceCopy: true)
        }
        try await MainActor.run {
            try require(recorder.summary?.lostSpanCount == 1 && recorder.summary?.affectedLineCount == 1,
                        "editor did not report the exact incompatible text-span loss")
            try require(editor.state == .editing && editor.message?.contains("已取消") == true,
                        "cancel did not leave the editor open without claiming a save")
        }
        let afterCancelDataVersion = try probe.dataVersion()
        let afterCancelCounts = try probe.counts()
        try require(afterCancelDataVersion == beforeDataVersion && afterCancelCounts == beforeCounts,
                    "cancelled editor timing-loss confirmation wrote to SQLite")

        await MainActor.run {
            recorder.allow = true
            editor.save(forceCopy: true)
        }
        try await waitUntil("confirmed text edit did not save") { editor.state == .saved && editor.draft?.sourceVersionID != saved.parentID }
        guard let childID = await MainActor.run(body: { editor.draft?.sourceVersionID }) else {
            throw ContractFailure("confirmed text edit did not create a child")
        }
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        guard let child = try await reopened.loadEditableVersion(versionID: childID, track: track, identity: identity),
              let parent = try await reopened.loadEditableVersion(versionID: saved.parentID, track: track, identity: identity) else {
            throw ContractFailure("confirmed text edit failed to reopen")
        }
        try require(child.document.lines[0].originalText == "明日🌸今日", "confirmed child did not preserve edited source text")
        try require(child.document.lines[0].timedSpans == Array(fixture.spans.dropFirst()),
                    "confirmed child retained a span on changed text or discarded compatible spans")
        try require(parent.document.lines[0].timedSpans == fixture.spans && parent.document.lines[0].originalText == fixture.document.lines[0].originalText,
                    "confirmed child edit changed parent text or timing")

        // The editor also exposes an end-time field. When it moves earlier,
        // retain only spans that still end within that changed row boundary.
        let endRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-end-loss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: endRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: endRoot) }
        let endURL = endRoot.appendingPathComponent("end.sqlite3")
        let endRepository = SQLiteLyricsRepository(databaseURL: endURL, alignmentProvenanceDirectory: endRoot.appendingPathComponent("provenance"))
        try await endRepository.prepare()
        let endSaved = try await endRepository.save(track: track, identity: identity, document: fixture.document)
        guard let endSource = try await endRepository.loadEditableVersion(versionID: endSaved.versionID!, track: track, identity: identity) else {
            throw ContractFailure("end-time source failed to load")
        }
        var endDraft = LibraryLyricsRevisionDraft(track: track, source: endSource)
        endDraft.lines[0].endTime = 0.7
        try require(endDraft.timingLossSummary.lostSpanCount == 2, "end-time change did not report spans past the new line end")
        let endRequest = try endDraft.saveRequest(confirmingTimingLoss: true)
        try require(endRequest.document.lines[0].timedSpans == [fixture.spans[0]], "end-time confirmation did not filter spans past the new line end")
        let endChild = try await endRepository.saveManualEdit(endRequest).lyricsVersion
        guard let endChild else { throw ContractFailure("confirmed end-time edit did not create a child") }
        let endReopened = SQLiteLyricsRepository(databaseURL: endURL, alignmentProvenanceDirectory: endRoot.appendingPathComponent("provenance"))
        try await endReopened.prepare()
        guard let endLoaded = try await endReopened.loadEditableVersion(versionID: endChild.record.id, track: track, identity: identity) else {
            throw ContractFailure("confirmed end-time child did not reopen")
        }
        try require(endLoaded.document.lines[0].endTime == 0.7 && endLoaded.document.lines[0].timedSpans == [fixture.spans[0]],
                    "reopened end-time child has incompatible spans or lost its end time")
        print("T2 incompatible editor edit: cancel rows unchanged; confirmation dropped exactly one incompatible span")
    }

    private static func prepareEditorForTextEdit(
        fixture: Fixture,
        databaseURL: URL,
        root: URL
    ) async throws -> (parentID: UUID, source: StoredEditableLyricsVersion) {
        let repository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let result = try await repository.save(track: fixture.track, identity: fixture.identity, document: fixture.document)
        guard let parentID = result.versionID,
              let source = try await repository.loadEditableVersion(versionID: parentID, track: fixture.track, identity: fixture.identity) else {
            throw ContractFailure("text-loss provider fixture failed to load")
        }
        return (parentID, source)
    }

    private static func makeTextEditingSession(
        fixture: Fixture,
        databaseURL: URL,
        root: URL,
        recorder: TimingConfirmationRecorder
    ) async throws -> LyricsEditorSessionController {
        let repository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        guard let stored = try await repository.loadBestStored(track: fixture.track, identity: fixture.identity),
              let storedVersionID = stored.versionID,
              let source = try await repository.loadEditableVersion(versionID: storedVersionID, track: fixture.track, identity: fixture.identity) else {
            throw ContractFailure("text-loss editor source failed to reload")
        }
        let editor = await MainActor.run { () -> LyricsEditorSessionController in
            let controller = LyricsEditorSessionController(repository: repository)
            controller.confirmTimingLoss = { summary in
                recorder.summary = summary
                return recorder.allow
            }
            controller.begin(
                track: fixture.track,
                identity: fixture.identity,
                document: source.document,
                lyricsVersionID: source.record.id,
                sourceContentHash: source.sourceContentHash,
                revision: 0,
                translations: [],
                selectedTranslation: nil,
                configuration: AITranslationConfiguration()
            )
            return controller
        }
        try await waitUntil("text-loss editor source did not load") { editor.availableVersions.contains(where: { $0.record.id == source.record.id }) }
        return editor
    }

    private static func libraryTimeChangeConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-time-loss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("time.sqlite3")
        let track = makeTrack("TimeLoss")
        let identity = TrackIdentity(track: track)
        let fixture = try yrcFixture(track: track, identity: identity)
        let repository = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let result = try await repository.save(track: track, identity: identity, document: fixture.document)
        guard let parentID = result.versionID,
              let source = try await repository.loadEditableVersion(versionID: result.versionID!, track: track, identity: identity) else {
            throw ContractFailure("YRC time-loss fixture failed to load")
        }
        var draft = LibraryLyricsRevisionDraft(track: track, source: source)
        draft.lines[0].startTime = 1.0
        let probe = try ReadOnlyProbe(url: dbURL)
        let beforeCounts = try probe.counts()
        let beforeDataVersion = try probe.dataVersion()
        do {
            _ = try draft.saveRequest()
            throw ContractFailure("library accepted incompatible timing loss without confirmation")
        } catch let error as LyricsEditingRepositoryError {
            guard case .timingLossRequiresConfirmation(let summary) = error else { throw error }
            try require(summary.lostSpanCount == 2 && summary.affectedLineCount == 1,
                        "library did not report the exact spans invalidated by a row-start change")
        }
        let afterCancelDataVersion = try probe.dataVersion()
        let afterCancelCounts = try probe.counts()
        try require(afterCancelDataVersion == beforeDataVersion && afterCancelCounts == beforeCounts,
                    "unconfirmed library timing-loss request wrote to SQLite")
        let confirmedRequest = try draft.saveRequest(confirmingTimingLoss: true)
        try require(confirmedRequest.document.lines[0].timedSpans == [fixture.spans[2]],
                    "confirmed library request did not retain the compatible remainder")
        let savedChild = try await repository.saveManualEdit(confirmedRequest).lyricsVersion
        guard let savedChild else { throw ContractFailure("confirmed library time edit did not create a child") }
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        guard let child = try await reopened.loadEditableVersion(versionID: savedChild.record.id, track: track, identity: identity),
              let parent = try await reopened.loadEditableVersion(versionID: parentID, track: track, identity: identity) else {
            throw ContractFailure("confirmed library time edit failed to reopen")
        }
        try require(child.document.lines[0].timestamp == 1.0 && child.document.lines[0].timedSpans == [fixture.spans[2]],
                    "library child pasted incompatible word timings after row-time change")
        try require(parent.document.lines[0].timestamp == 0 && parent.document.lines[0].timedSpans == fixture.spans,
                    "library timing edit changed the parent")
        print("T2 incompatible library retiming: unconfirmed request had zero writes; confirmation retained one valid span")
    }

    private static func translationOnlySave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-translation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("translation.sqlite3")
        let track = makeTrack("Translation")
        let identity = TrackIdentity(track: track)
        let fixture = try ttmlFixture(track: track, identity: identity)
        let repository = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let result = try await repository.save(track: track, identity: identity, document: fixture.document)
        guard let parentID = result.versionID,
              let source = try await repository.loadEditableVersion(versionID: result.versionID!, track: track, identity: identity) else {
            throw ContractFailure("translation-only source failed to load")
        }
        let before = try ReadOnlyProbe(url: dbURL).counts()
        let editor = await MainActor.run { () -> LyricsEditorSessionController in
            let controller = LyricsEditorSessionController(repository: repository)
            controller.begin(
                track: track,
                identity: identity,
                document: source.document,
                lyricsVersionID: parentID,
                sourceContentHash: source.sourceContentHash,
                revision: 0,
                translations: [],
                selectedTranslation: nil,
                configuration: AITranslationConfiguration()
            )
            return controller
        }
        try await waitUntil("translation-only editor source did not load") { editor.availableVersions.contains(where: { $0.record.id == parentID }) }
        await MainActor.run {
            for (index, line) in (editor.draft?.lines ?? []).enumerated() {
                editor.updateLine(line.id) { $0.translationText = "仅增加译文\(index + 1)" }
            }
            editor.save()
        }
        try await waitUntil("translation-only editor save did not finish") { editor.state == .saved }
        let after = try ReadOnlyProbe(url: dbURL).counts()
        try require(after.versions == before.versions && after.timings == before.timings && after.translations == before.translations + 1,
                    "translation-only edit created a lyric version/attachment or failed to create one translation layer")
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        guard let stored = try await reopened.loadBestStored(track: track, identity: identity) else {
            throw ContractFailure("translation-only source failed to reopen")
        }
        try require(stored.versionID == parentID && stored.document.lines[0].timedSpans == fixture.spans,
                    "translation-only save changed selected lyrics or dropped word timing")
        print("T2 translation-only edit added one translation row and no lyric/timing rows")
    }

    private static func attachmentFailureRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("rollback.sqlite3")
        let track = makeTrack("Rollback")
        let identity = TrackIdentity(track: track)
        let fixture = try ttmlFixture(track: track, identity: identity)
        let repository = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let result = try await repository.save(track: track, identity: identity, document: fixture.document)
        guard let parentID = result.versionID,
              let source = try await repository.loadEditableVersion(versionID: result.versionID!, track: track, identity: identity) else {
            throw ContractFailure("rollback source fixture failed to load")
        }
        var draft = LibraryLyricsRevisionDraft(track: track, source: source)
        draft.lines.append(LyricsEditorLineDraft(originalText: "untimed addition"))
        let request = try draft.saveRequest()
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: parentID)
        try createTimingFailureTrigger(databaseURL: dbURL)
        let probe = try ReadOnlyProbe(url: dbURL)
        let beforeCounts = try probe.counts()
        let beforeDataVersion = try probe.dataVersion()
        var saveError: String?
        do {
            _ = try await repository.saveManualEdit(request)
        } catch {
            saveError = String(describing: error)
        }
        try require(saveError?.contains("T2 injected attachment failure") == true,
                    "injected timing attachment error was swallowed or changed: \(saveError ?? "no error")")
        let afterFailureCounts = try probe.counts()
        let afterFailureDataVersion = try probe.dataVersion()
        try require(afterFailureCounts == beforeCounts && afterFailureDataVersion == beforeDataVersion,
                    "attachment insert failure left a half-saved version/selection/translation")
        guard let selected = try await repository.loadBestStored(track: track, identity: identity) else {
            throw ContractFailure("selected source disappeared after transaction rollback")
        }
        try require(selected.versionID == parentID, "transaction failure changed the selected lyrics version")
        print("T2 attachment failure rolled back all rows and preserved the selected parent")
    }

    private static func invalidAttachmentIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-T2-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("invalid.sqlite3")
        let track = makeTrack("Invalid")
        let identity = TrackIdentity(track: track)
        let fixture = try ttmlFixture(track: track, identity: identity)
        let ids = try await createBadPayloadFixture(fixture: fixture, databaseURL: dbURL, root: root)
        let badSpan = TimedTextSpan(
            id: 0,
            text: "今日",
            startTime: 0,
            endTime: 0.4,
            utf16Start: Int.max,
            utf16Length: 4,
            granularity: .timedUnit
        )
        let badPayload = DocumentTimingPayload(lines: [LineTimingPayload(lineIndex: 0, performerID: "v1", spans: [badSpan])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(badPayload)
        guard let payload = String(data: payloadData, encoding: .utf8) else { throw ContractFailure("invalid fixture JSON was not UTF-8") }
        try overwriteTimingPayload(databaseURL: dbURL, timingID: ids.timingID, payload: payload)

        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        guard let corrupted = try await reopened.loadEditableVersion(versionID: ids.timedVersion, track: track, identity: identity),
              let automatic = try await reopened.loadBestStored(track: track, identity: identity) else {
            throw ContractFailure("malformed timing fixture failed to reload")
        }
        try require(corrupted.document.timingVersionID == nil && !corrupted.document.hasTimedSpans,
                    "malformed attachment was projected as real word timing")
        try require(automatic.versionID == ids.lineOnlyVersion,
                    "malformed attachment was treated as valid word timing during automatic version arbitration")
        try await reopened.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: ids.lineOnlyVersion)
        guard let explicitlySelected = try await reopened.loadBestStored(track: track, identity: identity) else {
            throw ContractFailure("explicit line-only choice failed to load")
        }
        try require(explicitlySelected.versionID == ids.lineOnlyVersion && !explicitlySelected.document.hasTimedSpans,
                    "explicit preferred line-only version lost priority")
        print("T2 malformed payload rejected; automatic and explicit line-only selection remained valid")
    }

    private static func createBadPayloadFixture(
        fixture: Fixture,
        databaseURL: URL,
        root: URL
    ) async throws -> (timedVersion: UUID, lineOnlyVersion: UUID, timingID: UUID) {
        let repository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let timed = try await repository.save(track: fixture.track, identity: fixture.identity, document: fixture.document)
        guard let timedID = timed.versionID,
              let loaded = try await repository.loadEditableVersion(versionID: timed.versionID!, track: fixture.track, identity: fixture.identity),
              let timingID = loaded.document.timingVersionID else {
            throw ContractFailure("timed invalid-payload parent fixture failed to load")
        }
        let plainDocument = LyricsDocument(
            identity: fixture.identity,
            title: fixture.track.title,
            artist: fixture.track.artist,
            album: fixture.track.album,
            duration: fixture.track.duration,
            lines: fixture.document.lines.map { LyricLine(timestamp: $0.timestamp, originalText: $0.originalText, endTime: $0.endTime) },
            isSynchronized: true,
            source: .lrclib,
            confidence: 1,
            providerSourceID: "t2-explicit-line-only"
        )
        let plain = try await repository.save(track: fixture.track, identity: fixture.identity, document: plainDocument)
        guard let plainID = plain.versionID,
              let beforeCorruption = try await repository.loadBestStored(track: fixture.track, identity: fixture.identity) else {
            throw ContractFailure("line-only fixture failed to load")
        }
        try require(beforeCorruption.versionID == timedID, "valid fine-timing candidate did not retain automatic priority")
        return (timedID, plainID, timingID)
    }

    private static func insertLockedReading(databaseURL: URL, lyricsVersionID: UUID) throws {
        try sqliteWrite(databaseURL: databaseURL, sql: """
            INSERT INTO lyric_reading_layers(
                lyrics_version_id, line_index, kana_text, romaji_text, source,
                is_locked, created_at, updated_at
            ) VALUES ('\(lyricsVersionID.uuidString)', 0, 'こんにち', 'konnichi', 't2LegacyFixture', 1, 100, 100);
            """)
    }

    private static func createTimingFailureTrigger(databaseURL: URL) throws {
        try sqliteWrite(databaseURL: databaseURL, sql: """
            CREATE TRIGGER t2_fail_timing_attachment
            BEFORE INSERT ON lyrics_timing_versions
            BEGIN SELECT RAISE(ABORT, 'T2 injected attachment failure'); END;
            """)
    }

    private static func overwriteTimingPayload(databaseURL: URL, timingID: UUID, payload: String) throws {
        var database: OpaquePointer?
        let open = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard open == SQLITE_OK, let database else { throw ContractFailure("could not open isolated SQLite fixture for payload mutation") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "UPDATE lyrics_timing_versions SET spans_payload = ? WHERE id = ?;", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw ContractFailure("could not prepare timing payload mutation") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, payload, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, timingID.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw ContractFailure("malformed attachment fixture update failed")
        }
    }

    private static func sqliteWrite(databaseURL: URL, sql: String) throws {
        var database: OpaquePointer?
        let open = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard open == SQLITE_OK, let database else { throw ContractFailure("could not open isolated SQLite fixture for setup") }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let message { sqlite3_free(message) }
            throw ContractFailure("isolated SQLite fixture setup failed: \(detail)")
        }
    }

    private static func renderInput(_ line: LyricLine) -> [TimedTextSegment] {
        TimedTextComposer.composeSegments(
            displayText: line.originalText,
            originalText: line.originalText,
            spans: line.timedSpans ?? [],
            currentTime: 0.6
        )
    }
}
