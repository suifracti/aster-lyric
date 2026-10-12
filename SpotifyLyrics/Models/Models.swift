// Shared/Models/Models.swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreText)
import CoreText
#endif

public struct TrackArtistLink: Identifiable, Equatable, Hashable, Sendable {
    public let name: String
    public let url: URL?

    public var id: String { url?.absoluteString ?? "name:\(name)" }

    public init(name: String, url: URL? = nil) {
        self.name = name
        self.url = url
    }
}

public struct Track: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let artworkName: String
    public let isrc: String?
    public let spotifyId: String?
    public let artworkURL: URL?
    public let spotifyURL: URL?
    /// Structured identities are present for catalog results only. Desktop
    /// playback metadata may legitimately leave these empty.
    public let artistLinks: [TrackArtistLink]
    public let albumURL: URL?
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artworkName: String = "music.note",
        isrc: String? = nil,
        spotifyId: String? = nil,
        artworkURL: URL? = nil,
        spotifyURL: URL? = nil,
        artistLinks: [TrackArtistLink] = [],
        albumURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkName = artworkName
        self.isrc = isrc
        self.spotifyId = spotifyId
        self.artworkURL = artworkURL
        self.spotifyURL = spotifyURL
        self.artistLinks = artistLinks
        self.albumURL = albumURL
    }
}

/// A reading/base pair for SwiftUI ruby rendering.
///
/// `surface` is always copied from the original lyric. `ruby` is optional and
/// is only populated when the reading pipeline has a confirmed reading for a
/// token containing Han characters. This keeps unknown readings fail-closed
/// while allowing long readings to overhang their base text naturally.
public struct LyricRubyToken: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: Int
    public let surface: String
    public let ruby: String?
    /// The confirmed kana text that replaces `surface` in the kana-primary
    /// presentation. This is separate from `ruby`: for a token such as
    /// `々`, there may be replacement kana without an annotation to show.
    public let kanaSurface: String?
    public let romaji: String?
    public let confidence: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case surface
        case ruby
        case kanaSurface
        case romaji
        case confidence
    }

    public init(
        id: Int,
        surface: String,
        ruby: String?,
        kanaSurface: String? = nil,
        romaji: String? = nil,
        confidence: Double = 0
    ) {
        self.id = id
        self.surface = surface
        self.ruby = ruby
        self.kanaSurface = kanaSurface
        self.romaji = romaji
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        surface = try values.decode(String.self, forKey: .surface)
        ruby = try values.decodeIfPresent(String.self, forKey: .ruby)
        // Older saved token payloads do not have this key.
        kanaSurface = try values.decodeIfPresent(String.self, forKey: .kanaSurface)
        romaji = try values.decodeIfPresent(String.self, forKey: .romaji)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(surface, forKey: .surface)
        try values.encodeIfPresent(ruby, forKey: .ruby)
        try values.encodeIfPresent(kanaSurface, forKey: .kanaSurface)
        try values.encodeIfPresent(romaji, forKey: .romaji)
        try values.encode(confidence, forKey: .confidence)
    }

    public var isWhitespace: Bool {
        !surface.isEmpty && surface.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    public var hasRuby: Bool {
        guard let ruby, !ruby.isEmpty, !isWhitespace else { return false }
        return true
    }

    /// Kana-primary text for the third display mode. It never falls back to
    /// a guessed reading; callers only receive a ruby value when the reading
    /// pipeline confirmed one.
    public var kanaReplacementText: String {
        if let kanaSurface, !kanaSurface.isEmpty {
            return kanaSurface
        }
        if hasRuby, let ruby, !ruby.isEmpty {
            return ruby
        }
        return surface
    }
}

public enum LyricTimingGranularity: String, Codable, Sendable, Equatable {
    case syllable
    case word
    case timedUnit
}

public struct TimedTextSpan: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: Int
    public let text: String
    public let trailingWhitespace: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let utf16Start: Int
    public let utf16Length: Int
    public let granularity: LyricTimingGranularity

    public init(
        id: Int,
        text: String,
        trailingWhitespace: String = "",
        startTime: TimeInterval,
        endTime: TimeInterval,
        utf16Start: Int,
        utf16Length: Int,
        granularity: LyricTimingGranularity = .timedUnit
    ) {
        self.id = id
        self.text = text
        self.trailingWhitespace = trailingWhitespace
        self.startTime = startTime
        self.endTime = endTime
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.granularity = granularity
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

public struct ResolvedGraphemeSpan: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public let trailingWhitespace: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let range: Range<String.Index>
    public let granularity: LyricTimingGranularity

    public init(
        id: Int,
        text: String,
        trailingWhitespace: String = "",
        startTime: TimeInterval,
        endTime: TimeInterval,
        range: Range<String.Index>,
        granularity: LyricTimingGranularity
    ) {
        self.id = id
        self.text = text
        self.trailingWhitespace = trailingWhitespace
        self.startTime = startTime
        self.endTime = endTime
        self.range = range
        self.granularity = granularity
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

public struct TimedTextSegment: Equatable, Sendable {
    public let text: String
    /// Progress of this segment: 0.0 (future/unplayed) ... 1.0 (played).
    public let progress: Double
    /// Whether this segment represents an untimed gap (whitespace or punctuation).
    public let isUntimedGap: Bool

    public init(text: String, progress: Double, isUntimedGap: Bool = false) {
        self.text = text
        self.progress = min(max(0.0, progress), 1.0)
        self.isUntimedGap = isUntimedGap
    }

    public init(text: String, isHighlighted: Bool) {
        self.text = text
        self.progress = isHighlighted ? 1.0 : 0.0
        self.isUntimedGap = false
    }

    public var isPlayed: Bool { progress >= 1.0 }
    public var isActive: Bool { progress > 0.0 && progress < 1.0 }
    public var isHighlighted: Bool { progress > 0.0 }
}

public enum TimedTextComposer {
    private struct ResolvedSpan {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let range: Range<String.Index>
    }

    /// Resolves `timedSpans` into exact `Range<String.Index>` values on the specific `currentText` instance.
    /// Returns nil if ANY span fails UTF-16 bounds, grapheme boundary conversion, text equality, or monotonicity (Fail-Closed).
    private static func resolveSpans(
        in currentText: String,
        timedSpans: [TimedTextSpan]
    ) -> [ResolvedSpan]? {
        guard !timedSpans.isEmpty else { return nil }
        var resolved: [ResolvedSpan] = []
        resolved.reserveCapacity(timedSpans.count)

        let utf16 = currentText.utf16
        var lastEnd = currentText.startIndex

        for span in timedSpans {
            let endOffset = span.utf16Start.addingReportingOverflow(span.utf16Length)
            guard span.utf16Start >= 0,
                  span.utf16Length >= 0,
                  !endOffset.overflow,
                  endOffset.partialValue <= utf16.count else {
                return nil
            }
            guard let startU16 = utf16.index(utf16.startIndex, offsetBy: span.utf16Start, limitedBy: utf16.endIndex),
                  let endU16 = utf16.index(startU16, offsetBy: span.utf16Length, limitedBy: utf16.endIndex),
                  let startIdx = String.Index(startU16, within: currentText),
                  let endIdx = String.Index(endU16, within: currentText),
                  startIdx <= endIdx else {
                // Not a valid grapheme cluster boundary in currentText
                return nil
            }
            // Strict monotonicity: spans must not overlap and must proceed forward
            guard startIdx >= lastEnd else {
                return nil
            }
            let extracted = String(currentText[startIdx..<endIdx])
            guard extracted == span.text else {
                return nil
            }
            resolved.append(
                ResolvedSpan(
                    text: span.text,
                    startTime: span.startTime,
                    endTime: span.endTime,
                    range: startIdx..<endIdx
                )
            )
            lastEnd = endIdx
        }
        return resolved
    }

    /// Pure, deterministic progress calculation for a timed span.
    /// Clamped strictly to `0.0...1.0`.
    public static func calculateSpanProgress(
        startTime: TimeInterval,
        endTime: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        let duration = endTime - startTime
        if duration <= 0 {
            return currentTime >= startTime ? 1.0 : 0.0
        }
        if currentTime <= startTime {
            return 0.0
        }
        if currentTime >= endTime {
            return 1.0
        }
        let raw = (currentTime - startTime) / duration
        return min(max(0.0, raw), 1.0)
    }

    /// Composes display segments while ensuring source-of-truth timing safety.
    /// Resolves `spans` dynamically against `originalText`.
    /// If `displayText != originalText` (e.g. line breaker inserted `\n` or reading surface projection),
    /// or if any span fails grapheme boundary validation, safely falls back to a non-fine-timing full display text segment.
    public static func composeSegments(
        displayText: String,
        originalText: String,
        spans: [TimedTextSpan],
        currentTime: TimeInterval
    ) -> [TimedTextSegment] {
        guard !displayText.isEmpty else { return [] }
        guard !spans.isEmpty else {
            return [TimedTextSegment(text: displayText, progress: 1.0)]
        }
        // Strict identity: displayText must equal originalText
        guard displayText == originalText else {
            return [TimedTextSegment(text: displayText, progress: 1.0)]
        }
        // Resolve spans on this specific originalText instance
        guard let resolvedSpans = resolveSpans(in: originalText, timedSpans: spans) else {
            return [TimedTextSegment(text: displayText, progress: 1.0)]
        }

        var segments: [TimedTextSegment] = []
        var cursor = originalText.startIndex

        for span in resolvedSpans {
            if cursor < span.range.lowerBound {
                let untimedText = String(originalText[cursor..<span.range.lowerBound])
                if !untimedText.isEmpty {
                    let progress = currentTime >= span.startTime ? 1.0 : 0.0
                    segments.append(TimedTextSegment(text: untimedText, progress: progress, isUntimedGap: true))
                }
            }

            let spanText = String(originalText[span.range])
            if !spanText.isEmpty {
                let progress = calculateSpanProgress(
                    startTime: span.startTime,
                    endTime: span.endTime,
                    currentTime: currentTime
                )
                segments.append(TimedTextSegment(text: spanText, progress: progress, isUntimedGap: false))
            }

            cursor = max(cursor, span.range.upperBound)
        }

        if cursor < originalText.endIndex {
            let trailingText = String(originalText[cursor..<originalText.endIndex])
            if !trailingText.isEmpty {
                let lastSpanEnd = resolvedSpans.last?.endTime ?? 0
                let progress = currentTime >= lastSpanEnd ? 1.0 : 0.0
                segments.append(TimedTextSegment(text: trailingText, progress: progress, isUntimedGap: true))
            }
        }

        return segments
    }

    public static func composeSegments(
        text: String,
        spans: [TimedTextSpan],
        currentTime: TimeInterval
    ) -> [TimedTextSegment] {
        composeSegments(displayText: text, originalText: text, spans: spans, currentTime: currentTime)
    }

    #if canImport(AppKit) && canImport(CoreText)
    /// Constructs a CTFont matching SwiftUI's `.system(size:weight:design:)`.
    public static func makeSystemFont(
        size: CGFloat,
        weight: NSFont.Weight = .bold,
        design: NSFontDescriptor.SystemDesign = .rounded
    ) -> CTFont {
        let baseFont = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = baseFont.fontDescriptor.withDesign(design),
           let roundedFont = NSFont(descriptor: descriptor, size: size) {
            return roundedFont as CTFont
        }
        return baseFont as CTFont
    }
    #endif

    /// Computes typographic horizontal layout boundaries for each span across the full, unsplit originalText line using true system font metrics.
    /// Returns nil if spans fail validation or if CoreText typography cannot be computed (Fail-Closed).
    public static func computeLayoutFractions(
        originalText: String,
        spans: [TimedTextSpan],
        fontSize: CGFloat = 28,
        weight: CGFloat = 0.56, // Default to .heavy (0.56) / .bold (0.4)
        design: String = "rounded"
    ) -> TimedLineLayout? {
        guard !originalText.isEmpty, !spans.isEmpty else { return nil }
        guard let resolvedSpans = resolveSpans(in: originalText, timedSpans: spans) else {
            return nil
        }
        #if canImport(AppKit) && canImport(CoreText)
        let nsWeight = NSFont.Weight(weight)
        let sysDesign: NSFontDescriptor.SystemDesign = design == "rounded" ? .rounded : .default
        let font = makeSystemFont(size: fontSize, weight: nsWeight, design: sysDesign)

        let attrString = NSAttributedString(
            string: originalText,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let totalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard totalWidth > 0 else { return nil }

        var spanBounds: [TimedLineLayout.SpanBounds] = []
        spanBounds.reserveCapacity(resolvedSpans.count)

        for span in resolvedSpans {
            let startU16 = span.range.lowerBound.utf16Offset(in: originalText)
            let endU16 = span.range.upperBound.utf16Offset(in: originalText)
            let startX = CTLineGetOffsetForStringIndex(line, startU16, nil)
            let endX = CTLineGetOffsetForStringIndex(line, endU16, nil)
            let startFrac = min(max(0.0, startX / totalWidth), 1.0)
            let endFrac = min(max(0.0, endX / totalWidth), 1.0)
            spanBounds.append(
                TimedLineLayout.SpanBounds(
                    startTime: span.startTime,
                    endTime: span.endTime,
                    startFraction: startFrac,
                    endFraction: endFrac
                )
            )
        }

        return TimedLineLayout(spans: spanBounds, totalLineWidth: CGFloat(totalWidth))
        #else
        return nil
        #endif
    }

    public static func computeMultilineLayout(
        originalText: String,
        spans: [TimedTextSpan],
        fontSize: CGFloat = 28,
        weight: CGFloat = 0.56,
        design: String = "rounded",
        availableWidth: CGFloat,
        balanced: Bool = false
    ) -> TimedMultilineLayout? {
        #if canImport(AppKit) && canImport(CoreText)
        guard !originalText.isEmpty, !spans.isEmpty, availableWidth > 0 else {
            return nil
        }

        // Strict Canonical Validation: Must pass the exact resolveSpans validation
        guard let resolvedSpans = resolveSpans(in: originalText, timedSpans: spans) else {
            return nil
        }

        let nsWeight = NSFont.Weight(weight)
        let sysDesign: NSFontDescriptor.SystemDesign = design == "rounded" ? .rounded : .default
        let font = makeSystemFont(size: fontSize, weight: nsWeight, design: sysDesign)
        let totalUTF16Length = originalText.utf16.count

        let attrString = NSAttributedString(
            string: originalText,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )

        let typesetter = CTTypesetterCreateWithAttributedString(attrString)
        var startOffset = 0
        var rawVisualLines: [(line: CTLine, range: CFRange, text: String, width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat)] = []

        let balancedRanges = balanced ? V3LyricDisplayLineBreaker.ranges(originalText, font: font, width: availableWidth) : []
        var visualIndex = 0
        while startOffset < totalUTF16Length {
            let suggestedCount = balanced && visualIndex < balancedRanges.count
                ? balancedRanges[visualIndex].length
                : CTTypesetterSuggestLineBreak(typesetter, startOffset, Double(availableWidth))
            visualIndex += 1
            guard suggestedCount > 0 else { return nil }
            let lineRange = CFRangeMake(startOffset, suggestedCount)
            let ctLine = CTTypesetterCreateLine(typesetter, lineRange)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            let lineSubstr = (originalText as NSString).substring(with: NSRange(location: startOffset, length: suggestedCount))
            rawVisualLines.append((ctLine, lineRange, lineSubstr, lineWidth, ascent, descent, leading))
            startOffset += suggestedCount
        }

        // Canonical completeness: All characters must be consumed
        guard startOffset == totalUTF16Length, !rawVisualLines.isEmpty else {
            return nil
        }

        // For each resolved span, create fragments across overlapping visual lines
        struct RawFragment {
            let lineIndex: Int
            let spanID: Int
            let utf16Range: Range<Int>
            let text: String
            let startX: CGFloat
            let endX: CGFloat
            let rawWidth: CGFloat
        }

        var spanRawFragments: [Int: [RawFragment]] = [:]

        for (spanIdx, resolvedSpan) in resolvedSpans.enumerated() {
            let spanStart = resolvedSpan.range.lowerBound.utf16Offset(in: originalText)
            let spanEnd = resolvedSpan.range.upperBound.utf16Offset(in: originalText)

            for (lineIdx, rawLine) in rawVisualLines.enumerated() {
                let fullSubstr = rawLine.text
                let delimLen = fullSubstr.hasSuffix("\r\n") ? 2 : ((fullSubstr.hasSuffix("\n") || fullSubstr.hasSuffix("\r")) ? 1 : 0)
                let lineStart = rawLine.range.location
                let lineEnd = rawLine.range.location + rawLine.range.length - delimLen

                let overlapStart = max(spanStart, lineStart)
                let overlapEnd = min(spanEnd, lineEnd)

                if overlapStart < overlapEnd {
                    var sec1: CGFloat = 0, sec2: CGFloat = 0
                    let startX = CTLineGetOffsetForStringIndex(rawLine.line, overlapStart, &sec1)
                    let endX = CTLineGetOffsetForStringIndex(rawLine.line, overlapEnd, &sec2)
                    let fragWidth = max(0, endX - startX)
                    let fragText = (originalText as NSString).substring(with: NSRange(location: overlapStart, length: overlapEnd - overlapStart))

                    let frag = RawFragment(
                        lineIndex: lineIdx,
                        spanID: spanIdx,
                        utf16Range: overlapStart..<overlapEnd,
                        text: fragText,
                        startX: startX,
                        endX: endX,
                        rawWidth: fragWidth
                    )
                    spanRawFragments[spanIdx, default: []].append(frag)
                }
            }
        }

        // Full coverage validation: Every span must have valid contiguous fragments covering spanStart..<spanEnd
        for (spanIdx, resolvedSpan) in resolvedSpans.enumerated() {
            guard let fragments = spanRawFragments[spanIdx], !fragments.isEmpty else {
                return nil
            }
            let spanStart = resolvedSpan.range.lowerBound.utf16Offset(in: originalText)
            let spanEnd = resolvedSpan.range.upperBound.utf16Offset(in: originalText)

            guard fragments.first?.utf16Range.lowerBound == spanStart else {
                return nil
            }

            for j in 0..<(fragments.count - 1) {
                let currFrag = fragments[j]
                let nextFrag = fragments[j + 1]
                let rawLineOfCurr = rawVisualLines[currFrag.lineIndex]
                let delimLen = rawLineOfCurr.text.hasSuffix("\r\n") ? 2 : ((rawLineOfCurr.text.hasSuffix("\n") || rawLineOfCurr.text.hasSuffix("\r")) ? 1 : 0)
                let expectedNextStart = currFrag.utf16Range.upperBound + delimLen
                guard nextFrag.utf16Range.lowerBound == expectedNextStart else {
                    return nil
                }
            }

            let lastFrag = fragments.last!
            let rawLineOfLast = rawVisualLines[lastFrag.lineIndex]
            let lastDelimLen = rawLineOfLast.text.hasSuffix("\r\n") ? 2 : ((rawLineOfLast.text.hasSuffix("\n") || rawLineOfLast.text.hasSuffix("\r")) ? 1 : 0)
            let expectedLastEnd = (spanEnd == rawLineOfLast.range.location + rawLineOfLast.range.length) ? (spanEnd - lastDelimLen) : spanEnd
            guard lastFrag.utf16Range.upperBound == expectedLastEnd else {
                return nil
            }
        }

        // Time allocation for each span across its fragments
        var lineFragments: [Int: [TimedSpanFragment]] = [:]
        for (spanIdx, resolvedSpan) in resolvedSpans.enumerated() {
            guard let fragments = spanRawFragments[spanIdx], !fragments.isEmpty else { continue }
            let spanTotalWidth = fragments.reduce(0.0) { $0 + $1.rawWidth }
            let spanDuration = max(0.0, resolvedSpan.endTime - resolvedSpan.startTime)

            var curTime = resolvedSpan.startTime
            for (fIdx, f) in fragments.enumerated() {
                let fDuration: TimeInterval
                if spanTotalWidth > 0 {
                    let ratio = Double(f.rawWidth / spanTotalWidth)
                    fDuration = (fIdx == fragments.count - 1) ? (resolvedSpan.endTime - curTime) : (spanDuration * ratio)
                } else {
                    fDuration = spanDuration / Double(fragments.count)
                }
                let fEnd = min(resolvedSpan.endTime, curTime + fDuration)
                let timedFrag = TimedSpanFragment(
                    spanID: spanIdx,
                    utf16Range: f.utf16Range,
                    text: f.text,
                    startTime: curTime,
                    endTime: fEnd,
                    startX: f.startX,
                    endX: f.endX
                )
                lineFragments[f.lineIndex, default: []].append(timedFrag)
                curTime = fEnd
            }
        }

        // Assemble final visual lines with explicit delimiter handling
        var visualLines: [TimedVisualLine] = []
        for (lineIdx, rawLine) in rawVisualLines.enumerated() {
            let frags = lineFragments[lineIdx]?.sorted(by: { $0.startTime < $1.startTime }) ?? []
            let fullSubstr = rawLine.text
            let delimLen = fullSubstr.hasSuffix("\r\n") ? 2 : ((fullSubstr.hasSuffix("\n") || fullSubstr.hasSuffix("\r")) ? 1 : 0)
            let displayText = String(fullSubstr.dropLast(delimLen))
            let sourceRange = rawLine.range.location..<(rawLine.range.location + rawLine.range.length)

            let vLine = TimedVisualLine(
                lineIndex: lineIdx,
                sourceUTF16Range: sourceRange,
                displayText: displayText,
                trailingDelimiterLength: delimLen,
                totalWidth: rawLine.width,
                ascent: rawLine.ascent,
                descent: rawLine.descent,
                leading: rawLine.leading,
                fragments: frags
            )
            visualLines.append(vLine)
        }

        return TimedMultilineLayout(
            originalText: originalText,
            availableWidth: availableWidth,
            lines: visualLines
        )
        #else
        return nil
        #endif
    }

    public static func computeTimedRubyLayout(
        originalText: String,
        spans: [TimedTextSpan],
        rubyTokens: [LyricRubyToken]?,
        fontSize: CGFloat = 28,
        weight: CGFloat = 0.56,
        design: String = "rounded"
    ) -> TimedRubyLayout? {
        #if canImport(AppKit) && canImport(CoreText)
        guard !originalText.isEmpty, !spans.isEmpty else {
            #if DEBUG
            LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=empty_text_or_spans")
            #endif
            return nil
        }

        // Strict Canonical Validation: Must pass the exact resolveSpans validation
        guard let resolvedSpans = resolveSpans(in: originalText, timedSpans: spans) else {
            #if DEBUG
            LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=resolveSpans_failed")
            #endif
            return nil
        }

        let totalUTF16Length = originalText.utf16.count
        let nsText = originalText as NSString

        // 1. Partition originalText into aligned tokens (including plain gap runs)
        var rawTokens: [(id: Int, surface: String, ruby: String?, kanaSurface: String?, range: Range<Int>)] = []
        var curOffset = 0

        if let rubyTokens, !rubyTokens.isEmpty {
            for token in rubyTokens {
                guard !token.surface.isEmpty else { continue }
                let searchRange = NSRange(location: curOffset, length: totalUTF16Length - curOffset)
                let found = nsText.range(of: token.surface, options: [], range: searchRange)
                guard found.location != NSNotFound else {
                    #if DEBUG
                    LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=token_surface_not_found:\(token.surface)")
                    #endif
                    return nil
                }
                if found.location > curOffset {
                    let gapRange = curOffset..<found.location
                    let gapText = nsText.substring(with: NSRange(location: curOffset, length: found.location - curOffset))
                    rawTokens.append((id: rawTokens.count, surface: gapText, ruby: nil, kanaSurface: nil, range: gapRange))
                }
                let tokenRange = found.location..<(found.location + found.length)
                rawTokens.append((id: token.id, surface: token.surface, ruby: token.ruby, kanaSurface: token.kanaSurface, range: tokenRange))
                curOffset = found.location + found.length
            }
        }
        if curOffset < totalUTF16Length {
            let trailingRange = curOffset..<totalUTF16Length
            let trailingText = nsText.substring(with: NSRange(location: curOffset, length: totalUTF16Length - curOffset))
            rawTokens.append((id: rawTokens.count, surface: trailingText, ruby: nil, kanaSurface: nil, range: trailingRange))
        }

        // Validate reconstruction and grapheme boundaries
        var reconstructed = ""
        var expectedOffset = 0
        let utf16 = originalText.utf16
        for t in rawTokens {
            guard t.range.lowerBound == expectedOffset else {
                #if DEBUG
                LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=gap_alignment_mismatch")
                #endif
                return nil
            }
            guard t.surface == nsText.substring(with: NSRange(location: t.range.lowerBound, length: t.range.count)) else {
                #if DEBUG
                LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=surface_mismatch")
                #endif
                return nil
            }
            guard let startU16 = utf16.index(utf16.startIndex, offsetBy: t.range.lowerBound, limitedBy: utf16.endIndex),
                  let endU16 = utf16.index(utf16.startIndex, offsetBy: t.range.upperBound, limitedBy: utf16.endIndex),
                  let startIdx = String.Index(startU16, within: originalText),
                  let endIdx = String.Index(endU16, within: originalText),
                  startIdx <= endIdx else {
                #if DEBUG
                LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=grapheme_boundary_fail")
                #endif
                return nil
            }
            expectedOffset = t.range.upperBound
            reconstructed += t.surface
        }
        guard expectedOffset == totalUTF16Length, reconstructed == originalText else {
            #if DEBUG
            LyricsE2ELog.log("[V3TimedRubyLayoutFail] text=\(originalText) reason=reconstruction_mismatch:\(reconstructed)_vs_\(originalText)")
            #endif
            return nil
        }

        // 2. Measure each token with CoreText using exact system font
        let nsWeight = NSFont.Weight(weight)
        let sysDesign: NSFontDescriptor.SystemDesign = design == "rounded" ? .rounded : .default
        let font = makeSystemFont(size: fontSize, weight: nsWeight, design: sysDesign)

        struct RawTokenFragment {
            let tokenIndex: Int
            let spanID: Int
            let utf16Range: Range<Int>
            let text: String
            let startX: CGFloat
            let endX: CGFloat
            let rawWidth: CGFloat
        }

        var tokenMeasurements: [(ctLine: CTLine, width: CGFloat)] = []
        for t in rawTokens {
            let attr = NSAttributedString(string: t.surface, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CTLineGetTypographicBounds(ctLine, &a, &d, &l)
            tokenMeasurements.append((ctLine, w))
        }

        // 3. Map resolved spans to token fragments
        var spanRawFragments: [Int: [RawTokenFragment]] = [:]
        for (spanIdx, resolvedSpan) in resolvedSpans.enumerated() {
            let spanStart = resolvedSpan.range.lowerBound.utf16Offset(in: originalText)
            let spanEnd = resolvedSpan.range.upperBound.utf16Offset(in: originalText)

            for (tokenIdx, t) in rawTokens.enumerated() {
                let tokenStart = t.range.lowerBound
                let tokenEnd = t.range.upperBound

                let overlapStart = max(spanStart, tokenStart)
                let overlapEnd = min(spanEnd, tokenEnd)

                if overlapStart < overlapEnd {
                    let localStart = overlapStart - tokenStart
                    let localEnd = overlapEnd - tokenStart
                    let ctLine = tokenMeasurements[tokenIdx].ctLine

                    var sec1: CGFloat = 0, sec2: CGFloat = 0
                    let startX = CTLineGetOffsetForStringIndex(ctLine, localStart, &sec1)
                    let endX = CTLineGetOffsetForStringIndex(ctLine, localEnd, &sec2)
                    let fragWidth = max(0, endX - startX)
                    let fragText = (t.surface as NSString).substring(with: NSRange(location: localStart, length: localEnd - localStart))

                    let frag = RawTokenFragment(
                        tokenIndex: tokenIdx,
                        spanID: spanIdx,
                        utf16Range: overlapStart..<overlapEnd,
                        text: fragText,
                        startX: startX,
                        endX: endX,
                        rawWidth: fragWidth
                    )
                    spanRawFragments[spanIdx, default: []].append(frag)
                }
            }
        }

        // 4. Verify Full Coverage for each span
        for (spanIdx, resolvedSpan) in resolvedSpans.enumerated() {
            guard let fragments = spanRawFragments[spanIdx], !fragments.isEmpty else {
                return nil
            }
            let spanStart = resolvedSpan.range.lowerBound.utf16Offset(in: originalText)
            let spanEnd = resolvedSpan.range.upperBound.utf16Offset(in: originalText)

            guard fragments.first?.utf16Range.lowerBound == spanStart else {
                return nil
            }
            for j in 0..<(fragments.count - 1) {
                guard fragments[j].utf16Range.upperBound == fragments[j + 1].utf16Range.lowerBound else {
                    return nil
                }
            }
            guard fragments.last?.utf16Range.upperBound == spanEnd else {
                return nil
            }
        }

        // 5. Allocate time across fragments
        var tokenTimedFragments: [Int: [TimedSpanFragment]] = [:]
        for (spanIdx, resolvedSpan) in resolvedSpans.enumerated() {
            guard let fragments = spanRawFragments[spanIdx], !fragments.isEmpty else { continue }
            let spanTotalWidth = fragments.reduce(0.0) { $0 + $1.rawWidth }
            let spanDuration = max(0.0, resolvedSpan.endTime - resolvedSpan.startTime)

            var curTime = resolvedSpan.startTime
            for (fIdx, f) in fragments.enumerated() {
                let fDuration: TimeInterval
                if spanTotalWidth > 0 {
                    let ratio = Double(f.rawWidth / spanTotalWidth)
                    fDuration = (fIdx == fragments.count - 1) ? (resolvedSpan.endTime - curTime) : (spanDuration * ratio)
                } else {
                    fDuration = spanDuration / Double(fragments.count)
                }
                let fEnd = min(resolvedSpan.endTime, curTime + fDuration)
                let timedFrag = TimedSpanFragment(
                    spanID: spanIdx,
                    utf16Range: f.utf16Range,
                    text: f.text,
                    startTime: curTime,
                    endTime: fEnd,
                    startX: f.startX,
                    endX: f.endX
                )
                tokenTimedFragments[f.tokenIndex, default: []].append(timedFrag)
                curTime = fEnd
            }
        }

        // 6. Build final TimedRubyToken list
        var timedTokens: [TimedRubyToken] = []
        for (tokenIdx, t) in rawTokens.enumerated() {
            let frags = tokenTimedFragments[tokenIdx]?.sorted(by: { $0.startTime < $1.startTime }) ?? []
            let width = tokenMeasurements[tokenIdx].width
            let rubyTok = TimedRubyToken(
                id: t.id,
                sourceUTF16Range: t.range,
                surface: t.surface,
                ruby: t.ruby,
                kanaSurface: t.kanaSurface,
                baseWidth: width,
                fragments: frags
            )
            timedTokens.append(rubyTok)
        }

        return TimedRubyLayout(originalText: originalText, tokens: timedTokens)
        #else
        return nil
        #endif
    }
}

public struct TimedSpanFragment: Equatable, Sendable {
    public let spanID: Int
    public let utf16Range: Range<Int>
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let startX: CGFloat
    public let endX: CGFloat

    public init(
        spanID: Int,
        utf16Range: Range<Int>,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        startX: CGFloat,
        endX: CGFloat
    ) {
        self.spanID = spanID
        self.utf16Range = utf16Range
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.startX = startX
        self.endX = endX
    }
}

public struct TimedVisualLine: Equatable, Sendable {
    public let lineIndex: Int
    public let sourceUTF16Range: Range<Int>
    public let displayText: String
    public let trailingDelimiterLength: Int
    public let totalWidth: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat
    public let fragments: [TimedSpanFragment]

    public var text: String {
        displayText
    }

    public var utf16Range: Range<Int> {
        sourceUTF16Range
    }

    public var lineHeight: CGFloat {
        ascent + descent + leading
    }

    public init(
        lineIndex: Int,
        sourceUTF16Range: Range<Int>,
        displayText: String,
        trailingDelimiterLength: Int = 0,
        totalWidth: CGFloat,
        ascent: CGFloat = 0,
        descent: CGFloat = 0,
        leading: CGFloat = 0,
        fragments: [TimedSpanFragment]
    ) {
        self.lineIndex = lineIndex
        self.sourceUTF16Range = sourceUTF16Range
        self.displayText = displayText
        self.trailingDelimiterLength = trailingDelimiterLength
        self.totalWidth = totalWidth
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.fragments = fragments
    }

    public func fillFraction(at presentationTime: TimeInterval) -> Double {
        guard totalWidth > 0 else { return 0.0 }
        return Double(filledWidth(at: presentationTime) / totalWidth)
    }

    public func filledWidth(at presentationTime: TimeInterval) -> CGFloat {
        guard !fragments.isEmpty else { return 0.0 }
        guard let first = fragments.first, let last = fragments.last else { return 0.0 }

        if presentationTime <= first.startTime {
            return 0.0
        }
        if presentationTime >= last.endTime {
            return totalWidth
        }

        for frag in fragments {
            if presentationTime < frag.startTime {
                return frag.startX
            }
            if presentationTime <= frag.endTime {
                let duration = frag.endTime - frag.startTime
                let p = duration > 0 ? (presentationTime - frag.startTime) / duration : 1.0
                let clampedP = min(max(p, 0.0), 1.0)
                return frag.startX + CGFloat(clampedP) * (frag.endX - frag.startX)
            }
        }
        return totalWidth
    }
}

public struct TimedMultilineLayout: Equatable, Sendable {
    public let originalText: String
    public let availableWidth: CGFloat
    public let lines: [TimedVisualLine]

    public init(
        originalText: String,
        availableWidth: CGFloat,
        lines: [TimedVisualLine]
    ) {
        self.originalText = originalText
        self.availableWidth = availableWidth
        self.lines = lines
    }

    public var isSingleLine: Bool {
        lines.count <= 1
    }

    public var maxLineWidth: CGFloat {
        lines.map(\.totalWidth).max() ?? 0
    }
}

public struct TimedRubyToken: Identifiable, Equatable, Sendable {
    public let id: Int
    public let sourceUTF16Range: Range<Int>
    public let surface: String
    public let ruby: String?
    public let kanaSurface: String?
    public let baseWidth: CGFloat
    public let fragments: [TimedSpanFragment]

    public var hasRuby: Bool { ruby != nil }

    public init(
        id: Int,
        sourceUTF16Range: Range<Int>,
        surface: String,
        ruby: String?,
        kanaSurface: String? = nil,
        baseWidth: CGFloat,
        fragments: [TimedSpanFragment]
    ) {
        self.id = id
        self.sourceUTF16Range = sourceUTF16Range
        self.surface = surface
        self.ruby = ruby
        self.kanaSurface = kanaSurface
        self.baseWidth = baseWidth
        self.fragments = fragments
    }

    public func fillFraction(at presentationTime: TimeInterval) -> Double {
        guard baseWidth > 0 else { return 0.0 }
        return Double(filledWidth(at: presentationTime) / baseWidth)
    }

    public func filledWidth(at presentationTime: TimeInterval) -> CGFloat {
        guard !fragments.isEmpty else { return 0.0 }
        guard let first = fragments.first, let last = fragments.last else { return 0.0 }

        if presentationTime <= first.startTime {
            return 0.0
        }
        if presentationTime >= last.endTime {
            return baseWidth
        }

        for frag in fragments {
            if presentationTime < frag.startTime {
                return frag.startX
            }
            if presentationTime <= frag.endTime {
                let duration = frag.endTime - frag.startTime
                let p = duration > 0 ? (presentationTime - frag.startTime) / duration : 1.0
                let clampedP = min(max(p, 0.0), 1.0)
                return frag.startX + CGFloat(clampedP) * (frag.endX - frag.startX)
            }
        }
        return baseWidth
    }
}

public struct TimedRubyLayout: Equatable, Sendable {
    public let originalText: String
    public let tokens: [TimedRubyToken]

    public init(originalText: String, tokens: [TimedRubyToken]) {
        self.originalText = originalText
        self.tokens = tokens
    }

    public var reconstructedText: String {
        tokens.map(\.surface).joined()
    }
}

public struct TimedLineLayout: Equatable, Sendable {
    public struct SpanBounds: Equatable, Sendable {
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let startFraction: Double
        public let endFraction: Double

        public init(
            startTime: TimeInterval,
            endTime: TimeInterval,
            startFraction: Double,
            endFraction: Double
        ) {
            self.startTime = startTime
            self.endTime = endTime
            self.startFraction = min(max(0.0, startFraction), 1.0)
            self.endFraction = min(max(0.0, endFraction), 1.0)
        }
    }

    public let spans: [SpanBounds]
    public let totalLineWidth: CGFloat

    public init(spans: [SpanBounds], totalLineWidth: CGFloat = 0) {
        self.spans = spans
        self.totalLineWidth = totalLineWidth
    }

    public func fillFraction(at currentTime: TimeInterval) -> Double {
        guard !spans.isEmpty else { return 1.0 }
        guard let first = spans.first, let last = spans.last else { return 1.0 }
        if currentTime <= first.startTime { return 0.0 }
        if currentTime >= last.endTime { return 1.0 }

        for span in spans {
            if currentTime >= span.startTime && currentTime <= span.endTime {
                let duration = span.endTime - span.startTime
                let p = duration > 0 ? (currentTime - span.startTime) / duration : 1.0
                let clampedP = min(max(0.0, p), 1.0)
                return span.startFraction + (span.endFraction - span.startFraction) * clampedP
            } else if currentTime < span.startTime {
                // In untimed gap before this span
                return span.startFraction
            }
        }
        return 1.0
    }
}

public struct LyricsPresentationClock: Equatable, Sendable {
    public let authoritativePosition: TimeInterval
    public let receivedAtMonotonicTime: TimeInterval
    public let isPlaying: Bool
    public let trackID: String
    public let trackDuration: TimeInterval
    /// Presentation-only shift. The authoritative provider position remains
    /// untouched; this value is applied only to lyric selection/highlighting.
    public let presentationOffset: TimeInterval

    public init(
        authoritativePosition: TimeInterval = 0,
        receivedAtMonotonicTime: TimeInterval = 0,
        isPlaying: Bool = false,
        trackID: String = "",
        trackDuration: TimeInterval = 0,
        presentationOffset: TimeInterval = 0
    ) {
        self.authoritativePosition = max(0, authoritativePosition)
        self.receivedAtMonotonicTime = receivedAtMonotonicTime
        self.isPlaying = isPlaying
        self.trackID = trackID
        self.trackDuration = max(0, trackDuration)
        self.presentationOffset = min(10, max(-10, presentationOffset.isFinite ? presentationOffset : 0))
    }

    /// Raw playback-domain extrapolation without the lyrics presentation offset.
    /// Invariant 1: If isPlaying is false, returns authoritativePosition (frozen).
    /// Invariant 2: If isPlaying is true, advances linearly by (now - receivedAtMonotonicTime).
    /// Invariant 3: Clamped to [0, trackDuration] when duration is positive.
    public func playbackTime(at monotonicNow: TimeInterval) -> TimeInterval {
        let estimated = estimatedPlaybackTime(at: monotonicNow)
        if trackDuration > 0 {
            return min(trackDuration, max(0, estimated))
        }
        return max(0, estimated)
    }

    /// Returns an equivalent clock with a different lyric-only offset.
    /// The playback anchor and transport projection remain unchanged.
    public func withPresentationOffset(_ offset: TimeInterval) -> LyricsPresentationClock {
        LyricsPresentationClock(
            authoritativePosition: authoritativePosition,
            receivedAtMonotonicTime: receivedAtMonotonicTime,
            isPlaying: isPlaying,
            trackID: trackID,
            trackDuration: trackDuration,
            presentationOffset: offset
        )
    }

    /// Lyric presentation time: raw playback estimate plus the lyric-only
    /// offset, clamped only after the offset is applied.
    public func presentationTime(at monotonicNow: TimeInterval) -> TimeInterval {
        let estimated = estimatedPlaybackTime(at: monotonicNow) + presentationOffset
        if trackDuration > 0 {
            return min(trackDuration, max(0, estimated))
        }
        return max(0, estimated)
    }

    private func estimatedPlaybackTime(at monotonicNow: TimeInterval) -> TimeInterval {
        let elapsed = isPlaying ? max(0, monotonicNow - receivedAtMonotonicTime) : 0
        return authoritativePosition + elapsed
    }
}

/// Avoid publishing identical timer samples while preserving every real
/// playback-time change. PlaybackState uses this only for periodic tick
/// updates; seek, reset, and track-transition writes remain event-driven.
public enum PlaybackTickTimeUpdatePolicy {
    public static func shouldPublish(currentTime: TimeInterval, nextTime: TimeInterval) -> Bool {
        currentTime != nextTime
    }

    public static func shouldFinishMockPlayback(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) -> Bool {
        isPlaying && currentTime >= duration
    }
}

/// Next lyric-line boundary after the published index.
/// Equal timestamps are skipped so repeated lines collapse to one wake-up.
public enum LyricBoundary {
    public static func nextTime(
        afterIndex currentIndex: Int?,
        timestamps: [TimeInterval]
    ) -> TimeInterval? {
        guard !timestamps.isEmpty else { return nil }
        if let currentIndex {
            guard timestamps.indices.contains(currentIndex) else { return nil }
            let current = timestamps[currentIndex]
            return timestamps[(currentIndex + 1)...].first { $0 > current }
        }
        return timestamps.first
    }
}

/// Short-lived protection for a lyric boundary that was just confirmed.
/// Ordinary poll jitter must not reverse that one crossing; real seeks can.
public enum LyricIndexAntiRegression {
    /// One Spotify poll cycle plus a small margin. Long enough to absorb
    /// ordinary sample lag after a crossing; short enough that a later
    /// real Desktop seek is not stuck on the old line.
    public static let window: TimeInterval = 1.25

    public static func shouldSuppressPollRegression(
        isPlaying: Bool,
        proposedIndex: Int?,
        currentIndex: Int?,
        confirmedIndex: Int?,
        confirmedLineStart: TimeInterval?,
        incomingTime: TimeInterval,
        nowMonotonic: TimeInterval,
        confirmedAtMonotonic: TimeInterval
    ) -> Bool {
        guard isPlaying,
              let proposedIndex,
              let currentIndex,
              let confirmedIndex,
              let confirmedLineStart,
              proposedIndex == currentIndex - 1,
              confirmedIndex == currentIndex,
              incomingTime < confirmedLineStart,
              nowMonotonic - confirmedAtMonotonic >= 0,
              nowMonotonic - confirmedAtMonotonic < window else {
            return false
        }
        return true
    }
}

public struct LyricLine: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var timestamp: TimeInterval
    public var endTime: TimeInterval?
    public var originalText: String
    public var translationText: String?
    public var romajiText: String?
    public var kanaText: String?
    public var rubyTokens: [LyricRubyToken]?
    /// Performer / duet agent ID (e.g. "v1", "v2" from TTML).
    public var performerID: String?
    /// Word / syllable level timing spans. Optional additive enhancement.
    public var timedSpans: [TimedTextSpan]?
    /// Runtime-only reading projection fields. They are never written back
    /// into the source lyric version; the shared ReadingSessionController
    /// uses them to distinguish pinyin/script-converted display from legacy
    /// Japanese columns.
    public var readingRepresentationID: String?
    public var readingSurfaceText: String?
    
    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        originalText: String,
        endTime: TimeInterval? = nil,
        translationText: String? = nil,
        romajiText: String? = nil,
        kanaText: String? = nil,
        rubyTokens: [LyricRubyToken]? = nil,
        performerID: String? = nil,
        timedSpans: [TimedTextSpan]? = nil,
        readingRepresentationID: String? = nil,
        readingSurfaceText: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endTime = endTime
        self.originalText = originalText
        self.translationText = translationText
        self.romajiText = romajiText
        self.kanaText = kanaText
        self.rubyTokens = rubyTokens
        self.performerID = performerID
        self.timedSpans = timedSpans
        self.readingRepresentationID = readingRepresentationID
        self.readingSurfaceText = readingSurfaceText
    }

    /// Copies this line while preserving every current model field.
    public func replacingID(_ id: UUID) -> LyricLine {
        LyricLine(
            id: id,
            timestamp: timestamp,
            originalText: originalText,
            endTime: endTime,
            translationText: translationText,
            romajiText: romajiText,
            kanaText: kanaText,
            rubyTokens: rubyTokens,
            performerID: performerID,
            timedSpans: timedSpans,
            readingRepresentationID: readingRepresentationID,
            readingSurfaceText: readingSurfaceText
        )
    }

    public var hasTimedSpans: Bool {
        guard let timedSpans, !timedSpans.isEmpty else { return false }
        return true
    }

    /// Whether this line carries a complete, text-aligned span sequence that
    /// is safe to rank as real word timing. `lineStartIsMeaningful` must be
    /// false for legacy/partial rows whose start time is only a placeholder.
    public func hasValidTimedSpans(lineStartIsMeaningful: Bool = true) -> Bool {
        guard let timedSpans, !timedSpans.isEmpty,
              resolvedGraphemeSpans()?.count == timedSpans.count else { return false }

        var previousUTF16End = 0
        var previousStartTime: TimeInterval?
        for span in timedSpans {
            let endOffset = span.utf16Start.addingReportingOverflow(span.utf16Length)
            guard span.utf16Start >= previousUTF16End,
                  span.utf16Length > 0,
                  !endOffset.overflow,
                  span.startTime.isFinite,
                  span.endTime.isFinite,
                  span.startTime >= 0,
                  span.endTime >= span.startTime,
                  !lineStartIsMeaningful || (timestamp.isFinite && timestamp >= 0 && span.startTime >= timestamp),
                  endTime.map({ $0.isFinite && $0 >= 0 && span.endTime <= $0 }) ?? true,
                  previousStartTime.map({ span.startTime >= $0 }) ?? true else {
                return false
            }
            previousUTF16End = endOffset.partialValue
            previousStartTime = span.startTime
        }
        return true
    }

    /// Converts UTF-16 indexed `timedSpans` into exact `Range<String.Index>` spans.
    /// Returns nil if ANY span fails exact Extended Grapheme Cluster boundary validation (Fail-Closed, Contract 4).
    public func resolvedGraphemeSpans() -> [ResolvedGraphemeSpan]? {
        guard let timedSpans, !timedSpans.isEmpty else { return nil }
        var resolved: [ResolvedGraphemeSpan] = []
        resolved.reserveCapacity(timedSpans.count)

        let utf16 = originalText.utf16
        for span in timedSpans {
            let endOffset = span.utf16Start.addingReportingOverflow(span.utf16Length)
            guard span.utf16Start >= 0,
                  span.utf16Length >= 0,
                  !endOffset.overflow,
                  endOffset.partialValue <= utf16.count else {
                return nil
            }
            guard let startU16 = utf16.index(utf16.startIndex, offsetBy: span.utf16Start, limitedBy: utf16.endIndex),
                  let endU16 = utf16.index(startU16, offsetBy: span.utf16Length, limitedBy: utf16.endIndex),
                  let startIdx = String.Index(startU16, within: originalText),
                  let endIdx = String.Index(endU16, within: originalText),
                  startIdx <= endIdx else {
                // Fails exact grapheme boundary check
                return nil
            }
            let extracted = String(originalText[startIdx..<endIdx])
            guard extracted == span.text else {
                // Text mismatch check
                return nil
            }
            resolved.append(
                ResolvedGraphemeSpan(
                    id: span.id,
                    text: span.text,
                    trailingWhitespace: span.trailingWhitespace,
                    startTime: span.startTime,
                    endTime: span.endTime,
                    range: startIdx..<endIdx,
                    granularity: span.granularity
                )
            )
        }
        return resolved
    }
}

/// Presentation-only mapping for lyrics that explicitly carry multiple
/// performer IDs. IDs remain opaque source identities; the bounded offsets are
/// visual organization only and never imply a singer role or gender.
public struct LyricAgentPresentationMap: Equatable, Sendable {
    public let agentIDs: [String]

    public var isActive: Bool {
        agentIDs.count >= 2
    }

    public init(lines: [LyricLine]) {
        agentIDs = Set(
            lines.compactMap { line in
                guard let performerID = line.performerID else { return nil }
                let trimmed = performerID.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        ).sorted()
    }

    /// Returns a small visual offset while keeping every line's layout and
    /// timing geometry unchanged. The offset is capped for documents with
    /// more than three distinct opaque IDs.
    public func horizontalOffset(for performerID: String?) -> Int {
        guard isActive,
              let performerID,
              let normalizedID = normalizedID(performerID),
              let index = agentIDs.firstIndex(of: normalizedID) else {
            return 0
        }
        return min(index, 2) * 6
    }

    private func normalizedID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum LyricsDisplayMode: String, CaseIterable, Identifiable {
    case mainWindow = "主窗口"
    case floatingWindow = "悬浮歌词"
    case capsulePlayer = "顶部胶囊"
    case fullScreen = "全屏歌词"
    
    public var id: String { rawValue }
}

/// Controls how the confirmed kana layer is presented in the main lyrics view.
///
/// `showKana` remains as a source-compatible computed property for older
/// callers. Turning the layer off/on preserves the last selected visible
/// mode, while choosing a mode directly never depends on that Boolean.
public enum KanaDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case independentLine = "independentLine"
    case inlineRuby = "inlineRuby"
    case kanaReplacement = "kanaReplacement"
    case hidden = "hidden"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .independentLine: return "独立行"
        case .inlineRuby: return "悬浮注音"
        case .kanaReplacement: return "假名替换"
        case .hidden: return "隐藏"
        }
    }

    public var detail: String {
        switch self {
        case .independentLine: return "整行显示假名，适合初学者对照阅读"
        case .inlineRuby: return "假名贴在对应汉字上方，保持正文连续"
        case .kanaReplacement: return "假名替换汉字，原汉字置于上方作为辅助标注"
        case .hidden: return "不显示假名层"
        }
    }
}

public struct DisplayPreferences: Equatable {
    public var showOriginal: Bool = true
    public var showTranslation: Bool = true
    public var showRomaji: Bool = true
    public var showPinyin: Bool = true
    private var storedKanaDisplayMode: KanaDisplayMode
    private var lastVisibleKanaDisplayMode: KanaDisplayMode
    public var fontSize: CGFloat = 18
    public var opacity: Double = 0.85
    public var alwaysOnTop: Bool = true
    public var assistantFontSize: CGFloat = 14
    public var rubyFontSize: CGFloat = 10
    public var hideDistantAuxiliary: Bool = true

    public var kanaDisplayMode: KanaDisplayMode {
        get { storedKanaDisplayMode }
        set {
            storedKanaDisplayMode = newValue
            if newValue != .hidden {
                lastVisibleKanaDisplayMode = newValue
            }
        }
    }

    /// Compatibility bridge for the previous Boolean setting. It is only a
    /// visibility switch; it does not choose between the three presentations.
    public var showKana: Bool {
        get { kanaDisplayMode != .hidden }
        set {
            if newValue {
                if storedKanaDisplayMode == .hidden {
                    storedKanaDisplayMode = lastVisibleKanaDisplayMode
                }
            } else {
                if storedKanaDisplayMode != .hidden {
                    lastVisibleKanaDisplayMode = storedKanaDisplayMode
                }
                storedKanaDisplayMode = .hidden
            }
        }
    }

    public init(
        showOriginal: Bool = true,
        showTranslation: Bool = true,
        showRomaji: Bool = true,
        showPinyin: Bool = true,
        showKana: Bool = false,
        kanaDisplayMode: KanaDisplayMode? = nil,
        fontSize: CGFloat = 18,
        opacity: Double = 0.85,
        alwaysOnTop: Bool = true,
        assistantFontSize: CGFloat = 14,
        rubyFontSize: CGFloat = 10,
        hideDistantAuxiliary: Bool = true
    ) {
        self.showOriginal = showOriginal
        self.showTranslation = showTranslation
        self.showRomaji = showRomaji
        self.showPinyin = showPinyin
        let selectedMode = kanaDisplayMode ?? (showKana ? .independentLine : .hidden)
        self.storedKanaDisplayMode = selectedMode
        self.lastVisibleKanaDisplayMode = selectedMode == .hidden
            ? .independentLine
            : selectedMode
        self.fontSize = fontSize
        self.opacity = opacity
        self.alwaysOnTop = alwaysOnTop
        self.assistantFontSize = assistantFontSize
        self.rubyFontSize = rubyFontSize
        self.hideDistantAuxiliary = hideDistantAuxiliary
    }
}

#if canImport(AppKit) && canImport(CoreText)
/// Display-only measured wrapping. Source offsets remain intact for timed fragments.
public enum V3LyricDisplayLineBreaker {
    public static func breakText(_ text: String, fontSize: CGFloat, weight: CGFloat, availableWidth: CGFloat) -> String {
        let font = TimedTextComposer.makeSystemFont(size: fontSize, weight: NSFont.Weight(weight), design: .rounded)
        let parts = ranges(text, font: font, width: availableWidth).map { (text as NSString).substring(with: $0) }
        return parts.enumerated().map { index, part in
            index < parts.count - 1 && part.last?.isNewline != true ? part + "\n" : part
        }.joined()
    }

    static func ranges(_ text: String, font: CTFont, width: CGFloat) -> [NSRange] {
        guard width.isFinite, width > 0, !text.isEmpty else { return [] }
        var result: [NSRange] = []
        var offset = 0
        let source = text as NSString
        while offset < source.length {
            let newline = source.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: offset, length: source.length - offset))
            let end = newline.location == NSNotFound ? source.length : newline.location
            let paragraph = source.substring(with: NSRange(location: offset, length: end - offset))
            var delimiter = newline.location == NSNotFound ? 0 : 1
            if delimiter == 1 && source.character(at: end) == 13 && end + 1 < source.length && source.character(at: end + 1) == 10 { delimiter = 2 }
            var rows = paragraphRanges(paragraph, font: font, width: max(1, width - 1))
            if rows.isEmpty && delimiter > 0 { rows = [NSRange(location: 0, length: 0)] }
            if !rows.isEmpty { rows[rows.count - 1].length += delimiter }
            result += rows.map { NSRange(location: offset + $0.location, length: $0.length) }
            offset = end + delimiter
        }
        return result
    }

    private static func paragraphRanges(_ text: String, font: CTFont, width: CGFloat) -> [NSRange] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        let setter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var greedy: [NSRange] = []
        var start = 0
        while start < source.length {
            let count = CTTypesetterSuggestLineBreak(setter, start, Double(width))
            guard count > 0 else { return [NSRange(location: 0, length: source.length)] }
            greedy.append(NSRange(location: start, length: count)); start += count
        }
        guard greedy.count > 1, text.count <= 256 else { return greedy }
        var boundaries = [0]
        for character in text { boundaries.append(boundaries.last! + String(character).utf16.count) }
        let characters = Array(text)
        var words = Set<Int>()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            words.insert(range.upperBound.utf16Offset(in: text))
            words.insert(range.lowerBound.utf16Offset(in: text))
        }
        let forbidden = Set("、。，！？!?」』）)]】ぁぃぅぇぉっゃゅょァィゥェォッャュョー")
        let particles = Set("のをはがにとでも")
        // Reject over-wide ranges before allocating CTLine during live resizing.
        let fitEnds = boundaries.map { start in
            start + CTTypesetterSuggestClusterBreak(setter, start, Double(width))
        }
        let count = boundaries.count
        let rows = greedy.count
        var costs = Array(repeating: Array(repeating: Double.infinity, count: count), count: rows + 1)
        var previous = Array(repeating: Array(repeating: -1, count: count), count: rows + 1)
        var widths: [Int: Double] = [:]
        costs[0][0] = 0
        for row in 1...rows {
            for end in 1..<count {
                for begin in 0..<end where costs[row - 1][begin].isFinite {
                    guard boundaries[end] <= fitEnds[begin] else { continue }
                    if begin > 0 {
                        let before = characters[begin - 1], after = characters[begin]
                        if before.isASCII && after.isASCII && (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber) { continue }
                    }
                    let key = begin * count + end
                    let measured = widths[key] ?? CTLineGetTypographicBounds(CTTypesetterCreateLine(setter, CFRange(location: boundaries[begin], length: boundaries[end] - boundaries[begin])), nil, nil, nil)
                    widths[key] = measured
                    guard measured <= Double(width) + 0.01 else { continue }
                    var penalty = pow((Double(width) - measured) / Double(width), 2)
                    if end < count - 1 {
                        if !words.contains(boundaries[end]) && !characters[end - 1].isWhitespace { penalty += 0.12 }
                        if characters[end].isWhitespace { penalty += 0.15 }
                        if forbidden.contains(characters[end]) { penalty += 2 }
                        if particles.contains(characters[end]) { penalty += 0.20 }
                    }
                    let candidate = costs[row - 1][begin] + penalty
                    if candidate < costs[row][end] { costs[row][end] = candidate; previous[row][end] = begin }
                }
            }
        }
        guard costs[rows][count - 1].isFinite else { return greedy }
        var end = count - 1
        var result: [NSRange] = []
        for row in stride(from: rows, through: 1, by: -1) {
            let begin = previous[row][end]
            guard begin >= 0 else { return greedy }
            result.append(NSRange(location: boundaries[begin], length: boundaries[end] - boundaries[begin]))
            end = begin
        }
        return result.reversed()
    }
}
#endif
