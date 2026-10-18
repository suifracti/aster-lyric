import Foundation
import SQLite3
@main struct LibraryRevisionsContract {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-revisions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"), alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repo.prepare()
        let track = Track(title: "Revision fixture", artist: "Test", album: "Test", duration: 100, spotifyId: "revision-test")
        let identity = TrackIdentity(track: track)
        let original = LyricsDocument(identity: identity, title: track.title, artist: track.artist, album: track.album, duration: 100, lines: [
            LyricLine(timestamp: 1, originalText: "Original first"),
            LyricLine(timestamp: 4, originalText: "Original second")
        ], isSynchronized: true, source: .lrclib, confidence: 0.9, providerSourceID: "fixture")
        let saved = try await repo.save(track: track, identity: identity, document: original)
        let source = try await repo.loadEditableVersion(versionID: saved.versionID!, track: track, identity: identity)!

        // Every library category forks a revision while keeping its parent and
        // the precise lyric source association. Locked originals stay intact.
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
        let translationChild = try await repo.saveManualEdit(translationDraft.saveRequest()).translationVersion!
        precondition(translationChild.record.parentVersionID == originalTranslation.record.id)
        precondition(translationChild.record.lyricsVersionID == source.record.id)
        precondition(translationChild.record.sourceContentHash == source.sourceContentHash)
        precondition(translationChild.record.isManuallyEdited && !translationChild.record.isLocked)
        let translationVersions = try await repo.loadTranslationVersions(
            lyricsVersionID: source.record.id, targetLanguage: "zh-Hans", sourceContentHash: source.sourceContentHash
        )
        let retainedTranslation = translationVersions.first { $0.record.id == originalTranslation.record.id }!
        precondition(retainedTranslation.record.isLocked && retainedTranslation.lines == originalTranslation.lines)
        precondition(translationVersions.first { $0.record.id == translationChild.record.id }?.lines.map(\.translatedText) == ["修订译一", "原译二"])

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
        precondition(sparseDraft.lines == ["已有译文", ""], "An embedded blank line remains editable as an empty row")
        sparseDraft.lines[0] = "改过的已有译文"
        let sparseChild = try await repo.saveManualEdit(sparseDraft.saveRequest()).translationVersion!
        precondition(sparseChild.record.parentVersionID == sparseTranslation.record.id)
        precondition(sparseChild.record.lyricsVersionID == source.record.id)
        precondition(sparseChild.record.sourceContentHash == source.sourceContentHash)
        precondition(sparseChild.lines.map(\.translatedText) == ["改过的已有译文", ""])
        let sparseVersions = try await repo.loadTranslationVersions(
            lyricsVersionID: source.record.id, targetLanguage: "zh-Hans", sourceContentHash: source.sourceContentHash
        )
        precondition(sparseVersions.first { $0.record.id == sparseChild.record.id }?.lines.map(\.translatedText) == ["改过的已有译文", ""],
                     "A sparse manual child remains visible after reloading the library")
        let sparseParentAfter = sparseVersions.first { $0.record.id == sparseTranslation.record.id }
        precondition(sparseParentAfter?.lines == sparseTranslation.lines, "Editing the child must retain the sparse parent")

        var emptyManualDraft = LibraryTranslationRevisionDraft(track: track, lyricsSource: source, source: sparseTranslation)
        emptyManualDraft.lines = ["", ""]
        do {
            _ = try await repo.saveManualEdit(emptyManualDraft.saveRequest())
            fatalError("All-empty manual translation revision accepted")
        } catch LyricsEditingRepositoryError.invalidTranslation(_) { }

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
            fatalError("Sparse AI translation accepted")
        } catch TranslationRepositoryError.invalidLines(_) { }

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
        let originalReading = try await repo.saveReadingVersion(ReadingVersionSaveRequest(record: originalReadingRecord, lines: originalReadingLines))
        try await repo.markReadingLocked(versionID: originalReading.record.id, locked: true)
        var readingDraft = LibraryReadingRevisionDraft(track: track, lyricsSource: source, source: originalReading)
        readingDraft.lines[0] = "manual-reading"
        let readingChild = try await repo.saveReadingVersion(readingDraft.saveRequest())
        precondition(readingChild.record.parentVersionID == originalReading.record.id)
        precondition(readingChild.record.lyricsVersionID == source.record.id)
        precondition(readingChild.record.sourceContentHash == source.sourceContentHash)
        precondition(readingChild.record.isManuallyEdited && !readingChild.record.isLocked)
        let readingVersions = try await repo.loadReadingVersions(
            lyricsVersionID: source.record.id, representationID: ReadingRepresentationID.romaji.rawValue,
            sourceContentHash: source.sourceContentHash
        )
        let retainedReading = readingVersions.first { $0.record.id == originalReading.record.id }!
        precondition(retainedReading.record.isLocked && retainedReading.lines == originalReading.lines)
        precondition(readingVersions.first { $0.record.id == readingChild.record.id }?.lines.first?.readingText == "manual-reading")

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
        let timingSource = try await repo.loadEditableVersion(versionID: savedTimingLyrics.versionID!, track: timingTrack, identity: timingIdentity)!
        let originalTiming = try await repo.loadPersonalLibraryTimingVersion(id: timingSource.document.timingVersionID!)!
        var timingDraft = LibraryTimingRevisionDraft(track: timingTrack, lyricsSource: timingSource, source: originalTiming)!
        timingDraft.lines[0].spans[0].startTime += 0.1
        let timingChild = try await repo.savePersonalLibraryTimingRevision(timingDraft.saveRequest())
        precondition(timingChild.id != originalTiming.id)
        precondition(timingChild.lyricsVersionID == timingSource.record.id && timingChild.sourceContentHash == timingSource.sourceContentHash)
        let retainedTiming = try await repo.loadPersonalLibraryTimingVersion(id: originalTiming.id)
        precondition(retainedTiming == originalTiming)
        let editedTimingSource = try await repo.loadEditableVersion(versionID: timingSource.record.id, track: timingTrack, identity: timingIdentity)!
        precondition(editedTimingSource.document.timingVersionID == timingChild.id)
        let editedStartTime = editedTimingSource.document.lines[0].timedSpans?.first?.startTime ?? 0
        precondition(abs(editedStartTime - 1.2) < 0.0001)

        let request = LyricsEditSaveRequest(track: track, identity: identity, sourceVersionID: source.record.id, sourceContentHash: LyricsSourceContentHasher.hash(isSynchronized: source.record.isSynced, lines: source.lines), document: original, createLyricsVersion: true, lockLyricsVersion: true)
        let higher = try await repo.saveManualEdit(request).lyricsVersion!
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: source.record.id)
        let selected = try await repo.loadBestStored(track: track, identity: identity)
        precondition(selected?.versionID == source.record.id, "Explicit original selection must beat locked/high-confidence newer versions")
        precondition(higher.record.id != source.record.id)
        var revisionDraft = LibraryLyricsRevisionDraft(track: track, source: higher)
        do { _ = try revisionDraft.saveRequest(); fatalError("No-op revision accepted") }
        catch LyricsEditingRepositoryError.noChanges { }
        revisionDraft.lines[0].originalText = "Revised first"
        let revision = try await repo.saveManualEdit(revisionDraft.saveRequest()).lyricsVersion!
        precondition(revision.record.id != source.record.id && revision.record.id != higher.record.id)
        precondition(revision.record.parentVersionID == higher.record.id)
        precondition(revision.document.lines.map(\.originalText) == ["Revised first", "Original second"])
        precondition(revision.document.lines.map(\.timestamp) == [1, 4])
        let originalAfter = try await repo.loadEditableVersion(versionID: source.record.id, track: track, identity: identity)!
        let lockedAfter = try await repo.loadEditableVersion(versionID: higher.record.id, track: track, identity: identity)!
        precondition(originalAfter.record == source.record && originalAfter.lines == source.lines)
        precondition(lockedAfter.record == higher.record && lockedAfter.lines == higher.lines)
        let stillSelected = try await repo.loadBestStored(track: track, identity: identity)
        precondition(stillSelected?.versionID == source.record.id, "Save must not adopt implicitly")
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: revision.record.id)
        let newSelected = try await repo.loadBestStored(track: track, identity: identity)
        precondition(newSelected?.versionID == revision.record.id)
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: source.record.id)
        let reopened = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"), alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await reopened.prepare()
        let restored = try await reopened.loadBestStored(track: track, identity: identity)
        precondition(restored?.versionID == source.record.id)
        let detail = try await reopened.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey)!
        precondition(detail.lyricsVersions.count == 3 && detail.lyricsVersions.first(where: \.isCurrent)?.id == source.record.id)
        do { try await repo.setPersonalLibraryActiveLyrics(trackStableKey: "wrong-track", lyricsVersionID: source.record.id); fatalError("Cross-track selection accepted") }
        catch LyricsEditingRepositoryError.identityMismatch { }
        let retained = try await repo.loadBestStored(track: track, identity: identity)
        precondition(retained?.versionID == source.record.id)
        // Current-song editor saves still adopt new content after library preference exists.
        var normal = LibraryLyricsRevisionDraft(track: track, source: revision)
        normal.lines[0].originalText = "Normal editor revision"
        let prepared = try normal.saveRequest()
        let normalRequest = LyricsEditSaveRequest(track: track, identity: identity, sourceVersionID: revision.record.id, sourceContentHash: prepared.sourceContentHash, document: prepared.document, createLyricsVersion: true)
        let normalSaved = try await repo.saveManualEdit(normalRequest).lyricsVersion!
        let normalSelected = try await repo.loadBestStored(track: track, identity: identity)
        precondition(normalSelected?.versionID == normalSaved.record.id)
        // Clearing/moving start times must not retain hidden stale end times.
        var retimed = LibraryLyricsRevisionDraft(track: track, source: revision)
        retimed.lines[0].startTime = nil
        let partialRequest = try retimed.saveRequest()
        precondition(partialRequest.document.lines[0].endTime == nil)
        _ = try await repo.saveManualEdit(partialRequest)
        // Export/import retains original selection and lineage, without overriding local choice.
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: source.record.id)
        let package = try await repo.exportPersonalLibraryPackage(stableKey: identity.stableKey)
        precondition(package.preferredLyricsVersionID == source.record.id)
        let decoded = try JSONDecoder().decode(PersonalLyricsLibraryPackage.self, from: JSONEncoder().encode(package))
        let imported = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("import.sqlite3"), alignmentProvenanceDirectory: root.appendingPathComponent("import-provenance"))
        try await imported.importPersonalLibraryPackage(decoded)
        let importedSelected = try await imported.loadBestStored(track: track, identity: identity)
        precondition(importedSelected?.versionID == source.record.id)
        let importedRevision = try await imported.loadEditableVersion(versionID: revision.record.id, track: track, identity: identity)!
        precondition(importedRevision.record.parentVersionID == higher.record.id)
        try await imported.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: revision.record.id)
        try await imported.importPersonalLibraryPackage(decoded)
        let localWins = try await imported.loadBestStored(track: track, identity: identity)
        precondition(localWins?.versionID == revision.record.id)
        var handle: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("import.sqlite3").path, &handle) == SQLITE_OK)
        let escapedKey = identity.stableKey.replacingOccurrences(of: "'", with: "''")
        let redirectSQL = "INSERT INTO track_identity_redirects VALUES ('historical-fixture', '\(escapedKey)', 'fixture', 'fixture', 'fixture', 1);"
        precondition(sqlite3_exec(handle, redirectSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        var oldKeyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        var oldTrack = oldKeyJSON["track"] as! [String: Any]
        oldTrack["stableKey"] = "historical-fixture"
        oldKeyJSON["track"] = oldTrack
        let oldKeyPackage = try JSONDecoder().decode(PersonalLyricsLibraryPackage.self, from: JSONSerialization.data(withJSONObject: oldKeyJSON))
        let redirected = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("import.sqlite3"), alignmentProvenanceDirectory: root.appendingPathComponent("redirect-provenance"))
        try await redirected.importPersonalLibraryPackage(oldKeyPackage)
        let redirectSelected = try await redirected.loadBestStored(track: track, identity: identity)
        precondition(redirectSelected?.versionID == revision.record.id, "Historical-key import must preserve canonical local choice")
        print("Library revisions PASS: fork/original/selection/restore/normal editor/partial timing/export import/redirect preference")
    }
}
