import Foundation

// The production editor only touches this singleton after a save associated
// with a translation style profile. H1 uses no profile, so keep settings I/O
// outside this focused executable while compiling the real editor controller.
public final class AppSettingsStore: @unchecked Sendable {
    public static let shared = AppSettingsStore()
    public let translationProfiles: TranslationProfileStore

    private init() {
        let defaults = UserDefaults(suiteName: "h1-hash-domain-\(UUID().uuidString)")!
        translationProfiles = TranslationProfileStore(defaults: defaults)
    }
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "FAIL: \(description)" }
}

private actor DelayedEditingRepository: LyricsEditingRepository {
    let base: SQLiteLyricsRepository
    let delayedVersionID: UUID

    init(base: SQLiteLyricsRepository, delayedVersionID: UUID) {
        self.base = base
        self.delayedVersionID = delayedVersionID
    }

    func loadEditableVersions(track: Track, identity: TrackIdentity) async throws -> [StoredEditableLyricsVersion] {
        try await base.loadEditableVersions(track: track, identity: identity)
    }

    func loadEditableVersion(versionID: UUID, track: Track, identity: TrackIdentity) async throws -> StoredEditableLyricsVersion? {
        if versionID == delayedVersionID {
            // Deliberately ignore sleep cancellation so the production
            // controller's own cancellation/generation checks are exercised.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return try await base.loadEditableVersion(versionID: versionID, track: track, identity: identity)
    }

    func adoptLyricsVersion(trackStableKey: String, lyricsVersionID: UUID) async throws {
        try await base.adoptLyricsVersion(trackStableKey: trackStableKey, lyricsVersionID: lyricsVersionID)
    }

    func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) async throws -> [StoredTranslationVersion] {
        try await base.loadTranslationVersions(
            lyricsVersionID: lyricsVersionID,
            targetLanguage: targetLanguage,
            sourceContentHash: sourceContentHash
        )
    }

    func saveManualEdit(_ request: LyricsEditSaveRequest) async throws -> LyricsEditSaveResult {
        try await base.saveManualEdit(request)
    }

    func markLyricsVersionLocked(versionID: UUID, locked: Bool) async throws {
        try await base.markLyricsVersionLocked(versionID: versionID, locked: locked)
    }
}

private func waitUntil(
    _ description: String,
    attempts: Int = 150,
    condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ContractFailure(description)
}

private func translationDraft(text: String, sourceHash: String) -> AITranslationDraft {
    AITranslationDraft(
        lines: [AITranslationLine(index: 0, translation: text)],
        targetLanguage: "zh-Hans",
        model: "fixture-model",
        baseURLHost: "fixture.invalid",
        promptHash: "fixture-prompt",
        sourceContentHash: sourceHash
    )
}

@main
struct H1HashDomainBoundaryContract {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotifyLyrics-H1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("h1.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await repository.prepare()

        let track = Track(
            title: "H1 identity fixture",
            artist: "Contract",
            album: "Core Integrity",
            duration: 120,
            spotifyId: "h1-identity-fixture"
        )
        let identity = TrackIdentity(track: track)
        let providerA = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Provider A")],
            isSynchronized: false,
            source: .lrclib,
            confidence: 1,
            providerSourceID: "provider-a"
        )
        let timingID = UUID()
        let providerB = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [
                LyricLine(
                    timestamp: 1,
                    originalText: "Provider B",
                    endTime: 3,
                    performerID: "fixture",
                    timedSpans: [
                        TimedTextSpan(
                            id: 0,
                            text: "Provider B",
                            trailingWhitespace: "",
                            startTime: 1,
                            endTime: 3,
                            utf16Start: 0,
                            utf16Length: 10,
                            granularity: .timedUnit
                        )
                    ]
                )
            ],
            isSynchronized: true,
            source: .qqExperimental,
            confidence: 1,
            providerSourceID: "provider-b",
            timingVersionID: timingID
        )

        let savedA = try await repository.save(track: track, identity: identity, document: providerA)
        let savedB = try await repository.save(track: track, identity: identity, document: providerB)
        guard let providerAID = savedA.versionID,
              let providerAHash = savedA.sourceContentHash,
              let providerBID = savedB.versionID,
              let providerBHash = savedB.sourceContentHash,
              let storedA = try await repository.loadEditableVersion(versionID: providerAID, track: track, identity: identity),
              let storedB = try await repository.loadEditableVersion(versionID: providerBID, track: track, identity: identity) else {
            throw ContractFailure("provider fixtures were not persisted")
        }

        // Independent, fixed SHA-256 expectations for the exact sorted JSON
        // payloads document the two unchanged algorithms.
        guard providerAHash == "45e29e5816553994648ef33aa5646acdfde9f536f6132d96d4f57687f90a089e" else {
            throw ContractFailure("canonical source hash algorithm drifted: \(providerAHash)")
        }
        guard storedA.record.contentHash == "54aeeb5599664b75fd187ca8c250f4100f8ee851862f3897aa19c941d1f7fa6c" else {
            throw ContractFailure("provider dedup hash algorithm drifted: \(storedA.record.contentHash)")
        }
        guard storedA.record.contentHash != providerAHash else {
            throw ContractFailure("fixture did not establish distinct hash domains")
        }

        let duplicateA = try await repository.save(track: track, identity: identity, document: providerA)
        guard case .duplicate = duplicateA.disposition,
              duplicateA.versionID == providerAID,
              try await repository.versionCount(trackStableKey: identity.stableKey) == 2 else {
            throw ContractFailure("provider dedup no longer uses the version content hash")
        }
        guard storedB.document.timingVersionID == timingID,
              storedB.document.hasTimedSpans else {
            throw ContractFailure("timing fixture was not bound to provider B")
        }

        let translationA = try await repository.saveTranslation(
            lyricsVersionID: providerAID,
            sourceContentHash: providerAHash,
            originalLines: ["Provider A"],
            draft: translationDraft(text: "译文 A", sourceHash: providerAHash),
            forceNewVersion: true
        )
        let translationB = try await repository.saveTranslation(
            lyricsVersionID: providerBID,
            sourceContentHash: providerBHash,
            originalLines: ["Provider B"],
            draft: translationDraft(text: "译文 B", sourceHash: providerBHash),
            forceNewVersion: true
        )

        let readingRecord = ReadingVersionRecord(
            id: UUID(),
            lyricsVersionID: providerAID,
            sourceContentHash: providerAHash,
            engineID: ReadingEngineID.japaneseDictionary.rawValue,
            representationID: ReadingRepresentationID.kana.rawValue,
            language: .japanese,
            createdAt: Date(),
            updatedAt: Date(),
            isMachineGenerated: true,
            isManuallyEdited: false,
            isCurrent: true,
            isLocked: true,
            isArchived: false,
            parentVersionID: nil,
            confidence: 1,
            warningMetadata: [],
            contextHash: "h1-reading"
        )
        _ = try await repository.saveReadingVersion(ReadingVersionSaveRequest(
            record: readingRecord,
            lines: [
                ReadingLineResult(
                    lineIndex: 0,
                    originalText: "Provider A",
                    readingText: "ぷろばいだーえー",
                    language: .japanese,
                    tokens: [],
                    confidence: 1
                )
            ]
        ))

        let manualDocument = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Manual version", kanaText: "まにゅある")],
            isSynchronized: false,
            source: .manualEdit,
            confidence: 1,
            providerSourceID: "manualEdit"
        )
        let manualResult = try await repository.saveManualEdit(LyricsEditSaveRequest(
            track: track,
            identity: identity,
            sourceVersionID: providerAID,
            sourceContentHash: providerAHash,
            document: manualDocument,
            createLyricsVersion: true,
            translation: ManualTranslationEdit(targetLanguage: "zh-Hans", lines: ["人工译文"]),
            readingLayers: [
                LyricsReadingLayerDraft(
                    lineIndex: 0,
                    kanaText: "まにゅある",
                    romajiText: "manyuaru",
                    source: "legacyManual",
                    isLocked: true
                )
            ]
        ))
        guard let storedManual = manualResult.lyricsVersion,
              let manualTranslation = manualResult.translationVersion else {
            throw ContractFailure("manual fixture was not persisted")
        }
        let manualHash = LyricsSourceContentHasher.hash(
            isSynchronized: storedManual.record.isSynced,
            lines: storedManual.lines
        )

        let controller = await MainActor.run { () -> LyricsEditorSessionController in
            let value = LyricsEditorSessionController(repository: repository)
            value.isStillCurrent = { true }
            value.begin(
                track: track,
                identity: identity,
                document: storedA.document,
                lyricsVersionID: providerAID,
                sourceContentHash: providerAHash,
                revision: 1,
                translations: [translationA],
                selectedTranslation: translationA,
                configuration: AITranslationConfiguration(targetLanguage: "zh-Hans")
            )
            return value
        }
        try await waitUntil("initial version list did not load") {
            controller.availableVersions.count == 3
        }
        guard await MainActor.run(body: {
            controller.currentSourceContentHash == providerAHash
                && controller.selectedTranslation?.record.id == translationA.record.id
                && controller.draft?.lines.first?.translationText == "译文 A"
        }) else {
            throw ContractFailure("initial editor open lost provider A source identity")
        }

        await MainActor.run { controller.selectLyricsVersion(versionID: providerBID) }
        try await waitUntil("provider B selection did not complete") {
            controller.currentSourceVersionID == providerBID
        }
        guard await MainActor.run(body: {
            controller.currentSourceContentHash == providerBHash
                && controller.selectedTranslation?.record.id == translationB.record.id
                && controller.draft?.lines.first?.translationText == "译文 B"
        }) else {
            throw ContractFailure("provider B used the wrong source identity or lost translation")
        }

        await MainActor.run { controller.selectLyricsVersion(versionID: providerAID) }
        try await waitUntil("provider A reselection did not complete") {
            controller.currentSourceVersionID == providerAID
        }
        guard await MainActor.run(body: {
            controller.currentSourceContentHash == providerAHash
                && controller.selectedTranslation?.record.id == translationA.record.id
                && controller.draft?.lines.first?.translationText == "译文 A"
        }) else {
            throw ContractFailure("provider A -> B -> A crossed or lost translation binding")
        }

        await MainActor.run { controller.selectLyricsVersion(versionID: storedManual.record.id) }
        try await waitUntil("manual version selection did not complete") {
            controller.currentSourceVersionID == storedManual.record.id
        }
        guard await MainActor.run(body: {
            controller.currentSourceContentHash == manualHash
                && controller.selectedTranslation?.record.id == manualTranslation.record.id
                && controller.draft?.lines.first?.kanaText == "まにゅある"
                && controller.draft.map { controller.isReadingLocked(lineID: $0.lines[0].id) } == true
        }) else {
            throw ContractFailure("manual version lost canonical hash, translation, or locked reading")
        }

        let versionCountBeforeRejectedSave = try await repository.versionCount(trackStableKey: identity.stableKey)
        do {
            _ = try await repository.saveManualEdit(LyricsEditSaveRequest(
                track: track,
                identity: identity,
                sourceVersionID: providerAID,
                sourceContentHash: storedA.record.contentHash,
                document: manualDocument,
                createLyricsVersion: true,
                translation: ManualTranslationEdit(targetLanguage: "zh-Hans", lines: ["不得写入"])
            ))
            throw ContractFailure("dedup hash was accepted as a canonical source hash")
        } catch LyricsEditingRepositoryError.sourceContentMismatch {
            // Expected: the mismatch defense remains active.
        }
        guard try await repository.versionCount(trackStableKey: identity.stableKey) == versionCountBeforeRejectedSave else {
            throw ContractFailure("rejected source identity performed an extra write")
        }

        let readingAfterSwitch = try await repository.loadReadingVersions(
            lyricsVersionID: providerAID,
            representationID: ReadingRepresentationID.kana.rawValue,
            sourceContentHash: providerAHash
        )
        let providerBAfterSwitch = try await repository.loadEditableVersion(
            versionID: providerBID,
            track: track,
            identity: identity
        )
        guard readingAfterSwitch.first?.record.id == readingRecord.id,
              providerBAfterSwitch?.document.timingVersionID == timingID,
              providerBAfterSwitch?.document.hasTimedSpans == true else {
            throw ContractFailure("legacy reading/timing binding changed during version selection")
        }

        await MainActor.run { controller.selectLyricsVersion(versionID: providerAID) }
        try await waitUntil("provider A did not reload before save") {
            controller.currentSourceVersionID == providerAID
        }
        await MainActor.run {
            guard let lineID = controller.draft?.lines.first?.id else { return }
            controller.updateLine(lineID) { $0.originalText = "Provider A edited" }
            controller.save()
        }
        try await waitUntil("correct canonical identity did not save") {
            controller.state == .saved
        }
        guard let savedRevisionID = await MainActor.run(body: { controller.currentSourceVersionID }),
              let savedRevisionHash = await MainActor.run(body: { controller.currentSourceContentHash }),
              let savedRevision = try await repository.loadEditableVersion(
                  versionID: savedRevisionID,
                  track: track,
                  identity: identity
              ) else {
            throw ContractFailure("saved revision was not available")
        }
        let canonicalSavedRevisionHash = LyricsSourceContentHasher.hash(
            isSynchronized: savedRevision.record.isSynced,
            lines: savedRevision.lines
        )
        guard savedRevisionHash == canonicalSavedRevisionHash,
              await MainActor.run(body: { controller.draft?.sourceContentHash == canonicalSavedRevisionHash }) else {
            throw ContractFailure("save refresh fell back into the dedup hash domain")
        }
        let savedTranslations = try await repository.loadTranslationVersions(
            lyricsVersionID: savedRevisionID,
            targetLanguage: "zh-Hans",
            sourceContentHash: canonicalSavedRevisionHash
        )
        guard savedTranslations.count == 1 else {
            throw ContractFailure("saved revision translation could not reload with canonical identity")
        }

        let delayedRepository = DelayedEditingRepository(base: repository, delayedVersionID: providerBID)
        let raceController = await MainActor.run { () -> LyricsEditorSessionController in
            let value = LyricsEditorSessionController(repository: delayedRepository)
            value.isStillCurrent = { true }
            value.begin(
                track: track,
                identity: identity,
                document: storedA.document,
                lyricsVersionID: providerAID,
                sourceContentHash: providerAHash,
                revision: 2,
                translations: [translationA],
                selectedTranslation: translationA,
                configuration: AITranslationConfiguration(targetLanguage: "zh-Hans")
            )
            return value
        }
        try await waitUntil("race fixture versions did not load") {
            raceController.availableVersions.contains { $0.record.id == providerBID }
        }
        await MainActor.run {
            raceController.selectLyricsVersion(versionID: providerBID)
            raceController.selectLyricsVersion(versionID: providerAID)
        }
        try await waitUntil("newer provider A selection did not complete") {
            raceController.currentSourceVersionID == providerAID
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard await MainActor.run(body: {
            raceController.currentSourceVersionID == providerAID
                && raceController.currentSourceContentHash == providerAHash
                && raceController.draft?.lines.first?.originalText == "Provider A"
        }) else {
            throw ContractFailure("late provider B result overwrote the current A selection")
        }

        print("H1 hash domain boundary contract passed")
    }
}
