import Compression
import Foundation

/// Kugou's word-timed lyrics (KRC). The download (`fmt=krc`) is base64 of
/// `krc1` + bytes XOR'd with a fixed 16-byte key + a zlib stream. Inside, a
/// line is `[lineStartMs,lineDurationMs]` followed by `<offsetMs,durationMs,0>text`
/// for each word, offsets relative to the line. A line that is only a
/// singer's name and a colon (`刘兆宇：`) says who sings the lines after it;
/// it becomes the performer of those lines and is not shown itself.
/// A `[language:…]` tag may carry base64 JSON with a translation.
enum KRCParser {
    static let key: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

    static func decrypt(base64 content: String) -> String? {
        guard let raw = Data(base64Encoded: content), raw.count > 6,
              Array(raw.prefix(4)) == Array("krc1".utf8) else { return nil }
        var bytes = [UInt8](raw.dropFirst(4))
        for index in bytes.indices { bytes[index] ^= key[index % key.count] }
        // zlib: a 2-byte header, raw DEFLATE, a 4-byte checksum.
        guard bytes.count > 6 else { return nil }
        let deflate = Array(bytes[2...])
        var capacity = max(64 * 1024, deflate.count * 8)
        while capacity <= 16 << 20 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = compression_decode_buffer(&output, capacity, deflate, deflate.count, nil, COMPRESSION_ZLIB)
            if written > 0 && written < capacity {
                return String(decoding: output[0..<written], as: UTF8.self)
            }
            if written == 0 { return nil }
            capacity *= 4
        }
        return nil
    }

    private static let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"<(\d+),(\d+),-?\d+>([^<]*)"#)
    private static let singerRegex = try! NSRegularExpression(pattern: #"^\s*([^\s:：\[\]]{1,16})\s*[:：]\s*$"#)

    static func parse(_ text: String, identity: TrackIdentity, source: LyricsSource) -> LyricsDocument? {
        var lines: [LyricLine] = []
        var performer: String?
        var translations: [String] = []
        var rawIndices: [Int] = []
        var rawCount = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[language:"), let end = line.lastIndex(of: "]") {
                translations = translation(fromLanguageTag: String(line[line.index(line.startIndex, offsetBy: 10)..<end]))
                continue
            }
            let whole = NSRange(line.startIndex..., in: line)
            guard let match = lineRegex.firstMatch(in: line, range: whole),
                  let startRange = Range(match.range(at: 1), in: line),
                  let durationRange = Range(match.range(at: 2), in: line),
                  let restRange = Range(match.range(at: 3), in: line),
                  let startMs = Double(line[startRange]), let durationMs = Double(line[durationRange]) else { continue }
            let lineStart = startMs / 1000
            let rest = String(line[restRange])
            var words: [(text: String, start: Double, end: Double)] = []
            for word in wordRegex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                guard let o = Range(word.range(at: 1), in: rest), let d = Range(word.range(at: 2), in: rest),
                      let t = Range(word.range(at: 3), in: rest),
                      let offset = Double(rest[o]), let duration = Double(rest[d]) else { continue }
                let piece = String(rest[t])
                guard !piece.isEmpty else { continue }
                let start = lineStart + offset / 1000
                words.append((piece, start, start + duration / 1000))
            }
            let rawIndex = rawCount
            rawCount += 1
            let full = words.isEmpty ? rest : words.map(\.text).joined()
            let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let singer = singerRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let nameRange = Range(singer.range(at: 1), in: trimmed) {
                performer = String(trimmed[nameRange])
                continue
            }
            var spans: [TimedTextSpan] = []
            var cursor = 0
            for (index, word) in words.enumerated() {
                let length = word.text.utf16.count
                spans.append(TimedTextSpan(id: index, text: word.text, startTime: word.start, endTime: max(word.start, word.end),
                                           utf16Start: cursor, utf16Length: length))
                cursor += length
            }
            let hasTiming = spans.contains { $0.endTime > $0.startTime }
            rawIndices.append(rawIndex)
            lines.append(LyricLine(timestamp: lineStart, originalText: full,
                                   endTime: durationMs > 0 ? lineStart + durationMs / 1000 : nil,
                                   performerID: performer,
                                   timedSpans: hasTiming ? spans : nil))
        }
        guard !lines.isEmpty else { return nil }
        // A single named singer is not a duet.
        if Set(lines.compactMap(\.performerID)).count < 2 {
            lines = lines.map { var line = $0; line.performerID = nil; return line }
        }
        // Translation rows follow every timed line of the file, singer lines included.
        if !translations.isEmpty, translations.count == rawCount {
            for (index, raw) in rawIndices.enumerated() where !translations[raw].trimmingCharacters(in: .whitespaces).isEmpty {
                lines[index].translationText = translations[raw]
            }
        }
        lines.sort { $0.timestamp < $1.timestamp }
        return LyricsDocument(identity: identity, title: nil, artist: nil, album: nil,
                              duration: lines.last.map { $0.endTime ?? $0.timestamp },
                              lines: lines, isSynchronized: true, source: source, confidence: 1)
    }

    /// `{"content":[{"type":1,"lyricContent":[["译文"],…]}]}`; type 1 is a translation.
    static func translation(fromLanguageTag tag: String) -> [String] {
        guard let data = Data(base64Encoded: tag),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              let entry = content.first(where: { ($0["type"] as? Int) == 1 }),
              let rows = entry["lyricContent"] as? [[String]] else { return [] }
        return rows.map { $0.joined() }
    }
}
