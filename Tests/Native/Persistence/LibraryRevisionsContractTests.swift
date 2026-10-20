import Foundation
import SQLite3
import XCTest
@testable import SpotifyLyrics

final class LibraryRevisionsContractTests: XCTestCase {
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
        let sparseVersions = try await repo.loadTranslationVersions(
            lyricsVersionID: source.record.id, targetLanguage: "zh-Hans", sourceContentHash: source.sourceContentHash
        )
        XCTAssertEqual(
            sparseVersions.first { $0.record.id == sparseChild.record.id }?.lines.map(\.translatedText),
            ["改过的已有译文", ""],
            "A sparse manual child remains visible after reloading the library"
        )
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

        let timingTrack = Track(title: "Timing fixture", artist: "Test", album: "Test", duration: 100, spotifyId: "timing-revision-test")
        let timingIdentity = TrackIdentity(track: timingTrack)
        let timingDocument = LyricsDocument(
            identity: timingIdentity, title: timingTrack.title, artist: timingTrack.artist, album: timingTrack.album, duration: 100,
            lines: [LyricLine(timestamp: 1, originalText: "Timed words", endTime: 3, timedSpans: [
                TimedTextSpan(id: 0, text: "Timed", trailingWhitespace: " ", startTime: 1.1, endTime: 1.7, utf16Start: 0, utf16Length: 5, granularity: .word),
                TimedTextSpan(id: 1, text: "words", startTime: 1.8, endTime: 2.4, utf16Start: 6, utf16Length: 5, granularity: .word)
            ])],
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
        let editedStartTime = editedTimingSource?.document.lines[0].timedSpans?.first?.startTime ?? 0
        XCTAssertEqual(editedStartTime, 1.2, accuracy: 0.0001)

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
