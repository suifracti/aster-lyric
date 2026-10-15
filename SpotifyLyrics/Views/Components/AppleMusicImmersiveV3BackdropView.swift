import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A single track-bound key projection shared by V3 and fullscreen through
/// the same backdrop view and cache. Playback time is intentionally absent.
enum AppleMusicImmersiveV3BackdropKey {
    static func make(
        identityKey: String,
        artworkURL: URL?,
        forceNoArtwork: Bool
    ) -> String {
        "\(identityKey)|\(artworkURL?.absoluteString ?? "no-artwork")|\(forceNoArtwork ? "debug-no-artwork" : "artwork")"
    }
}

/// The V3 backdrop is deliberately track-bound rather than playback-bound.
/// Cover data is reduced and sampled once per TrackIdentity/artwork key; the
/// SwiftUI view never rebuilds a full-resolution blur on every time tick.
struct AppleMusicImmersiveV3BackdropView: View {
    let track: Track
    let identity: TrackIdentity?
    var isInstrumental: Bool = false
    @ObservedObject var settings: AppSettingsStore
    var presentationOverride: V3ArtworkPresentation? = nil

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var artworkImage: NSImage?
    @State private var outgoingArtworkImage: NSImage?
    @State private var ambientArtworkImage: NSImage?
    @State private var outgoingAmbientArtworkImage: NSImage?
    @State private var noiseImage: NSImage?
    @State private var palette = BackdropPalette.neutral
    @State private var accessibilityDisplayRevision = 0

    private var artworkPresentation: V3ArtworkPresentation { presentationOverride ?? settings.v3ArtworkPresentation }
    private var backdropBlurRadius: Double { settings.v3PreviewBlur(for: artworkPresentation) }
    private var artworkPosition: String { settings.v3PreviewPosition(for: artworkPresentation) }
    private var artworkSizeScale: Double { settings.v3PreviewScale(for: artworkPresentation) }

    var body: some View {
        ZStack {
            neutralBackground

            if let outgoingArtworkImage {
                artworkLayers(
                    image: outgoingArtworkImage,
                    ambientImage: outgoingAmbientArtworkImage
                )
                    .opacity(0.28)
                    .transition(.opacity)
            }

            if let artworkImage {
                artworkLayers(image: artworkImage, ambientImage: ambientArtworkImage)
                    .transition(.opacity)
            }

            // The veil is intentionally independent of playback position.
            if artworkPresentation != .stage {
                Color.black.opacity(readabilityVeilOpacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: requestKey) {
            await loadSnapshot(for: requestKey)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            accessibilityDisplayRevision &+= 1
        }
    }

    private var requestKey: String {
        let identityKey = identity?.stableKey ?? track.id
        return AppleMusicImmersiveV3BackdropKey.make(
            identityKey: identityKey,
            artworkURL: track.artworkURL,
            forceNoArtwork: debugForceNoArtwork
        )
    }

    /// Debug-only visual validation switch. It exercises the same neutral
    /// fallback path without creating a second artwork loader or altering
    /// production behavior.
    private var debugForceNoArtwork: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["SPOTIFYLYRICS_BACKDROP_NO_ARTWORK"] == "1"
#else
        false
#endif
    }

    private var presentationID: BackdropPresentationID {
        BackdropPresentationID.active
    }

    private var presentationStyle: BackdropPresentationStyle {
        presentationID.style
    }

    private var reduceTransparency: Bool {
        // Referencing the revision makes the view redraw when the system
        // accessibility display options change without reloading artwork.
        let _ = accessibilityDisplayRevision
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var increaseContrast: Bool {
        let _ = accessibilityDisplayRevision
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var readabilityVeilOpacity: Double {
        let style = presentationStyle
        let baseVeil = max(
            style.minimumLyricVeil,
            palette.readabilityVeilOpacity * style.lyricVeilMultiplier
        )

        // Moderate luminance adjustment for bright covers to preserve artwork glow
        let luminanceBoost = palette.luminance > 0.5 ? (palette.luminance - 0.5) * 0.32 : 0.0
        let paletteVeil = min(0.38, baseVeil + luminanceBoost)

        // Ambient needs its artwork colors visible; the lyric side has its
        // own localized protection. Keep Classic's established veil intact.
        if artworkPresentation == .ambientFeathered {
            if reduceTransparency { return min(0.76, max(0.56, paletteVeil + 0.22)) }
            if increaseContrast { return min(0.48, paletteVeil + 0.12) }
            return min(0.10, paletteVeil * 0.26)
        }

        if reduceTransparency {
            return min(0.90, max(0.62, paletteVeil + 0.18))
        }

        if increaseContrast {
            return min(0.88, paletteVeil + 0.14)
        }

        return min(0.42, paletteVeil)
    }

    private var artworkTransitionDuration: Double {
        accessibilityReduceMotion
            ? LyricsDesignTokens.Motion.reduceMotionDuration
            : presentationStyle.transitionDuration
    }

    private var outgoingTransitionDuration: Double {
        accessibilityReduceMotion
            ? LyricsDesignTokens.Motion.reduceMotionDuration
            : presentationStyle.outgoingTransitionDuration
    }

    private var neutralBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    color(BackdropPalette.neutral.primary),
                    color(BackdropPalette.neutral.secondary),
                    color(BackdropPalette.neutral.glow)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    color(BackdropPalette.neutral.glow).opacity(0.42),
                    .clear
                ],
                center: UnitPoint(x: 0.16, y: 0.5),
                startRadius: 20,
                endRadius: 520
            )
        }
    }

    private var normalizedBlur: Double {
        max(0, min(100, backdropBlurRadius)) / 100.0
    }

    private var effectiveBlurRadius: Double {
        if settings.v3InstrumentalPureImmersion && isInstrumental {
            return normalizedBlur * 4.0
        }
        // Crisp continuous linear mapping (0% = 0.0pt, 25% = 7.0pt, 60% = 16.8pt, 100% = 28.0pt)
        // 0% is 100% clear artwork image, 100% maxes out at a soft 28pt blur instead of heavy mush
        return normalizedBlur * 28.0
    }

    private var effectiveScreenBlurRadius: Double {
        if settings.v3InstrumentalPureImmersion && isInstrumental {
            return normalizedBlur * 1.2
        }
        return normalizedBlur * 14.0
    }

    private var coverLightCenter: UnitPoint {
        let position = artworkPosition
        if position == "right" {
            return UnitPoint(x: 0.76, y: 0.38)
        } else if position == "center" {
            return UnitPoint(x: 0.50, y: 0.36)
        } else {
            return UnitPoint(x: 0.24, y: 0.38)
        }
    }

    @ViewBuilder
    private func artworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        switch artworkPresentation {
        case .ambient:
            ambientArtworkLayers(image: image, ambientImage: ambientImage)
        case .ambientFeathered:
            featheredAmbientArtworkLayers(image: image, ambientImage: ambientImage)
        case .stage:
            stageArtworkLayers(image: image, ambientImage: ambientImage)
        case .classic:
            legacyArtworkLayers(image: image)
        case .lyricsOnly:
            quietArtworkColors
        case .albumPoster:
            quietArtworkColors
            GeometryReader { canvas in
                Image(nsImage: ambientImage ?? image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: canvas.size.width, height: canvas.size.height)
                    .blur(radius: 18 + normalizedBlur * 46)
                    .saturation(0.65)
                    .opacity(reduceTransparency ? 0.08 : 0.20)
            }
            .clipped()
            ambientReadingVeil
        }
    }

    private var quietArtworkColors: some View {
        ZStack {
            Color(red: 0.055, green: 0.060, blue: 0.075)
            LinearGradient(
                colors: [
                    ambientColor(palette.primary, saturation: 0.48, maximumLuminance: 0.25),
                    ambientColor(palette.secondary, saturation: 0.32, maximumLuminance: 0.16),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(reduceTransparency ? 0.36 : 0.64 - normalizedBlur * 0.20)
            RadialGradient(
                colors: [ambientColor(palette.glow, saturation: 0.40, maximumLuminance: 0.34).opacity(0.16), .clear],
                center: coverLightCenter,
                startRadius: 20,
                endRadius: 380 + normalizedBlur * 360
            )
        }
    }

    @ViewBuilder
    private func stageArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        GeometryReader { geometry in
            let aspect = image.size.width > 0 && image.size.height > 0
                ? image.size.width / image.size.height : 1.0
            let artworkRect = stageArtworkPlaneSize(canvas: geometry.size, artworkAspectRatio: aspect)
            ZStack {
                if artworkRect.minX > 0.5 {
                    stageEdgeExtension(image: image, horizontal: true, leading: true)
                        .frame(width: artworkRect.minX, height: artworkRect.height)
                        .position(x: artworkRect.minX / 2, y: artworkRect.midY)
                    stageEdgeExtension(image: image, horizontal: true, leading: false)
                        .frame(width: artworkRect.minX, height: artworkRect.height)
                        .position(x: artworkRect.maxX + artworkRect.minX / 2, y: artworkRect.midY)
                }
                if artworkRect.minY > 0.5 {
                    stageEdgeExtension(image: image, horizontal: false, leading: true)
                        .frame(width: artworkRect.width, height: artworkRect.minY)
                        .position(x: artworkRect.midX, y: artworkRect.minY / 2)
                    stageEdgeExtension(image: image, horizontal: false, leading: false)
                        .frame(width: artworkRect.width, height: artworkRect.minY)
                        .position(x: artworkRect.midX, y: artworkRect.maxY + artworkRect.minY / 2)
                }
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: artworkRect.width, height: artworkRect.height)
                    .position(x: artworkRect.midX, y: artworkRect.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        // Full original cover over a diffuse extension; lyric layout is unchanged.
        Color.black.opacity(settings.v3StageReadabilityEnabled ? 0.56 : (increaseContrast ? 0.40 : 0.24))
        LinearGradient(colors: [.black.opacity(0.08), .clear, .black.opacity(0.30)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Matching reflected edge pixels join the original without a separate tonal band.
    /// Only the extension stretches; blur rises towards the outside of the window.
    private func stageEdgeExtension(image: NSImage, horizontal: Bool, leading: Bool) -> some View {
        let outer: UnitPoint = horizontal ? (leading ? .leading : .trailing) : (leading ? .top : .bottom)
        let inner: UnitPoint = horizontal ? (leading ? .trailing : .leading) : (leading ? .bottom : .top)
        return GeometryReader { geometry in
            let reflected = Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
            ZStack {
                reflected
                reflected
                    .blur(radius: 18 + normalizedBlur * 42)
                    .mask(LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.55),
                        .init(color: .clear, location: 1)
                    ], startPoint: outer, endPoint: inner))
            }
            .clipped()
        }
    }

    /// Stage presentation sizing helper for geometry contracts.
    private func stageArtworkPlaneSize(
        canvas: CGSize,
        artworkAspectRatio: CGFloat
    ) -> CGRect {
        V3ResponsiveGeometry.stageArtworkRect(
            canvasSize: canvas,
            artworkAspectRatio: artworkAspectRatio,
            requestedScale: artworkSizeScale,
            position: artworkPosition
        )
    }

    // The original ambient artwork composition, recovered from the
    // pre-2026-10-11 source (4886985). The fourth mode keeps the newer
    // radial feathering implementation independently.
    @ViewBuilder
    private func ambientArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        let style = presentationStyle
        let saturation = min(
            1.3,
            style.paletteSaturation * 1.18 + (increaseContrast ? 0.06 : 0)
        )
        let diffusionRadius = normalizedBlur * 48.0

        // A luminance-clamped album field keeps very bright artwork legible
        // without falling back to an unrelated black canvas.
        LinearGradient(
            colors: [
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.42),
                ambientColor(palette.secondary, saturation: saturation * 0.90, maximumLuminance: 0.30),
                Color(red: 0.055, green: 0.060, blue: 0.072)
            ],
            startPoint: coverLightCenter,
            endPoint: artworkPosition == "right" ? .topLeading : .bottomTrailing
        )

        // Retain album structure before applying the user-controlled diffusion.
        // Keep image visibility independent of diffusion, including at 0%.
        // The full-resolution snapshot avoids baked-in blur at the clear endpoint.
        Group {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .scaleEffect(1.12)
                .blur(radius: diffusionRadius, opaque: true)
                .saturation(saturation)
                .opacity(0.56)
        }

        RadialGradient(
            colors: [
                ambientColor(palette.glow, saturation: saturation, maximumLuminance: 0.58)
                    .opacity(0.34),
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.40)
                    .opacity(0.12),
                .clear
            ],
            center: coverLightCenter,
            startRadius: 18,
            endRadius: 680 + normalizedBlur * 220
        )
        .blendMode(.screen)

        ambientReadingVeil

        RadialGradient(
            colors: [
                .clear,
                Color.black.opacity(min(0.36, style.vignetteIntensity * 0.72))
            ],
            center: coverLightCenter,
            startRadius: 180,
            endRadius: 980
        )

        if let noiseImage {
            Image(nsImage: noiseImage)
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(min(0.055, style.noiseIntensity))
        }
    }

    @ViewBuilder
    private func featheredAmbientArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        let style = presentationStyle
        let saturation = min(
            1.3,
            style.paletteSaturation * 1.18 + (increaseContrast ? 0.06 : 0)
        )
        let diffusionRadius = normalizedBlur * 56.0

        // A luminance-clamped album field keeps very bright artwork legible
        // without falling back to an unrelated black canvas.
        LinearGradient(
            colors: [
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.46),
                ambientColor(palette.secondary, saturation: saturation * 0.90, maximumLuminance: 0.34),
                Color(red: 0.085, green: 0.090, blue: 0.110)
            ],
            startPoint: coverLightCenter,
            endPoint: artworkPosition == "right" ? .topLeading : .bottomTrailing
        )

        // Show the complete cover as a softly feathered source of ambient
        // light.  No scaled-to-fill crop or hard square image boundary:
        // 0% retains its detail, while 100% becomes an album-colored wash.
        GeometryReader { canvas in
            let side = min(canvas.size.height * 1.02, canvas.size.width * 0.86)
            let imageX: CGFloat = artworkPosition == "right" ? 0.56
                : (artworkPosition == "center" ? 0.50 : 0.44)

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: side, height: side)
                .blur(radius: diffusionRadius)
                .saturation(saturation)
                .opacity(palette.luminance > 0.58 ? 0.66 : 0.82)
                .mask(
                    RadialGradient(
                        stops: [
                            .init(color: .white, location: 0.00),
                            .init(color: .white, location: 0.30),
                            .init(color: .white.opacity(0.80), location: 0.52),
                            .init(color: .clear, location: 1.00)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: side * 0.52
                    )
                )
                .position(x: canvas.size.width * imageX, y: canvas.size.height * 0.50)
        }
        .clipped()

        RadialGradient(
            colors: [
                ambientColor(palette.glow, saturation: saturation, maximumLuminance: 0.52)
                    .opacity(0.28),
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.40)
                    .opacity(0.13),
                .clear
            ],
            center: coverLightCenter,
            startRadius: 18,
            endRadius: 680 + normalizedBlur * 220
        )
        .blendMode(.screen)

        ambientReadingVeil

        RadialGradient(
            colors: [
                .clear,
                Color.black.opacity(min(0.20, style.vignetteIntensity * 0.46))
            ],
            center: coverLightCenter,
            startRadius: 180,
            endRadius: 980
        )

        if let noiseImage {
            Image(nsImage: noiseImage)
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(min(0.055, style.noiseIntensity))
        }
    }

    @ViewBuilder
    private var ambientReadingVeil: some View {
        let feathered = artworkPresentation == .ambientFeathered
        if artworkPosition == "right" {
            LinearGradient(
                colors: [Color.black.opacity(feathered ? 0.30 : 0.42),
                         Color.black.opacity(feathered ? 0.12 : 0.18), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if artworkPosition == "center" {
            RadialGradient(
                colors: [.clear, Color.black.opacity(feathered ? 0.18 : 0.34)],
                center: .center,
                startRadius: 160,
                endRadius: 920
            )
        } else {
            LinearGradient(
                colors: [.clear, Color.black.opacity(feathered ? 0.10 : 0.16),
                         Color.black.opacity(feathered ? 0.31 : 0.46)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    @ViewBuilder
    private func legacyArtworkLayers(image: NSImage) -> some View {
        let style = presentationStyle
        let saturation = min(
            1.4,
            style.paletteSaturation * 1.35 + (increaseContrast ? 0.08 : 0)
        )

        // complete artwork plane scaledToFit()
        // Layer 0: Static Album Ambient Base (Dark-neutral album color transition, 100% independent of Blur slider)
        LinearGradient(
            colors: [
                color(palette.primary, saturation: saturation * 0.35).opacity(0.80),
                color(palette.secondary, saturation: saturation * 0.25).opacity(0.60)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Layer 1: Restrained Cover Ambient Light Source (Dynamic anchor emitting from physical album cover)
        ZStack {
            color(palette.primary, saturation: saturation)
                .opacity(0.85)

            RadialGradient(
                colors: [
                    color(palette.primary, saturation: saturation * 1.15).opacity(0.14),
                    .clear
                ],
                center: coverLightCenter,
                startRadius: 40,
                endRadius: 900
            )

            RadialGradient(
                colors: [
                    color(palette.glow, saturation: saturation * 1.10).opacity(0.08),
                    .clear
                ],
                center: coverLightCenter,
                startRadius: 20,
                endRadius: 750
            )
        }
        .opacity(0.35 + 0.65 * normalizedBlur)

        // Layer 2: Main scaled cover substrate. Unlike the old implementation,
        // both the full 80–140% range and crop position now affect this image.
        GeometryReader { geometry in
            let scale = min(1.4, max(0.8, artworkSizeScale))
            let mainSubstrateImage = Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(style.artworkScale * scale)
                .offset(x: classicArtworkOffset(for: geometry.size.width))
                .blur(radius: effectiveBlurRadius)
                .opacity(min(1, style.artworkOpacity * style.textureIntensity))

            if artworkPosition == "left" {
                mainSubstrateImage
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.00),
                                .init(color: .black, location: 0.28),
                                .init(color: .black.opacity(0.85), location: 0.45),
                                .init(color: .black.opacity(0.40), location: 0.62),
                                .init(color: .black.opacity(0.12), location: 0.78),
                                .init(color: .clear, location: 0.92)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            } else {
                mainSubstrateImage
            }
        }

        // Layer 3: Specular Screen Light Bloom Pass (Only active when blur > 0 to avoid obscuring 0% clear artwork)
        if effectiveScreenBlurRadius > 0 {
            GeometryReader { geometry in
                let scale = min(1.4, max(0.8, artworkSizeScale))

                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(style.artworkScreenScale * scale)
                    .offset(x: classicArtworkOffset(for: geometry.size.width))
                    .blur(radius: effectiveScreenBlurRadius)
                    .blendMode(.screen)
                    .opacity(0.35 * style.textureIntensity * normalizedBlur)
            }
        }

        // Layer 4: Overlay blend color gradient for vivid color saturation
        LinearGradient(
            colors: [
                color(palette.primary, saturation: saturation)
                    .opacity(min(1, 0.28 * style.paletteOpacity)),
                color(palette.secondary, saturation: saturation)
                    .opacity(min(1, 0.22 * style.paletteOpacity)),
                color(palette.glow, saturation: saturation)
                    .opacity(min(1, 0.18 * style.paletteOpacity))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .blendMode(.overlay)

        // Layer 5: Soft Continuous Spatial Light Falloff towards lyrics reading area
        let lightDecayOpacity = min(0.18, max(0.05, palette.luminance * 0.15))
        LinearGradient(
            colors: [
                .clear,
                Color.black.opacity(lightDecayOpacity * 0.40),
                Color.black.opacity(lightDecayOpacity)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        // Layer 6: Edge Vignette Darkening
        RadialGradient(
            colors: [
                .clear,
                Color.black.opacity(min(0.35, style.vignetteIntensity * 0.65))
            ],
            center: .center,
            startRadius: 160,
            endRadius: 950
        )

        // Procedural Grain Noise Overlay (防断层极轻微感)
        if let noiseImage {
            Image(nsImage: noiseImage)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(style.noiseIntensity * 0.8)
        }
    }

    private func classicArtworkOffset(for width: CGFloat) -> CGFloat {
        switch artworkPosition {
        case "right": return width * 0.10
        case "center": return 0
        default: return width * -0.10
        }
    }

    @MainActor
    private func loadSnapshot(for key: String) async {
        outgoingArtworkImage = artworkImage
        outgoingAmbientArtworkImage = ambientArtworkImage
        artworkImage = nil
        ambientArtworkImage = nil
        noiseImage = nil
        // A track without artwork must not inherit the previous track's
        // palette while its new snapshot is being resolved.
        palette = .neutral

        if debugForceNoArtwork {
            outgoingArtworkImage = nil
            return
        }

        guard let artworkURL = track.artworkURL,
              let image = await ArtworkImageLoader.shared.image(for: artworkURL),
              let imageData = image.tiffRepresentation,
              !Task.isCancelled else {
            outgoingArtworkImage = nil
            return
        }

        let snapshot = await AppleMusicImmersiveV3BackdropCache.shared.snapshot(
            for: key,
            artworkData: imageData
        )
        guard key == requestKey, !Task.isCancelled else { return }

        let nextArtwork = NSImage(data: snapshot.artworkData)
        let nextAmbientArtwork = NSImage(data: snapshot.ambientArtworkData)
        let nextNoise = NSImage(data: snapshot.noiseData)
        withAnimation(.easeInOut(duration: artworkTransitionDuration)) {
            palette = snapshot.palette
            artworkImage = nextArtwork
            ambientArtworkImage = nextAmbientArtwork
            noiseImage = nextNoise
        }

        try? await Task.sleep(
            nanoseconds: UInt64(outgoingTransitionDuration * 1_000_000_000)
        )
        guard key == requestKey, !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: outgoingTransitionDuration)) {
            outgoingArtworkImage = nil
            outgoingAmbientArtworkImage = nil
        }
    }

    private func color(_ value: BackdropColor, saturation: Double = 1) -> Color {
        let luminance = (value.red * 0.2126)
            + (value.green * 0.7152)
            + (value.blue * 0.0722)
        let amount = min(1, max(0, saturation))
        return Color(
            red: luminance + (value.red - luminance) * amount,
            green: luminance + (value.green - luminance) * amount,
            blue: luminance + (value.blue - luminance) * amount
        )
    }

    private func ambientColor(
        _ value: BackdropColor,
        saturation: Double,
        maximumLuminance: Double
    ) -> Color {
        // Near-monochrome and white artwork otherwise collapses into flat
        // cement gray. Blend only a restrained midnight-blue anchor into
        // those palettes; colorful covers remain entirely album-derived.
        let lowChromaAnchorAmount = min(
            0.30,
            max(0, (0.16 - palette.saturation) / 0.16) * 0.30
        )
        let anchor = BackdropColor(red: 0.08, green: 0.12, blue: 0.18)
        let anchored = BackdropColor(
            red: value.red + (anchor.red - value.red) * lowChromaAnchorAmount,
            green: value.green + (anchor.green - value.green) * lowChromaAnchorAmount,
            blue: value.blue + (anchor.blue - value.blue) * lowChromaAnchorAmount
        )
        let sourceLuminance = max(
            0.001,
            (anchored.red * 0.2126) + (anchored.green * 0.7152) + (anchored.blue * 0.0722)
        )
        let scale = min(1, maximumLuminance / sourceLuminance)
        let red = anchored.red * scale
        let green = anchored.green * scale
        let blue = anchored.blue * scale
        let clampedLuminance = (red * 0.2126) + (green * 0.7152) + (blue * 0.0722)
        let amount = min(1, max(0, saturation))
        return Color(
            red: clampedLuminance + (red - clampedLuminance) * amount,
            green: clampedLuminance + (green - clampedLuminance) * amount,
            blue: clampedLuminance + (blue - clampedLuminance) * amount
        )
    }
}

public struct AppleMusicImmersiveV3BackdropSnapshot: Sendable {
    public let artworkData: Data
    public let ambientArtworkData: Data
    public let noiseData: Data
    public let palette: BackdropPalette

    /// The snapshot keeps the sampled values together so V3 and fullscreen
    /// consume the same immutable, track-bound evidence rather than deriving
    /// their own background state.
    public var luminance: Double { palette.luminance }
    public var saturation: Double { palette.saturation }
    public var readabilityVeilOpacity: Double { palette.readabilityVeilOpacity }

    public init(
        artworkData: Data,
        ambientArtworkData: Data,
        noiseData: Data,
        palette: BackdropPalette
    ) {
        self.artworkData = artworkData
        self.ambientArtworkData = ambientArtworkData
        self.noiseData = noiseData
        self.palette = palette
    }
}

/// Cached low-resolution artwork and optional procedural texture for V3.
/// The key includes TrackIdentity so a reused cover URL on another track does
/// not accidentally keep stale color treatment.
public actor AppleMusicImmersiveV3BackdropCache {
    public static let shared = AppleMusicImmersiveV3BackdropCache()

    private var values: [String: AppleMusicImmersiveV3BackdropSnapshot] = [:]
    private var inFlight: [String: Task<AppleMusicImmersiveV3BackdropSnapshot, Never>] = [:]
    private var order: [String] = []
    private let capacity = 48

    public init() {}

    public func snapshot(
        for key: String,
        artworkData: Data
    ) async -> AppleMusicImmersiveV3BackdropSnapshot {
        if let cached = values[key] {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            Self.makeSnapshot(artworkData: artworkData, seed: Self.seed(for: key))
        }
        inFlight[key] = task

        let snapshot = await task.value
        inFlight[key] = nil
        values[key] = snapshot
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > capacity, let evicted = order.first {
            order.removeFirst()
            values[evicted] = nil
        }
        return snapshot
    }

    private nonisolated static func makeSnapshot(
        artworkData: Data,
        seed: UInt64
    ) -> AppleMusicImmersiveV3BackdropSnapshot {
        // The visible artwork is also used by the zero-blur ambient and
        // stage presentations. 640px makes a large window look soft even
        // when the user explicitly selects 0%; keep the derivative small,
        // but retain enough resolution for the actual artwork plane.
        let reducedArtwork = thumbnailData(from: artworkData, maxPixel: 1280)
        let ambientArtwork = thumbnailData(from: artworkData, maxPixel: 384)
        let palette = BackdropPalette.from(imageData: reducedArtwork)
        let noise = makeNoiseData(seed: seed)
        return AppleMusicImmersiveV3BackdropSnapshot(
            artworkData: reducedArtwork,
            ambientArtworkData: ambientArtwork,
            noiseData: noise,
            palette: palette
        )
    }

    private nonisolated static func thumbnailData(from data: Data, maxPixel: Int) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return data
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), let encoded = encode(thumbnail, as: .jpeg) else {
            return data
        }
        return encoded
    }

    private nonisolated static func makeNoiseData(seed: UInt64) -> Data {
        let size = 96
        var value = seed
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let gray = UInt8(112 + ((value >> 56) & 31))
            bytes[index] = gray
            bytes[index + 1] = gray
            bytes[index + 2] = gray
            bytes[index + 3] = 26
        }

        let rawData = Data(bytes)
        guard let provider = CGDataProvider(data: rawData as CFData),
              let image = CGImage(
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: size * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let encoded = encode(image, as: .png) else {
            return Data()
        }
        return encoded
    }

    private nonisolated static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let output = CFDataCreateMutable(nil, 0)
        guard let output,
              let destination = CGImageDestinationCreateWithData(
                  output,
                  type.identifier as CFString,
                  1,
                  nil
              ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private nonisolated static func seed(for key: String) -> UInt64 {
        key.utf8.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
