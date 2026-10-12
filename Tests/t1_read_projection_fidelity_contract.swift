import Foundation
import Darwin
import SQLite3

// The real editor controller references this store only on its save path.
// This contract does not save or read app settings; isolate the singleton so
// compiling the production controller cannot touch the user's preferences.
public final class AppSettingsStore: @unchecked Sendable {
    public static let shared = AppSettingsStore()
    public let translationProfiles: TranslationProfileStore

    private init() {
        let defaults = UserDefaults(suiteName: "t1-read-projection-\(UUID().uuidString)")!
        translationProfiles = TranslationProfileStore(defaults: defaults)
    }
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = "FAIL: \(message)" }
}

private struct InertLyricsProvider: LyricsProvider {
    let name = "t1-inert-provider"

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .noLyrics
    }
}

private struct ReflectedField<Value> {
    let exists: Bool
    let value: Value?
}

private func reflectedOptional<Value>(_ value: Any, field name: String, as type: Value.Type) -> ReflectedField<Value> {
    guard let child = Mirror(reflecting: value).children.first(where: { $0.label == name }) else {
        return ReflectedField(exists: false, value: nil)
    }
    let optional = Mirror(reflecting: child.value)
    if optional.displayStyle == .optional {
        return ReflectedField(exists: true, value: optional.children.first?.value as? Value)
    }
    return ReflectedField(exists: true, value: child.value as? Value)
}

private func reflectedValue<Value>(_ value: Any, field name: String, as type: Value.Type) -> Value? {
    Mirror(reflecting: value).children.first(where: { $0.label == name })?.value as? Value
}

private func waitUntil(
    _ description: String,
    attempts: Int = 200,
    condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ContractFailure(description)
}

private struct Snapshot: Equatable {
    let dataVersion: Int
    let tables: [String: [[String]]]
}

private final class ReadOnlyDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error \(result)"
            if let opened { sqlite3_close(opened) }
            throw ContractFailure("could not open isolated database snapshot: \(message)")
        }
        handle = opened
    }

    deinit { sqlite3_close(handle) }

    func snapshot() throws -> Snapshot {
        let dataVersion = try scalarInt("PRAGMA data_version;")
        let names = try rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        var tables: [String: [[String]]] = [:]
        for row in names {
            guard let name = row.first else { continue }
            let columns = try rows("SELECT * FROM \"\(name)\" LIMIT 0;").first?.count ?? columnCount("\(name)")
            guard columns > 0 else {
                tables[name] = []
                continue
            }
            let order = (1...columns).map(String.init).joined(separator: ", ")
            tables[name] = try rows("SELECT * FROM \"\(name)\" ORDER BY \(order);")
        }
        return Snapshot(dataVersion: dataVersion, tables: tables)
    }

    private func columnCount(_ table: String) throws -> Int {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, "SELECT * FROM \"\(table)\" LIMIT 0;", -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error("prepare column count") }
        defer { sqlite3_finalize(statement) }
        return Int(sqlite3_column_count(statement))
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let result = try rows(sql)
        guard let value = result.first?.first.flatMap(Int.init) else {
            throw ContractFailure("query did not return an integer: \(sql)")
        }
        return value
    }

    private func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error("prepare query") }
        defer { sqlite3_finalize(statement) }
        var output: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return output }
            guard step == SQLITE_ROW else { throw error("step query") }
            output.append((0..<sqlite3_column_count(statement)).map { index in
                if sqlite3_column_type(statement, index) == SQLITE_NULL { return "<NULL>" }
                if sqlite3_column_type(statement, index) == SQLITE_BLOB {
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return "" }
                    return UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: count)
                        .map { String(format: "%02x", $0) }
                        .joined()
                }
                guard let text = sqlite3_column_text(statement, index) else { return "" }
                return String(cString: text)
            })
        }
    }

    private func error(_ operation: String) -> ContractFailure {
        ContractFailure("\(operation) failed: \(String(cString: sqlite3_errmsg(handle)))")
    }
}

@main
struct T1ReadProjectionFidelityContract {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func run() async throws {
        let testCase = CommandLine.arguments.dropFirst().first ?? "all"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotifyLyrics-T1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("t1-fixture.sqlite3")
        let repository = SQLiteLyricsRepository(
            databaseURL: databaseURL,
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance", isDirectory: true)
        )
        try await repository.prepare()
        let track = Track(
            title: "T1 read projection fixture",
            artist: "Projection Test",
            album: "Core Integrity",
            duration: 120,
            spotifyId: "t1-projection-fixture"
        )
        let identity = TrackIdentity(track: track)

        if testCase == "partial" || testCase == "all" {
            try await runPartialTimelineCase(repository: repository, track: track, identity: identity, root: root)
        }
        if testCase == "legacy" || testCase == "all" {
            try await runLegacyReadingCase(repository: repository, track: track, identity: identity, root: root)
        }
        if testCase != "partial" && testCase != "legacy" && testCase != "all" {
            throw ContractFailure("unknown case \(testCase)")
        }
        print("T1 read/projection fidelity contract passed (\(testCase))")
    }

    private static func runPartialTimelineCase(
        repository: SQLiteLyricsRepository,
        track: Track,
        identity: TrackIdentity,
        root: URL
    ) async throws {
        let source = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [
                LyricLine(timestamp: 0, originalText: "Explicit zero", endTime: 2),
                LyricLine(timestamp: 0, originalText: "Unset placeholder")
            ],
            isSynchronized: false,
            source: .amll,
            confidence: 1,
            providerSourceID: "t1-partial-zero",
            explicitlyTimedLineIndices: [0]
        )
        let saved = try await repository.save(track: track, identity: identity, document: source)
        guard let versionID = saved.versionID,
              let loaded = try await repository.loadEditableVersion(versionID: versionID, track: track, identity: identity) else {
            throw ContractFailure("partial fixture failed to load from SQLite")
        }
        guard loaded.document.explicitlyTimedLineIndices == Set([0]),
              loaded.document.lineHasExplicitTiming(0),
              !loaded.document.lineHasExplicitTiming(1),
              loaded.document.language == "und",
              loaded.document.timingVersionID == nil,
              loaded.document.lines[0].performerID == nil,
              loaded.document.lines[0].timedSpans == nil,
              loaded.document.lines[0].timestamp == 0,
              loaded.document.lines[1].timestamp == 0 else {
            throw ContractFailure("SQLite did not preserve explicit zero versus unset placeholder")
        }

        let noMaskSource = LyricsDocument(
            identity: identity,
            lines: [LyricLine(timestamp: 0, originalText: "Legacy unset time")],
            isSynchronized: false,
            source: .lrclib,
            providerSourceID: "t1-no-mask"
        )
        let noMaskSave = try await repository.save(track: track, identity: identity, document: noMaskSource)
        guard let noMaskID = noMaskSave.versionID,
              let noMaskLoaded = try await repository.loadEditableVersion(versionID: noMaskID, track: track, identity: identity),
              noMaskLoaded.document.explicitlyTimedLineIndices == nil else {
            throw ContractFailure("SQLite did not preserve the absent partial-timeline mask")
        }

        let session = await makeSession(repository: repository, track: track, identity: identity)
        await MainActor.run {
            session.adoptPersisted(document: loaded.document, versionID: versionID, sourceContentHash: saved.sourceContentHash ?? "")
        }
        try await assertPartialSession(session, expectedMask: Set([0]), expectedHash: saved.sourceContentHash ?? "")

        let editor = await makeEditor(
            repository: repository,
            track: track,
            identity: identity,
            document: try await activeDocument(from: session),
            versionID: versionID,
            sourceHash: saved.sourceContentHash ?? "",
            selectedTranslation: nil
        )
        try await waitUntil("partial editor versions did not load") { editor.availableVersions.count == 2 }
        try await assertPartialDraft(editor, expectedMask: Set([0]), expectedHash: saved.sourceContentHash ?? "")

        let noMaskSession = await makeSession(repository: repository, track: track, identity: identity)
        await MainActor.run {
            noMaskSession.adoptPersisted(document: noMaskLoaded.document, versionID: noMaskID, sourceContentHash: noMaskSave.sourceContentHash ?? "")
        }
        try await assertReflectedMask(noMaskSession, expected: nil)
        try await MainActor.run {
            guard let document = noMaskSession.activeDocument,
                  !document.lineHasExplicitTiming(0),
                  noMaskSession.activeSourceContentHash == (noMaskSave.sourceContentHash ?? "") else {
                throw ContractFailure("session changed absent-mask timeline semantics or source identity")
            }
        }
        let noMaskEditor = await makeEditor(
            repository: repository,
            track: track,
            identity: identity,
            document: try await activeDocument(from: noMaskSession),
            versionID: noMaskID,
            sourceHash: noMaskSave.sourceContentHash ?? "",
            selectedTranslation: nil
        )
        try await waitUntil("no-mask editor versions did not load") { noMaskEditor.availableVersions.count == 2 }
        try await assertDraftMask(noMaskEditor, expected: nil, expectedSync: false)

        // The current SQLite schema stores which rows have times, but not the
        // distinction between an in-memory nil mask and an explicit empty Set.
        // Exercise that model-level distinction through the actual session and
        // draft copies without inventing a schema migration.
        let emptyMaskDocument = LyricsDocument(
            identity: identity,
            lines: [LyricLine(timestamp: 0, originalText: "No explicit rows")],
            isSynchronized: false,
            source: .manualImport,
            explicitlyTimedLineIndices: []
        )
        await MainActor.run {
            session.adoptPersisted(document: emptyMaskDocument, versionID: versionID, sourceContentHash: saved.sourceContentHash ?? "")
        }
        try await assertReflectedMask(session, expected: [])
        let emptyMaskEditor = await makeEditor(
            repository: repository,
            track: track,
            identity: identity,
            document: try await activeDocument(from: session),
            versionID: versionID,
            sourceHash: saved.sourceContentHash ?? "",
            selectedTranslation: nil
        )
        try await waitUntil("empty-mask editor versions did not load") { emptyMaskEditor.availableVersions.count == 2 }
        try await assertDraftMask(emptyMaskEditor, expected: [], expectedSync: false)

        let nilMaskDocument = LyricsDocument(
            identity: identity,
            lines: [LyricLine(timestamp: 0, originalText: "Legacy no-mask row")],
            isSynchronized: false,
            source: .manualImport,
            explicitlyTimedLineIndices: nil
        )
        await MainActor.run {
            session.adoptPersisted(document: nilMaskDocument, versionID: versionID, sourceContentHash: saved.sourceContentHash ?? "")
        }
        try await assertReflectedMask(session, expected: nil)
        let nilMaskEditor = await makeEditor(
            repository: repository,
            track: track,
            identity: identity,
            document: try await activeDocument(from: session),
            versionID: versionID,
            sourceHash: saved.sourceContentHash ?? "",
            selectedTranslation: nil
        )
        try await waitUntil("nil-mask editor versions did not load") { nilMaskEditor.availableVersions.count == 2 }
        try await assertDraftMask(nilMaskEditor, expected: nil, expectedSync: false)

        _ = root
    }

    private static func runLegacyReadingCase(
        repository: SQLiteLyricsRepository,
        track: Track,
        identity: TrackIdentity,
        root: URL
    ) async throws {
        let partial = LyricsDocument(
            identity: identity,
            lines: [LyricLine(timestamp: 0, originalText: "plain", endTime: 2)],
            isSynchronized: false,
            source: .lrclib,
            providerSourceID: "t1-untimed-version"
        )
        let partialSave = try await repository.save(track: track, identity: identity, document: partial)
        guard let partialID = partialSave.versionID else { throw ContractFailure("untimed switch fixture was not stored") }

        let timingID = UUID()
        let spans = [
            TimedTextSpan(id: 0, text: "今日", startTime: 0, endTime: 1, utf16Start: 0, utf16Length: 2, granularity: .word),
            TimedTextSpan(id: 1, text: "🌸", startTime: 1, endTime: 2, utf16Start: 2, utf16Length: 2, granularity: .word),
            TimedTextSpan(id: 2, text: "今日", startTime: 2, endTime: 4, utf16Start: 4, utf16Length: 2, granularity: .word)
        ]
        let originalText = "今日🌸今日"
        let source = LyricsDocument(
            identity: identity,
            title: "Stored title metadata",
            artist: "Stored artist metadata",
            album: "Stored album metadata",
            duration: 120,
            lines: [
                LyricLine(
                    timestamp: 0,
                    originalText: originalText,
                    endTime: 4,
                    translationText: "compatibility line translation",
                    romajiText: "kyou",
                    kanaText: "きょう",
                    performerID: "v2",
                    timedSpans: spans
                )
            ],
            isSynchronized: true,
            source: .neteaseExperimental,
            confidence: 1,
            providerSourceID: "t1-authoritative-provider-source",
            spotifyTrackID: "t1-source-evidence",
            isrc: "T1-ISRC-FIXTURE",
            language: "ja",
            timingVersionID: timingID
        )
        let saved = try await repository.save(track: track, identity: identity, document: source)
        guard let versionID = saved.versionID, let sourceHash = saved.sourceContentHash else {
            throw ContractFailure("timed source fixture was not stored with canonical identity")
        }
        try insertLegacyLockedReading(
            databaseURL: repository.databaseURL,
            lyricsVersionID: versionID,
            kanaText: "こんにち",
            romajiText: "konnichi"
        )
        _ = try await repository.saveManualEdit(LyricsEditSaveRequest(
            track: track,
            identity: identity,
            sourceVersionID: versionID,
            sourceContentHash: sourceHash,
            document: source,
            createLyricsVersion: false,
            translation: ManualTranslationEdit(targetLanguage: "zh-Hans", lines: ["同一版本译文"])
        ))
        let initialTranslations = try await repository.loadTranslationVersions(
            lyricsVersionID: versionID,
            targetLanguage: "zh-Hans",
            sourceContentHash: sourceHash
        )
        guard let translation = initialTranslations.first(where: {
            $0.lines.first?.translatedText == "同一版本译文"
        }) else { throw ContractFailure("translation fixture did not load") }
        let alternateTranslation = try await repository.saveTranslation(
            lyricsVersionID: versionID,
            sourceContentHash: sourceHash,
            originalLines: [originalText],
            draft: AITranslationDraft(
                lines: [AITranslationLine(index: 0, translation: "切换后的译文")],
                targetLanguage: "zh-Hans",
                model: "T1 fixture",
                baseURLHost: "fixture.invalid",
                promptHash: "t1-alternate-translation",
                sourceContentHash: sourceHash,
                isMachineGenerated: false,
                isManuallyEdited: true
            ),
            forceNewVersion: true
        )
        let translations = try await repository.loadTranslationVersions(
            lyricsVersionID: versionID,
            targetLanguage: "zh-Hans",
            sourceContentHash: sourceHash
        )
        guard translations.count == 2,
              translations.contains(where: { $0.record.id == alternateTranslation.record.id }) else {
            throw ContractFailure("alternate same-version translation fixture did not load")
        }

        let observer = try ReadOnlyDatabase(url: repository.databaseURL)
        let beforeRead = try observer.snapshot()
        guard let loaded = try await repository.loadEditableVersion(versionID: versionID, track: track, identity: identity) else {
            throw ContractFailure("timed version failed to load")
        }
        try assertLockedOverlay(
            loaded.document,
            track: track,
            identity: identity,
            expectedSpans: spans,
            timingID: timingID
        )
        guard loaded.lines[0].originalText == originalText,
              loaded.lines[0].kanaText == "きょう",
              loaded.lines[0].romajiText == "kyou",
              loaded.sourceContentHash == sourceHash,
              LyricsPersistenceMapper.sourceContentHash(document: loaded.document) != sourceHash else {
            throw ContractFailure("display reading was used as the canonical source or rewrote stored original reading")
        }

        let session = await makeSession(repository: repository, track: track, identity: identity)
        await MainActor.run {
            session.adoptPersisted(document: loaded.document, versionID: versionID, sourceContentHash: sourceHash)
        }
        try await assertSessionOverlay(
            session,
            track: track,
            identity: identity,
            sourceHash: sourceHash,
            expectedSpans: spans,
            timingID: timingID
        )

        // Repeat repository loads and switch session identity through the
        // untimed sibling version before entering the editor draft.
        _ = try await repository.loadEditableVersion(versionID: versionID, track: track, identity: identity)
        guard let untimed = try await repository.loadEditableVersion(versionID: partialID, track: track, identity: identity) else {
            throw ContractFailure("untimed sibling version failed to load")
        }
        await MainActor.run {
            session.adoptPersisted(document: untimed.document, versionID: partialID, sourceContentHash: partialSave.sourceContentHash ?? "")
        }
        guard await MainActor.run(body: { session.activeLyricsVersionID == partialID }) else {
            throw ContractFailure("session did not switch to untimed sibling")
        }
        let loadedAgain = try await repository.loadEditableVersion(versionID: versionID, track: track, identity: identity)
        guard let loadedAgain else { throw ContractFailure("timed version failed to reload") }
        await MainActor.run {
            session.adoptPersisted(document: loadedAgain.document, versionID: versionID, sourceContentHash: sourceHash)
        }
        try await assertSessionOverlay(
            session,
            track: track,
            identity: identity,
            sourceHash: sourceHash,
            expectedSpans: spans,
            timingID: timingID
        )

        let editor = await makeEditor(
            repository: repository,
            track: track,
            identity: identity,
            document: try await activeDocument(from: session),
            versionID: versionID,
            sourceHash: sourceHash,
            translations: translations,
            selectedTranslation: translation
        )
        try await waitUntil("timed editor versions did not load") { editor.availableVersions.count >= 2 }
        try await assertEditorOverlay(
            editor,
            track: track,
            sourceHash: sourceHash,
            expectedTranslation: "同一版本译文",
            expectedSpans: spans,
            timingID: timingID
        )

        await MainActor.run { editor.selectTranslation(versionID: alternateTranslation.record.id) }
        try await assertEditorOverlay(
            editor,
            track: track,
            sourceHash: sourceHash,
            expectedTranslation: "切换后的译文",
            expectedSpans: spans,
            timingID: timingID
        )
        guard await MainActor.run(body: {
            editor.selectedTranslation?.record.id == alternateTranslation.record.id && editor.draft?.isDirty == false
        }) else {
            throw ContractFailure("translation switch did not adopt the selected clean draft")
        }
        await MainActor.run { editor.selectTranslation(versionID: translation.record.id) }
        try await assertEditorOverlay(
            editor,
            track: track,
            sourceHash: sourceHash,
            expectedTranslation: "同一版本译文",
            expectedSpans: spans,
            timingID: timingID
        )

        // Exercise the real editor's version-switch load and return path too.
        await MainActor.run { editor.selectLyricsVersion(versionID: partialID) }
        try await waitUntil("editor did not switch to untimed sibling") { editor.currentSourceVersionID == partialID }
        await MainActor.run { editor.selectLyricsVersion(versionID: versionID) }
        try await waitUntil("editor did not return to timed version") { editor.currentSourceVersionID == versionID }
        try await assertEditorOverlay(
            editor,
            track: track,
            sourceHash: sourceHash,
            expectedTranslation: "切换后的译文",
            expectedSpans: spans,
            timingID: timingID
        )

        let afterRead = try observer.snapshot()
        guard beforeRead == afterRead else {
            throw ContractFailure("repository/session/editor projection changed database rows or data_version")
        }
        _ = root
    }

    private static func makeSession(
        repository: SQLiteLyricsRepository,
        track: Track,
        identity: TrackIdentity
    ) async -> LyricsSessionController {
        let session = await MainActor.run {
            LyricsSessionController(providers: [InertLyricsProvider()], repository: repository)
        }
        await MainActor.run {
            session.begin(track: track, identity: identity, automaticallySearch: false)
        }
        return session
    }

    private static func makeEditor(
        repository: SQLiteLyricsRepository,
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument,
        versionID: UUID,
        sourceHash: String,
        translations: [StoredTranslationVersion] = [],
        selectedTranslation: StoredTranslationVersion?
    ) async -> LyricsEditorSessionController {
        await MainActor.run {
            let editor = LyricsEditorSessionController(repository: repository)
            editor.isStillCurrent = { true }
            editor.begin(
                track: track,
                identity: identity,
                document: document,
                lyricsVersionID: versionID,
                sourceContentHash: sourceHash,
                revision: 1,
                translations: translations,
                selectedTranslation: selectedTranslation,
                configuration: AITranslationConfiguration(targetLanguage: "zh-Hans")
            )
            return editor
        }
    }

    private static func activeDocument(from session: LyricsSessionController) async throws -> LyricsDocument {
        try await MainActor.run {
            guard let document = session.activeDocument else {
                throw ContractFailure("session has no active document to pass into the editor")
            }
            return document
        }
    }

    private static func assertPartialSession(
        _ session: LyricsSessionController,
        expectedMask: Set<Int>,
        expectedHash: String
    ) async throws {
        try await MainActor.run {
            guard let document = session.activeDocument else { throw ContractFailure("session has no active partial document") }
            print("partial session observed mask=\(String(describing: document.explicitlyTimedLineIndices)) sync=\(document.isSynchronized) hashMatch=\(session.activeSourceContentHash == expectedHash) line0Explicit=\(document.lineHasExplicitTiming(0)) line1Explicit=\(document.lineHasExplicitTiming(1))")
            guard document.explicitlyTimedLineIndices == expectedMask,
                  document.isSynchronized == false,
                  document.lineHasExplicitTiming(0),
                  !document.lineHasExplicitTiming(1),
                  document.lines[0].timestamp == 0,
                  document.lines[1].timestamp == 0,
                  document.lines[0].endTime == 2,
                  document.lines[0].timedSpans == nil,
                  document.lines[0].performerID == nil,
                  document.lines[0].kanaText == nil,
                  document.lines[0].romajiText == nil,
                  document.language == "und",
                  document.timingVersionID == nil,
                  session.activeIdentity == document.identity,
                  session.activeSourceContentHash == expectedHash else {
                throw ContractFailure("session dropped explicit-zero/placeholder mask or canonical source identity")
            }
        }
    }

    private static func assertPartialDraft(
        _ editor: LyricsEditorSessionController,
        expectedMask: Set<Int>,
        expectedHash: String
    ) async throws {
        try await MainActor.run {
            guard let draft = editor.draft, !draft.lines.isEmpty else {
                throw ContractFailure("editor has no partial draft")
            }
            let mask = reflectedOptional(draft, field: "explicitlyTimedLineIndices", as: Set<Int>.self)
            let language = reflectedOptional(draft, field: "language", as: String.self)
            let timingID = reflectedOptional(draft, field: "timingVersionID", as: UUID.self)
            let performer = reflectedOptional(draft.lines[0], field: "performerID", as: String.self)
            let spans = reflectedOptional(draft.lines[0], field: "timedSpans", as: [TimedTextSpan].self)
            guard reflectedValue(draft, field: "isSynchronized", as: Bool.self) == false,
                  mask.exists, mask.value == expectedMask,
                  language.exists, language.value == "und",
                  timingID.exists, timingID.value == nil,
                  performer.exists, performer.value == nil,
                  spans.exists, spans.value == nil,
                  draft.lines.count == 2,
                  draft.lines[0].startTime == 0,
                  draft.lines[0].endTime == 2,
                  draft.lines[1].startTime == nil,
                  draft.sourceContentHash == expectedHash else {
                throw ContractFailure("editor draft lost partial mask or treated placeholder zero as a real time")
            }
        }
    }

    private static func assertReflectedMask(_ session: LyricsSessionController, expected: Set<Int>?) async throws {
        try await MainActor.run {
            guard let document = session.activeDocument else { throw ContractFailure("session has no active document for nil/empty mask") }
            let actual = document.explicitlyTimedLineIndices
            guard actual == expected else { throw ContractFailure("session collapsed nil and empty timing masks") }
        }
    }

    private static func assertDraftMask(
        _ editor: LyricsEditorSessionController,
        expected: Set<Int>?,
        expectedSync: Bool
    ) async throws {
        try await MainActor.run {
            guard let draft = editor.draft else { throw ContractFailure("editor has no draft for nil/empty mask") }
            let mask = reflectedOptional(draft, field: "explicitlyTimedLineIndices", as: Set<Int>.self)
            guard mask.exists, mask.value == expected,
                  reflectedValue(draft, field: "isSynchronized", as: Bool.self) == expectedSync else {
                throw ContractFailure("editor draft collapsed nil and empty timing masks or sync state")
            }
        }
    }

    private static func assertLockedOverlay(
        _ document: LyricsDocument,
        track: Track,
        identity: TrackIdentity,
        expectedSpans: [TimedTextSpan],
        timingID: UUID
    ) throws {
        print("legacy overlay observed kana=\(String(describing: document.lines.first?.kanaText)) romaji=\(String(describing: document.lines.first?.romajiText)) spans=\(document.lines.first?.timedSpans?.count ?? 0) performer=\(String(describing: document.lines.first?.performerID)) language=\(String(describing: document.language)) timingID=\(String(describing: document.timingVersionID)) provider=\(String(describing: document.providerSourceID))")
        guard document.lines.count == 1,
              document.identity == identity,
              document.title == track.title,
              document.artist == track.artist,
              document.album == track.album,
              document.duration == track.duration,
              document.source == .neteaseExperimental,
              document.confidence == 1,
              document.lines[0].originalText == "今日🌸今日",
              document.lines[0].timestamp == 0,
              document.lines[0].endTime == 4,
              document.lines[0].translationText == "compatibility line translation",
              document.lines[0].kanaText == "こんにち",
              document.lines[0].romajiText == "konnichi",
              document.lines[0].performerID == "v2",
              document.lines[0].timedSpans == expectedSpans,
              document.language == "ja",
              document.timingVersionID == timingID,
              document.providerSourceID == "t1-authoritative-provider-source" else {
            throw ContractFailure("repository locked-reading overlay dropped timing, metadata, or failed to apply the locked reading")
        }
    }

    private static func assertSessionOverlay(
        _ session: LyricsSessionController,
        track: Track,
        identity: TrackIdentity,
        sourceHash: String,
        expectedSpans: [TimedTextSpan],
        timingID: UUID
    ) async throws {
        try await MainActor.run {
            guard let document = session.activeDocument,
                  document.identity == identity,
                  session.activeIdentity == identity,
                  document.title == track.title,
                  document.artist == track.artist,
                  document.album == track.album,
                  document.duration == track.duration,
                  document.source == .neteaseExperimental,
                  document.confidence == 1,
                  document.providerSourceID == "t1-authoritative-provider-source",
                  document.lines.first?.originalText == "今日🌸今日",
                  document.lines.first?.timestamp == 0,
                  document.lines.first?.endTime == 4,
                  document.lines.first?.translationText == "compatibility line translation",
                  document.lines.first?.kanaText == "こんにち",
                  document.lines.first?.romajiText == "konnichi",
                  document.lines.first?.performerID == "v2",
                  document.lines.first?.timedSpans == expectedSpans,
                  document.language == "ja",
                  document.timingVersionID == timingID,
                  session.activeSourceContentHash == sourceHash else {
                throw ContractFailure("session projection dropped locked reading, spans, metadata, or canonical identity")
            }
#if DEBUG
            guard session.debugLyricsBindingToken == sourceHash else {
                throw ContractFailure("session recomputed the canonical hash from the converted display projection")
            }
#endif
        }
    }

    private static func assertEditorOverlay(
        _ editor: LyricsEditorSessionController,
        track: Track,
        sourceHash: String,
        expectedTranslation: String,
        expectedSpans: [TimedTextSpan],
        timingID: UUID
    ) async throws {
        try await MainActor.run {
            guard let draft = editor.draft, let line = draft.lines.first else {
                throw ContractFailure("editor has no timed draft")
            }
            let spans = reflectedOptional(line, field: "timedSpans", as: [TimedTextSpan].self)
            let performer = reflectedOptional(line, field: "performerID", as: String.self)
            let draftLanguage = reflectedOptional(draft, field: "language", as: String.self)
            let draftTimingID = reflectedOptional(draft, field: "timingVersionID", as: UUID.self)
            let draftSynced = reflectedValue(draft, field: "isSynchronized", as: Bool.self)
            guard line.originalText == "今日🌸今日",
                  draft.title == track.title,
                  draft.artist == track.artist,
                  draft.album == track.album,
                  draft.duration == track.duration,
                  draft.source == .neteaseExperimental,
                  line.startTime == 0,
                  line.endTime == 4,
                  line.translationText == expectedTranslation,
                  line.kanaText == "こんにち",
                  line.romajiText == "konnichi",
                  spans.exists, spans.value == expectedSpans,
                  performer.exists, performer.value == "v2",
                  draftLanguage.exists, draftLanguage.value == "ja",
                  draftTimingID.exists, draftTimingID.value == timingID,
                  draftSynced == true,
                  draft.sourceVersionID == editor.currentSourceVersionID,
                  draft.sourceContentHash == sourceHash else {
                throw ContractFailure("editor draft translation=\(expectedTranslation) lost locked reading, line timing, spans, performer/language, attachment identity, or source identity")
            }
            guard editor.isReadingLocked(lineID: line.id) else {
                throw ContractFailure("legacy locked-reading state was not retained in the editor")
            }
        }
    }

    private static func insertLegacyLockedReading(
        databaseURL: URL,
        lyricsVersionID: UUID,
        kanaText: String,
        romajiText: String
    ) throws {
        var database: OpaquePointer?
        let open = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard open == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error \(open)"
            if let database { sqlite3_close(database) }
            throw ContractFailure("could not seed historical locked-reading fixture: \(message)")
        }
        defer { sqlite3_close(database) }
        let sql = """
        INSERT INTO lyric_reading_layers(
            lyrics_version_id, line_index, kana_text, romaji_text, source,
            is_locked, created_at, updated_at
        ) VALUES ('\(lyricsVersionID.uuidString)', 0, '\(kanaText)', '\(romajiText)', 'legacyLockedFixture', 1, 100, 100);
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw ContractFailure("could not seed historical locked-reading fixture: \(message)")
        }
    }
}
