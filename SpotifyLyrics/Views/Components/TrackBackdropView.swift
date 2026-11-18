import AppKit
import SwiftUI

private struct DirectionDBackdropTreatmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var directionDBackdropTreatment: Bool {
        get { self[DirectionDBackdropTreatmentKey.self] }
        set { self[DirectionDBackdropTreatmentKey.self] = newValue }
    }
}

struct TrackBackdropView: View {
    let track: Track
    let identity: TrackIdentity?
    let isLiveTrack: Bool

    @State private var loaded: BackdropPayload?
    private var currentPayload: BackdropPayload? { loaded?.url == requestKey ? loaded : nil }
    @Environment(\.directionDBackdropTreatment) private var directionDBackdropTreatment

    var body: some View {
        ZStack {
            neutralBackground

            if let currentPayload {
                backdropLayers(for: currentPayload)
                    .transition(.opacity)
            }

            Color.black.opacity(directionDBackdropTreatment
                ? min(0.70, max(0.26, (currentPayload?.palette.readabilityVeilOpacity ?? 0.36) * 0.82))
                : (currentPayload?.palette.readabilityVeilOpacity ?? 0.36))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: requestKey) {
            await reload(for: requestKey)
        }
    }

    private var requestKey: URL? {
        isLiveTrack && identity != nil ? track.artworkURL : nil
    }

    private var neutralBackground: some View {
        let palette = BackdropPalette.neutral
        return ZStack {
            LinearGradient(
                colors: [
                    color(palette.primary),
                    color(palette.secondary),
                    color(palette.glow).opacity(directionDBackdropTreatment ? 0.72 : 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if directionDBackdropTreatment {
                RadialGradient(
                    colors: [color(palette.glow).opacity(0.34), .clear],
                    center: UnitPoint(x: 0.18, y: 0.42),
                    startRadius: 24,
                    endRadius: 560
                )
            }
        }
    }

    private func backdropLayers(for payload: BackdropPayload) -> some View {
        let palette = payload.palette
        return ZStack {
            Image(nsImage: payload.image)
                .resizable()
                .scaledToFill()
                .scaleEffect(directionDBackdropTreatment ? 1.24 : 1.34)
                .blur(radius: directionDBackdropTreatment ? 48 : 72)
                .opacity(directionDBackdropTreatment
                    ? min(0.70, palette.textureOpacity + 0.22)
                    : palette.textureOpacity)

            if directionDBackdropTreatment {
                Image(nsImage: payload.image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.12)
                    .blur(radius: 22)
                    .blendMode(.screen)
                    .opacity(0.10)
            }

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(directionDBackdropTreatment ? 0.14 : 0.34)

            LinearGradient(
                colors: [
                    color(palette.primary).opacity(directionDBackdropTreatment ? 0.62 : 0.86),
                    color(palette.secondary).opacity(directionDBackdropTreatment ? 0.74 : 0.94),
                    color(palette.glow).opacity(directionDBackdropTreatment ? 0.42 : 0.64)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    color(palette.glow).opacity(directionDBackdropTreatment ? 0.48 : 0.36),
                    .clear
                ],
                center: directionDBackdropTreatment
                    ? UnitPoint(x: 0.16, y: 0.44)
                    : .topTrailing,
                startRadius: 16,
                endRadius: 560
            )

            if directionDBackdropTreatment {
                // One continuous canvas: the lyric side is quieter, not a
                // second opaque panel.
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.10), Color.black.opacity(0.30)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.44)],
                    center: .center,
                    startRadius: 160,
                    endRadius: 900
                )
            }
        }
        .clipped()
    }

    @MainActor
    private func reload(for url: URL?) async {
        guard !Task.isCancelled else { return }
        if loaded?.url != url { loaded = nil }
        guard let url, let image = await ArtworkImageLoader.shared.image(for: url), !Task.isCancelled,
              let imageData = image.tiffRepresentation else { return }
        let palette = await BackdropPaletteCache.shared.palette(
            for: AppleMusicImmersiveV3BackdropKey.make(artworkURL: url),
            imageData: imageData
        )
        guard url == requestKey, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.42)) {
            loaded = .init(url: url, image: image, palette: palette)
        }
    }

    private func color(_ value: BackdropColor) -> Color {
        Color(red: value.red, green: value.green, blue: value.blue)
    }
}

private struct BackdropPayload {
    let url: URL
    let image: NSImage
    let palette: BackdropPalette
}
