import Foundation

/// A working manuscript is an ordinary UTF-8 file with a small LRC header.
/// The writing below the blank line is preserved verbatim, including stanzas.
struct LyricManuscript: Equatable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var text: String
    var recordingKey: String?
    var filedVersionID: UUID?

    static func sourcePrefix(_ id: UUID) -> String { "manuscript:\(id.uuidString):" }

    init(id: UUID = UUID(), title: String = "", artist: String = "", album: String = "", text: String = "",
         recordingKey: String? = nil, filedVersionID: UUID? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.text = text
        self.recordingKey = recordingKey
        self.filedVersionID = filedVersionID
    }

    var data: Data {
        var header = ["[re:Aster · Lyric]", "[aster-draft:\(id.uuidString)]"]
        if let recordingKey { header.append("[aster-recording:\(recordingKey)]") }
        if let filedVersionID { header.append("[aster-version:\(filedVersionID.uuidString)]") }
        for (tag, value) in [("ti", title), ("ar", artist), ("al", album)] where !value.isEmpty {
            header.append("[\(tag):\(value.components(separatedBy: .newlines).joined(separator: " "))]")
        }
        return Data((header.joined(separator: "\n") + "\n\n" + text).utf8)
    }

    init(data: Data) throws {
        let raw = try TextLyricsImportParser.decode(data).text
        guard raw.prefix(while: { !$0.isNewline }) == "[re:Aster · Lyric]" else {
            self.init(text: raw)
            return
        }
        var fields: [String: String] = [:]
        var rest = raw[...]
        var foundBody = false
        while let end = rest.firstIndex(where: \.isNewline) {
            let line = rest[..<end]
            rest = rest[rest.index(after: end)...]
            if line.isEmpty { foundBody = true; break }
            guard line.first == "[", line.last == "]", let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[line.index(after: line.startIndex)..<colon])] = String(line[line.index(after: colon)..<line.index(before: line.endIndex)])
        }
        guard foundBody else { self.init(text: raw); return }
        self.init(id: fields["aster-draft"].flatMap(UUID.init(uuidString:)) ?? UUID(), title: fields["ti"] ?? "",
                  artist: fields["ar"] ?? "", album: fields["al"] ?? "", text: String(rest),
                  recordingKey: fields["aster-recording"], filedVersionID: fields["aster-version"].flatMap(UUID.init(uuidString:)))
    }

    func lyricFile() throws -> LocalLyricsFile { try LocalLyricsFile(manuscript: self) }
}

struct ManuscriptStanzas {
    struct Stanza {
        let text: String
        let lines: [Substring]
        let firstOccurrence: Int
    }

    let stanzas: [Stanza]
    private let leading: String
    private let trailing: String
    private let separators: [String]
    private let newSeparator: String

    init(_ text: String) {
        let original = text as NSString
        var ranges: [NSRange] = []
        var start: Int?, lastContentEnd = 0, cursor = 0
        while cursor < original.length {
            var end = 0, contentEnd = 0
            original.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            let line = original.substring(with: NSRange(location: cursor, length: contentEnd - cursor))
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let start { ranges.append(NSRange(location: start, length: lastContentEnd - start)) }
                start = nil
            } else {
                if start == nil { start = cursor }
                lastContentEnd = contentEnd
            }
            cursor = end
        }
        if let start { ranges.append(NSRange(location: start, length: lastContentEnd - start)) }
        var first: [String: Int] = [:]
        stanzas = ranges.enumerated().map { index, range in
            let body = original.substring(with: range)
            let occurrence = first[body] ?? index
            first[body] = occurrence
            return Stanza(text: body, lines: body.split(whereSeparator: \.isNewline), firstOccurrence: occurrence)
        }
        leading = original.substring(to: ranges.first?.location ?? original.length)
        trailing = ranges.last.map { original.substring(from: NSMaxRange($0)) } ?? ""
        separators = zip(ranges, ranges.dropFirst()).map { left, right in
            original.substring(with: NSRange(location: NSMaxRange(left), length: right.location - NSMaxRange(left)))
        }
        newSeparator = text.contains("\r\n") ? "\r\n\r\n" : "\n\n"
    }

    func moving(_ index: Int, by step: Int) -> String? {
        guard stanzas.indices.contains(index), stanzas.indices.contains(index + step) else { return nil }
        var parts = stanzas.map(\.text)
        parts.swapAt(index, index + step)
        return join(parts)
    }

    func repeatingAtEnd(_ index: Int) -> String? {
        guard stanzas.indices.contains(index) else { return nil }
        return join(stanzas.map(\.text) + [stanzas[index].text])
    }

    private func join(_ parts: [String]) -> String {
        var result = leading
        for (index, part) in parts.enumerated() {
            if index > 0 { result += separators.indices.contains(index - 1) ? separators[index - 1] : newSeparator }
            result += part
        }
        return result + trailing
    }
}
