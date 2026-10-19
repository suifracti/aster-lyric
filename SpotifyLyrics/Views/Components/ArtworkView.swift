import AppKit
import SwiftUI

/// Reusable artwork surface shared by the focus and immersive layouts.
struct ArtworkView: View {
    let track: Track
    let size: CGFloat
    var showsAlbumLabel: Bool = true
    /// V2 keeps its established icon-like radius; V3 opts into a small
    /// album-cover radius without changing the shared component's default.
    var cornerRadiusRatio: CGFloat = 0.18
    var preservesCompleteArtwork: Bool = false
    @State private var remoteArtwork: NSImage?

    var body: some View {
        ZStack {
            fallbackArtwork

            if let remoteArtwork {
                Image(nsImage: remoteArtwork)
                    .resizable()
                    .aspectRatio(contentMode: preservesCompleteArtwork ? .fit : .fill)
                    .transition(.opacity)
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * cornerRadiusRatio, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * cornerRadiusRatio, style: .continuous)
                .stroke(LyricsDesignTokens.controlBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(showsAlbumLabel ? 0.28 : 0.18), radius: size * 0.08, y: size * 0.04)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.album.isEmpty ? "专辑封面" : "专辑封面，\(track.album)")
        .task(id: "\(track.id)|\(effectiveArtworkURL?.absoluteString ?? "no-artwork")|\(debugForceNoArtwork ? "debug-no-artwork" : "artwork")") {
            remoteArtwork = nil
            guard !debugForceNoArtwork else { return }
            remoteArtwork = await ArtworkImageLoader.shared.image(for: effectiveArtworkURL)
        }
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
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
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
