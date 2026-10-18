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

/// Bounded, centered image geometry: resizing a background never changes canvas layout.
enum V3BackdropArtworkGeometry {
    static func rect(canvas: CGSize, artwork: CGSize, scale: Double, complete: Bool) -> CGRect {
        let aspect = max(0.01, artwork.width / max(1, artwork.height))
        let fitHeight = min(canvas.height, canvas.width / aspect)
        let fillHeight = max(canvas.height, canvas.width / aspect)
        let height = (complete ? min(fillHeight, fitHeight * 1.15) : fillHeight) * scale
        let width = height * aspect
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
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
    private var artworkSizeScale: Double { settings.v3PreviewBackdropScale(for: artworkPresentation) }
    private var showsCompleteArtwork: Bool { settings.v3BackgroundShowsCompleteArtwork(for: artworkPresentation) }

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

        if reduceTransparency {
            return min(0.85, max(0.55, paletteVeil + 0.18))
        }

        if increaseContrast {
            return min(0.75, paletteVeil + 0.14)
        }

        switch artworkPresentation {
        case .authenticAmbient:
            return min(0.42, paletteVeil)
        case .ambientFeathered:
            return min(0.10, paletteVeil * 0.26)
        case .ambient:
            return min(0.16, paletteVeil * 0.44)
        case .classic:
            return min(0.24, paletteVeil * 0.62)
        case .classicGaussian:
            return min(0.18, paletteVeil * 0.48)
        case .stage:
            return 0
        default:
            return min(0.42, paletteVeil)
        }
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

    /// Non-linear perceptual blur response (power curve ~1.35) gives finer precision
    /// in the lower range (retaining artwork sharpness/legibility) while ensuring distinct,
    /// noticeable visual progression between 60%, 80%, and 100%.
    private var perceptualBlur: Double {
        pow(normalizedBlur, 1.35)
    }

    private var effectiveBlurRadius: Double {
        if settings.v3InstrumentalPureImmersion && isInstrumental {
            return perceptualBlur * 4.0
        }
        // Crisp non-linear mapping (0% = 0.0pt, 25% = 5.9pt, 60% = 19.1pt, 80% = 28.1pt, 100% = 38.0pt)
        // For pure Gaussian mode, provide a smooth, creamy blur up to 54pt.
        let maxBlur = artworkPresentation == .classicGaussian ? 54.0 : 38.0
        return perceptualBlur * maxBlur
    }

    private var effectiveScreenBlurRadius: Double {
        if settings.v3InstrumentalPureImmersion && isInstrumental {
            return perceptualBlur * 1.2
        }
        return perceptualBlur * 16.0
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
        case .authenticAmbient:
            authenticAmbientArtworkLayers(image: image, ambientImage: ambientImage)
        case .ambient:
            ambientArtworkLayers(image: image, ambientImage: ambientImage)
        case .ambientFeathered:
            featheredAmbientArtworkLayers(image: image, ambientImage: ambientImage)
        case .stage:
            stageArtworkLayers(image: image, ambientImage: ambientImage)
        case .classic:
            legacyArtworkLayers(image: image)
        case .classicGaussian:
            gaussianArtworkLayers(image: image)
        case .lyricsOnly:
            quietArtworkColors
        case .albumPoster:
            quietArtworkColors
            framedArtwork(image: ambientImage ?? image, scale: artworkSizeScale,
                          blur: 18 + perceptualBlur * 46)
                .saturation(0.65)
                .opacity(reduceTransparency ? 0.08 : 0.20)
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
            .opacity(reduceTransparency ? 0.36 : 0.64 - perceptualBlur * 0.20)
            RadialGradient(
                colors: [ambientColor(palette.glow, saturation: 0.40, maximumLuminance: 0.34).opacity(0.16), .clear],
                center: coverLightCenter,
                startRadius: 20,
                endRadius: (380 + perceptualBlur * 360) * artworkSizeScale
            )
        }
    }

    @ViewBuilder
    private func stageArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        if !showsCompleteArtwork {
            framedArtwork(image: image, scale: artworkSizeScale, blur: 0)
        } else {
            GeometryReader { geometry in
                let aspect = image.size.width > 0 && image.size.height > 0
                    ? image.size.width / image.size.height : 1.0
                let artworkRect = stageArtworkPlaneSize(canvas: geometry.size, artworkAspectRatio: aspect)
                ZStack {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().blur(radius: 18 + perceptualBlur * 42)
                        .opacity(0.3)

                    if artworkRect.minX > 0.5 {
                        stageEdgeExtension(image: image, horizontal: true, leading: true)
                            .frame(width: artworkRect.minX, height: artworkRect.height)
                            .position(x: artworkRect.minX / 2, y: artworkRect.midY)
                    }
                    if geometry.size.width - artworkRect.maxX > 0.5 {
                        let remaining = geometry.size.width - artworkRect.maxX
                        stageEdgeExtension(image: image, horizontal: true, leading: false)
                            .frame(width: remaining, height: artworkRect.height)
                            .position(x: artworkRect.maxX + remaining / 2, y: artworkRect.midY)
                    }
                    if artworkRect.minY > 0.5 {
                        stageEdgeExtension(image: image, horizontal: false, leading: true)
                            .frame(width: artworkRect.width, height: artworkRect.minY)
                            .position(x: artworkRect.midX, y: artworkRect.minY / 2)
                    }
                    if geometry.size.height - artworkRect.maxY > 0.5 {
                        let remaining = geometry.size.height - artworkRect.maxY
                        stageEdgeExtension(image: image, horizontal: false, leading: false)
                            .frame(width: artworkRect.width, height: remaining)
                            .position(x: artworkRect.midX, y: artworkRect.maxY + remaining / 2)
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
        }
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
                    .blur(radius: 18 + perceptualBlur * 42)
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

    // Faithful reproduction of Release v0.1.2 ambientArtworkLayers (blob 5f6d828636ca7fb36381219b96ced4c2bd01739a)
    @ViewBuilder
    private func authenticAmbientArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
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
        framedArtwork(image: image, scale: 1.12 * artworkSizeScale, blur: diffusionRadius)
            .saturation(saturation)
            .opacity(0.56)

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

    // The original ambient artwork composition, recovered from the
    // pre-2026-10-11 source (4886985). The fourth mode keeps the newer
    // radial feathering implementation independently.
    @ViewBuilder
    private func ambientArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        let style = presentationStyle
        let saturation = min(
            1.35,
            style.paletteSaturation * 1.22 + (increaseContrast ? 0.08 : 0)
        )
        let diffusionRadius = perceptualBlur * 58.0

        // A rich album color field derived from dominant cover colors
        LinearGradient(
            colors: [
                ambientColor(palette.primary, saturation: saturation * 1.05, maximumLuminance: 0.52),
                ambientColor(palette.secondary, saturation: saturation * 0.95, maximumLuminance: 0.40),
                ambientColor(palette.glow, saturation: saturation * 0.70, maximumLuminance: 0.22)
            ],
            startPoint: coverLightCenter,
            endPoint: artworkPosition == "right" ? .topLeading : .bottomTrailing
        )

        // Retain album structure before applying the user-controlled diffusion.
        // Full opacity and vivid colors prevent grayish/muddy appearance.
        framedArtwork(image: image, scale: showsCompleteArtwork ? artworkSizeScale : 1.12 * artworkSizeScale,
                      blur: diffusionRadius)
            .saturation(saturation)
            .opacity(0.85)

        RadialGradient(
            colors: [
                ambientColor(palette.glow, saturation: saturation, maximumLuminance: 0.62)
                    .opacity(0.32),
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.44)
                    .opacity(0.14),
                .clear
            ],
            center: coverLightCenter,
            startRadius: 20,
            endRadius: 750 + perceptualBlur * 240
        )
        .blendMode(.screen)

        ambientReadingVeil

        RadialGradient(
            colors: [
                .clear,
                Color.black.opacity(min(0.20, style.vignetteIntensity * 0.40))
            ],
            center: coverLightCenter,
            startRadius: 220,
            endRadius: 1050
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
        let diffusionRadius = perceptualBlur * 64.0
        let washBlur = diffusionRadius * 1.30
        let washOpacity = 0.38 * min(1.0, 0.35 + perceptualBlur * 1.6)

        LinearGradient(
            colors: [
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.50),
                ambientColor(palette.secondary, saturation: saturation * 0.95, maximumLuminance: 0.38),
                ambientColor(palette.glow, saturation: saturation * 0.70, maximumLuminance: 0.22)
            ],
            startPoint: coverLightCenter,
            endPoint: artworkPosition == "right" ? .topLeading : .bottomTrailing
        )

        // Ambient continuation: wide-spread soft wash that fills the window
        // canvas so wide screens never have an empty, dark void on the right.
        GeometryReader { canvas in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: canvas.size.width, height: canvas.size.height)
                .clipped()
                .blur(radius: washBlur)
                .saturation(saturation * 0.9)
                .opacity(washOpacity)
        }

        // Show the complete cover as a softly feathered source of ambient light.
        GeometryReader { canvas in
            let side = min(canvas.size.height * 1.02, canvas.size.width * 0.86) * artworkSizeScale
            let sourceWidth = showsCompleteArtwork ? side : canvas.size.width * artworkSizeScale
            let sourceHeight = showsCompleteArtwork ? side : canvas.size.height * artworkSizeScale
            let imageX: CGFloat = artworkPosition == "right" ? 0.56
                : (artworkPosition == "center" ? 0.50 : 0.44)

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: showsCompleteArtwork ? .fit : .fill)
                .frame(width: sourceWidth, height: sourceHeight)
                .clipped()
                .blur(radius: diffusionRadius)
                .saturation(saturation)
                .opacity(palette.luminance > 0.58 ? 0.72 : 0.86)
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
                ambientColor(palette.glow, saturation: saturation, maximumLuminance: 0.58)
                    .opacity(0.36),
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.44)
                    .opacity(0.18),
                .clear
            ],
            center: coverLightCenter,
            startRadius: 20,
            endRadius: 850 + perceptualBlur * 280
        )
        .blendMode(.screen)

        ambientReadingVeil

        RadialGradient(
            colors: [
                .clear,
                Color.black.opacity(min(0.16, style.vignetteIntensity * 0.35))
            ],
            center: coverLightCenter,
            startRadius: 220,
            endRadius: 1050
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

    /// Independent enlarged-cover option. The existing light-bloom renderer
    /// is retained above as an ambient variant rather than renamed Gaussian.
    private func gaussianArtworkLayers(image: NSImage) -> some View {
        GeometryReader { geometry in
            let scale = 1 + (min(1.4, max(0.8, artworkSizeScale)) - 0.8) * 0.6
            framedArtwork(image: image, scale: showsCompleteArtwork ? artworkSizeScale : scale * 1.04,
                          blur: effectiveBlurRadius,
                          horizontalOffset: showsCompleteArtwork ? 0 : classicArtworkOffset(for: geometry.size.width))

        }
        .clipped()
    }

    @ViewBuilder
    private func legacyArtworkLayers(image: NSImage) -> some View {
        let style = presentationStyle
        let saturation = min(
            1.4,
            style.paletteSaturation * 1.35 + (increaseContrast ? 0.08 : 0)
        )

        // complete artwork plane scaledToFit()
        // Layer 0: Static Album Ambient Base with vibrant album color foundation
        LinearGradient(
            colors: [
                color(palette.primary, saturation: saturation * 0.75).opacity(0.85),
                color(palette.secondary, saturation: saturation * 0.60).opacity(0.70),
                color(palette.glow, saturation: saturation * 0.50).opacity(0.40)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Layer 1: Restrained Cover Ambient Light Source emitting naturally from cover center
        ZStack {
            color(palette.primary, saturation: saturation)
                .opacity(0.85)

            RadialGradient(
                colors: [
                    color(palette.primary, saturation: saturation * 1.25).opacity(0.26),
                    .clear
                ],
                center: coverLightCenter,
                startRadius: 40,
                endRadius: 1100
            )

            RadialGradient(
                colors: [
                    color(palette.glow, saturation: saturation * 1.20).opacity(0.18),
                    .clear
                ],
                center: coverLightCenter,
                startRadius: 20,
                endRadius: 900
            )
        }
        .opacity(0.45 + 0.55 * perceptualBlur)

        // Layer 2: Main scaled cover substrate with smooth continuous background extension.
        // Both the full 80–140% range and crop position now affect this image.
        GeometryReader { geometry in
            let scale = min(1.4, max(0.8, artworkSizeScale))
            let effectiveScale = style.artworkScale * scale
            let offset = classicArtworkOffset(for: geometry.size.width, scale: scale, effectiveScale: effectiveScale)

            framedArtwork(image: image, scale: showsCompleteArtwork ? scale : effectiveScale,
                          blur: effectiveBlurRadius, horizontalOffset: showsCompleteArtwork ? 0 : offset)
                .opacity(min(1, style.artworkOpacity * style.textureIntensity))
        }

        // Layer 3: Specular Screen Light Bloom Pass (Only active when blur > 0 to avoid obscuring 0% clear artwork)
        if effectiveScreenBlurRadius > 0 {
            GeometryReader { geometry in
                let scale = min(1.4, max(0.8, artworkSizeScale))
                let effectiveScale = style.artworkScale * scale
                let offset = classicArtworkOffset(for: geometry.size.width, scale: scale, effectiveScale: effectiveScale)

                framedArtwork(image: image, scale: showsCompleteArtwork ? scale : effectiveScale,
                              blur: effectiveScreenBlurRadius, horizontalOffset: showsCompleteArtwork ? 0 : offset,
                              fillsEdges: false)
                    .blendMode(.screen)
                    .opacity(0.40 * style.textureIntensity * perceptualBlur)
            }
        }

        // Layer 4: Overlay blend color gradient for vivid color saturation
        LinearGradient(
            colors: [
                color(palette.primary, saturation: saturation)
                    .opacity(min(1, 0.34 * style.paletteOpacity)),
                color(palette.secondary, saturation: saturation)
                    .opacity(min(1, 0.26 * style.paletteOpacity)),
                color(palette.glow, saturation: saturation)
                    .opacity(min(1, 0.22 * style.paletteOpacity))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .blendMode(.overlay)

        // Layer 5: Soft Continuous Spatial Light Falloff towards lyrics reading area
        let lightDecayOpacity = min(0.22, max(0.06, palette.luminance * 0.18))
        let veilStart: UnitPoint = artworkPosition == "right" ? .trailing : .leading
        let veilEnd: UnitPoint = artworkPosition == "right" ? .leading : .trailing
        if artworkPosition != "center" {
            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(lightDecayOpacity * 0.40),
                    Color.black.opacity(lightDecayOpacity)
                ],
                startPoint: veilStart,
                endPoint: veilEnd
            )
        }

        // Layer 6: Edge Vignette Darkening (restrained to avoid harsh dark borders)
        RadialGradient(
            colors: [
                .clear,
                Color.black.opacity(min(0.24, style.vignetteIntensity * 0.45))
            ],
            center: .center,
            startRadius: 180,
            endRadius: 1050
        )

        // Procedural Grain Noise Overlay (防断层极轻微感)
        if let noiseImage {
            Image(nsImage: noiseImage)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(style.noiseIntensity * 0.8)
        }
    }

    private func framedArtwork(image: NSImage, scale: Double, blur: Double,
                               horizontalOffset: CGFloat = 0, fillsEdges: Bool = true) -> some View {
        GeometryReader { canvas in
            let rect = V3BackdropArtworkGeometry.rect(canvas: canvas.size, artwork: image.size,
                                                      scale: scale, complete: showsCompleteArtwork)
            let featherEdges = showsCompleteArtwork || scale < 1
            let overscan = max(0, (rect.width - canvas.size.width) / 2)
            let offset = min(overscan, max(-overscan, horizontalOffset))
            ZStack {
                if fillsEdges && featherEdges {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: canvas.size.width, height: canvas.size.height)
                        .clipped()
                        .blur(radius: blur * 1.25)
                        .opacity(showsCompleteArtwork ? 0.70 * min(1, 0.35 + perceptualBlur * 0.65) : 0.70)
                }
                Image(nsImage: image)
                    .resizable().interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .blur(radius: blur)
                    .mask {
                        if featherEdges {
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                .init(color: .white, location: 0.05), .init(color: .white, location: 0.95),
                                .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.04), .init(color: .white, location: 0.96),
                                    .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        } else { Color.white }
                    }
                    .position(x: canvas.size.width / 2 + offset, y: canvas.size.height / 2)
            }
            .frame(width: canvas.size.width, height: canvas.size.height)
            .clipped()
        }
    }

    private func classicArtworkOffset(for width: CGFloat) -> CGFloat {
        let scale = min(1.4, max(0.8, artworkSizeScale))
        let effectiveScale = presentationStyle.artworkScale * scale
        return classicArtworkOffset(for: width, scale: scale, effectiveScale: effectiveScale)
    }

    private func classicArtworkOffset(for width: CGFloat, scale: CGFloat, effectiveScale: CGFloat) -> CGFloat {
        guard scale > 0.8 else { return 0 }
        let progress = (scale - 0.8) / (1.4 - 0.8)
        let targetRatio: CGFloat
        switch artworkPosition {
        case "right": targetRatio = 0.10
        case "center": targetRatio = 0
        default: targetRatio = -0.10
        }
        let requestedOffset = targetRatio * width * progress
        let availableOverscan = max(0, (effectiveScale - 1.0) * width * 0.5)
        return min(availableOverscan, max(-availableOverscan, requestedOffset))
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
        // Baseline low-frequency derivative: thumbnailData(from: artworkData, maxPixel: 48)
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
