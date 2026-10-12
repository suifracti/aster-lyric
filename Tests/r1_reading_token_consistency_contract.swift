import Foundation
import Darwin
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Test-only adapters isolate preferences and optional candidate refinement.
// All reading generation, SQLite save/load, session, and projection behavior
// under test comes from production sources.
public struct AITranslationConfiguration: Sendable {
    public init() {}
}

public struct AIReadingCandidateService: Sendable {
    public init() {}
    public func refine(
        result: ReadingGenerationResult,
        request: ReadingGenerationRequest,
        configuration: AITranslationConfiguration
    ) async throws -> ReadingGenerationResult {
        _ = request
        _ = configuration
        return result
    }
}

public final class AppSettingsStore: @unchecked Sendable {
    public let readingUserDictionary: ReadingUserDictionaryStore
    public let aiTranslationConfiguration = AITranslationConfiguration()
    public let readingPreferences: ReadingPreferences

    public init(defaults: UserDefaults, automaticPolicy: ReadingUncertaintyPolicy = .needsConfirmation) {
        readingUserDictionary = ReadingUserDictionaryStore(defaults: defaults)
        readingPreferences = ReadingPreferences(
            automaticGeneration: false,
            aiAssistedCandidate: false,
            uncertaintyPolicy: automaticPolicy
        )
    }
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = "FAIL: \(message)" }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ContractFailure(message) }
}

private final class ReadOnlyDataVersionProbe {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ContractFailure("could not open read-only data-version probe")
        }
        handle = opened
    }

    deinit { sqlite3_close(handle) }

    func dataVersion() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA data_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ContractFailure("could not prepare read-only data-version query") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContractFailure("data-version query returned no row") }
        return Int(sqlite3_column_int(statement, 0))
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    attempts: Int = 400,
    condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ContractFailure(description)
}

private func segmentedTokens(
    _ text: String,
    parts: [(surface: String, reading: String, source: ReadingTokenSource)]
) -> [ReadingToken] {
    var offset = 0
    let tokens = parts.enumerated().map { index, part in
        let start = offset
        offset += part.surface.count
        return ReadingToken(id: index, surface: part.surface, reading: part.reading,
            startOffset: start, endOffset: offset, source: part.source, confidence: 1)
    }
    precondition(offset == text.count)
    return tokens
}

private actor DelayedGeneratedSaveRepository: ReadingRepository {
    private let base: SQLiteLyricsRepository
    private var generatedSaveReached = false
    private var generatedSaveContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(base: SQLiteLyricsRepository) { self.base = base }

    func loadReadingVersions(lyricsVersionID: UUID, representationID: String?, sourceContentHash: String) async throws -> [StoredReadingVersion] {
        try await base.loadReadingVersions(lyricsVersionID: lyricsVersionID,
            representationID: representationID, sourceContentHash: sourceContentHash)
    }

    func saveReadingVersion(_ request: ReadingVersionSaveRequest) async throws -> StoredReadingVersion {
        let stored = try await base.saveReadingVersion(request)
        guard request.record.sourceKind == .generated else { return stored }
        generatedSaveReached = true
        generatedSaveContinuation?.resume()
        generatedSaveContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return stored
    }

    func adoptReadingVersion(versionID: UUID) async throws { try await base.adoptReadingVersion(versionID: versionID) }
    func markReadingLocked(versionID: UUID, locked: Bool) async throws { try await base.markReadingLocked(versionID: versionID, locked: locked) }
    func archiveReadingVersion(versionID: UUID, archived: Bool) async throws { try await base.archiveReadingVersion(versionID: versionID, archived: archived) }
    func deleteReadingVersion(versionID: UUID) async throws { try await base.deleteReadingVersion(versionID: versionID) }

    func waitForGeneratedSave() async {
        if generatedSaveReached { return }
        await withCheckedContinuation { continuation in generatedSaveContinuation = continuation }
    }

    func releaseGeneratedSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@main
struct R1ReadingTokenConsistencyContract {
    private struct ManualEditFixture {
        let track: Track
        let identity: TrackIdentity
        let sourceText: String
        let spans: [TimedTextSpan]
        let lyricsVersionID: UUID
        let sourceHash: String
        let sourceBefore: StoredEditableLyricsVersion
        let timingID: UUID
        let parentLines: [ReadingLineResult]
        let parent: ReadingVersionRecord
        let noOpVersionID: UUID
        let childVersionID: UUID
        let updatedReadingText: String
    }

    static func main() async {
        do {
            let mode = CommandLine.arguments.dropFirst().first ?? "all"
            if mode == "manual" || mode == "all" { try await runManualEditRoundTrip() }
            if mode == "race" || mode == "all" { try await runDelayedGenerationRace() }
            if mode == "click" || mode == "all" { try await runClickCorrectionRoundTrip() }
            guard ["manual", "race", "click", "all"].contains(mode) else { throw ContractFailure("unknown case \(mode)") }
            print("R1 reading/token consistency contract PASS (\(mode))")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func runManualEditRoundTrip() async throws {
        let root = try temporaryRoot("manual")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("r1-manual.sqlite3")
        let fixture = try await makeManualEditFixture(root: root, dbURL: dbURL)
        let track = fixture.track
        let identity = fixture.identity
        let sourceText = fixture.sourceText
        let spans = fixture.spans
        let lyricsVersionID = fixture.lyricsVersionID
        let sourceHash = fixture.sourceHash
        let sourceBefore = fixture.sourceBefore
        let timingID = fixture.timingID
        let parentLines = fixture.parentLines
        let parent = fixture.parent
        let noOpVersionID = fixture.noOpVersionID
        let childVersionID = fixture.childVersionID
        let updatedReadingText = fixture.updatedReadingText

        // The fixture helper has returned, releasing its production session
        // and repository actors so their SQLite handles close before reopen.
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        let readOnlyProbe = try ReadOnlyDataVersionProbe(url: dbURL)
        let dataVersionBeforeLoadAndProjection = try readOnlyProbe.dataVersion()
        guard let sourceAfter = try await reopened.loadEditableVersion(versionID: lyricsVersionID, track: track, identity: identity) else {
            throw ContractFailure("source lyrics did not survive reading edit/reopen")
        }
        let versions = try await reopened.loadReadingVersions(lyricsVersionID: lyricsVersionID, representationID: nil, sourceContentHash: sourceHash)
        guard let child = versions.first(where: { $0.record.id == childVersionID }),
              let noOp = versions.first(where: { $0.record.id == noOpVersionID }),
              let original = versions.first(where: { $0.record.id == parent.id }) else {
            throw ContractFailure("parent/no-op/edited reading versions did not all reload")
        }
        let staleTokensRemain = !child.lines[0].tokens.isEmpty
        print("R1 ROUNDTRIP: changed line retained old tokens after save/reopen = \(staleTokensRemain)")
        let timingAfter = sourceAfter.document.timingVersionID?.uuidString ?? "nil"
        let timingBefore = sourceBefore.document.timingVersionID?.uuidString ?? "nil"
        let sourceRowsUnchanged = sourceAfter.document.lines.count == sourceBefore.document.lines.count
            && zip(sourceAfter.document.lines, sourceBefore.document.lines).allSatisfy { after, before in
                after.timestamp == before.timestamp && after.endTime == before.endTime
                    && after.originalText == before.originalText && after.translationText == before.translationText
                    && after.romajiText == before.romajiText && after.kanaText == before.kanaText
                    && after.performerID == before.performerID && after.timedSpans == before.timedSpans
            }
        print("R1 SOURCE CHECK: rows=\(sourceRowsUnchanged) hash=\(sourceAfter.sourceContentHash == sourceBefore.sourceContentHash) timing=\(timingAfter)/\(timingBefore)")
        try require(!staleTokensRemain, "changed readingText was saved/reloaded with the old repeated-word userDictionary tokens")
        try require(child.lines[0].readingText == updatedReadingText, "independent reading row did not retain the edited text")
        try require(child.lines[1].tokens == parentLines[1].tokens && child.lines[1].readingText == "つきとつき",
                    "unchanged line lost its valid manual tokens")
        try require(noOp.lines[0].tokens == parentLines[0].tokens,
                    "unchanged readingText unnecessarily invalidated correct tokens")
        try require(original.lines == parentLines && original.record.id == parent.id,
                    "creating a manual child overwrote the prior reading version")
        try require(sourceRowsUnchanged && sourceAfter.sourceContentHash == sourceBefore.sourceContentHash
                    && sourceAfter.document.identity == sourceBefore.document.identity
                    && sourceAfter.document.language == sourceBefore.document.language
                    && sourceAfter.document.source == sourceBefore.document.source
                    && sourceAfter.document.providerSourceID == sourceBefore.document.providerSourceID,
                    "reading edit changed canonical lyrics/timing data or its timing attachment")
        try require(sourceAfter.document.timingVersionID == timingID && sourceAfter.document.lines[0].timedSpans == spans,
                    "reading edit changed the timing attachment or Unicode/repeated-word spans")

        let projection = ReadingProjection(lyricsVersionID: lyricsVersionID, sourceContentHash: sourceHash,
            readingVersionID: childVersionID, representationID: ReadingRepresentationID.kana.rawValue,
            sourceKind: child.record.sourceKind, lines: child.lines, isNoSelection: false)
        let projected = projection.applying(to: sourceAfter.document.lines)

        let reopenedSuite = "r1-reopened-session-\(UUID().uuidString)"
        let reopenedDefaults = UserDefaults(suiteName: reopenedSuite)!
        defer { reopenedDefaults.removePersistentDomain(forName: reopenedSuite) }
        let reopenedSettings = AppSettingsStore(defaults: reopenedDefaults)
        let reopenedSession = await MainActor.run {
            ReadingSessionController(repository: reopened, settings: reopenedSettings)
        }
        await MainActor.run {
            reopenedSession.synchronize(lyricsVersionID: lyricsVersionID, sourceContentHash: sourceHash,
                lines: sourceAfter.document.lines, language: sourceAfter.document.language,
                trackStableKey: identity.stableKey, artistDisplay: track.artist)
        }
        try await waitUntil("a new session did not restore the edited current reading version") {
            reopenedSession.selectedVersion?.record.id == childVersionID
        }
        let reopenedSessionProjection = await MainActor.run {
            reopenedSession.project(onto: sourceAfter.document.lines)
        }
        let dataVersionAfterLoadAndProjection = try readOnlyProbe.dataVersion()
        try require(dataVersionAfterLoadAndProjection == dataVersionBeforeLoadAndProjection,
                    "reading load/projection performed a SQLite write")
        try require(child.record.isCurrent && reopenedSessionProjection[0].kanaText == updatedReadingText,
                    "database/session reopen did not restore the edited current version and its projection")
        try require(projected[0].kanaText == updatedReadingText, "independent reading line did not use the saved new readingText")
        try require(projected[0].romajiText == JapaneseRomanizer.romanizeConfirmedKana(updatedReadingText),
                    "romaji did not derive from the saved new readingText")
        try require(projected[0].rubyTokens == nil,
                    "inline Ruby still exposed old tokens after a whole-line partial edit without a provable map")
        try require(projected[1].rubyTokens?.map { $0.surface + ":" + ($0.ruby ?? "nil") } == ["月:つき", "と:nil", "月:つき"],
                    "untouched duplicate userDictionary token mapping was not preserved")

        let badVersionID = UUID()
        let badNow = Date()
        let badRecord = ReadingVersionRecord(id: badVersionID, lyricsVersionID: lyricsVersionID, sourceContentHash: sourceHash,
            engineID: ReadingEngineID.japaneseContextual.rawValue, representationID: ReadingRepresentationID.kana.rawValue,
            sourceKind: .manualEdit, language: .japanese, createdAt: badNow, updatedAt: badNow,
            isMachineGenerated: false, isManuallyEdited: true, isCurrent: false, isLocked: false, isArchived: false,
            parentVersionID: parent.id, confidence: 1, warningMetadata: [], contextHash: "r1-invalid-token")
        let mismatchedLine = ReadingLineResult(lineIndex: 0, originalText: sourceText, readingText: updatedReadingText,
            language: .japanese, tokens: parentLines[0].tokens, confidence: 1)
        do {
            _ = try await reopened.saveReadingVersion(ReadingVersionSaveRequest(record: badRecord,
                lines: [mismatchedLine, parentLines[1]]))
            throw ContractFailure("repository accepted a manual kana line with conflicting readingText and tokens")
        } catch let error as ReadingRepositoryError {
            guard case .invalidLines = error else { throw error }
        }
        let badGeneratedVersionID = UUID()
        let badGeneratedRecord = ReadingVersionRecord(id: badGeneratedVersionID, lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceHash, engineID: parent.engineID, representationID: parent.representationID,
            sourceKind: .generated, language: parent.language, createdAt: badNow, updatedAt: badNow,
            isMachineGenerated: true, isManuallyEdited: false, isCurrent: false, isLocked: false, isArchived: false,
            parentVersionID: parent.id, confidence: 0.9, warningMetadata: [], contextHash: "r1-invalid-generated-token")
        do {
            _ = try await reopened.saveReadingVersion(ReadingVersionSaveRequest(record: badGeneratedRecord,
                lines: [mismatchedLine, parentLines[1]]))
            throw ContractFailure("repository accepted a generated kana line with conflicting readingText and tokens")
        } catch let error as ReadingRepositoryError {
            guard case .invalidLines = error else { throw error }
        }
        let invalidRangeVersionID = UUID()
        let first = parentLines[0].tokens[0]
        let invalidRangeToken = ReadingToken(id: first.id, surface: first.surface, reading: first.reading,
            startOffset: first.startOffset, endOffset: first.endOffset + 1, source: first.source, confidence: first.confidence)
        let invalidRangeLine = parentLines[0].replacingTokens([invalidRangeToken] + Array(parentLines[0].tokens.dropFirst()))
        let invalidRangeRecord = ReadingVersionRecord(id: invalidRangeVersionID, lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceHash, engineID: parent.engineID, representationID: parent.representationID,
            sourceKind: .manualEdit, language: .japanese, createdAt: badNow, updatedAt: badNow,
            isMachineGenerated: false, isManuallyEdited: true, isCurrent: false, isLocked: false, isArchived: false,
            parentVersionID: parent.id, confidence: 1, warningMetadata: [], contextHash: "r1-invalid-range")
        do {
            _ = try await reopened.saveReadingVersion(ReadingVersionSaveRequest(record: invalidRangeRecord,
                lines: [invalidRangeLine, parentLines[1]]))
            throw ContractFailure("repository accepted a manual token range outside Swift Character boundaries")
        } catch let error as ReadingRepositoryError {
            guard case .invalidLines = error else { throw error }
        }
        let afterRejectedWrites = try await reopened.loadReadingVersions(lyricsVersionID: lyricsVersionID,
            representationID: nil, sourceContentHash: sourceHash)
        try require(!afterRejectedWrites.contains(where: {
            $0.record.id == badVersionID || $0.record.id == badGeneratedVersionID || $0.record.id == invalidRangeVersionID
        }),
                    "rejected inconsistent token records left readable partial versions")

        // The edit creates an immutable child. The prior manual version remains
        // selectable and can still become the persisted current version again.
        await MainActor.run { reopenedSession.select(versionID: parent.id) }
        try await waitUntil("the production session did not reselect the prior reading version") {
            reopenedSession.selectedVersion?.record.id == parent.id
        }
        var restoredParent = false
        for _ in 0..<100 {
            let versionsAfterReselect = try await reopened.loadReadingVersions(
                lyricsVersionID: lyricsVersionID, representationID: nil, sourceContentHash: sourceHash)
            if versionsAfterReselect.contains(where: { $0.record.id == parent.id && $0.record.isCurrent }) {
                restoredParent = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(restoredParent, "prior reading version was selectable in memory but did not persist as current")
    }

    private static func makeManualEditFixture(root: URL, dbURL: URL) async throws -> ManualEditFixture {
        let track = Track(title: "R1 duplicate token fixture", artist: "Core Integrity", album: "Fixture", duration: 30, spotifyId: "r1-manual")
        let identity = TrackIdentity(track: track)
        let sourceText = "身体と身体👩‍🎤か\u{3099}"
        let spans = [
            TimedTextSpan(id: 0, text: "身体", startTime: 0, endTime: 0.5, utf16Start: 0, utf16Length: 2, granularity: .word),
            TimedTextSpan(id: 1, text: "と", startTime: 0.5, endTime: 1, utf16Start: 2, utf16Length: 1, granularity: .word),
            TimedTextSpan(id: 2, text: "身体", startTime: 1, endTime: 1.5, utf16Start: 3, utf16Length: 2, granularity: .word),
            TimedTextSpan(id: 3, text: "👩‍🎤", startTime: 1.5, endTime: 2, utf16Start: 5, utf16Length: 5, granularity: .word),
            TimedTextSpan(id: 4, text: "か\u{3099}", startTime: 2, endTime: 2.5, utf16Start: 10, utf16Length: 2, granularity: .word)
        ]
        let sourceDocument = LyricsDocument(
            identity: identity, title: track.title, artist: track.artist, album: track.album,
            duration: track.duration,
            lines: [
                LyricLine(timestamp: 0, originalText: sourceText, endTime: 2.5,
                    translationText: "fixture translation", kanaText: "provider kana", performerID: "v1", timedSpans: spans),
                LyricLine(timestamp: 4, originalText: "月と月", endTime: 7,
                    performerID: "v2", timedSpans: [TimedTextSpan(id: 0, text: "月", startTime: 4, endTime: 4.5, utf16Start: 0, utf16Length: 1, granularity: .word)])
            ],
            isSynchronized: true, source: .amll, confidence: 1, providerSourceID: "r1-ttml-yrc-fixture", language: "ja"
        )
        let repository = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let lyricsSave = try await repository.save(track: track, identity: identity, document: sourceDocument)
        guard let lyricsVersionID = lyricsSave.versionID, let sourceHash = lyricsSave.sourceContentHash,
              let sourceBefore = try await repository.loadEditableVersion(versionID: lyricsVersionID, track: track, identity: identity),
              let timingID = sourceBefore.document.timingVersionID else {
            throw ContractFailure("source timing fixture failed to load with an immutable timing attachment")
        }

        let oldReadingText = "しんたいとしんたい👩‍🎤が"
        let unchangedReadingText = "つきとつき"
        let parentLines = [
            ReadingLineResult(lineIndex: 0, originalText: sourceText, readingText: oldReadingText, language: .japanese,
                tokens: segmentedTokens(sourceText, parts: [
                    ("身体", "しんたい", .userDictionary), ("と", "と", .provider),
                    ("身体", "しんたい", .userDictionary), ("👩‍🎤", "👩‍🎤", .provider), ("か\u{3099}", "が", .provider)
                ]), confidence: 1),
            ReadingLineResult(lineIndex: 1, originalText: "月と月", readingText: unchangedReadingText, language: .japanese,
                tokens: segmentedTokens("月と月", parts: [("月", "つき", .userDictionary), ("と", "と", .provider), ("月", "つき", .userDictionary)]), confidence: 1)
        ]
        let now = Date()
        let parent = ReadingVersionRecord(id: UUID(), lyricsVersionID: lyricsVersionID, sourceContentHash: sourceHash,
            engineID: ReadingEngineID.japaneseContextual.rawValue, representationID: ReadingRepresentationID.kana.rawValue,
            sourceKind: .manualEdit, language: .japanese, createdAt: now, updatedAt: now,
            isMachineGenerated: false, isManuallyEdited: true, isCurrent: false, isLocked: false, isArchived: false,
            parentVersionID: nil, confidence: 1, warningMetadata: [], contextHash: "r1-parent")
        let storedParent = try await repository.saveReadingVersion(ReadingVersionSaveRequest(record: parent, lines: parentLines))
        try await repository.adoptReadingVersion(versionID: parent.id)

        let suite = "r1-reading-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let session = await MainActor.run { ReadingSessionController(repository: repository, settings: settings) }
        await MainActor.run {
            session.synchronize(lyricsVersionID: lyricsVersionID, sourceContentHash: sourceHash,
                lines: sourceBefore.document.lines, language: sourceBefore.document.language,
                trackStableKey: identity.stableKey, artistDisplay: track.artist)
        }
        try await waitUntil("parent reading version did not load into the production session") {
            session.selectedVersion?.record.id == parent.id
        }

        // Exact no-op editor save: the unchanged manually corrected row must retain its tokens.
        let noOpSubmission = ReadingManualEdit.lines(from: storedParent.lines, drafts: [oldReadingText, unchangedReadingText])
        try require(noOpSubmission[0].tokens == parentLines[0].tokens,
                    "production editor payload cleared tokens without a readingText change")
        try await session.saveManualEdit(storedParent, readingLines: noOpSubmission)
        try await waitUntil("no-op manual reading save did not select its persisted child") {
            session.selectedVersion?.record.id != parent.id
        }
        guard let noOpVersionID = await MainActor.run(body: { session.selectedVersion?.record.id }) else {
            throw ContractFailure("no-op child selection was missing")
        }

        // The first repeated word changes while the second does not. No positional map exists,
        // so the production editor/session boundary must invalidate this row's old tokens.
        let updatedReadingText = "からだとしんたい👩‍🎤が"
        let changedSubmission = ReadingManualEdit.lines(from: storedParent.lines, drafts: [updatedReadingText, unchangedReadingText])
        try require(changedSubmission[0].tokens.isEmpty && changedSubmission[1].tokens == parentLines[1].tokens,
                    "production editor payload did not invalidate only the changed line")
        try await session.saveManualEdit(storedParent, readingLines: changedSubmission)
        try await waitUntil("changed manual reading save did not select its persisted child") {
            session.selectedVersion?.record.id != noOpVersionID
                && session.selectedVersion?.record.sourceKind == .manualEdit
        }
        guard let childVersionID = await MainActor.run(body: { session.selectedVersion?.record.id }) else {
            throw ContractFailure("edited child selection was missing")
        }

        var rejectedEditorLines = changedSubmission
        rejectedEditorLines[0] = ReadingLineResult(lineIndex: 0, originalText: "wrong source surface",
            readingText: updatedReadingText, language: .japanese, tokens: [], confidence: 1)
        do {
            try await session.saveManualEdit(storedParent, readingLines: rejectedEditorLines)
            throw ContractFailure("session reported success for a repository-rejected whole-line save")
        } catch let error as ReadingRepositoryError {
            guard case .invalidLines = error else { throw error }
        }
        let failedSaveKeptSelection = await MainActor.run {
            session.selectedVersion?.record.id == childVersionID && session.message.contains("保存失败")
        }
        try require(failedSaveKeptSelection,
                    "failed manual save changed the selected version or hid its error")

        // Recreate a persisted pre-R1 row after the production save: old builds
        // stored the stale token JSON beside the edited text. The production
        // loader must preserve the version/text while disabling that token map.
        try injectTokens(dbURL: dbURL, versionID: childVersionID, lineIndex: 0, tokens: parentLines[0].tokens)

        return ManualEditFixture(track: track, identity: identity, sourceText: sourceText, spans: spans,
            lyricsVersionID: lyricsVersionID, sourceHash: sourceHash, sourceBefore: sourceBefore, timingID: timingID,
            parentLines: parentLines, parent: parent,
            noOpVersionID: noOpVersionID, childVersionID: childVersionID, updatedReadingText: updatedReadingText)
    }

    private static func runDelayedGenerationRace() async throws {
        let root = try temporaryRoot("race")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("r1-race.sqlite3")
        let base = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await base.prepare()
        let track = Track(title: "R1 async generation fixture", artist: "Core Integrity", album: "Fixture", duration: 20, spotifyId: "r1-race")
        let identity = TrackIdentity(track: track)
        let text = "あいうえお"
        let document = LyricsDocument(identity: identity, lines: [LyricLine(timestamp: 0, originalText: text)],
            isSynchronized: true, source: .amll, confidence: 1, providerSourceID: "r1-race-source", language: "ja")
        let lyrics = try await base.save(track: track, identity: identity, document: document)
        guard let lyricsID = lyrics.versionID, let hash = lyrics.sourceContentHash,
              let source = try await base.loadEditableVersion(versionID: lyrics.versionID!, track: track, identity: identity) else {
            throw ContractFailure("async race source fixture failed to load")
        }
        let parentNow = Date()
        let parentID = UUID()
        let parentLine = ReadingLineResult(lineIndex: 0, originalText: text, readingText: text, language: .japanese,
            tokens: segmentedTokens(text, parts: Array(text).map { (String($0), String($0), .provider) }), confidence: 1)
        let parentRecord = ReadingVersionRecord(id: parentID, lyricsVersionID: lyricsID, sourceContentHash: hash,
            engineID: ReadingEngineID.japaneseContextual.rawValue, representationID: ReadingRepresentationID.kana.rawValue,
            sourceKind: .manualEdit, language: .japanese, createdAt: parentNow, updatedAt: parentNow,
            isMachineGenerated: false, isManuallyEdited: true, isCurrent: false, isLocked: false, isArchived: false,
            parentVersionID: nil, confidence: 1, warningMetadata: [], contextHash: "r1-race-parent")
        let parent = try await base.saveReadingVersion(ReadingVersionSaveRequest(record: parentRecord, lines: [parentLine]))
        try await base.adoptReadingVersion(versionID: parentID)

        let gated = DelayedGeneratedSaveRepository(base: base)
        let suite = "r1-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults, automaticPolicy: .allowLocalHighConfidence)
        let session = await MainActor.run { ReadingSessionController(repository: gated, settings: settings) }
        await MainActor.run {
            session.synchronize(lyricsVersionID: lyricsID, sourceContentHash: hash,
                lines: source.document.lines, language: "ja", trackStableKey: identity.stableKey, artistDisplay: track.artist)
        }
        try await waitUntil("race parent reading version did not load") { session.selectedVersion?.record.id == parentID }

        await MainActor.run { session.generateCurrentReading(representationID: .kana) }
        await gated.waitForGeneratedSave()
        let newText = "かきくけこ"
        let editTask = Task { @MainActor in
            try await session.saveManualEdit(parent, readingLines: ReadingManualEdit.lines(from: [parentLine], drafts: [newText]))
        }
        // Let the manual request cancel/invalidate the delayed generated operation before releasing it.
        try await Task.sleep(nanoseconds: 150_000_000)
        await gated.releaseGeneratedSave()
        try await editTask.value
        try await waitUntil("manual edit did not become the live selection after the generated callback") {
            session.selectedVersion?.record.id != parentID && session.selectedVersion?.lines.first?.readingText == newText
        }

        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        let versions = try await reopened.loadReadingVersions(lyricsVersionID: lyricsID, representationID: nil, sourceContentHash: hash)
        guard let current = versions.first(where: { $0.record.isCurrent }) else {
            throw ContractFailure("no persisted current reading version after delayed callback")
        }
        print("R1 RACE: persisted current after delayed generation = \(current.record.sourceKind.rawValue), reading=\(current.lines.first?.readingText ?? "nil")")
        try require(current.record.sourceKind == .manualEdit && current.lines.first?.readingText == newText,
                    "delayed generated result adopted over a newer manual whole-line edit")
    }

    private static func runClickCorrectionRoundTrip() async throws {
        let root = try temporaryRoot("click")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("r1-click.sqlite3")
        let repository = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let track = Track(title: "R1 click correction fixture", artist: "Core Integrity", album: "Fixture", duration: 18, spotifyId: "r1-click")
        let identity = TrackIdentity(track: track)
        let line = LyricLine(timestamp: 0, originalText: "身体にしてあげよう", kanaText: "しんたいにしてあげよう")
        let document = LyricsDocument(identity: identity, lines: [line], isSynchronized: true,
            source: .amll, confidence: 1, providerSourceID: "r1-click-source", language: "ja")
        let lyrics = try await repository.save(track: track, identity: identity, document: document)
        guard let lyricsID = lyrics.versionID, let hash = lyrics.sourceContentHash else {
            throw ContractFailure("click correction source fixture failed to save")
        }
        let suite = "r1-click-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let session = await MainActor.run { ReadingSessionController(repository: repository, settings: settings) }
        await MainActor.run {
            session.synchronize(lyricsVersionID: lyricsID, sourceContentHash: hash, lines: [line],
                language: "ja", trackStableKey: identity.stableKey, artistDisplay: track.artist)
        }
        try await session.correctRuby(surface: "身体", reading: "からだ", trackKey: identity.stableKey,
            lyricsVersionID: lyricsID, visibleLines: [line], expectedReadingVersionID: nil)
        guard let selectedID = await MainActor.run(body: { session.selectedVersion?.record.id }) else {
            throw ContractFailure("click correction did not publish the adopted reading version")
        }
        let reopened = SQLiteLyricsRepository(databaseURL: dbURL, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        let stored = try await reopened.loadReadingVersions(lyricsVersionID: lyricsID,
            representationID: ReadingRepresentationID.kana.rawValue, sourceContentHash: hash)
        guard let selected = stored.first(where: { $0.record.id == selectedID }) else {
            throw ContractFailure("click-correction child failed to reload")
        }
        try require(selected.lines[0].readingText == "からだにしてあげよう"
                    && selected.lines[0].hasConsistentKanaTokenProjection
                    && selected.lines[0].tokens.contains(where: { $0.surface == "身体" && $0.reading == "からだ" && $0.source == .userDictionary }),
                    "word-click correction no longer persists a consistent song-scoped token map")
        let projected = ReadingProjection(lyricsVersionID: lyricsID, sourceContentHash: hash,
            readingVersionID: selectedID, representationID: ReadingRepresentationID.kana.rawValue,
            sourceKind: selected.record.sourceKind, lines: selected.lines, isNoSelection: false).applying(to: [line])[0]
        try require(projected.kanaText == "からだにしてあげよう"
                    && projected.rubyTokens?.contains(where: { $0.surface == "身体" && $0.ruby == "からだ" }) == true
                    && projected.romajiText?.contains("karada") == true,
                    "persisted click correction did not reach inline Ruby, independent text, and romaji")
        let remembered = ReadingUserDictionaryStore(defaults: defaults).load()
        try require(remembered.contains(where: { $0.surface == "身体" && $0.reading == "からだ" && $0.trackStableKey == identity.stableKey }),
                    "word-click correction did not remember its exact song-scoped dictionary entry")
    }

    private static func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifyLyrics-R1-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func injectTokens(dbURL: URL, versionID: UUID, lineIndex: Int, tokens: [ReadingToken]) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ContractFailure("could not seed an isolated historical token mismatch")
        }
        defer { sqlite3_close(database) }
        let prepared = "UPDATE reading_lines SET tokens_json = ? WHERE reading_version_id = ? AND line_index = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, prepared, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContractFailure("could not prepare isolated historical token row")
        }
        defer { sqlite3_finalize(statement) }
        let json = try JSONEncoder().encode(tokens)
        guard let jsonText = String(data: json, encoding: .utf8) else { throw ContractFailure("token fixture was not UTF-8") }
        sqlite3_bind_text(statement, 1, jsonText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, versionID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(lineIndex))
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw ContractFailure("could not seed the historical inconsistent token row")
        }
    }
}
