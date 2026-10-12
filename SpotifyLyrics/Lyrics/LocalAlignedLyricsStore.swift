import Foundation

public enum LocalAlignedLyricsStoreError: Error, Equatable, Sendable {
    case locked(URL)
}

extension LocalAlignedLyricsStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .locked:
            return "本地歌词已锁定，未覆盖现有结果"
        }
    }
}

/// Writes confirmed aligned lyrics into the user local lyrics directory.
/// Does not mutate original audio. Index can rescan afterwards.
public enum LocalAlignedLyricsStore {
    public static func defaultSaveDirectory(
        home: URL = LyricsQStorage.homeDirectory
    ) -> URL {
        home.appendingPathComponent("Music/SpotifyLyrics/Lyrics", isDirectory: true)
    }

    public static func save(
        document: LyricsDocument,
        report: AlignmentReport,
        manuallyCorrected: Bool = false,
        locked: Bool = false,
        versionID: UUID? = nil,
        directory: URL? = nil
    ) throws -> URL {
        let dir = directory ?? defaultSaveDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let title = document.title ?? "unknown"
        let artist = document.artist ?? "unknown"
        let safeTitle = sanitize(title)
        let safeArtist = sanitize(artist)
        let suffix: String
        if let versionID {
            suffix = ".\(report.audioSHA256.prefix(12)).\(versionID.uuidString.prefix(8))"
        } else {
            suffix = ".aligned"
        }
        let fileURL = dir.appendingPathComponent("\(safeArtist) - \(safeTitle)\(suffix).lrc")

        guard !isLocked(fileURL: fileURL) else {
            throw LocalAlignedLyricsStoreError.locked(fileURL)
        }

        let body = LRCParser.serialize(
            document: document,
            report: report,
            manuallyCorrected: manuallyCorrected,
            locked: locked
        )
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        LyricsE2ELog.log("SAVE aligned lrc path=\(fileURL.path) lines=\(document.lines.count) manual=\(manuallyCorrected)")
        // Force index refresh so local provider can see the new file.
        _ = LocalLyricsIndex.shared.entries(forceRescan: true)
        return fileURL
    }

    public static func isLocked(fileURL: URL) -> Bool {
        guard let body = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return body.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces).lowercased() == "# locked=true"
        }
    }

    private static func sanitize(_ text: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return text.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension LRCParser {
    static func serialize(
        document: LyricsDocument,
        report: AlignmentReport? = nil,
        manuallyCorrected: Bool = false,
        locked: Bool = false
    ) -> String {
        var lines: [String] = []
        if let title = document.title { lines.append("[ti:\(title)]") }
        if let artist = document.artist { lines.append("[ar:\(artist)]") }
        if let album = document.album { lines.append("[al:\(album)]") }
        if let duration = document.duration, duration > 0 {
            lines.append("[length:\(formatTimestamp(duration))]")
        }
        lines.append("[re:SpotifyLyrics]")
        lines.append("[ve:alignment-v1]")
        lines.append("[by:automaticAlignment]")
        if let report {
            lines.append(contentsOf: [
                "# source=automaticAlignment",
                "# model=\(report.modelID)",
                "# audioSha256=\(report.audioSHA256)",
                "# sourceVersionID=\(report.sourceVersionID?.uuidString ?? "")",
                "# sourceContentHash=\(report.sourceContentHash ?? "")",
                "# algorithmVersion=\(report.parameters.algorithmVersion)",
                "# recognizerID=\(report.parameters.recognizerID)",
                "# sampleRate=\(report.sampleRate)",
                "# channels=\(report.channels)",
                "# overallConfidence=\(String(format: "%.4f", report.overallConfidence))",
                "# usedVocalsStem=\(report.usedVocalsStem)",
                "# createdAt=\(ISO8601DateFormatter().string(from: report.createdAt))",
                "# manuallyCorrected=\(manuallyCorrected)",
                "# locked=\(locked)"
            ])
            for (idx, line) in report.lines.enumerated() {
                lines.append(
                    "# line\(idx)=status:\(line.status.rawValue);conf:\(String(format: "%.3f", line.confidence));evidence:\(line.evidence.kind.rawValue);segments:\(line.evidence.segmentStartIndex.map(String.init) ?? "-")-\(line.evidence.segmentEndIndex.map(String.init) ?? "-");end:\(line.endTime.map { String(format: "%.3f", $0) } ?? "-")"
                )
            }
        } else {
            lines.append("# source=\(document.source.rawValue)")
            lines.append("# manuallyCorrected=\(manuallyCorrected)")
            lines.append("# locked=\(locked)")
        }

        for line in document.lines {
            let ts = formatTimestamp(line.timestamp)
            lines.append("[\(ts)]\(line.originalText)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatTimestamp(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%02d:%06.3f", minutes, seconds)
    }
}
