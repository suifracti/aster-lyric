import Foundation

/// File-based progressive auto-alignment state (no schema change).
/// Paths: Application Support or TEMP root under SpotifyLyricsAutomaticAlignment/.
public enum AutomaticAlignmentProgressStore {
    public struct TimedLineRecord: Codable, Equatable, Sendable {
        public let lyricLineIndex: Int
        public let startTime: TimeInterval
        public let endTime: TimeInterval?
        public let evidence: String
        public let quality: Double
        public let updatedAt: Date
    }

    public struct ProgressDocument: Codable, Equatable, Sendable {
        public let identityKey: String
        public let parentVersionID: String
        public let sourceContentHash: String
        public let engineID: String
        public var timedLines: [TimedLineRecord]
        public var coveredRanges: [[String: Double]]
        public var updatedAt: Date
        public var lastDecision: String
        public var lastReason: String

        public var timedIndexSet: Set<Int> {
            Set(timedLines.map(\.lyricLineIndex))
        }
    }

    private static var rootDirectory: URL {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested {
            return DebugAcceptanceDataIsolation.configuration.root.appendingPathComponent("alignment-progress", isDirectory: true)
        }
#endif
        let base: URL
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_AUTO_ALIGN_PROGRESS_DIR"],
           !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("SpotifyLyrics", isDirectory: true)
                .appendingPathComponent("AutomaticAlignmentProgress", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func fileURL(identityKey: String, sourceHash: String) -> URL {
        let safe = identityKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = "\(String(safe.prefix(48)))_\(String(sourceHash.prefix(16))).json"
        return rootDirectory.appendingPathComponent(name)
    }

    public static func load(identityKey: String, sourceHash: String) -> ProgressDocument? {
        let url = fileURL(identityKey: identityKey, sourceHash: sourceHash)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProgressDocument.self, from: data)
    }

    public static func save(_ doc: ProgressDocument) throws {
        let url = fileURL(identityKey: doc.identityKey, sourceHash: doc.sourceContentHash)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(doc).write(to: url, options: .atomic)
    }

    /// Merge new draft lines into progress, never replacing higher quality times.
    public static func merge(
        existing: ProgressDocument?,
        identityKey: String,
        parentVersionID: UUID,
        sourceHash: String,
        engineID: String,
        draft: AssistedAlignmentDraft,
        decision: String,
        reason: String
    ) -> ProgressDocument {
        var byIndex: [Int: TimedLineRecord] = [:]
        if let existing {
            for r in existing.timedLines { byIndex[r.lyricLineIndex] = r }
        }
        for line in draft.lines where line.status == .suggested {
            guard let start = line.suggestedStartTime else { continue }
            let evidence = line.evidenceSummary
            if evidence.lowercased().contains("weakinterpolated") { continue }
            let quality: Double = {
                switch line.confidenceClass {
                case .high: return 0.9
                case .medium: return 0.75
                case .low: return 0.55
                case .none: return 0.4
                }
            }()
            if let old = byIndex[line.lyricLineIndex], old.quality > quality + 0.02 {
                continue
            }
            byIndex[line.lyricLineIndex] = TimedLineRecord(
                lyricLineIndex: line.lyricLineIndex,
                startTime: start,
                endTime: line.suggestedEndTime,
                evidence: evidence,
                quality: quality,
                updatedAt: Date()
            )
        }
        return ProgressDocument(
            identityKey: identityKey,
            parentVersionID: parentVersionID.uuidString,
            sourceContentHash: sourceHash,
            engineID: engineID,
            timedLines: byIndex.values.sorted { $0.lyricLineIndex < $1.lyricLineIndex },
            coveredRanges: existing?.coveredRanges ?? [],
            updatedAt: Date(),
            lastDecision: decision,
            lastReason: reason
        )
    }

    public static func applyProgress(
        _ progress: ProgressDocument,
        to plain: LyricsDocument
    ) -> LyricsDocument {
        var lines = plain.lines
        let map = Dictionary(uniqueKeysWithValues: progress.timedLines.map { ($0.lyricLineIndex, $0) })
        for i in lines.indices {
            if let rec = map[i] {
                lines[i].timestamp = rec.startTime
                lines[i].endTime = rec.endTime
            }
        }
        let timedCount = lines.filter { $0.timestamp >= 0 && !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let required = lines.filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let full = required > 0 && timedCount == required
        return LyricsDocument(
            identity: plain.identity,
            title: plain.title,
            artist: plain.artist,
            album: plain.album,
            duration: plain.duration,
            lines: lines,
            isSynchronized: full,
            source: full ? .automaticAlignment : plain.source,
            confidence: plain.confidence,
            providerSourceID: plain.providerSourceID,
            explicitlyTimedLineIndices: full ? nil : Set(map.keys)
        )
    }
}
