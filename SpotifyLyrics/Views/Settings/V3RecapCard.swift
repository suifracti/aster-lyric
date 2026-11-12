import AppKit
import SwiftUI

/// 回顾卡 (F6): the chosen time range of 听歌统计 as one 1080 × 1350 picture —
/// time listened, songs and plays, the most played singer and the top five
/// songs. Made only when asked; copied and saved like the lyric share card.
@MainActor
enum V3RecapCard {
    static func make(_ statistics: ListeningStatistics) async -> URL? {
        let songs = Array(statistics.topSongs.prefix(5))
        var covers: [String: NSImage] = [:]
        for song in songs {
            if let image = await ArtworkImageLoader.shared.image(for: song.artworkURL) { covers[song.stableKey] = image }
        }
        let ground = songs.first.flatMap { covers[$0.stableKey] }.flatMap { V3LyricShareCard.thumbnail($0, side: 10) }
        let renderer = ImageRenderer(content: V3RecapCardView(statistics: statistics, songs: songs, covers: covers, ground: ground))
        renderer.proposedSize = ProposedViewSize(V3LyricShareCard.size)
        renderer.scale = 1
        guard let image = renderer.nsImage else { return nil }
        return V3LyricShareCard.deliver(image, name: "听歌回顾 \(statistics.timeRange.title)")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }
}

struct V3RecapCardView: View {
    let statistics: ListeningStatistics
    let songs: [ListeningStatisticsSong]
    let covers: [String: NSImage]
    let ground: NSImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.11, green: 0.11, blue: 0.14)
            if let ground {
                Image(nsImage: ground).resizable().interpolation(.high).scaledToFill()
                    .frame(width: V3LyricShareCard.size.width, height: V3LyricShareCard.size.height).clipped()
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(statistics.timeRange.title) · 听歌回顾")
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text(V3RecapCard.durationText(statistics.totalListeningTime))
                    .font(.system(size: 104, weight: .bold)).foregroundStyle(.white)
                    .padding(.top, 18)
                Text("\(statistics.uniqueSongCount) 首歌 · \(statistics.sessionCount) 次播放")
                    .font(.system(size: 32, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 6)
                if let artist = statistics.topArtists.first {
                    HStack(spacing: 14) {
                        Text("最常听").font(.system(size: 28)).foregroundStyle(.white.opacity(0.6))
                        Text(artist.artist).font(.system(size: 40, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    .padding(.top, 44)
                }
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(songs.enumerated()), id: \.element.stableKey) { index, song in
                        HStack(spacing: 24) {
                            Text("\(index + 1)").font(.system(size: 34, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55)).frame(width: 34, alignment: .leading)
                            Group {
                                if let cover = covers[song.stableKey] {
                                    Image(nsImage: cover).resizable().scaledToFill()
                                } else {
                                    Color.white.opacity(0.14)
                                }
                            }
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(song.title).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text("\(song.artist) · \(song.sessionCount) 次").font(.system(size: 26))
                                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.top, 52)
                Spacer(minLength: 30)
                HStack {
                    Text("只统计 Aster · Lyric 运行期间观察到的播放").font(.system(size: 20)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text("Aster · Lyric").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(90)
            .frame(width: V3LyricShareCard.size.width, height: V3LyricShareCard.size.height, alignment: .topLeading)
        }
        .frame(width: V3LyricShareCard.size.width, height: V3LyricShareCard.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}
