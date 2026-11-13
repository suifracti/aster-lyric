import Foundation

/// A "lyric" that is only credits (作词：… 作曲：… 编曲：…) and no sung
/// words. Chinese catalogues return this for songs whose words were never
/// entered; it must not be adopted as the song's lyrics (Lyricify drops the
/// same lines).
enum LyricsCreditOnly {
    private static let credit = try! NSRegularExpression(
        pattern: #"^\s*(作词|作詞|作曲|编曲|編曲|填词|填詞|制作人|製作人|监制|監製|出品|发行|發行|录音|錄音|混音|母带|母帶|和声|和聲|吉他|贝斯|貝斯|鼓|键盘|鍵盤|弦乐|弦樂|演唱|原唱|翻唱|词|詞|曲|OP|SP|ISRC|lyrics(\s+by)?|lyricist|composer|composed\s+by|written\s+by|arranged\s+by|arranger|produced\s+by|producer|mixed\s+by|mastered\s+by)\s*[:：]"#,
        options: [.caseInsensitive])

    static func isCredit(_ text: String) -> Bool {
        credit.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// True when there is at least one line and every non-empty line is a
    /// credit, or the song's own "Title - Artist" heading that precedes them.
    static func matches(_ texts: [String]) -> Bool {
        let lines = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 30 else { return false }
        let credits = lines.filter(isCredit).count
        guard credits > 0 else { return false }
        // One heading line is allowed before the credits; anything else is a sung line.
        let others = lines.count - credits
        return others == 0 || (others == 1 && !isCredit(lines[0]) && lines[0].contains(" - "))
    }

    static func matches(_ lines: [LyricLine]) -> Bool { matches(lines.map(\.originalText)) }

    /// The same test on raw LRC text: time tags and `[ti:…]` headers are ignored.
    static func matches(lrc: String) -> Bool {
        matches(lrc.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"\[[^\]]*\]|<[^>]*>|\(\d+,\d+(,\d+)?\)"#, with: "", options: .regularExpression)
        })
    }
}
