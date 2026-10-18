import SwiftUI

public struct ListeningStatisticsView: View {
    @EnvironmentObject private var playback: PlaybackState
    @State private var visibleSongCount = 20
    @State private var selectedTimeRange: ListeningStatisticsTimeRange = .allTime

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        StatisticsRecordMark()
                        Text("LYRIC ISLAND · LISTENING NOTES")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    Text("听歌统计")
                        .font(.system(size: 25, weight: .semibold))
                    Text("仅统计应用运行期间观察到的播放；新版会分别记录单曲循环，旧记录中合并的循环次数无法还原。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("时间范围", selection: $selectedTimeRange) {
                    ForEach(ListeningStatisticsTimeRange.allCases) { timeRange in
                        Text(timeRange.title).tag(timeRange)
                    }
                }
                .pickerStyle(.segmented)

                if let error = playback.listeningStatisticsError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重试") { playback.refreshListeningStatistics(for: selectedTimeRange) }
                    }
                }
                if playback.isListeningStatisticsLoading {
                    ProgressView("读取统计…")
                }
                if let statistics = playback.listeningStatistics {
                    if statistics.timeRange != selectedTimeRange {
                        Text("上次成功读取：\(statistics.timeRange.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if statistics.isEmpty {
                        emptyState
                    } else {
                        summary(statistics)
                        if !statistics.dailyPlayCounts.isEmpty {
                            trendSection(statistics.dailyPlayCounts)
                        }
                        topSongs(statistics.topSongs)
                        topArtists(statistics.topArtists)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(28)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    playback.refreshListeningStatistics(for: selectedTimeRange)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新听歌统计")
            }
        }
        .onAppear {
            playback.refreshListeningStatistics(for: selectedTimeRange)
        }
        .onChange(of: selectedTimeRange) { _, newValue in
            visibleSongCount = 20
            playback.refreshListeningStatistics(for: newValue)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("暂无统计记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("播放歌曲后，这里会显示 Lyric Island 观察到的听歌时长和排序。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func summary(_ statistics: ListeningStatistics) -> some View {
        HStack(spacing: 0) {
            summaryCard(
                title: "总听歌时长",
                value: formattedDuration(statistics.totalListeningTime),
                icon: "clock"
            )
            Divider().frame(height: 44).padding(.horizontal, 16)
            summaryCard(
                title: "播放记录",
                value: "\(statistics.sessionCount)",
                icon: "music.note.list"
            )
            Divider().frame(height: 44).padding(.horizontal, 16)
            summaryCard(
                title: "独立歌曲数",
                value: "\(statistics.uniqueSongCount)",
                icon: "music.quarternote.3"
            )
        }
    }

    private func summaryCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func trendSection(_ dailyCounts: [ListeningStatisticsDailyCount]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("最近 7 天", systemImage: "chart.bar")
                    .font(.headline)
                Text("每日观察播放记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 12) {
                let maxCount = max(dailyCounts.map(\.count).max() ?? 0, 1)
                ForEach(dailyCounts) { item in
                    VStack(spacing: 6) {
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(item.count > 0 ? .primary : .tertiary)

                        let barHeight = item.count > 0
                            ? max(6, CGFloat(item.count) / CGFloat(maxCount) * 56)
                            : 4

                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.count > 0 ? Color.accentColor : Color.secondary.opacity(0.18))
                                .frame(height: barHeight)
                        }
                        .frame(height: 60)

                        Text(item.dayLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func topSongs(_ songs: [ListeningStatisticsSong]) -> some View {
        let displaySongs = Array(songs.prefix(visibleSongCount))
        if !displaySongs.isEmpty {
            statisticsGroup(title: "歌曲排行", icon: "music.note") {
                ForEach(Array(displaySongs.enumerated()), id: \.element.id) { index, song in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .leading)
                        ListeningArtwork(url: song.artworkURL)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(song.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(song.sessionCount) 次 · \(formattedDuration(song.observedListeningTime))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if song.id != displaySongs.last?.id {
                        Divider()
                    }
                }
                if songs.count > visibleSongCount {
                    Button("显示更多歌曲") { visibleSongCount += 20 }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func topArtists(_ artists: [ListeningStatisticsArtist]) -> some View {
        let displayArtists = Array(artists.prefix(5))
        if !displayArtists.isEmpty {
            statisticsGroup(title: "艺人排行", icon: "person.2") {
                ForEach(Array(displayArtists.enumerated()), id: \.element.id) { index, artist in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .leading)
                        Text(artist.artist)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(artist.sessionCount) 次 · \(formattedDuration(artist.observedListeningTime))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if artist.id != displayArtists.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func statisticsGroup<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            VStack(spacing: 0) {
                content()
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)小时 \(minutes)分"
        }
        if minutes > 0 {
            return "\(minutes)分 \(seconds)秒"
        }
        return "\(seconds)秒"
    }
}

private struct StatisticsRecordMark: View {
    var body: some View {
        VStack(spacing: 3) {
            Capsule().frame(width: 16, height: 2)
            Capsule().frame(width: 11, height: 2).frame(width: 16, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}
