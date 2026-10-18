import Foundation

private struct Fixture {
    let repository: SQLiteLyricsRepository
    let track: Track
    let identity: TrackIdentity
    let document: LyricsDocument
    let versionID: UUID
    let sourceHash: String
}

private func makeFixture(root: URL, name: String, translations: [String?]) async throws -> Fixture {
    let track = Track(
        title: name,
        artist: "Provider Embedded Contract",
        album: "Temporary Fixture",
        duration: 30,
        spotifyId: "contract-\(name)"
    )
    let identity = TrackIdentity(track: track)
    let originals = ["作词：", "ぼくの歌", "编曲：", ""]
    precondition(translations.count == originals.count)
    let document = LyricsDocument(
        identity: identity,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        lines: originals.enumerated().map { index, text in
            LyricLine(timestamp: Double(index * 3), originalText: text, translationText: translations[index])
        },
        isSynchronized: true,
        source: .neteaseExperimental,
        confidence: 0.99,
        providerSourceID: "provider-embedded-contract-\(name)"
    )
    let database = root.appendingPathComponent("\(name).sqlite3")
    let repository = SQLiteLyricsRepository(
        databaseURL: database,
        alignmentProvenanceDirectory: root.appendingPathComponent("\(name)-provenance")
    )
    try await repository.prepare()
    let saved = try await repository.save(track: track, identity: identity, document: document)
    guard let versionID = saved.versionID, let sourceHash = saved.sourceContentHash else {
        fatalError("fixture lyric document was not inserted: \(saved.disposition)")
    }
    return Fixture(repository: repository, track: track, identity: identity, document: document,
        versionID: versionID, sourceHash: sourceHash)
}

private func translations(_ version: StoredTranslationVersion) -> [String] {
    version.lines.sorted { $0.lineIndex < $1.lineIndex }.map(\.translatedText)
}

@main
struct ProviderEmbeddedSparseTranslationContract {
    static func main() async throws {
        guard let rawRoot = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_PROVIDER_EMBEDDED_TEST_ROOT"] else {
            fatalError("runner-private test root required")
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = try await makeFixture(root: root, name: "sparse-source", translations: [nil, "我在唱歌", nil, ""])
        try await source.repository.preserveEmbeddedTranslation(lyricsVersionID: source.versionID,
            sourceContentHash: source.sourceHash)

        let embedded = try await source.repository.loadTranslationVersions(lyricsVersionID: source.versionID,
            targetLanguage: "zh-Hans", sourceContentHash: source.sourceHash)
        guard let savedEmbedded = embedded.first(where: { $0.record.sourceKind == .providerEmbedded }) else {
            fatalError("sparse provider translation was not saved")
        }
        precondition(savedEmbedded.record.engineID == "provider-embedded")
        precondition(savedEmbedded.record.status == .complete)
        precondition(savedEmbedded.lines.count == 4)
        precondition(savedEmbedded.lines.map(\.lineIndex) == [0, 1, 2, 3])
        precondition(translations(savedEmbedded) == ["", "我在唱歌", "", ""])
        print("PASS sparse provider-embedded source keeps all row indexes and empty untranslated rows")

        let reopened = SQLiteLyricsRepository(databaseURL: source.repository.databaseURL,
            alignmentProvenanceDirectory: root.appendingPathComponent("sparse-source-provenance"))
        try await reopened.prepare()
        let afterReopen = try await reopened.loadTranslationVersions(lyricsVersionID: source.versionID,
            targetLanguage: "zh-Hans", sourceContentHash: source.sourceHash)
        guard let reopenedEmbedded = afterReopen.first(where: { $0.record.sourceKind == .providerEmbedded }) else {
            fatalError("sparse provider translation did not survive reopen")
        }
        precondition(reopenedEmbedded.lines.count == 4)
        precondition(translations(reopenedEmbedded) == ["", "我在唱歌", "", ""])
        print("PASS sparse provider-embedded version remains selectable after SQLite reopen")

        for (kind, isMachineGenerated, isManuallyEdited) in [
            (AITranslationSourceKind.ai, true, false),
            (.manualEdit, false, true)
        ] {
            let draft = AITranslationDraft(
                lines: [
                    AITranslationLine(index: 0, translation: ""),
                    AITranslationLine(index: 1, translation: "AI/人工完整译文"),
                    AITranslationLine(index: 2, translation: ""),
                    AITranslationLine(index: 3, translation: "")
                ],
                targetLanguage: "zh-Hans",
                model: "contract fixture",
                baseURLHost: "",
                promptHash: "contract fixture",
                sourceContentHash: source.sourceHash,
                sourceKind: kind,
                isMachineGenerated: isMachineGenerated,
                isManuallyEdited: isManuallyEdited
            )
            do {
                _ = try await source.repository.saveTranslation(lyricsVersionID: source.versionID,
                    sourceContentHash: source.sourceHash, originalLines: source.document.lines.map(\.originalText),
                    draft: draft, forceNewVersion: true)
                fatalError("\(kind.rawValue) translation with missing nonblank-source rows was accepted")
            } catch TranslationRepositoryError.invalidLines { }
        }
        print("PASS AI and manual translation drafts still reject missing nonblank-source rows")

        let emptySource = try await makeFixture(root: root, name: "empty-source", translations: [nil, nil, nil, nil])
        try await emptySource.repository.preserveEmbeddedTranslation(lyricsVersionID: emptySource.versionID,
            sourceContentHash: emptySource.sourceHash)
        let emptyVersions = try await emptySource.repository.loadTranslationVersions(lyricsVersionID: emptySource.versionID,
            targetLanguage: "zh-Hans", sourceContentHash: emptySource.sourceHash)
        precondition(!emptyVersions.contains(where: { $0.record.sourceKind == .providerEmbedded }),
            "all-empty source translations must not create a version")
        print("PASS all-empty provider source does not create an embedded translation version")

        let newlineDraft = AITranslationDraft(
            lines: [
                AITranslationLine(index: 0, translation: ""),
                AITranslationLine(index: 1, translation: "第一行\n第二行"),
                AITranslationLine(index: 2, translation: ""),
                AITranslationLine(index: 3, translation: "")
            ],
            targetLanguage: "und",
            model: "provider embedded",
            baseURLHost: "",
            promptHash: "",
            sourceContentHash: source.sourceHash,
            sourceKind: .providerEmbedded,
            isMachineGenerated: false,
            engineID: "provider-embedded"
        )
        do {
            _ = try await source.repository.saveTranslation(lyricsVersionID: source.versionID,
                sourceContentHash: source.sourceHash, originalLines: source.document.lines.map(\.originalText),
                draft: newlineDraft, forceNewVersion: true)
            fatalError("provider embedded translation containing line breaks was accepted")
        } catch TranslationRepositoryError.invalidLines { }
        print("PASS provider embedded translation rejects line breaks")
    }
}
