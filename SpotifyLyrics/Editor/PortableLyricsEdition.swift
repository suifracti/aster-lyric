import Foundation

enum PortableLyricsFormat: CaseIterable, Identifiable {
    case ttml, originalLRC, translationLRC, readingText

    var id: Self { self }
    var fileExtension: String {
        switch self {
        case .ttml: "ttml"
        case .originalLRC, .translationLRC: "lrc"
        case .readingText: "txt"
        }
    }
    var label: String {
        switch self {
        case .ttml: "完整歌词 · TTML"
        case .originalLRC: "原词 · LRC"
        case .translationLRC: "当前译文 · LRC"
        case .readingText: "对照文本 · TXT"
        }
    }
}

/// Everything written to a portable file comes from the open edition. The
/// playback session and the adopted version of a different recording are irrelevant.
struct PortableLyricsEdition {
    let document: LyricsDocument
    let title: String
    var originalSource = ""
    var originalLocked = false
    var translationLanguage: String?
    var translationSource = ""
    var translationLocked = false
    var readings: [String?] = []
    var matchesOriginal = true

    var formats: [PortableLyricsFormat] {
        guard matchesOriginal else { return [.readingText] }
        var result: [PortableLyricsFormat] = [.ttml, .originalLRC]
        if document.lines.contains(where: { $0.translationText?.isEmpty == false }) { result.append(.translationLRC) }
        result.append(.readingText)
        return result
    }

    func filename(for format: PortableLyricsFormat) -> String {
        let stem = title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).filter { !$0.isEmpty }.joined(separator: " ")
        let tag = format == .translationLRC ? "." + (translationLanguage ?? "und") : ""
        return (stem.isEmpty ? "歌词" : stem) + tag + " · 副本." + format.fileExtension
    }

    func contents(_ format: PortableLyricsFormat) -> String {
        switch format {
        case .originalLRC:
            return LRCExporter.original(document: document, source: originalSource, locked: originalLocked)
        case .translationLRC:
            return LRCExporter.translation(document: document, translations: document.lines.map { $0.translationText ?? "" },
                                           targetLanguage: translationLanguage ?? "und", source: translationSource, locked: translationLocked)
        case .readingText:
            let byline = [document.artist, document.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            var paragraphs = [[title, byline].filter { !$0.isEmpty }.joined(separator: "\n")]
            for (index, line) in document.lines.enumerated() {
                let reading = readings.indices.contains(index) ? readings[index]
                    : [line.kanaText, line.romajiText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let background = line.backgroundText.flatMap { $0.isEmpty ? nil : "（\($0)）" }
                paragraphs.append([line.originalText, reading, line.translationText, background].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
        case .ttml:
            return ttml()
        }
    }

    private func ttml() -> String {
        let root = XMLElement(name: "tt")
        for (prefix, uri) in [("", "http://www.w3.org/ns/ttml"), ("ttm", "http://www.w3.org/ns/ttml#metadata"),
                              ("amll", "http://www.example.com/ns/amll")] {
            root.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        }
        root.setAttributesWith(["xml:lang": document.language ?? "und"])
        let head = XMLElement(name: "head"), metadata = XMLElement(name: "metadata")
        root.addChild(head)
        head.addChild(metadata)
        for (key, value) in [("musicName", document.title ?? title), ("artists", document.artist), ("album", document.album)] {
            guard let value, !value.isEmpty else { continue }
            let item = XMLElement(name: "amll:meta")
            item.setAttributesWith(["key": key, "value": value])
            metadata.addChild(item)
        }
        let agents = Self.agentIDs(document.lines)
        for id in agents.values.sorted() {
            let agent = XMLElement(name: "ttm:agent")
            agent.setAttributesWith(["type": "other", "xml:id": id])
            metadata.addChild(agent)
        }
        let body = XMLElement(name: "body"), div = XMLElement(name: "div")
        if let duration = document.duration.flatMap(Self.clock) { body.setAttributesWith(["dur": duration]) }
        root.addChild(body)
        body.addChild(div)
        for (index, line) in document.lines.enumerated() where !line.originalText.isEmpty {
            let p = XMLElement(name: "p")
            var attributes: [String: String] = [:]
            if document.lineHasExplicitTiming(index) {
                attributes["begin"] = Self.clock(line.timestamp)
                attributes["end"] = line.endTime.flatMap(Self.clock)
            }
            attributes["ttm:agent"] = line.performerID.flatMap { agents[$0] }
            p.setAttributesWith(attributes)
            div.addChild(p)
            let spans = line.hasValidTimedSpans(lineStartIsMeaningful: document.lineHasExplicitTiming(index))
                ? line.resolvedGraphemeSpans() ?? [] : []
            var cursor = line.originalText.startIndex
            for span in spans {
                p.addText(String(line.originalText[cursor..<span.range.lowerBound]))
                let word = XMLElement(name: "span", stringValue: String(line.originalText[span.range]))
                word.setAttributesWith(["begin": Self.clock(span.startTime), "end": Self.clock(span.endTime)].compactMapValues { $0 })
                p.addChild(word)
                cursor = span.range.upperBound
            }
            p.addText(String(line.originalText[cursor...]))
            let translations = line.sourceTranslations.isEmpty
                ? line.translationText.map { [LyricSourceTranslation(language: translationLanguage, text: $0)] } ?? [] : line.sourceTranslations
            for track in translations { p.addCompanion("x-translation", text: track.text, language: track.language) }
            let languageCode = document.language.flatMap { Locale.Language(identifier: $0).languageCode?.identifier } ?? "und"
            p.addCompanion("x-roman", text: line.romajiText, language: languageCode + "-Latn")
            p.addCompanion("x-bg", text: line.backgroundText)
        }
        let xml = XMLDocument(rootElement: root)
        xml.version = "1.0"
        xml.characterEncoding = "UTF-8"
        // Pretty-printing would insert new whitespace into sung phrases.
        return xml.xmlString(options: .nodeCompactEmptyElement) + "\n"
    }

    private static func clock(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1_000 else { return nil }
        let ms = Int((seconds * 1_000).rounded())
        return String(format: "%02lld:%02lld:%02lld.%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1_000 % 60, ms % 1_000)
    }

    private static func agentIDs(_ lines: [LyricLine]) -> [String: String] {
        let voices = Set(lines.compactMap(\.performerID).filter { !$0.isEmpty }).sorted()
        var names: [String: String] = [:]
        for voice in voices where voice.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil { names[voice] = voice }
        var next = 1
        for voice in voices where names[voice] == nil {
            while names.values.contains("v\(next)") { next += 1 }
            names[voice] = "v\(next)"
            next += 1
        }
        return names
    }
}

private extension XMLElement {
    func addText(_ value: String) {
        if !value.isEmpty { addChild(XMLNode.text(withStringValue: value) as! XMLNode) }
    }

    func addCompanion(_ role: String, text: String?, language: String? = nil) {
        guard let text, !text.isEmpty else { return }
        let span = XMLElement(name: "span", stringValue: text)
        span.setAttributesWith(["ttm:role": role, "xml:lang": language].compactMapValues { $0 })
        addChild(span)
    }
}

extension LibraryPassagePage {
    var portableEdition: PortableLyricsEdition {
        let track = entry.libraryTrack
        let timed = Set(lines.indices.filter { lines[$0].startTime != nil })
        let document = LyricsDocument(identity: TrackIdentity(track: track), title: entry.title, artist: entry.artist,
            album: entry.album, duration: entry.duration > 0 ? entry.duration : nil,
            lines: lines.map(\.lyricLine), isSynchronized: !lines.isEmpty && timed.count == lines.count,
            source: .manualImport, language: language,
            explicitlyTimedLineIndices: timed.isEmpty ? nil : timed)
        return PortableLyricsEdition(document: document, title: entry.title, originalSource: originalSource, originalLocked: originalLocked,
            translationLanguage: translationLanguage, translationSource: translationSource, translationLocked: translationLocked,
            readings: lines.map(\.reading), matchesOriginal: matchesOriginalVersion)
    }
}
