import AppKit
import SwiftUI

/// Cover thumbnails use the same file and network cache as the playback view.
struct CachedArtwork<Placeholder: View>: View {
    let url: URL?
    private let placeholder: Placeholder
    @State private var loaded: (url: URL, image: NSImage)?

    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let url, let image = loaded?.url == url ? loaded?.image : ArtworkImageLoader.shared.imageInMemory(for: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { loaded = nil; return }
            let image = await ArtworkImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            loaded = image.map { (url, $0) }
        }
    }
}

/// Reusable artwork surface shared by the focus and immersive layouts.
struct ArtworkView: View {
    let track: Track
    let size: CGFloat
    var showsAlbumLabel: Bool = true
    /// V2 keeps its established icon-like radius; V3 opts into a small
    /// album-cover radius without changing the shared component's default.
    var cornerRadiusRatio: CGFloat = 0.18
    var preservesCompleteArtwork: Bool = false
    var reportsForegroundFrame: Bool = false
    @State private var remoteArtwork: NSImage?
    /// The cover being replaced, kept underneath until the new one is clear.
    @State private var outgoingArtwork: NSImage?
    @State private var developed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardSize: CGSize {
        let slot = CGSize(width: size, height: size)
        guard preservesCompleteArtwork, let artwork = remoteArtwork,
              artwork.size.width > 0, artwork.size.height > 0 else { return slot }
        let scale = size / max(artwork.size.width, artwork.size.height)
        return CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
    }

    var body: some View {
        // Keep the layout slot stable while reporting the visible cover to the
        // progress halo, caption and scene effects inside that slot.
        artworkCard
            .v3ReportsForegroundCover(cornerRadiusRatio: cornerRadiusRatio, enabled: reportsForegroundFrame)
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(track.album.isEmpty ? "专辑封面" : "专辑封面，\(track.album)")
            .task(id: "\(effectiveArtworkURL?.absoluteString ?? "no-artwork")|\(debugForceNoArtwork ? "debug-no-artwork" : "artwork")") {
                await loadArtwork()
            }
    }

    private var artworkCard: some View {
        let dimensions = cardSize
        let shape = RoundedRectangle(cornerRadius: min(dimensions.width, dimensions.height) * cornerRadiusRatio,
                                     style: .continuous)
        return ZStack {
            if (remoteArtwork == nil || !developed) && outgoingArtwork == nil { fallbackArtwork }

            if let outgoingArtwork {
                Image(nsImage: outgoingArtwork)
                    .resizable()
                    .aspectRatio(contentMode: preservesCompleteArtwork ? .fit : .fill)
            }
            if let remoteArtwork {
                // 显影: a new cover comes up out of a soft blur, like a print developing.
                Image(nsImage: remoteArtwork)
                    .resizable()
                    .aspectRatio(contentMode: preservesCompleteArtwork ? .fit : .fill)
                    .blur(radius: developed || reduceMotion ? 0 : size * 0.05)
                    .scaleEffect(developed || reduceMotion ? 1 : 1.04)
                    .opacity(developed ? 1 : 0)
            }

            if showsAlbumLabel {
                VStack {
                    Spacer()
                    Text(track.album.uppercased())
                        .font(.system(size: max(8, size * 0.1), weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(LyricsDesignTokens.primaryText.opacity(0.78))
                        .padding(.bottom, size * 0.1)
                }
            }
        }
        .frame(width: dimensions.width, height: dimensions.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(LyricsDesignTokens.controlBorder, lineWidth: 1) }
        .shadow(color: .black.opacity(showsAlbumLabel ? 0.28 : 0.18), radius: size * 0.08, y: size * 0.04)
    }

    private func loadArtwork() async {
        // A song without artwork never keeps the previous song's image.
        let next = debugForceNoArtwork ? nil : await ArtworkImageLoader.shared.image(for: effectiveArtworkURL)
        guard !Task.isCancelled else { return }
        guard let next else { outgoingArtwork = nil; remoteArtwork = nil; developed = true; return }
        if next === remoteArtwork { outgoingArtwork = nil; developed = true; return }
        outgoingArtwork = remoteArtwork
        developed = false
        remoteArtwork = next
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .easeOut(duration: 0.75)) { developed = true }
        try? await Task.sleep(nanoseconds: 800_000_000)
        if !Task.isCancelled { outgoingArtwork = nil }
    }

    /// Debug-only fixture for visual validation. It forces the same formal
    /// neutral placeholder used when a track has no artwork, including the
    /// foreground cover, so a no-art screenshot cannot retain the previous
    /// track's remote image. Release builds always use the real track URL.
    private var debugForceNoArtwork: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["SPOTIFYLYRICS_BACKDROP_NO_ARTWORK"] == "1"
#else
        false
#endif
    }

    private var effectiveArtworkURL: URL? {
        debugForceNoArtwork ? nil : track.artworkURL
    }

    private var effectiveArtworkName: String {
        debugForceNoArtwork ? "music.note" : track.artworkName
    }

    private var fallbackArtwork: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.34, green: 0.25, blue: 0.24),
                            Color(red: 0.16, green: 0.19, blue: 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color(red: 0.83, green: 0.67, blue: 0.45).opacity(0.42))
                .frame(width: size * 0.72, height: size * 0.72)
                .blur(radius: size * 0.12)
                .offset(x: size * 0.18, y: -size * 0.14)

            // Large no-artwork surfaces show a quiet mark plus the song identity
            // instead of a symbol that dominates half the window.
            let showsIdentity = remoteArtwork == nil && size >= 160 && !track.title.isEmpty
            VStack(spacing: size * 0.05) {
                Image(systemName: effectiveArtworkName)
                    .font(.system(size: size * (showsIdentity ? 0.14 : 0.31), weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(LyricsDesignTokens.primaryText.opacity(showsIdentity ? 0.6 : 1))
                if showsIdentity {
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.system(size: min(26, size * 0.06), weight: .semibold, design: .rounded))
                            .foregroundStyle(LyricsDesignTokens.primaryText)
                        if !track.artist.isEmpty {
                            Text(track.artist)
                                .font(.system(size: min(17, size * 0.04), weight: .medium, design: .rounded))
                                .foregroundStyle(LyricsDesignTokens.primaryText.opacity(0.7))
                        }
                    }
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, size * 0.1)
                }
            }
        }
    }
}
