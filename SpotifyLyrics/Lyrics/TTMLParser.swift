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
        source: LyricsSource = .amll
    ) -> LyricsDocument? {
        guard let data = content.data(using: .utf8), !content.isEmpty else { return nil }

        let delegate = TTMLParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldReportNamespacePrefixes = false
        xmlParser.shouldResolveExternalEntities = false

        guard xmlParser.parse(), !delegate.parsedLines.isEmpty else {
            return nil
        }

        let timingMode = delegate.timingMode
        var lines: [LyricLine] = []

        for rawLine in delegate.parsedLines {
            guard !rawLine.originalText.isEmpty else { continue }

            // If timing mode is explicitly "Line", fine timing is disabled for all lines.
            let validSpans: [TimedTextSpan]? = {
                if timingMode == .line {
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

            lines.append(
                LyricLine(
                    timestamp: rawLine.startTime,
                    originalText: rawLine.originalText,
                    endTime: rawLine.endTime,
                    performerID: rawLine.performerID,
                    timedSpans: validSpans,
                    backgroundText: rawLine.backgroundText
                )
            )
        }

        guard !lines.isEmpty else { return nil }
        lines.sort { $0.timestamp < $1.timestamp }

        let duration = lines.last?.endTime ?? lines.last?.timestamp

        return LyricsDocument(
            identity: identity,
            title: delegate.title,
            artist: delegate.artist,
            duration: duration,
            lines: lines,
            isSynchronized: true,
            source: source,
            confidence: 1.0
        )
    }

    /// Parses timestamp string in formats: "00:01:23.456", "01:23.45", "12.34s", "1234ms", "12.34"
    public static func parseTimestamp(_ raw: String) -> TimeInterval? {
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

private final class TTMLParserDelegate: NSObject, XMLParserDelegate {
    enum SpanKind {
        case primary
        case background
        case translation
        case romanization
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
        let isTimed: Bool
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let utf16StartInCanonical: Int
        var text: String
    }

    struct RawLine {
        let startTime: TimeInterval
        let endTime: TimeInterval?
        let performerID: String?
        let originalText: String
        let candidateSpans: [CandidateSpan]?
        let backgroundText: String?
    }

    var title: String?
    var artist: String?
    var timingMode: TTMLTimingMode?
    var parsedLines: [RawLine] = []

    private var inBody = false
    private var inParagraph = false
    private var paragraphIsIgnored = false

    private var currentLineStart: TimeInterval = 0
    private var currentLineEnd: TimeInterval?
    private var currentPerformerID: String?

    private var canonicalParagraphText = ""
    /// 和声 (`x-bg`) text of the paragraph, kept beside the canonical text.
    private var backgroundParagraphText = ""
    private var spanStack: [SpanFrame] = []
    private var paragraphCandidateSpans: [CandidateSpan] = []

    private func role(from dict: [String: String]) -> String {
        (dict["ttm:role"] ?? dict["ttml:role"] ?? dict["role"] ?? "").lowercased()
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
        let name = elementName.lowercased()
        if name == "tt" {
            let modeRaw = attributeDict["itunes:timing"] ?? attributeDict["timing"]
            if let modeRaw {
                timingMode = TTMLTimingMode(rawValue: modeRaw)
            }
        } else if name == "body" {
            inBody = true
        } else if inBody && name == "p" {
            inParagraph = true
            canonicalParagraphText = ""
            backgroundParagraphText = ""
            paragraphCandidateSpans = []
            spanStack = []
            currentPerformerID = agent(from: attributeDict)

            let pRole = role(from: attributeDict)
            if pRole.contains("x-bg") || pRole.contains("background") ||
               pRole.contains("x-translation") || pRole.contains("translation") ||
               pRole.contains("x-roman") || pRole.contains("roman") {
                paragraphIsIgnored = true
            } else {
                paragraphIsIgnored = false
            }

            let beginStr = attributeDict["begin"] ?? "0"
            currentLineStart = TTMLParser.parseTimestamp(beginStr) ?? 0

            if let endStr = attributeDict["end"] {
                currentLineEnd = TTMLParser.parseTimestamp(endStr)
            } else {
                currentLineEnd = nil
            }
        } else if inParagraph && !paragraphIsIgnored && name == "span" {
            let sRole = role(from: attributeDict)

            // Nested-safe span kind resolution
            let kind: SpanKind
            if let parent = spanStack.last, parent.kind != .primary {
                kind = parent.kind
            } else if sRole.contains("x-bg") || sRole.contains("background") {
                kind = .background
            } else if sRole.contains("x-translation") || sRole.contains("translation") {
                kind = .translation
            } else if sRole.contains("x-roman") || sRole.contains("roman") {
                kind = .romanization
            } else {
                kind = .primary
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
        guard inParagraph && !paragraphIsIgnored else { return }

        if !spanStack.isEmpty {
            let topIndex = spanStack.count - 1
            spanStack[topIndex].text += string

            // Contract 1: Only primary span text enters canonical text
            if spanStack[topIndex].kind == .primary {
                canonicalParagraphText += string
            } else if spanStack[topIndex].kind == .background {
                backgroundParagraphText += string
            }
        } else {
            // Contract 1: Direct text nodes between spans enter canonical text in order.
            // Formatting whitespace containing newlines between elements is discarded.
            if (string.contains("\n") || string.contains("\r")) &&
                string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return
            }
            canonicalParagraphText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if inParagraph && !paragraphIsIgnored && name == "span" {
            guard !spanStack.isEmpty else { return }
            let frame = spanStack.removeLast()

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
