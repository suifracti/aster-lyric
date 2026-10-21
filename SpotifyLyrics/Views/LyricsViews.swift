import SwiftUI

struct LineDisplayView: View {
    let line: LyricLine
    let isActive: Bool
    let prefs: DisplayPreferences

    private var baseFont: Font {
        .system(
            size: prefs.fontSize,
            weight: isActive ? .bold : .medium,
            design: .rounded
        )
    }

    private var rubyFont: Font {
        .system(
            size: max(11, prefs.fontSize * 0.55),
            weight: isActive ? .bold : .medium,
            design: .rounded
        )
    }

    private var baseColor: Color {
        isActive ? .primary : .secondary.opacity(0.8)
    }

    private var rubyColor: Color {
        isActive ? .accentColor.opacity(0.8) : .secondary.opacity(0.7)
    }

    private var displayKanaText: String? {
        line.kanaText.map(JapaneseRomanizer.displayKana)
    }

    /// Keep the compatibility/floating/full-screen renderer consistent with
    /// the main lyric canvas. Some older payloads duplicate the confirmed
    /// kana in `romajiText`; do not render that same layer twice.
    private var distinctRomaji: String? {
        guard prefs.showRomaji,
              let romaji = line.romajiText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !romaji.isEmpty else {
            return nil
        }

        if let kana = displayKanaText,
           !kana.isEmpty,
           normalizedDisplayText(romaji) == normalizedDisplayText(kana) {
            return nil
        }
        return romaji
    }

    /// An all-kana line is its own reading; a second row would repeat it.
    private var readingRepeatsOriginal: Bool {
        guard let kana = displayKanaText, !kana.isEmpty else { return false }
        return normalizedDisplayText(kana) == normalizedDisplayText(line.originalText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if prefs.kanaDisplayMode == .kanaReplacement,
               let kana = displayKanaText,
               !kana.isEmpty {
                KanaReplacementLineView(
                    originalText: line.originalText,
                    kanaText: kana,
                    tokens: line.rubyTokens,
                    showsOriginalAnnotation: prefs.showOriginal && !line.originalText.isEmpty,
                    baseFont: baseFont,
                    annotationFont: rubyFont,
                    baseColor: baseColor,
                    annotationColor: rubyColor
                )
            } else if prefs.showOriginal, !line.originalText.isEmpty {
                if prefs.kanaDisplayMode == .inlineRuby,
                   let kana = displayKanaText,
                   !kana.isEmpty {
                    RubyLineView(
                        originalText: line.originalText,
                        kanaText: kana,
                        tokens: line.rubyTokens,
                        baseFont: baseFont,
                        rubyFont: rubyFont,
                        baseColor: baseColor,
                        rubyColor: rubyColor
                    )
                } else {
                    Text(line.originalText)
                        .font(baseFont)
                        .foregroundColor(baseColor)
                        .scaleEffect(isActive ? 1.03 : 1.0, anchor: .leading)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
                }

                if prefs.kanaDisplayMode == .independentLine,
                   prefs.showKana,
                   !readingRepeatsOriginal,
                   let kana = displayKanaText,
                   !kana.isEmpty {
                    Text(kana)
                        .font(.system(size: prefs.fontSize * 0.65, weight: .medium, design: .rounded))
                        .foregroundColor(rubyColor)
                }
            } else if prefs.showKana, let kana = displayKanaText, !kana.isEmpty {
                Text(kana)
                    .font(.system(size: prefs.fontSize * 0.65, weight: .light, design: .rounded))
                    .foregroundColor(isActive ? .accentColor.opacity(0.8) : .secondary)
            }
            if let romaji = distinctRomaji {
                Text(romaji)
                    .font(.system(size: prefs.fontSize * 0.75, weight: .regular, design: .monospaced))
                    .foregroundColor(isActive ? .accentColor : .secondary.opacity(0.7))
            }
            if prefs.showTranslation, let trans = line.translationText, !trans.isEmpty {
                Text(trans)
                    .font(.system(size: prefs.fontSize * 0.85, weight: .medium, design: .rounded))
                    .foregroundColor(isActive ? .primary.opacity(0.9) : .secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 4)
    }

    private func normalizedDisplayText(_ text: String) -> String {
        JapaneseRomanizer.displayKana(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
    }
}

struct PlainLyricsListView: View {
    let lines: [LyricLine]
    let prefs: DisplayPreferences

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lines) { line in
                    LineDisplayView(line: line, isActive: false, prefs: prefs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }
}

// Legacy floating renderer. The production floating window now lives under
// Views/Floating and consumes the shared live session directly. Keep this
// source-compatible renderer for the retained compatibility surfaces only.
struct LegacyFloatingLyricsView: View {
    @EnvironmentObject var state: PlaybackState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                if state.lyricsAreSynchronized,
                   let index = state.currentLineIndex,
                   index < state.lyrics.count {
                    let line = state.lyrics[index]
                    LineDisplayView(line: line, isActive: true, prefs: state.preferences)
                } else if !state.lyricsAreSynchronized, !state.lyrics.isEmpty {
                    PlainLyricsListView(lines: state.lyrics, prefs: state.preferences)
                } else {
                    Text(state.lyricsStatusMessage.isEmpty ? "歌词已加载" : state.lyricsStatusMessage)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }
}

// Top Capsule Player View
struct CapsulePlayerView: View {
    @EnvironmentObject var state: PlaybackState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.currentTrack.artworkName)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.currentTrack.title)
                    .font(.caption)
                    .bold()
                    .lineLimit(1)
                if let index = state.currentLineIndex, index < state.lyrics.count {
                    Text(state.lyrics[index].originalText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if !state.lyricsAreSynchronized, let firstLine = state.lyrics.first {
                    Text(firstLine.originalText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: { state.togglePlayPause() }) {
                Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }
}
