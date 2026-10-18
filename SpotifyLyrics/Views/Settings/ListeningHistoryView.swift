import SwiftUI

public struct ListeningHistoryView: View {
    @EnvironmentObject private var playback: PlaybackState

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    ListeningRecordMark()
                    Text("LYRIC ISLAND · LISTENING JOURNAL")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                }
                Text("最近播放")
                    .font(.system(size: 25, weight: .semibold))
                Text("这里只记录 Lyric Island 运行期间观察到的播放，不代表 Spotify 的完整播放历史。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)

            if let error = playback.listeningHistoryError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { playback.refreshListeningHistory() }
                }
                .padding(.vertical, 12)
            }
            if playback.isListeningHistoryLoading {
                ProgressView("读取最近播放…")
                    .padding(.vertical, 12)
            }

            if playback.listeningHistory.isEmpty {
                if playback.listeningHistoryError == nil && !playback.isListeningHistoryLoading {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("暂无 Lyric Island 观察记录")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("播放歌曲后，这里会显示本次运行期间观察到的记录。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playback.listeningHistory.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 12) {
                                ListeningArtwork(url: entry.artworkURL)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text(entry.artist)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 12)

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(entry.startedAt, format: .dateTime
                                        .year().month(.twoDigits).day(.twoDigits)
                                        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                        .font(.system(size: 11, design: .monospaced))
                                    Text("本次聆听 · \(formattedDuration(entry.observedPlaybackDuration))")
                                        .font(.system(size: 11))
                                }
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.vertical, 11)
                            .overlay(alignment: .bottom) {
                                if index < playback.listeningHistory.count - 1 { Divider() }
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(28)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    playback.refreshListeningHistory()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新最近播放记录")
            }
        }
        .onAppear {
            playback.refreshListeningHistory()
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)小时 \(minutes)分 \(seconds % 60)秒" }
        if minutes > 0 { return "\(minutes)分 \(seconds % 60)秒" }
        return "\(seconds)秒"
    }

}

/// Shared cached cover for observed playback, with a neutral missing-art fallback.
struct ListeningArtwork: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("专辑封面")
        .task(id: url) {
            image = nil
            let loaded = await ArtworkImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct ListeningRecordMark: View {
    var body: some View {
        VStack(spacing: 3) {
            Capsule().frame(width: 16, height: 2)
            Capsule().frame(width: 11, height: 2).frame(width: 16, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}
