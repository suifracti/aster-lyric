import AppKit
import Foundation

public struct BackdropColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    public var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: 1)
    }

    public static let neutral = BackdropColor(red: 0.12, green: 0.14, blue: 0.2)
}

public struct BackdropPalette: Equatable, Sendable {
    public let primary: BackdropColor
    public let secondary: BackdropColor
    public let glow: BackdropColor
    public let luminance: Double
    public let saturation: Double
    public let readabilityVeilOpacity: Double
    public let textureOpacity: Double

    public init(
        primary: BackdropColor,
        secondary: BackdropColor,
        glow: BackdropColor,
        luminance: Double,
        saturation: Double,
        readabilityVeilOpacity: Double,
        textureOpacity: Double
    ) {
        self.primary = primary
        self.secondary = secondary
        self.glow = glow
        self.luminance = luminance
        self.saturation = saturation
        self.readabilityVeilOpacity = readabilityVeilOpacity
        self.textureOpacity = textureOpacity
    }

    public static let neutral = BackdropPalette(
        primary: .neutral,
        secondary: BackdropColor(red: 0.08, green: 0.1, blue: 0.16),
        glow: BackdropColor(red: 0.24, green: 0.19, blue: 0.3),
        luminance: 0.14,
        saturation: 0.38,
        readabilityVeilOpacity: 0.34,
        textureOpacity: 0.28
    )

    public static func from(image: NSImage) -> BackdropPalette {
        guard let imageData = image.tiffRepresentation else {
            return .neutral
        }
        return from(imageData: imageData)
    }

    /// Computes the palette from immutable image data so callers can move the
    /// work off the main actor. The result is deterministic for a given cover.
    public static func from(imageData: Data) -> BackdropPalette {
        guard let representation = NSBitmapImageRep(data: imageData) else {
            return .neutral
        }

        let width = max(1, representation.pixelsWide)
        let height = max(1, representation.pixelsHigh)
        let step = max(1, max(width, height) / 32)
        var samples: [(color: BackdropColor, saturation: Double, luminance: Double)] = []

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let sample = BackdropColor(
                    red: Double(color.redComponent),
                    green: Double(color.greenComponent),
                    blue: Double(color.blueComponent)
                )
                samples.append((sample, saturation(of: sample), luminance(of: sample)))
            }
        }

        guard !samples.isEmpty else { return .neutral }
        let average = BackdropColor(
            red: samples.map { $0.color.red }.reduce(0, +) / Double(samples.count),
            green: samples.map { $0.color.green }.reduce(0, +) / Double(samples.count),
            blue: samples.map { $0.color.blue }.reduce(0, +) / Double(samples.count)
        )
        let vivid = samples.max { lhs, rhs in
            (lhs.saturation * 0.8 + lhs.luminance * 0.2) < (rhs.saturation * 0.8 + rhs.luminance * 0.2)
        }?.color ?? average
        let primary = blend(vivid, average, amount: 0.35)
        let secondary = blend(primary, vivid, amount: 0.50)
        let glow = blend(vivid, BackdropColor(red: 0.95, green: 0.75, blue: 0.65), amount: 0.35)
        let averageLuminance = luminance(of: average)
        let averageSaturation = samples.map(\.saturation).reduce(0, +) / Double(samples.count)

        let veil: Double
        switch averageLuminance {
        case 0.72...:
            veil = 0.30
        case 0.5..<0.72:
            veil = 0.22
        case ..<0.16:
            veil = 0.15
        default:
            veil = 0.18
        }

        return BackdropPalette(
            primary: primary,
            secondary: secondary,
            glow: glow,
            luminance: averageLuminance,
            saturation: averageSaturation,
            readabilityVeilOpacity: max(veil, averageSaturation > 0.7 ? 0.24 : 0.16),
            textureOpacity: averageLuminance > 0.82 ? 0.35 : 0.45
        )
    }

    private static func luminance(of color: BackdropColor) -> Double {
        (color.red * 0.2126) + (color.green * 0.7152) + (color.blue * 0.0722)
    }

    private static func saturation(of color: BackdropColor) -> Double {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        guard maximum > 0 else { return 0 }
        return (maximum - minimum) / maximum
    }

    private static func blend(_ lhs: BackdropColor, _ rhs: BackdropColor, amount: Double) -> BackdropColor {
        let amount = min(1, max(0, amount))
        return BackdropColor(
            red: lhs.red + (rhs.red - lhs.red) * amount,
            green: lhs.green + (rhs.green - lhs.green) * amount,
            blue: lhs.blue + (rhs.blue - lhs.blue) * amount
        )
    }
}

/// Stable, presentation-only IDs for the Phase 2.3D backdrop system.
///
/// These IDs do not create settings, database records, or a second artwork
/// pipeline.  `customV1` is reserved for a future Experience Library entry;
/// the first four presets are the only runnable presets in this phase.
public enum BackdropPresentationID: String, CaseIterable, Sendable {
    case legacyV3V1 = "backdrop.legacyV3.v1"
    case defaultV1 = "backdrop.default.v1"
    case clearV1 = "backdrop.clear.v1"
    case immersiveV1 = "backdrop.immersive.v1"
    case highContrastV1 = "backdrop.highContrast.v1"
    case customV1 = "backdrop.custom.v1"

    public static let defaultID: BackdropPresentationID = .defaultV1

#if DEBUG
    /// Debug-only override used by controlled visual validation. Release
    /// builds always resolve to the default presentation.
    public static var active: BackdropPresentationID {
        guard let raw = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_BACKDROP_PRESET"],
              !raw.isEmpty else {
            return .defaultV1
        }

        if let exact = BackdropPresentationID(rawValue: raw) {
            return exact
        }

        let shorthand = raw.hasPrefix("backdrop.") ? raw : "backdrop.\(raw).v1"
        return BackdropPresentationID(rawValue: shorthand) ?? persistedSelection
    }
#else
    public static var active: BackdropPresentationID { persistedSelection }
#endif

    private static var persistedSelection: BackdropPresentationID {
        guard let raw = UserDefaults.lyricsQ.string(
            forKey: PresentationSelectionStore.runtimeKey(for: .backdrop)
        ), let selected = BackdropPresentationID(rawValue: raw), selected.isRunnableInPhase2_3D else {
            return .defaultV1
        }
        return selected
    }

    public var isRunnableInPhase2_3D: Bool {
        switch self {
        case .legacyV3V1, .customV1:
            return false
        case .defaultV1, .clearV1, .immersiveV1, .highContrastV1:
            return true
        }
    }

    public var style: BackdropPresentationStyle {
        switch self {
        case .legacyV3V1:
            // The retained V3 compatibility path has an identity, not a
            // second cache or rendering implementation. Until the legacy
            // surface is promoted into the Experience Library, it resolves
            // to the safe default style when inspected by diagnostics.
            return BackdropPresentationID.defaultV1.style
        case .defaultV1:
            return BackdropPresentationStyle(
                textureIntensity: LyricsDesignTokens.Backdrop.textureIntensity,
                artworkScreenOpacity: 0.85,
                artworkOpacity: 0.95,
                artworkScreenBlur: 10,
                artworkBlur: 36,
                artworkScreenScale: 1.18,
                artworkScale: 1.36,
                paletteSaturation: 1.2,
                paletteOpacity: 0.25,
                glowIntensity: 0.45,
                lyricVeilMultiplier: 0.45,
                minimumLyricVeil: 0.14,
                vignetteIntensity: 0.28,
                noiseIntensity: 0.02,
                transitionDuration: LyricsDesignTokens.Backdrop.transitionDuration,
                outgoingTransitionDuration: LyricsDesignTokens.Backdrop.outgoingTransitionDuration
            )
        case .clearV1:
            return BackdropPresentationStyle(
                textureIntensity: 0.42,
                artworkScreenOpacity: 0.28,
                artworkOpacity: 0.30,
                artworkScreenBlur: 34,
                artworkBlur: 96,
                artworkScreenScale: 1.08,
                artworkScale: 1.20,
                paletteSaturation: 0.20,
                paletteOpacity: 0.42,
                glowIntensity: 0.18,
                lyricVeilMultiplier: 0.58,
                minimumLyricVeil: 0.30,
                vignetteIntensity: 0.22,
                noiseIntensity: 0.006,
                transitionDuration: 0.38,
                outgoingTransitionDuration: 0.16
            )
        case .immersiveV1:
            return BackdropPresentationStyle(
                textureIntensity: 1.25,
                artworkScreenOpacity: 0.86,
                artworkOpacity: 0.92,
                artworkScreenBlur: 18,
                artworkBlur: 58,
                artworkScreenScale: 1.20,
                artworkScale: 1.44,
                paletteSaturation: 1.35,
                paletteOpacity: 1.35,
                glowIntensity: 0.92,
                lyricVeilMultiplier: 0.82,
                minimumLyricVeil: 0.26,
                vignetteIntensity: 0.52,
                noiseIntensity: 0.05,
                transitionDuration: 0.46,
                outgoingTransitionDuration: 0.20
            )
        case .highContrastV1:
            return BackdropPresentationStyle(
                textureIntensity: 0.62,
                artworkScreenOpacity: 0.38,
                artworkOpacity: 0.44,
                artworkScreenBlur: 26,
                artworkBlur: 84,
                artworkScreenScale: 1.16,
                artworkScale: 1.34,
                paletteSaturation: 0.56,
                paletteOpacity: 0.56,
                glowIntensity: 0.30,
                lyricVeilMultiplier: 1.08,
                minimumLyricVeil: 0.42,
                vignetteIntensity: 0.56,
                noiseIntensity: 0.012,
                transitionDuration: 0.32,
                outgoingTransitionDuration: 0.12
            )
        case .customV1:
            // Custom is a stable future ID only. It deliberately falls back
            // to the safe default until Experience Library editing exists.
            return BackdropPresentationID.defaultV1.style
        }
    }
}

public struct BackdropPresentationStyle: Equatable, Sendable {
    public let textureIntensity: Double
    public let artworkScreenOpacity: Double
    public let artworkOpacity: Double
    public let artworkScreenBlur: Double
    public let artworkBlur: Double
    public let artworkScreenScale: Double
    public let artworkScale: Double
    public let paletteSaturation: Double
    public let paletteOpacity: Double
    public let glowIntensity: Double
    public let lyricVeilMultiplier: Double
    public let minimumLyricVeil: Double
    public let vignetteIntensity: Double
    public let noiseIntensity: Double
    public let transitionDuration: Double
    public let outgoingTransitionDuration: Double

    public init(
        textureIntensity: Double,
        artworkScreenOpacity: Double,
        artworkOpacity: Double,
        artworkScreenBlur: Double,
        artworkBlur: Double,
        artworkScreenScale: Double,
        artworkScale: Double,
        paletteSaturation: Double,
        paletteOpacity: Double,
        glowIntensity: Double,
        lyricVeilMultiplier: Double,
        minimumLyricVeil: Double,
        vignetteIntensity: Double,
        noiseIntensity: Double,
        transitionDuration: Double,
        outgoingTransitionDuration: Double
    ) {
        self.textureIntensity = textureIntensity
        self.artworkScreenOpacity = artworkScreenOpacity
        self.artworkOpacity = artworkOpacity
        self.artworkScreenBlur = artworkScreenBlur
        self.artworkBlur = artworkBlur
        self.artworkScreenScale = artworkScreenScale
        self.artworkScale = artworkScale
        self.paletteSaturation = paletteSaturation
        self.paletteOpacity = paletteOpacity
        self.glowIntensity = glowIntensity
        self.lyricVeilMultiplier = lyricVeilMultiplier
        self.minimumLyricVeil = minimumLyricVeil
        self.vignetteIntensity = vignetteIntensity
        self.noiseIntensity = noiseIntensity
        self.transitionDuration = transitionDuration
        self.outgoingTransitionDuration = outgoingTransitionDuration
    }
}

/// Track-bound cache for the relatively expensive cover sampling step.
///
/// Playback position never participates in the cache key. A new palette is
/// computed only when the track/artwork identity changes, and the sampling is
/// performed in a detached utility task rather than in a SwiftUI body.
public actor BackdropPaletteCache {
    public static let shared = BackdropPaletteCache()

    private var values: [String: BackdropPalette] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<BackdropPalette, Never>] = [:]
    private let capacity = 64

    public init() {}

    public func palette(for key: String, imageData: Data) async -> BackdropPalette {
        if let cached = values[key] {
            return cached
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            BackdropPalette.from(imageData: imageData)
        }
        inFlight[key] = task

        let palette = await task.value
        inFlight[key] = nil
        values[key] = palette
        order.removeAll { $0 == key }
        order.append(key)

        if order.count > capacity, let evicted = order.first {
            order.removeFirst()
            values[evicted] = nil
        }

        return palette
    }
}
