import Foundation

/// Parser for NetEase YRC (verbatim / word-timed) lyrics format.
///
/// Format per line:
/// `[lineStartMs,lineDurationMs](word1StartMs,word1DurationMs,0)word1Text(word2StartMs,word2DurationMs,0)word2Text...`
public enum YRCParser {
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\[(\d+),(\d+)(?:,\d+)?\](.*)$"#
    )
    private static let wordRegex = try! NSRegularExpression(
        pattern: #"\((\d+),(\d+)(?:,\d+)?\)(.*?)(?=\(\d+,\d+(?:,\d+)?\)|$)"#
    )

    public static func parse(
        _ content: String,
        identity: TrackIdentity,
        source: LyricsSource = .neteaseExperimental
    ) -> LyricsDocument? {
        guard !content.isEmpty else { return nil }

        var parsedLines: [LyricLine] = []
        var title: String?
        var artist: String?
        var album: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Check metadata tags e.g. [ti: ...], [ar: ...]
            if let tag = metadataTag(in: line) {
                switch tag.key {
                case "ti": title = tag.value
                case "ar": artist = tag.value
                case "al": album = tag.value
                default: break
                }
                continue
            }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let lineMatch = lineRegex.firstMatch(in: line, range: lineRange) else {
                continue
            }

            guard let startMsRange = Range(lineMatch.range(at: 1), in: line),
                  let durMsRange = Range(lineMatch.range(at: 2), in: line),
                  let startMs = Double(line[startMsRange]),
                  let durMs = Double(line[durMsRange]) else {
                continue
            }

            let lineStart = startMs / 1000.0
            let lineEnd = lineStart + (durMs / 1000.0)

            guard let restRange = Range(lineMatch.range(at: 3), in: line) else {
                continue
            }
            let rest = String(line[restRange])
            let restNSRange = NSRange(rest.startIndex..<rest.endIndex, in: rest)
            let wordMatches = wordRegex.matches(in: rest, range: restNSRange)

            if wordMatches.isEmpty {
                let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                parsedLines.append(
                    LyricLine(
                        timestamp: lineStart,
                        originalText: trimmed,
                        endTime: durMs > 0 ? lineEnd : nil
                    )
                )
                continue
            }

            var words: [(text: String, start: TimeInterval, end: TimeInterval)] = []
            var fullLineText = ""

            for wMatch in wordMatches {
                guard let wStartRange = Range(wMatch.range(at: 1), in: rest),
                      let wDurRange = Range(wMatch.range(at: 2), in: rest),
                      let wStartMs = Double(rest[wStartRange]),
                      let wDurMs = Double(rest[wDurRange]),
                      let wTextRange = Range(wMatch.range(at: 3), in: rest) else {
                    continue
                }
                let wText = String(rest[wTextRange])
                guard !wText.isEmpty else { continue }

                let wStart = wStartMs / 1000.0
                let wEnd = wStart + (wDurMs / 1000.0)
                words.append((text: wText, start: wStart, end: wEnd))
                fullLineText += wText
            }

            guard !words.isEmpty else { continue }

            var spans: [TimedTextSpan] = []
            spans.reserveCapacity(words.count)
            var currentU16 = 0
            var hasRealDuration = false

            for (idx, w) in words.enumerated() {
                let u16Length = w.text.utf16.count
                if w.end > w.start {
                    hasRealDuration = true
                }
                spans.append(
                    TimedTextSpan(
                        id: idx,
                        text: w.text,
                        trailingWhitespace: "",
                        startTime: w.start,
                        endTime: w.end,
                        utf16Start: currentU16,
                        utf16Length: u16Length,
                        granularity: .timedUnit
                    )
                )
                currentU16 += u16Length
            }

            let lineSpans = hasRealDuration ? spans : nil
            let bounds = TimedLineBounds.covering(spans: lineSpans ?? [], start: lineStart,
                                                  end: durMs > 0 ? lineEnd : (words.last?.end ?? lineStart))

            parsedLines.append(
                LyricLine(
                    timestamp: bounds.start,
                    originalText: fullLineText,
                    endTime: bounds.end,
                    timedSpans: lineSpans
                )
            )
        }

        guard !parsedLines.isEmpty else { return nil }
        parsedLines.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }

        let duration = parsedLines.last?.endTime ?? parsedLines.last?.timestamp

        return LyricsDocument(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lines: parsedLines,
            isSynchronized: true,
            source: source,
            confidence: 1.0
        )
    }

    private static func metadataTag(in line: String) -> (key: String, value: String)? {
        guard line.first == "[", let closing = line.firstIndex(of: ":"), let end = line.firstIndex(of: "]"), closing < end else {
            return nil
        }
        let keyStart = line.index(after: line.startIndex)
        let key = String(line[keyStart..<closing]).lowercased()
        let valueStart = line.index(after: closing)
        let value = String(line[valueStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }
}

/// Imports a matching recording from an existing Lyrimuse file cache when
/// the reader explicitly searches alternate versions. No account or service
/// access is needed.
enum LyrimuseLyricsCache {
    private struct Recording: Decodable {
        let spotify_track_id: String?
        let duration_secs: TimeInterval?
        let lyrics_speakers: Speakers?
        struct Speakers: Decodable { let yrc: [String]? }
    }

    static func candidate(for track: Track, root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse", isDirectory: true)) -> LyricsCandidate? {
        guard let id = TrackIdentity.spotifyRequestTrackID(track.spotifyId ?? track.spotifyURL?.absoluteString),
              let data = read(root.appendingPathComponent("lyrimuse-enrich-index.json"), limit: 24 << 20),
              let recordings = try? JSONDecoder().decode([String: Recording].self, from: data) else { return nil }
        let matches = recordings.filter { $0.value.spotify_track_id == id }.sorted { $0.key < $1.key }
        let identity = TrackIdentity(track: track)
        for (key, record) in matches {
            guard !Task.isCancelled, let duration = record.duration_secs, duration.isFinite,
                  duration > 0, track.duration <= 0 || abs(track.duration - duration) <= 2 else { continue }
            let names = key.split(separator: "|", omittingEmptySubsequences: false)
            guard names.count == 3, !names.joined().contains("/"),
                  TrackTextNormalizer.normalize(String(names[1])) == TrackTextNormalizer.normalize(track.title) else { continue }
            let base = root.appendingPathComponent("lyrics", isDirectory: true)
                .appendingPathComponent(names.joined(separator: " - "))
            guard let body = read(base.appendingPathExtension("yrc"), limit: 1 << 20),
                  let lyrics = String(data: body, encoding: .utf8) else { continue }
            let rawRows = lyrics.split(whereSeparator: \.isNewline).filter { $0.first == "[" && $0.dropFirst().first?.isNumber == true }
            var lines = rawRows.compactMap { YRCParser.parse(String($0), identity: identity, source: .local)?.lines.first }
            guard lines.count == rawRows.count, let last = lines.last,
                  zip(lines, lines.dropFirst()).allSatisfy({ $0.timestamp <= $1.timestamp }),
                  last.timestamp <= duration + 0.5,
                  lines.contains(where: { $0.hasValidTimedSpans() }) else { continue }
            if let roles = record.lyrics_speakers?.yrc, roles.count == lines.count,
               roles.allSatisfy({ ["", "v1", "v2", "v3", "合"].contains($0) }) {
                for i in lines.indices where !roles[i].isEmpty {
                    lines[i].performerID = roles[i] == "合" ? LyricAgentPresentationMap.ensembleID : roles[i]
                }
            }
            if let translated = read(base.appendingPathExtension("tr.lrc"), limit: 1 << 20),
               let content = String(data: translated, encoding: .utf8) {
                lines = TimedLyricsCompanionMerger.merge(content, into: lines, layer: .translation)
                for index in lines.indices {
                    if let translation = lines[index].translationText {
                        lines[index].sourceTranslations = [.init(language: nil, text: translation)]
                    }
                }
            }
            if let romanized = read(base.appendingPathExtension("roma.lrc"), limit: 1 << 20),
               let content = String(data: romanized, encoding: .utf8) {
                lines = TimedLyricsCompanionMerger.merge(content, into: lines, layer: .romaji)
            }
            let candidateID = "lyrimuse-cache:" + id
            return LyricsCandidate(id: candidateID, identity: identity, title: track.title, artist: track.artist,
                album: track.album, duration: duration, lines: lines, isSynchronized: true, source: .local,
                confidence: 1, providerSourceID: candidateID, spotifyTrackID: id, providerName: "Lyrimuse 本机缓存")
        }
        return nil
    }

    private static func read(_ url: URL, limit: Int) -> Data? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, (1...limit).contains(size) else { return nil }
        return try? Data(contentsOf: url)
    }
}
