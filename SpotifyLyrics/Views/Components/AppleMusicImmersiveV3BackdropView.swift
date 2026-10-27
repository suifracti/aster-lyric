import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Artwork color sampling is shared across listening surfaces by artwork URL.
enum AppleMusicImmersiveV3BackdropKey {
    static func make(artworkURL: URL?) -> String {
        "artwork|\(artworkURL?.absoluteString ?? "none")"
    }
}

/// Bounded, centered image geometry: resizing a background never changes canvas layout.
enum V3BackdropArtworkGeometry {
    /// Shared framing baseline; individual themes retain their own lighting passes.
    static func imageScale(requested: Double, complete: Bool) -> Double {
        let scale = requested.isFinite ? min(1.4, max(0.8, requested)) : 1
        return scale * (complete ? 1 : 1.12)
    }

    static func horizontalOffset(width: CGFloat, scale: CGFloat, effectiveScale: CGFloat, position: String) -> CGFloat {
        guard scale > 0.8 else { return 0 }
        let progress = (scale - 0.8) / (1.4 - 0.8)
        let targetRatio: CGFloat
        switch position {
        case "right": targetRatio = 0.10
        case "center": targetRatio = 0
        default: targetRatio = -0.10
        }
        let requestedOffset = targetRatio * width * progress
        let availableOverscan = max(0, (effectiveScale - 1.0) * width * 0.5)
        return min(availableOverscan, max(-availableOverscan, requestedOffset))
    }

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
/// Cover data is reduced and sampled once per artwork URL; the
/// SwiftUI view never rebuilds a full-resolution blur on every time tick.
struct AppleMusicImmersiveV3BackdropView: View {
    @Environment(\.v3NightGentle) private var nightGentle
    let track: Track
    let identity: TrackIdentity?
    var isInstrumental: Bool = false
    var isPlaying: Bool = true
    @ObservedObject var settings: AppSettingsStore
    var presentationOverride: V3ArtworkPresentation? = nil
    var sceneOverride: V3ListeningScene? = nil
    private var listeningScene: V3ListeningScene? { presentationOverride == nil ? settings.v3ListeningScene : sceneOverride }

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var artworkImage: NSImage?
    @State private var outgoingArtworkImage: NSImage?
    @State private var ambientArtworkImage: NSImage?
    @State private var outgoingAmbientArtworkImage: NSImage?
    @State private var noiseImage: NSImage?
    @State private var palette = BackdropPalette.neutral
    @State private var accessibilityDisplayRevision = 0
    @State private var isWindowVisible = false

    private var artworkPresentation: V3ArtworkPresentation { presentationOverride ?? settings.v3ArtworkPresentation }
    private var backdropBlurRadius: Double { settings.v3PreviewBlur(for: artworkPresentation, scene: listeningScene) }
    private var artworkPosition: String { settings.v3PreviewPosition(for: artworkPresentation, scene: listeningScene) }
    private var artworkSizeScale: Double { settings.v3PreviewBackdropScale(for: artworkPresentation, scene: listeningScene) }
    private var showsCompleteArtwork: Bool { settings.v3BackgroundShowsCompleteArtwork(for: artworkPresentation, scene: listeningScene) }
    private var backdropImageScale: Double {
        V3BackdropArtworkGeometry.imageScale(requested: artworkSizeScale, complete: showsCompleteArtwork)
    }

    var body: some View {
        ZStack {
            neutralBackground

            if listeningScene == .flowingField && artworkPresentation == .classic {
                // This scene is a color field, not another enlarged/blurred portrait.
                flowingArtworkColors
            } else if listeningScene == .focusedLyrics || listeningScene == .linerNotes {
                quietArtworkColors
                if listeningScene == .linerNotes {
                    LinearGradient(colors: [.white.opacity(0.045), .clear, .black.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            } else {
                if let outgoingArtworkImage {
                    artworkLayers(image: outgoingArtworkImage, ambientImage: outgoingAmbientArtworkImage)
                        .opacity(0.28).transition(.opacity)
                }
                if let artworkImage {
                    artworkLayers(image: artworkImage, ambientImage: ambientArtworkImage)
                        .transition(.opacity)
                }
                // Legacy exposure and the accepted original look stay unchanged.
                // The common *local* reading protection is applied by the text host.
                if artworkPresentation != .stage { Color.black.opacity(readabilityVeilOpacity) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background(alignment: .topLeading) {
            V3WindowVisibilityProbe(isVisible: $isWindowVisible)
                .frame(width: 0, height: 0)
        }
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
        return "\(paletteCacheKey)|\(identityKey)|\(debugForceNoArtwork ? "debug-no-artwork" : "artwork")"
    }

    private var paletteCacheKey: String {
        AppleMusicImmersiveV3BackdropKey.make(artworkURL: track.artworkURL)
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

    /// Existing renderer response retained for compatibility. Physical radius
    /// differences are not a guarantee of equal perceived changes near the upper end.
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
            classicArtworkLayers(image: image)
        case .classicGaussian:
            gaussianArtworkLayers(image: image)
        case .lyricsOnly:
            quietArtworkColors
            atmosphereField(for: .lyricsOnly)
        case .albumPoster:
            quietArtworkColors
            framedArtwork(image: ambientImage ?? image, scale: backdropImageScale,
                          blur: 18 + perceptualBlur * 46)
                .saturation(0.65)
                .opacity(reduceTransparency ? 0.08 : 0.20)
            atmosphereField(for: .albumPoster)
            ambientReadingVeil
        }
    }

    @ViewBuilder
    private func atmosphereField(for presentation: V3ArtworkPresentation) -> some View {
        let level = min(nightGentle ? 1 : 2, settings.v3AtmosphereLevel(for: presentation, scene: listeningScene))
        if level > 0, let kind = atmosphereKind(for: presentation) {
            V3AtmosphereFieldView(
                kind: kind,
                primary: ambientColor(palette.primary, saturation: 0.82, maximumLuminance: 0.46),
                secondary: ambientColor(palette.secondary, saturation: 0.72, maximumLuminance: 0.34),
                glow: ambientColor(palette.glow, saturation: 0.90, maximumLuminance: 0.52),
                level: level,
                isPlaying: isPlaying,
                isVisible: isWindowVisible,
                reduceMotion: accessibilityReduceMotion
            )
        }
    }

    private func atmosphereKind(for presentation: V3ArtworkPresentation) -> V3AtmosphereFieldKind? {
        switch presentation {
        case .classic: return .classic
        case .authenticAmbient: return .authenticAmbient
        case .ambient: return .ambient
        case .ambientFeathered: return .ambientFeathered
        case .stage: return .stage
        case .lyricsOnly: return .lyricsOnly
        case .albumPoster: return .albumPoster
        case .classicGaussian: return nil
        }
    }

    private var flowingArtworkColors: some View {
        ZStack {
            LinearGradient(colors: [ambientColor(palette.primary, saturation: 0.70, maximumLuminance: 0.26),
                                    ambientColor(palette.secondary, saturation: 0.72, maximumLuminance: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            V3AtmosphereFieldView(
                kind: .flowingField,
                primary: ambientColor(palette.primary, saturation: 0.88, maximumLuminance: 0.58),
                secondary: ambientColor(palette.secondary, saturation: 0.78, maximumLuminance: 0.40),
                glow: ambientColor(palette.glow, saturation: 0.84, maximumLuminance: 0.62),
                level: min(nightGentle ? 1 : 2, settings.v3AtmosphereLevel(for: artworkPresentation, scene: listeningScene)),
                isPlaying: isPlaying, isVisible: isWindowVisible,
                reduceMotion: accessibilityReduceMotion || reduceTransparency,
                softness: normalizedBlur
            )
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
            framedArtwork(image: image, scale: backdropImageScale, blur: 0)
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
        atmosphereField(for: .stage)
        // Full original cover over a diffuse extension; lyric layout is unchanged.
        Color.black.opacity(listeningScene == .coverPhoto ? 0.08 : (settings.v3StageReadabilityEnabled ? 0.56 : (increaseContrast ? 0.40 : 0.24)))
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

    // Original ambient light composition with the shared percentage response and framing.
    @ViewBuilder
    private func authenticAmbientArtworkLayers(image: NSImage, ambientImage: NSImage?) -> some View {
        let style = presentationStyle
        let saturation = min(
            1.3,
            style.paletteSaturation * 1.18 + (increaseContrast ? 0.06 : 0)
        )
        let diffusionRadius = perceptualBlur * 48.0
        // 背景明暗 only rescales the luminance clamps and the artwork opacity, so
        // at 100% the composition is byte-identical to the old 原版环境光 and the
        // lighter 封面柔焦 look stays reachable above 100%.
        let brightness = settings.v3BackgroundBrightness(for: .authenticAmbient, scene: listeningScene)

        // A luminance-clamped album field keeps very bright artwork legible
        // without falling back to an unrelated black canvas.
        LinearGradient(
            colors: [
                ambientColor(palette.primary, saturation: saturation,
                             maximumLuminance: min(0.85, 0.42 * brightness)),
                ambientColor(palette.secondary, saturation: saturation * 0.90,
                             maximumLuminance: min(0.85, 0.30 * brightness)),
                Color(red: 0.055, green: 0.060, blue: 0.072)
            ],
            startPoint: coverLightCenter,
            endPoint: artworkPosition == "right" ? .topLeading : .bottomTrailing
        )

        // Retain album structure before applying the user-controlled diffusion.
        // Keep image visibility independent of diffusion, including at 0%.
        // The full-resolution snapshot avoids baked-in blur at the clear endpoint.
        framedArtwork(image: image, scale: backdropImageScale, blur: diffusionRadius)
            .saturation(saturation)
            .opacity(min(0.74, 0.56 * brightness))

        atmosphereField(for: .authenticAmbient)

        RadialGradient(
            colors: [
                ambientColor(palette.glow, saturation: saturation,
                             maximumLuminance: min(0.85, 0.58 * brightness))
                    .opacity(0.34),
                ambientColor(palette.primary, saturation: saturation,
                             maximumLuminance: min(0.85, 0.40 * brightness))
                    .opacity(0.12),
                .clear
            ],
            center: coverLightCenter,
            startRadius: 18,
            endRadius: 680 + perceptualBlur * 220
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
        framedArtwork(image: image, scale: backdropImageScale,
                      blur: diffusionRadius)
            .saturation(saturation)
            .opacity(0.85)

        atmosphereField(for: .ambient)

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
            let rect = V3BackdropArtworkGeometry.rect(canvas: canvas.size, artwork: image.size,
                                                       scale: backdropImageScale, complete: showsCompleteArtwork)
            let side = min(rect.width, rect.height)
            let sourceWidth = rect.width
            let sourceHeight = rect.height
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

        atmosphereField(for: .ambientFeathered)

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
            framedArtwork(image: image, scale: backdropImageScale,
                          blur: effectiveBlurRadius,
                          horizontalOffset: showsCompleteArtwork ? 0 : classicArtworkOffset(for: geometry.size.width))

        }
        .clipped()
    }

    @ViewBuilder
    private func classicArtworkLayers(image: NSImage) -> some View {
        let saturation = min(1.2, presentationStyle.paletteSaturation * 1.12)

        LinearGradient(
            colors: [
                ambientColor(palette.primary, saturation: saturation, maximumLuminance: 0.34),
                ambientColor(palette.secondary, saturation: saturation * 0.86, maximumLuminance: 0.24),
                Color(red: 0.035, green: 0.042, blue: 0.058)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // A quiet, stationary field remains when motion is disabled.
        RadialGradient(
            colors: [
                ambientColor(palette.glow, saturation: 0.78, maximumLuminance: 0.30).opacity(0.24),
                .clear
            ],
            center: coverLightCenter,
            startRadius: 24,
            endRadius: 720
        )

        GeometryReader { geometry in
            let scale = min(1.4, max(0.8, artworkSizeScale))
            let effectiveScale = backdropImageScale
            let offset = classicArtworkOffset(
                for: geometry.size.width,
                scale: scale,
                effectiveScale: effectiveScale
            )
            framedArtwork(
                image: image,
                scale: showsCompleteArtwork ? scale : effectiveScale,
                blur: effectiveBlurRadius,
                horizontalOffset: showsCompleteArtwork ? 0 : offset
            )
            .saturation(saturation)
            .opacity(0.30)
        }

        atmosphereField(for: .classic)

        if artworkPosition != "center" {
            let veilStart: UnitPoint = artworkPosition == "right" ? .trailing : .leading
            let veilEnd: UnitPoint = artworkPosition == "right" ? .leading : .trailing
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.08), Color.black.opacity(0.18)],
                startPoint: veilStart,
                endPoint: veilEnd
            )
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
        let effectiveScale = backdropImageScale
        return classicArtworkOffset(for: width, scale: scale, effectiveScale: effectiveScale)
    }

    private func classicArtworkOffset(for width: CGFloat, scale: CGFloat, effectiveScale: CGFloat) -> CGFloat {
        V3BackdropArtworkGeometry.horizontalOffset(width: width, scale: scale, effectiveScale: effectiveScale,
                                                   position: artworkPosition)
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
            for: paletteCacheKey,
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

enum V3AtmosphereFieldKind {
    case flowingField
    case classic
    case authenticAmbient
    case ambient
    case ambientFeathered
    case stage
    case lyricsOnly
    case albumPoster
}

/// Isolated decorative layer: it owns its own clock and never changes layout.
struct V3AtmosphereFieldView: View {
    let kind: V3AtmosphereFieldKind
    let primary: Color
    let secondary: Color
    let glow: Color
    let level: Int
    let isPlaying: Bool
    let isVisible: Bool
    let reduceMotion: Bool

    var softness: Double = 0.25
    @State private var elapsed = 0.0
    @State private var segmentStart: Date?

    private var isPaused: Bool {
        level == 0 || !isPlaying || !isVisible || reduceMotion
    }

    private func point(x: Double, y: Double) -> UnitPoint {
        UnitPoint(x: CGFloat(x), y: CGFloat(y))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { timeline in
            GeometryReader { geometry in
                // The timeline redraws this small field only. No per-frame State
                // writes, image decoding, lyric work or global notifications.
                let running = segmentStart.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                let phase = (elapsed + (isPaused ? 0 : running)) * (level <= 1 ? 0.11 : 0.15)
                field(size: geometry.size, phase: phase)
            }
        }
        .onChange(of: isPaused) { _, paused in
            if let segmentStart { elapsed += max(0, Date().timeIntervalSince(segmentStart)) }
            segmentStart = paused ? nil : .now
        }
        .onAppear { if !isPaused { segmentStart = .now } }
        .onDisappear {
            if let segmentStart { elapsed += max(0, Date().timeIntervalSince(segmentStart)) }
            segmentStart = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func field(size: CGSize, phase: Double) -> some View {
        let extent = max(size.width, size.height)
        let strength = level == 1 ? 0.24 : 0.40

        switch kind {
        case .flowingField:
            let spread = 0.36 + min(1, max(0, softness)) * 0.32
            ZStack {
                RadialGradient(colors: [glow.opacity(0.62), primary.opacity(0.24), .clear],
                    center: point(x: 0.24 + sin(phase * 0.55) * 0.12,
                                  y: 0.40 + cos(phase * 0.45) * 0.12),
                    startRadius: extent * 0.035, endRadius: extent * spread)
                RadialGradient(colors: [secondary.opacity(0.48), .clear],
                    center: point(x: 0.74 + cos(phase * 0.43) * 0.12,
                                  y: 0.63 + sin(phase * 0.35) * 0.14),
                    startRadius: extent * 0.025, endRadius: extent * (spread + 0.10))
                RadialGradient(colors: [primary.opacity(0.32), .clear],
                    center: point(x: 0.62 + sin(phase * 0.31) * 0.13,
                                  y: 0.19 + cos(phase * 0.28) * 0.10),
                    startRadius: 1, endRadius: extent * spread * 0.76)
            }.blendMode(.screen)
        case .classic:
            ZStack {
                RadialGradient(
                    colors: [glow.opacity(strength * 0.68), .clear],
                    center: point(x: 0.22 + sin(phase * 0.70) * 0.12,
                                  y: 0.31 + cos(phase * 0.53) * 0.10),
                    startRadius: 8,
                    endRadius: extent * 0.62
                )
                RadialGradient(
                    colors: [primary.opacity(strength * 0.48), .clear],
                    center: point(x: 0.78 + cos(phase * 0.43) * 0.09,
                                  y: 0.70 + sin(phase * 0.61) * 0.11),
                    startRadius: 16,
                    endRadius: extent * 0.54
                )
                RadialGradient(
                    colors: [secondary.opacity(strength * 0.34), .clear],
                    center: point(x: 0.47 + sin(phase * 0.31) * 0.10,
                                  y: 0.20 + cos(phase * 0.38) * 0.08),
                    startRadius: 12,
                    endRadius: extent * 0.46
                )
            }
            .blendMode(.screen)

        case .authenticAmbient:
            RadialGradient(
                colors: [glow.opacity(strength * 0.58), primary.opacity(strength * 0.18), .clear],
                center: point(x: 0.36 + sin(phase * 0.34) * 0.14,
                              y: 0.48 + cos(phase * 0.28) * 0.12),
                startRadius: extent * 0.08,
                endRadius: extent * 0.76
            )
            .blendMode(.screen)

        case .ambient:
            LinearGradient(
                colors: [primary.opacity(strength * 0.52), .clear,
                         secondary.opacity(strength * 0.24), glow.opacity(strength * 0.36)],
                startPoint: point(x: 0.02 + sin(phase * 0.24) * 0.18, y: 0.05),
                endPoint: point(x: 0.98 + cos(phase * 0.24) * 0.18, y: 0.95)
            )
            .blendMode(.screen)

        case .ambientFeathered:
            RadialGradient(
                stops: [
                    .init(color: secondary.opacity(strength * 0.36), location: 0),
                    .init(color: glow.opacity(strength * 0.28), location: 0.42),
                    .init(color: .clear, location: 1)
                ],
                center: point(x: 0.70 + cos(phase * 0.29) * 0.12,
                              y: 0.46 + sin(phase * 0.32) * 0.10),
                startRadius: 0,
                endRadius: extent * 0.72
            )
            .blendMode(.screen)

        case .stage:
            RadialGradient(
                colors: [glow.opacity(strength * 0.44), primary.opacity(strength * 0.12), .clear],
                center: point(x: 0.50 + sin(phase * 0.22) * 0.13,
                              y: 0.18 + cos(phase * 0.18) * 0.07),
                startRadius: 4,
                endRadius: extent * 0.43
            )
            .blendMode(.screen)

        case .lyricsOnly:
            LinearGradient(
                colors: [.clear, primary.opacity(strength * 0.20), .clear],
                startPoint: point(x: 0.06, y: 0.14 + sin(phase * 0.18) * 0.12),
                endPoint: point(x: 0.88, y: 0.88 + cos(phase * 0.18) * 0.12)
            )
            .blendMode(.softLight)

        case .albumPoster:
            RadialGradient(
                colors: [secondary.opacity(strength * 0.28), glow.opacity(strength * 0.18), .clear],
                center: point(x: 0.20 + sin(phase * 0.16) * 0.06,
                              y: 0.50 + cos(phase * 0.14) * 0.08),
                startRadius: 0,
                endRadius: extent * 0.46
            )
            .blendMode(.screen)
        }
    }


}

struct V3WindowVisibilityProbe: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> V3WindowVisibilityTrackingView {
        let view = V3WindowVisibilityTrackingView()
        let binding = _isVisible
        view.onVisibilityChange = { binding.wrappedValue = $0 }
        return view
    }

    func updateNSView(_ nsView: V3WindowVisibilityTrackingView, context: Context) {
        let binding = _isVisible
        nsView.onVisibilityChange = { binding.wrappedValue = $0 }
        nsView.refreshWindowObservers()
    }

    static func dismantleNSView(_ nsView: V3WindowVisibilityTrackingView, coordinator: ()) {
        nsView.stopObserving()
    }
}

final class V3WindowVisibilityTrackingView: NSView {
    var onVisibilityChange: ((Bool) -> Void)?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var lastReportedVisibility: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshWindowObservers()
    }

    func refreshWindowObservers() {
        guard observedWindow !== window else {
            reportVisibility()
            return
        }
        stopObserving()
        observedWindow = window
        guard let window else {
            reportVisibility()
            return
        }
        observe(NSWindow.didChangeOcclusionStateNotification, object: window)
        observe(NSWindow.didMiniaturizeNotification, object: window)
        observe(NSWindow.didDeminiaturizeNotification, object: window)
        observe(NSApplication.didHideNotification, object: NSApp)
        observe(NSApplication.didUnhideNotification, object: NSApp)
        reportVisibility()
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        observedWindow = nil
    }

    private func observe(_ name: Notification.Name, object: AnyObject?) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { [weak self] _ in
            self?.reportVisibility()
        })
    }

    private func reportVisibility() {
        let visible = window.map {
            $0.isVisible && $0.occlusionState.contains(.visible) && !NSApp.isHidden
        } ?? false
        guard lastReportedVisibility != visible else { return }
        lastReportedVisibility = visible
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = self.window.map {
                $0.isVisible && $0.occlusionState.contains(.visible) && !NSApp.isHidden
            } ?? false
            guard current == visible else {
                self.reportVisibility()
                return
            }
            self.onVisibilityChange?(current)
        }
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
/// The same artwork URL shares its sampled palette across listening surfaces.
public actor AppleMusicImmersiveV3BackdropCache {
    public static let shared = AppleMusicImmersiveV3BackdropCache()

    private var values: [String: AppleMusicImmersiveV3BackdropSnapshot] = [:]
    private var inFlight: [String: Task<AppleMusicImmersiveV3BackdropSnapshot, Never>] = [:]
    private var order: [String] = []
    private let capacity = 48

    public init() {}

    public func cachedPalette(for key: String) -> BackdropPalette? { values[key]?.palette }

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
