import Foundation

/// Stored line-timed lyrics can be upgraded to word timing (网易 yrc, QQ qrc,
/// 酷狗 krc, AMLL) when a source later offers it for the same song. Lyrimuse
/// showed 逐字 for Lost My Mind while we kept a QQ line-timed version saved
/// before QRC was read; QQ had the QRC all along.
///
/// The upgrade never changes what the listener reads: the new version must
/// carry the same lines at the same moments, only with finer timing. A
/// manual, local, aligned or ASR version is never replaced.
public enum LyricsWordTimingUpgrade {
    /// Sources whose stored line timing came from an online catalogue.
    static let upgradableSources: Set<LyricsSource> = [
        .amll, .lrclib, .neteaseExperimental, .qqExperimental,
        .kuwoExperimental, .kugouExperimental, .linkcore, .petitLyrics,
    ]

    /// Largest start-time difference for a line to count as the same moment.
    static let lineStartTolerance: TimeInterval = 1.0
    /// Share of the held sung lines that must reappear in the upgrade.
    static let requiredCoverage = 0.8

    public static func hasWordTiming(_ document: LyricsDocument) -> Bool {
        let sung = document.lines.filter { !normalized($0.originalText).isEmpty }
        guard !sung.isEmpty else { return false }
        let worded = sung.filter { $0.hasValidTimedSpans(lineStartIsMeaningful: document.isSynchronized) }
        return worded.count * 2 >= sung.count
    }

    /// True for a stored, online, line-timed version without word timing.
    public static func wantsUpgrade(_ held: LyricsDocument) -> Bool {
        held.isSynchronized
            && upgradableSources.contains(held.source)
            && !held.lines.contains(where: { !($0.timedSpans?.isEmpty ?? true) })
            && held.lines.contains(where: { !normalized($0.originalText).isEmpty })
    }

    /// The upgrade has word timing and the same lines at the same moments.
    public static func isCompatible(held: LyricsDocument, upgrade: LyricsDocument) -> Bool {
        guard wantsUpgrade(held), upgrade.isSynchronized, hasWordTiming(upgrade),
              held.identity == upgrade.identity else { return false }
        var byText: [String: [TimeInterval]] = [:]
        for line in upgrade.lines {
            let key = normalized(line.originalText)
            guard !key.isEmpty else { continue }
            byText[key, default: []].append(line.timestamp)
        }
        let sung = held.lines.filter { !normalized($0.originalText).isEmpty }
        let matched = sung.filter { line in
            byText[normalized(line.originalText)]?.contains { abs($0 - line.timestamp) <= lineStartTolerance } == true
        }
        return Double(matched.count) >= Double(sung.count) * requiredCoverage
    }

    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }))
    }
}

/// QRC, KRC and YRC give each line a `[start,duration]` header rounded on its
/// own, so the last word can end a few milliseconds after the line (Lost My
/// Mind: 「また世界の底に」 words to 31.396). `hasValidTimedSpans` then rejected
/// the whole song's word timing and it ranked as line timing. The line now
/// covers its words.
enum TimedLineBounds {
    static func covering(spans: [TimedTextSpan], start: TimeInterval, end: TimeInterval?) -> (start: TimeInterval, end: TimeInterval?) {
        guard let first = spans.map(\.startTime).min(), let last = spans.map(\.endTime).max() else { return (start, end) }
        return (min(start, first), end.map { max($0, last) })
    }
}
