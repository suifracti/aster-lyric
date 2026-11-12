import SwiftUI

public struct ListeningHistoryView: View {
    @EnvironmentObject private var playback: PlaybackState
    /// 列表 or 封面墙; remembered.
    @AppStorage("listening.history.coverWall.v1") private var showsWall = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The page tab already names it; the scope note is one quiet line.
            HStack {
                Text("只记录 Aster · Lyric 运行期间观察到的播放")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("不代表 Spotify 的完整播放历史。")
                Spacer(minLength: 12)
                Picker("显示方式", selection: $showsWall) {
                    Text("列表").tag(false)
                    Text("封面墙").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("封面墙：每首一张，最近听的在前；指向一张会把同一歌手以外的变暗")
            }
            .padding(.bottom, 10)

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
                        Text("暂无 Aster · Lyric 观察记录")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("播放歌曲后，这里会显示本次运行期间观察到的记录。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if showsWall {
                ListeningCoverWall(entries: playback.listeningHistory)
                    .padding(.horizontal, -28).padding(.bottom, -28)
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
                                    Text(v3ShortDateText(entry.startedAt))
                                        .font(.system(size: 11))
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
