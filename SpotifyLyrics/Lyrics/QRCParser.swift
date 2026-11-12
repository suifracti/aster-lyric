import Compression
import Foundation

/// QQ Music's word-timed lyrics (QRC). The lyric arrives as hex; QQ encrypts
/// it with triple DES (decrypt–encrypt–decrypt, key
/// `!@#)(*$%123ZXC!@!@#)(NHL`) in a variant of a well-known public-domain
/// DES (see `QQDES`).
/// After that a zlib stream gives XML whose `LyricContent` holds lines like
/// `[22120,3390]不(22120,330)如(22450,420)` — a word, then its absolute start
/// and duration in milliseconds.
enum QRCParser {
    static let key = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    static func decrypt(hex: String) -> String? {
        let digits = Array(hex.utf8)
        guard digits.count >= 16, digits.count % 16 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(digits.count / 2)
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var index = 0
        while index < digits.count {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        let k1 = QQDES.subkeys(Array(key[0..<8]), decrypt: true)
        let k2 = QQDES.subkeys(Array(key[8..<16]), decrypt: false)
        let k3 = QQDES.subkeys(Array(key[16..<24]), decrypt: true)
        var plain = [UInt8](); plain.reserveCapacity(bytes.count)
        var offset = 0
        while offset < bytes.count {
            var block = Array(bytes[offset..<(offset + 8)])
            block = QQDES.crypt(block, k3)
            block = QQDES.crypt(block, k2)
            block = QQDES.crypt(block, k1)
            plain += block
            offset += 8
        }
        guard plain.count > 6, plain[0] == 0x78 else { return nil }
        let deflate = Array(plain[2...])
        var capacity = max(64 * 1024, deflate.count * 8)
        while capacity <= 16 << 20 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = compression_decode_buffer(&output, capacity, deflate, deflate.count, nil, COMPRESSION_ZLIB)
            if written > 0 && written < capacity {
                var text = Array(output[0..<written])
                if text.starts(with: [0xEF, 0xBB, 0xBF]) { text.removeFirst(3) }
                return String(decoding: text, as: UTF8.self)
            }
            if written == 0 { return nil }
            capacity *= 4
        }
        return nil
    }

    /// The QRC text inside the XML (`LyricContent="…"`), or the text itself
    /// when it is not XML.
    static func lyricContent(fromXML xml: String) -> String? {
        guard xml.contains("LyricContent") else { return xml.contains("[") ? xml : nil }
        guard let start = xml.range(of: "LyricContent=\"") else { return nil }
        let rest = xml[start.upperBound...]
        guard let end = rest.range(of: "\"/>") ?? rest.range(of: "\" />") ?? rest.range(of: "\"") else { return nil }
        return String(rest[..<end.lowerBound])
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#10;", with: "\n").replacingOccurrences(of: "&#13;", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"(.*?)\((\d+),(\d+)\)"#)
    private static let singerRegex = try! NSRegularExpression(pattern: #"^\s*([^\s:：\[\]]{1,16})\s*[:：]\s*$"#)

    /// Lines with word spans. A line that is only `歌手：` names the singer
    /// of the lines after it, as in Kugou's KRC.
    static func parseLines(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var performer: String?
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = lineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let s = Range(match.range(at: 1), in: line), let d = Range(match.range(at: 2), in: line),
                  let r = Range(match.range(at: 3), in: line),
                  let startMs = Double(line[s]), let durationMs = Double(line[d]) else { continue }
            let rest = String(line[r])
            var words: [(text: String, start: Double, end: Double)] = []
            for word in wordRegex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                guard let t = Range(word.range(at: 1), in: rest), let ws = Range(word.range(at: 2), in: rest),
                      let wd = Range(word.range(at: 3), in: rest),
                      let wordStart = Double(rest[ws]), let wordDuration = Double(rest[wd]) else { continue }
                let text = String(rest[t])
                guard !text.isEmpty else { continue }
                words.append((text, wordStart / 1000, (wordStart + wordDuration) / 1000))
            }
            let full = words.isEmpty ? rest : words.map(\.text).joined()
            let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let singer = singerRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let name = Range(singer.range(at: 1), in: trimmed) {
                performer = String(trimmed[name])
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
            let lineStart = startMs / 1000
            lines.append(LyricLine(timestamp: lineStart, originalText: full,
                                   endTime: durationMs > 0 ? lineStart + durationMs / 1000 : nil,
                                   performerID: performer,
                                   timedSpans: spans.contains { $0.endTime > $0.startTime } ? spans : nil))
        }
        if Set(lines.compactMap(\.performerID)).count < 2 {
            lines = lines.map { var line = $0; line.performerID = nil; return line }
        }
        return lines.sorted { $0.timestamp < $1.timestamp }
    }
}

/// QQ Music's DES. It descends from Brad Conte's public-domain DES and keeps
/// its bit layout (each 4-byte word read in reverse), with QQ's changes: two
/// S-box entries (S2[23] = 15, S4[53] = 10) and a key schedule whose second
/// half reads its bits one place over. Lyricify Lyrics Helper (Apache-2.0)
/// documents the same algorithm; this is an independent Swift version.
enum QQDES {
    private static let sboxes: [[UInt8]] = {
        var boxes: [[UInt8]] = [
            [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
            [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
            [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
            [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
            [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
            [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
            [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
            [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]]
        boxes[1][23] = 15
        boxes[3][53] = 10
        return boxes
    }()

    /// Bit `b` of the block, counting each 4-byte word from its last byte.
    private static func bit(_ a: [UInt8], _ b: Int, to c: Int) -> UInt32 {
        UInt32((a[b / 32 * 4 + 3 - (b % 32) / 8] >> (7 - (b % 8))) & 1) << UInt32(c)
    }
    private static func bitR(_ a: UInt32, _ b: Int, to c: Int) -> UInt8 { UInt8(((a >> UInt32(31 - b)) & 1) << UInt32(c)) }
    private static func bitL(_ a: UInt32, _ b: Int, to c: Int) -> UInt32 { ((a << UInt32(b)) & 0x8000_0000) >> UInt32(c) }
    private static func sboxIndex(_ a: UInt8) -> Int { Int((a & 0x20) | ((a & 0x1F) >> 1) | ((a & 0x01) << 4)) }

    private static let shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let permC = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    private static let permD = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    private static let compression = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
                                      40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]
    private static let roundPermutation = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9,
                                           1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24]

    static func subkeys(_ key: [UInt8], decrypt: Bool) -> [[UInt8]] {
        var c: UInt32 = 0, d: UInt32 = 0
        for i in 0..<28 {
            c |= bit(key, permC[i], to: 31 - i)
            d |= bit(key, permD[i], to: 31 - i)
        }
        var schedule = [[UInt8]](repeating: [UInt8](repeating: 0, count: 6), count: 16)
        for round in 0..<16 {
            let s = UInt32(shifts[round])
            c = ((c << s) | (c >> (28 - s))) & 0xFFFF_FFF0
            d = ((d << s) | (d >> (28 - s))) & 0xFFFF_FFF0
            let target = decrypt ? 15 - round : round
            for j in 0..<24 { schedule[target][j / 8] |= bitR(c, compression[j], to: 7 - j % 8) }
            for j in 24..<48 { schedule[target][j / 8] |= bitR(d, compression[j] - 27, to: 7 - j % 8) }
        }
        return schedule
    }

    private static func f(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        let t1 = bitL(state, 31, to: 0) | ((state & 0xF000_0000) >> 1) | bitL(state, 4, to: 5) | bitL(state, 3, to: 6)
            | ((state & 0x0F00_0000) >> 3) | bitL(state, 8, to: 11) | bitL(state, 7, to: 12)
            | ((state & 0x00F0_0000) >> 5) | bitL(state, 12, to: 17) | bitL(state, 11, to: 18)
            | ((state & 0x000F_0000) >> 7) | bitL(state, 16, to: 23)
        let t2 = bitL(state, 15, to: 0) | ((state & 0x0000_F000) << 15) | bitL(state, 20, to: 5) | bitL(state, 19, to: 6)
            | ((state & 0x0000_0F00) << 13) | bitL(state, 24, to: 11) | bitL(state, 23, to: 12)
            | ((state & 0x0000_00F0) << 11) | bitL(state, 28, to: 17) | bitL(state, 27, to: 18)
            | ((state & 0x0000_000F) << 9) | bitL(state, 0, to: 23)
        var large: [UInt8] = [UInt8(t1 >> 24 & 0xFF), UInt8(t1 >> 16 & 0xFF), UInt8(t1 >> 8 & 0xFF),
                              UInt8(t2 >> 24 & 0xFF), UInt8(t2 >> 16 & 0xFF), UInt8(t2 >> 8 & 0xFF)]
        for i in 0..<6 { large[i] ^= key[i] }
        let sixes: [UInt8] = [large[0] >> 2, ((large[0] & 0x03) << 4) | (large[1] >> 4),
                              ((large[1] & 0x0F) << 2) | (large[2] >> 6), large[2] & 0x3F,
                              large[3] >> 2, ((large[3] & 0x03) << 4) | (large[4] >> 4),
                              ((large[4] & 0x0F) << 2) | (large[5] >> 6), large[5] & 0x3F]
        var mixed: UInt32 = 0
        for (box, six) in sixes.enumerated() { mixed |= UInt32(sboxes[box][sboxIndex(six)]) << UInt32(28 - 4 * box) }
        var result: UInt32 = 0
        for (destination, source) in roundPermutation.enumerated() { result |= bitL(mixed, source, to: destination) }
        return result
    }

    static func crypt(_ input: [UInt8], _ keys: [[UInt8]]) -> [UInt8] {
        var s0: UInt32 = 0, s1: UInt32 = 0
        for group in 0..<4 {
            for step in 0..<8 {
                let position = 31 - (group * 8 + step)
                s0 |= bit(input, 57 + 2 * group - 8 * step, to: position)
                s1 |= bit(input, 56 + 2 * group - 8 * step, to: position)
            }
        }
        for round in 0..<15 {
            let t = s1
            s1 = f(s1, keys[round]) ^ s0
            s0 = t
        }
        s0 = f(s1, keys[15]) ^ s0
        var output = [UInt8](repeating: 0, count: 8)
        let order = [3, 2, 1, 0, 7, 6, 5, 4]
        for (k, index) in order.enumerated() {
            let b = 7 - k
            output[index] = bitR(s1, b, to: 7) | bitR(s0, b, to: 6) | bitR(s1, b + 8, to: 5) | bitR(s0, b + 8, to: 4)
                | bitR(s1, b + 16, to: 3) | bitR(s0, b + 16, to: 2) | bitR(s1, b + 24, to: 1) | bitR(s0, b + 24, to: 0)
        }
        return output
    }
}
