import Foundation

/// Non-lyrics provenance for a confirmed alignment. Deliberately excludes the
/// original audio path, audio bytes, full transcript and a second lyric copy.
public struct AlignmentProvenanceDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let lyricsVersionID: UUID
    public let parentVersionID: UUID
    public let sourceContentHash: String
    public let audioSHA256: String
    public let audioDuration: TimeInterval
    public let sampleRate: Int
    public let channels: Int
    public let engine: String
    public let parameters: AlignmentParameters
    public let createdAt: Date
    public let overallConfidence: Double
    public let lines: [Line]

    public struct Line: Codable, Equatable, Sendable {
        public let lineIndex: Int
        public let status: AlignmentLineStatus
        public let confidence: Double
        public let evidence: AlignmentLineEvidence

        public init(
            lineIndex: Int,
            status: AlignmentLineStatus,
            confidence: Double,
            evidence: AlignmentLineEvidence
        ) {
            self.lineIndex = lineIndex
            self.status = status
            self.confidence = confidence
            self.evidence = evidence
        }
    }

    public init(
        lyricsVersionID: UUID,
        parentVersionID: UUID,
        report: AlignmentReport
    ) {
        self.schemaVersion = 1
        self.lyricsVersionID = lyricsVersionID
        self.parentVersionID = parentVersionID
        self.sourceContentHash = report.sourceContentHash ?? ""
        self.audioSHA256 = report.audioSHA256
        self.audioDuration = report.audioDuration
        self.sampleRate = report.sampleRate
        self.channels = report.channels
        self.engine = report.modelID
        self.parameters = report.parameters
        self.createdAt = report.createdAt
        self.overallConfidence = report.overallConfidence
        self.lines = report.lines.enumerated().map { index, line in
            Line(
                lineIndex: index,
                status: line.status,
                confidence: line.confidence,
                evidence: line.evidence
            )
        }
    }
}

public struct AlignmentProvenanceStore: Sendable {
    public static var defaultDirectory: URL {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_ALIGNMENT_PROVENANCE_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpotifyLyrics/AlignmentProvenance", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = AlignmentProvenanceStore.defaultDirectory) {
#if DEBUG
        DebugAcceptanceDataIsolation.requireStorage(directory)
#endif
        self.directory = directory
    }

    public func url(for versionID: UUID) -> URL {
        directory.appendingPathComponent("\(versionID.uuidString).json")
    }

    @discardableResult
    public func write(
        versionID: UUID,
        parentVersionID: UUID,
        report: AlignmentReport
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = AlignmentProvenanceDocument(
            lyricsVersionID: versionID,
            parentVersionID: parentVersionID,
            report: report
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let destination = url(for: versionID)
        let temporary = directory.appendingPathComponent(".\(versionID.uuidString).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    public func remove(versionID: UUID) throws {
        let destination = url(for: versionID)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.removeItem(at: destination)
    }

    public func availability(for versionID: UUID) -> AlignmentProvenanceAvailability {
        guard let data = try? Data(contentsOf: url(for: versionID)) else {
            return .unavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AlignmentProvenanceDocument.self, from: data)) == nil
            ? .unavailable
            : .available
    }

    /// Locking an automatic alignment requires readable provenance. The store
    /// is fail-closed: a missing/corrupt sidecar cannot be treated as safe.
    public func isLockable(versionID: UUID) -> Bool {
        let source = url(for: versionID)
        guard let data = try? Data(contentsOf: source) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(AlignmentProvenanceDocument.self, from: data) else {
            return false
        }
        return document.lines.allSatisfy {
            $0.status == .aligned && $0.confidence >= 0.6 && $0.evidence.kind == .directSpeech
        }
    }
}
