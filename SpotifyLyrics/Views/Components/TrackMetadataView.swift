import SwiftUI

enum TrackMetadataPresentation {
    case standard
    case v3Immersive
}

struct TrackMetadataView: View {
    let track: Track
    var titleSize: CGFloat = 20
    var alignment: HorizontalAlignment = .leading
    var presentation: TrackMetadataPresentation = .standard

    private var artistLinks: [TrackArtistLink] {
        track.artistLinks.isEmpty
            ? [TrackArtistLink(name: track.artist)]
            : track.artistLinks
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(track.title)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .help("\(track.title)\n右键复制歌曲信息")
                .contextMenu {
                    Button("复制歌名", systemImage: "doc.on.doc") {
                        _ = TrackMetadataCopy.copy(track.title)
                    }
                    Button("复制歌手", systemImage: "person") {
                        _ = TrackMetadataCopy.copy(track.artist)
                    }
                    if !track.album.isEmpty {
                        Button("复制专辑", systemImage: "square.stack") {
                            _ = TrackMetadataCopy.copy(track.album)
                        }
                    }
                    Divider()
                    Button("复制歌曲信息", systemImage: "list.clipboard") {
                        _ = TrackMetadataCopy.copy(TrackMetadataCopy.summary(
                            title: track.title, artist: track.artist, album: track.album
                        ))
                    }
                }

            ViewThatFits(in: .horizontal) {
                metadataSingleLine
                metadataStacked
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title)，\(track.artist)，\(track.album)")
    }

    private var metadataSingleLine: some View {
        HStack(spacing: 6) {
            artistGroup
            if !track.album.isEmpty {
                Text("·")
                    .foregroundStyle(separatorColor)
                albumButton
            }
        }
        .font(metadataFont)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metadataStacked: some View {
        VStack(alignment: alignment, spacing: 2) {
            artistGroup
            if !track.album.isEmpty {
                HStack(spacing: 4) {
                    Text("·")
                        .foregroundStyle(separatorColor)
                    albumButton
                }
            }
        }
        .font(metadataFont)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    private var metadataFont: Font {
        .system(
            size: max(12, titleSize * 0.58),
            weight: presentation == .v3Immersive ? .semibold : .medium,
            design: .rounded
        )
    }

    private var artistGroup: some View {
        HStack(spacing: 4) {
            ForEach(Array(artistLinks.enumerated()), id: \.offset) { index, artist in
                if index > 0 {
                    Text(",")
                        .foregroundStyle(separatorColor)
                }
                artistButton(artist)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private func artistButton(_ artist: TrackArtistLink) -> some View {
        if let url = artist.url {
            Button(artist.name) {
                _ = NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .foregroundStyle(artistColor)
            .help("在 Spotify 打开艺人：\(artist.name)\n右键复制歌手")
            .contextMenu {
                Button("复制歌手", systemImage: "doc.on.doc") {
                    _ = TrackMetadataCopy.copy(artist.name)
                }
            }
        } else {
            Text(artist.name)
                .foregroundStyle(artistColor)
                .help("\(artist.name)\n右键复制歌手")
                .contextMenu {
                    Button("复制歌手", systemImage: "doc.on.doc") {
                        _ = TrackMetadataCopy.copy(artist.name)
                    }
                }
        }
    }

    private var albumButton: some View {
        Group {
            if let url = track.albumURL {
                Button(track.album) {
                    _ = NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .help("在 Spotify 打开专辑：\(track.album)\n右键复制专辑")
            } else {
                Text(track.album)
                    .help("\(track.album)\n右键复制专辑")
            }
        }
        .font(.system(size: max(11, titleSize * 0.52), design: .rounded))
        .foregroundStyle(albumColor)
        .lineLimit(1)
        .contextMenu {
            Button("复制专辑", systemImage: "doc.on.doc") {
                _ = TrackMetadataCopy.copy(track.album)
            }
        }
    }

    private var artistColor: Color {
        presentation == .v3Immersive
            ? Color.white.opacity(0.90)
            : LyricsDesignTokens.secondaryText
    }

    private var albumColor: Color {
        presentation == .v3Immersive
            ? Color.white.opacity(0.72)
            : LyricsDesignTokens.mutedText
    }

    private var separatorColor: Color {
        presentation == .v3Immersive
            ? Color.white.opacity(0.46)
            : LyricsDesignTokens.mutedText.opacity(0.6)
    }
}
