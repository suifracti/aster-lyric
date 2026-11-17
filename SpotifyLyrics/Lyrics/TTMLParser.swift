import Foundation

/// ITunes / Apple Music TTML timing mode declared on `<tt>`.
public enum TTMLTimingMode: String, Equatable, Sendable {
    case line = "Line"
    case word = "Word"
    case none = "None"
}

/// Controlled-subset TTML / Apple Music XML lyrics parser for Phase 1.
///
/// Complies with Phase 1 Contracts:
/// - Contract 1: Canonical primary text constructed strictly in XML document order.
/// - Contract 2: `ttm:agent` is preserved as `performerID` (duet lines are formal main lyrics);
///   `ttm:role="x-bg"`, `ttm:role="x-translation"`, `ttm:role="x-roman"` subtrees are strictly excluded from canonical text.
/// - Contract 3: `itunes:timing` modes ("Line", "Word", inferred) supported.
/// - Contract 4: Real fail-closed validation: `canonical[range] == span.text` and Extended Grapheme Cluster alignment.
/// - Contract 5: Marks spans with `.timedUnit` without guessing word/syllable.
public enum TTMLParser {

    public static func parse(
        _ content: String,
        identity: TrackIdentity,
        source: LyricsSource = .amll,
        preferredTranslationLanguage: String = "zh-Hans"
    ) -> LyricsDocument? {
        parse(data: Data(content.utf8), identity: identity, source: source, preferredTranslationLanguage: preferredTranslationLanguage)
    }

    public static func parse(
        data: Data,
        identity: TrackIdentity,
        source: LyricsSource = .amll,
        preferredTranslationLanguage: String = "zh-Hans"
    ) -> LyricsDocument? {
        guard !data.isEmpty else { return nil }
        let delegate = TTMLParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldReportNamespacePrefixes = false
        xmlParser.shouldResolveExternalEntities = false

        guard xmlParser.parse(), delegate.isTimedTextDocument, !delegate.parsedLines.isEmpty else {
            return nil
        }

        let timingMode = delegate.timingMode
        var lines: [LyricLine] = []
        var timedIndices = Set<Int>()

        for rawLine in delegate.parsedLines {
            guard !rawLine.originalText.isEmpty else { continue }

            // If timing mode is explicitly "Line", fine timing is disabled for all lines.
            let validSpans: [TimedTextSpan]? = {
                if timingMode == .line || timingMode == TTMLTimingMode.none {
                    return nil
                }
                guard let candidateSpans = rawLine.candidateSpans, !candidateSpans.isEmpty else {
                    return nil
                }

                // Strict Fail-Closed Verification (Contract 4):
                // 1. Verify every span's UTF-16 range exists within originalText.
                // 2. Verify UTF-16 range translates to valid String.Index Range without crossing grapheme boundaries.
                // 3. Verify originalText[range] == span.text.
                var validatedSpans: [TimedTextSpan] = []
                let utf16 = rawLine.originalText.utf16

                for (index, candidate) in candidateSpans.enumerated() {
                    let startOffset = candidate.utf16Start
                    let length = candidate.utf16Length
                    let endOffset = startOffset + length

                    guard startOffset >= 0, length > 0, endOffset <= utf16.count else {
                        return nil // Out of bounds fail-closed
                    }

                    guard let startUTF16 = utf16.index(utf16.startIndex, offsetBy: startOffset, limitedBy: utf16.endIndex),
                          let endUTF16 = utf16.index(utf16.startIndex, offsetBy: endOffset, limitedBy: utf16.endIndex) else {
                        return nil
                    }

                    guard let startGrapheme = String.Index(startUTF16, within: rawLine.originalText),
                          let endGrapheme = String.Index(endUTF16, within: rawLine.originalText) else {
                        return nil // Non-grapheme boundary fail-closed
                    }

                    let substring = String(rawLine.originalText[startGrapheme..<endGrapheme])
                    guard substring == candidate.text else {
                        return nil // Substring mismatch fail-closed
                    }

                    validatedSpans.append(
                        TimedTextSpan(
                            id: index,
                            text: candidate.text,
                            trailingWhitespace: "",
                            startTime: candidate.startTime,
                            endTime: candidate.endTime,
                            utf16Start: startOffset,
                            utf16Length: length,
                            granularity: .timedUnit
                        )
                    )
                }

                return validatedSpans.isEmpty ? nil : validatedSpans
            }()

            let start = rawLine.startTime ?? validSpans?.first?.startTime
            let hasTiming = timingMode != TTMLTimingMode.none
            if hasTiming && start != nil { timedIndices.insert(lines.count) }
            let linked = rawLine.key.flatMap { delegate.header.linked[$0] } ?? []
            let companions = rawLine.companions + linked
            var translations: [LyricSourceTranslation] = []
            for item in companions where item.kind == .translation && !item.text.isEmpty {
                let track = LyricSourceTranslation(language: item.language, text: item.text)
                if !track.text.isEmpty && !translations.contains(where: { $0.language == track.language }) {
                    translations.append(track)
                }
            }
            lines.append(
                LyricLine(
                    timestamp: hasTiming ? start ?? 0 : 0,
                    originalText: rawLine.originalText,
                    endTime: hasTiming && start != nil ? rawLine.endTime ?? validSpans?.last?.endTime : nil,
                    romajiText: TTMLCompanion.preferred(.romanization, in: companions, language: delegate.language),
                    performerID: rawLine.performerID,
                    timedSpans: validSpans,
                    backgroundText: rawLine.backgroundText,
                    sourceTranslations: translations
                )
            )
        }

        guard !lines.isEmpty else { return nil }
        let synchronized = timedIndices.count == lines.count
        let duration = delegate.bodyDuration ?? timedIndices.compactMap { lines[$0].endTime ?? lines[$0].timestamp }.max()
        if synchronized { lines.sort { $0.timestamp < $1.timestamp } }

        let languages = LyricSourceTranslation.languages(in: lines)
        if let preferred = LyricSourceTranslation.preferred(languages, for: preferredTranslationLanguage) {
            for index in lines.indices { lines[index].translationText = lines[index].sourceTranslation(in: preferred) }
        }

        return LyricsDocument(
            identity: identity,
            title: delegate.header.title,
            artist: delegate.header.artist,
            album: delegate.header.album,
            duration: duration,
            lines: lines,
            isSynchronized: synchronized,
            source: source,
            confidence: 1.0,
            language: delegate.language,
            explicitlyTimedLineIndices: synchronized || timedIndices.isEmpty ? nil : timedIndices
        )
    }

    /// Parses timestamp string in formats: "00:01:23.456", "01:23.45", "12.34s", "1234ms", "12.34"
    public static func parseTimestamp(_ raw: String) -> TimeInterval? {
        guard let seconds = seconds(from: raw), seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max) / 1000 else { return nil }
        return seconds
    }

    private static func seconds(from raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("ms"), let val = Double(trimmed.dropLast(2)) {
            return val / 1000.0
        }
        if trimmed.hasSuffix("s"), let val = Double(trimmed.dropLast(1)) {
            return val
        }

        let parts = trimmed.split(separator: ":")
        if parts.count == 3 {
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            return h * 3600.0 + m * 60.0 + s
        } else if parts.count == 2 {
            guard let m = Double(parts[0]),
                  let s = Double(parts[1]) else { return nil }
            return m * 60.0 + s
        } else if parts.count == 1, let s = Double(parts[0]) {
            return s
        }
        return nil
    }
}

extension TTMLParser {
    /// 和声 text as one tidy line: whitespace collapsed, and the brackets many
    /// files wrap it in removed. Nil when nothing is left.
    static func tidiedBackground(_ raw: String) -> String? {
        var text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let pairs: [(Character, Character)] = [("(", ")"), ("（", "）")]
        for (open, close) in pairs where text.first == open && text.last == close && text.count > 2 {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { text = String(inner).trimmingCharacters(in: .whitespaces) }
        }
        return text.isEmpty ? nil : text
    }
}

private struct TTMLCompanion {
    enum Kind { case translation, romanization }
    let kind: Kind
    let language: String?
    var text = ""

    static func preferred(_ kind: Kind, in tracks: [Self], language: String?) -> String? {
        let available = tracks.filter { $0.kind == kind && !$0.text.isEmpty }
        guard let language else { return available.first?.text }
        let wanted = Locale.Language(identifier: language)
        let sameLanguage = available.filter { track in
            guard let tag = track.language else { return false }
            return Locale.Language(identifier: tag).languageCode == wanted.languageCode
        }
        let match = sameLanguage.first { $0.language?.caseInsensitiveCompare(language) == .orderedSame }
            ?? sameLanguage.first { $0.language.map { Locale.Language(identifier: $0).script == wanted.script } == true }
        return (match ?? sameLanguage.first ?? available.first)?.text
    }
}

/// AMLL inline tags and Apple's separate head tracks can coexist in one file.
/// Only an exact paragraph key attaches a head track to a sung line.
private struct TTMLHeader {
    private(set) var linked: [String: [TTMLCompanion]] = [:]
    private(set) var title: String?
    private(set) var album: String?
    private var artists: [String] = []
    private var agents: [String] = []
    var artist: String? {
        let names = artists.isEmpty ? agents : artists
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var path: [String] = []
    private var track: TTMLCompanion?
    private var lineKey: String?
    private var backgroundDepth: Int?
    private var buffer = ""

    mutating func start(_ name: String, attributes: [String: String], isBackground: Bool) {
        path.append(name)
        if isBackground && backgroundDepth == nil { backgroundDepth = path.count }
        switch name {
        case "meta":
            guard let value = attributes["value"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            switch attributes["key"] {
            case "musicName": title = value
            case "artists" where !artists.contains(value): artists.append(value)
            case "album": album = value
            default: break
            }
        case "translation", "transliteration":
            track = TTMLCompanion(kind: name == "translation" ? .translation : .romanization, language: attributes["xml:lang"])
        case "text" where track != nil:
            lineKey = attributes["for"]
            buffer = ""
        case "title", "name":
            buffer = ""
        default: break
        }
    }

    mutating func characters(_ text: String) {
        guard backgroundDepth == nil else { return }
        if lineKey != nil || path.last == "title" || path.last == "name" { buffer += text }
    }

    mutating func end(_ name: String) {
        if path.count == backgroundDepth { backgroundDepth = nil }
        switch name {
        case "text":
            if let key = lineKey, var value = track {
                value.text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.text.isEmpty { linked[key, default: []].append(value) }
            }
            lineKey = nil
        case "translation", "transliteration": track = nil
        case "title" where title == nil, "name" where path.contains("agent"):
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                if name == "title" { title = value }
                else if !agents.contains(value) { agents.append(value) }
            }
        default: break
        }
        _ = path.popLast()
    }
}

private final class TTMLParserDelegate: NSObject, XMLParserDelegate {
    enum SpanKind {
        case primary
        case background
        case translation
        case romanization
        case ignored
    }

    struct CandidateSpan {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let utf16Start: Int
        let utf16Length: Int
    }

    struct SpanFrame {
        let kind: SpanKind
        let companionIndex: Int?
        let isTimed: Bool
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let utf16StartInCanonical: Int
        var text: String
    }

    struct RawLine {
        let key: String?
        let companions: [TTMLCompanion]
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let performerID: String?
        let originalText: String
        let candidateSpans: [CandidateSpan]?
        let backgroundText: String?
    }

    var header = TTMLHeader()
    var isTimedTextDocument = false
    var language: String?
    var bodyDuration: TimeInterval?
    var timingMode: TTMLTimingMode?
    var parsedLines: [RawLine] = []

    private var inBody = false
    private var inHead = false
    private var inParagraph = false
    private var paragraphIsIgnored = false

    private var currentKey: String?
    private var currentCompanions: [TTMLCompanion] = []
    private var currentLineStart: TimeInterval?
    private var currentLineEnd: TimeInterval?
    private var currentPerformerID: String?

    private var canonicalParagraphText = ""
    /// 和声 (`x-bg`) text of the paragraph, kept beside the canonical text.
    private var backgroundParagraphText = ""
    private var spanStack: [SpanFrame] = []
    private var paragraphCandidateSpans: [CandidateSpan] = []

    private func explicitKind(_ dict: [String: String]) -> SpanKind? {
        let role = (dict["ttm:role"] ?? dict["ttml:role"] ?? dict["role"] ?? "").lowercased()
        if role.contains("x-bg") || role.contains("background") { return .background }
        if role.contains("translation") { return .translation }
        if role.contains("roman") { return .romanization }
        return nil
    }

    private func agent(from dict: [String: String]) -> String? {
        dict["ttm:agent"] ?? dict["agent"]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.components(separatedBy: ":").last!.lowercased()
        if name == "tt" {
            isTimedTextDocument = true
            language = attributeDict["xml:lang"]
            let modeRaw = attributeDict["itunes:timing"] ?? attributeDict["timing"]
            if let modeRaw {
                timingMode = TTMLTimingMode(rawValue: modeRaw)
            }
        } else if name == "head" {
            inHead = true
        } else if inHead {
            header.start(name, attributes: attributeDict, isBackground: explicitKind(attributeDict) == .background)
        } else if name == "body" {
            inBody = true
            bodyDuration = attributeDict["dur"].flatMap(TTMLParser.parseTimestamp)
        } else if inBody && name == "p" {
            inParagraph = true
            canonicalParagraphText = ""
            backgroundParagraphText = ""
            paragraphCandidateSpans = []
            spanStack = []
            currentPerformerID = agent(from: attributeDict)
            currentKey = attributeDict["itunes:key"] ?? attributeDict["key"]
            currentCompanions = []
            paragraphIsIgnored = explicitKind(attributeDict) != nil
            currentLineStart = attributeDict["begin"].flatMap(TTMLParser.parseTimestamp)

            if let endStr = attributeDict["end"] {
                currentLineEnd = TTMLParser.parseTimestamp(endStr)
            } else {
                currentLineEnd = nil
            }
        } else if inParagraph && !paragraphIsIgnored && name == "span" {
            let role = explicitKind(attributeDict)
            let parent = spanStack.last?.kind ?? .primary
            let kind: SpanKind
            var companionIndex = spanStack.last?.companionIndex
            if parent == .primary {
                kind = role ?? .primary
                if kind == .translation || kind == .romanization {
                    companionIndex = currentCompanions.count
                    currentCompanions.append(TTMLCompanion(
                        kind: kind == .translation ? .translation : .romanization,
                        language: attributeDict["xml:lang"]
                    ))
                }
            } else if let role, role != parent {
                // Backing annotations belong to the backing voice, in either nesting direction.
                kind = .ignored
                companionIndex = nil
            } else {
                kind = parent
            }

            let begin = attributeDict["begin"].flatMap(TTMLParser.parseTimestamp)
            let end = attributeDict["end"].flatMap(TTMLParser.parseTimestamp)

            // Contract 2: Only primary spans with explicit begin/end and end >= begin are timed
            let isTimed: Bool
            if kind == .primary, let b = begin, let e = end, e >= b {
                isTimed = true
            } else {
                isTimed = false
            }

            let utf16Start = canonicalParagraphText.utf16.count

            spanStack.append(
                SpanFrame(
                    kind: kind,
                    companionIndex: companionIndex,
                    isTimed: isTimed,
                    startTime: begin,
                    endTime: end,
                    utf16StartInCanonical: utf16Start,
                    text: ""
                )
            )
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if string.contains(where: \.isNewline) && string.allSatisfy(\.isWhitespace) { return }
        if inHead { header.characters(string); return }
        guard inParagraph && !paragraphIsIgnored else { return }

        if !spanStack.isEmpty {
            let topIndex = spanStack.count - 1
            spanStack[topIndex].text += string

            // Contract 1: Only primary span text enters canonical text
            if spanStack[topIndex].kind == .primary {
                canonicalParagraphText += string
            } else if spanStack[topIndex].kind == .background {
                backgroundParagraphText += string
            } else if let index = spanStack[topIndex].companionIndex {
                currentCompanions[index].text += string
            }
        } else {
            // Contract 1: Direct text nodes between spans enter canonical text in order.
            canonicalParagraphText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.components(separatedBy: ":").last!.lowercased()
        if name == "head" {
            inHead = false
        } else if inHead {
            header.end(name)
        } else if inParagraph && !paragraphIsIgnored && name == "span" {
            guard !spanStack.isEmpty else { return }
            let frame = spanStack.removeLast()
            if let index = frame.companionIndex, index != spanStack.last?.companionIndex {
                currentCompanions[index].text = currentCompanions[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if frame.kind == .primary && frame.isTimed {
                let spanLength = frame.text.utf16.count
                if spanLength > 0, let start = frame.startTime, let end = frame.endTime {
                    paragraphCandidateSpans.append(
                        CandidateSpan(
                            text: frame.text,
                            startTime: start,
                            endTime: end,
                            utf16Start: frame.utf16StartInCanonical,
                            utf16Length: spanLength
                        )
                    )
                }
            }
        } else if inParagraph && name == "p" {
            inParagraph = false
            guard !paragraphIsIgnored else { return }

            let raw = canonicalParagraphText
            guard let firstNonWhitespace = raw.firstIndex(where: {
                !CharacterSet.whitespacesAndNewlines.contains($0.unicodeScalars.first!)
            }), let lastNonWhitespace = raw.lastIndex(where: {
                !CharacterSet.whitespacesAndNewlines.contains($0.unicodeScalars.first!)
            }) else {
                return
            }

            let actualLeadingTrim = raw[..<firstNonWhitespace].utf16.count
            let afterLast = raw.index(after: lastNonWhitespace)
            let trimmedCanonical = String(raw[firstNonWhitespace..<afterLast])

            let adjustedSpans: [CandidateSpan]? = {
                guard !paragraphCandidateSpans.isEmpty else { return nil }
                var list: [CandidateSpan] = []
                for candidate in paragraphCandidateSpans {
                    let adjStart = candidate.utf16Start - actualLeadingTrim
                    if adjStart >= 0 && adjStart + candidate.utf16Length <= trimmedCanonical.utf16.count {
                        list.append(
                            CandidateSpan(
                                text: candidate.text,
                                startTime: candidate.startTime,
                                endTime: candidate.endTime,
                                utf16Start: adjStart,
                                utf16Length: candidate.utf16Length
                            )
                        )
                    }
                }
                return list.isEmpty ? nil : list
            }()

            parsedLines.append(
                RawLine(
                    key: currentKey,
                    companions: currentCompanions,
                    startTime: currentLineStart,
                    endTime: currentLineEnd,
                    performerID: currentPerformerID,
                    originalText: trimmedCanonical,
                    candidateSpans: adjustedSpans,
                    backgroundText: TTMLParser.tidiedBackground(backgroundParagraphText)
                )
            )
        } else if name == "body" {
            inBody = false
        }
    }
}
