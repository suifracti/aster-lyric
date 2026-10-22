import Foundation
import SwiftUI
import AppKit
import Combine
import os

enum AppleMusicImmersiveV3ProgressDensity: Equatable {
    case wide
    case medium
    case small
    case focus

    var containerHeight: CGFloat {
        switch self {
        case .wide: return 24
        case .medium: return 22
        case .small: return 20
        case .focus: return 20
        }
    }

    /// The visible rail stays thin; this is the stable pointer and keyboard
    /// target used while the window is being resized or the pointer is near
    /// the controls. Keeping the hit target independent from rail thickness
    /// prevents tiny controls from changing the surrounding composition.
    var interactionHeight: CGFloat { containerHeight }

    var trackHeight: CGFloat {
        switch self {
        case .wide, .medium: return LyricsDesignTokens.Progress.trackHeight
        case .small, .focus: return LyricsDesignTokens.Progress.compactTrackHeight
        }
    }

    var isFocus: Bool { self == .focus }
}

/// A restrained playback rail shared by every V3 size projection. It owns no
/// clock and only sends an explicit seek after the user finishes editing.
private struct AppleMusicImmersiveV3PlaybackProgress: View {
    @Environment(\.v3CoverAccent) private var coverAccent
    @Environment(\.v3PlaybackVisible) private var playbackVisible
    @V3ContentPlaybackState var state: PlaybackState
    let density: AppleMusicImmersiveV3ProgressDensity
    let maxWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.v3PlaybackInteractionChanged) private var interactionChanged

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftPosition: Double?

    private var duration: Double {
        max(0.1, state.currentTrack.duration)
    }

    private var playbackPosition: Double {
        let rawValue = draftPosition ?? state.presentationClock.playbackTime(
            at: ProcessInfo.processInfo.systemUptime
        )
        return min(max(rawValue, 0), duration)
    }

    private var progressFraction: Double {
        min(max(playbackPosition / duration, 0), 1)
    }

    private var isEmphasized: Bool { isHovered || isEditing }

    private var progressActiveGradient: LinearGradient {
        LinearGradient(
            colors: [
                coverAccent.opacity(isEmphasized ? 0.96 : 0.86),
                coverAccent.opacity(isEmphasized ? 0.82 : 0.68)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !playbackVisible || !state.isPlaying || isEditing || reduceMotion
        )) { _ in
            progressRail
        }
    }

    private var progressRail: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let trackHeight = isEmphasized
                ? LyricsDesignTokens.Progress.hoverTrackHeight
                : density.trackHeight
            let activeWidth = max(0, width * progressFraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(
                        isEmphasized
                            ? LyricsDesignTokens.Progress.hoverInactiveOpacity
                            : LyricsDesignTokens.Progress.inactiveOpacity
                    ))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(progressActiveGradient)
                    .frame(width: activeWidth, height: trackHeight)

                if isEmphasized {
                    Circle()
                        .fill(.white)
                        .frame(
                            width: LyricsDesignTokens.Progress.hoverThumbSize,
                            height: LyricsDesignTokens.Progress.hoverThumbSize
                        )
                        .offset(x: min(
                            max(activeWidth - LyricsDesignTokens.Progress.hoverThumbSize / 2, 0),
                            max(0, width - LyricsDesignTokens.Progress.hoverThumbSize)
                        ))
                }

                // The native control remains the accessibility and input
                // surface; the custom rail above keeps the resting visual
                // quiet without introducing a second seek implementation.
                V3PlaybackInputSlider(
                    value: Binding(
                        get: { playbackPosition },
                        set: { draftPosition = min(max($0, 0), duration) }
                    ),
                    duration: duration,
                    onEditingChanged: handleEditingChanged
                )
                .frame(height: density.interactionHeight)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion, duration: 0.14)) {
                    isHovered = hovering
                }
            }
        }
        .frame(
            width: density.isFocus ? LyricsDesignTokens.Progress.focusWidth : nil,
            height: density.interactionHeight
        )
        .frame(maxWidth: density.isFocus ? nil : (maxWidth ?? .infinity))
        .animation(
            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion, duration: 0.14),
            value: isEmphasized
        )
    }

    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing
        interactionChanged(editing)
        // A native Slider may write its binding before beginning tracking.
        // Preserve that target rather than replacing it with the live clock.
        guard !editing, let draftPosition else { return }
        self.draftPosition = nil
        state.seek(to: min(max(draftPosition, 0), duration), source: "v3-progress-slider")
    }
}

/// Keep the native accessibility/keyboard control fully hit-testable. A
/// translucent SwiftUI Slider can let its hosting window claim the drag.
private struct V3PlaybackInputSlider: NSViewRepresentable {
    @Binding var value: Double
    let duration: Double
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> V3PlaybackNativeSlider {
        let slider = V3PlaybackNativeSlider()
        slider.cell = V3PlaybackSliderCell()
        slider.minValue = 0
        slider.maxValue = duration
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("播放进度")
        slider.onTrackingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.parent.onEditingChanged(editing)
        }
        return slider
    }

    func updateNSView(_ slider: V3PlaybackNativeSlider, context: Context) {
        context.coordinator.parent = self
        slider.maxValue = duration
        if !slider.isTrackingInteraction { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: V3PlaybackInputSlider
        init(parent: V3PlaybackInputSlider) { self.parent = parent }

        @objc func changed(_ sender: V3PlaybackNativeSlider) {
            // Keyboard and accessibility changes need the same single commit
            // as pointer tracking, even when AppKit skips mouseDown entirely.
            let standalone = !sender.isTrackingInteraction
            if standalone { parent.onEditingChanged(true) }
            parent.value = sender.doubleValue
            if standalone { parent.onEditingChanged(false) }
        }
    }
}

private final class V3PlaybackNativeSlider: NSSlider {
    var onTrackingChanged: ((Bool) -> Void)?
    private(set) var isTrackingInteraction = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isTrackingInteraction = true
        onTrackingChanged?(true)
        defer {
            isTrackingInteraction = false
            onTrackingChanged?(false)
        }
        applyPointerPosition(event)
        // AppKit's cell tracker can miss a sparse final jump. Apply mouseUp
        // too, so the committed draft always reflects where tracking ended.
        while let next = window?.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            applyPointerPosition(next)
            if next.type == .leftMouseUp { break }
        }
    }

    private func applyPointerPosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        doubleValue = Self.pointerPosition(x: point.x, width: bounds.width, duration: maxValue)
        _ = sendAction(action, to: target)
    }

    static func pointerPosition(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0,
              duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, Double(x / width))) * duration
    }
}

private final class V3PlaybackSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {}
    override func drawKnob(_ knobRect: NSRect) {}
}

struct AppleMusicImmersiveV3TransportControls: View {
    @V3ContentPlaybackState var state: PlaybackState
    let alignment: HorizontalAlignment
    let progressDensity: AppleMusicImmersiveV3ProgressDensity
    let progressMaxWidth: CGFloat?

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            AppleMusicImmersiveV3PlaybackProgress(
                state: state,
                density: progressDensity,
                maxWidth: progressMaxWidth
            )

            HStack {
                V3TransportClockLabel(state: state)
                Spacer()
                Text(formatTime(state.currentTrack.duration))
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))
            .frame(maxWidth: progressMaxWidth ?? .infinity)
            .padding(.horizontal, 2)

            V3PlaybackButtons(state: state)
                .frame(maxWidth: progressMaxWidth ?? .infinity, alignment: .center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct V3TransportClockLabel: View {
    @Environment(\.v3PlaybackVisible) private var playbackVisible
    @V3ContentPlaybackState var state: PlaybackState

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !playbackVisible || !state.isPlaying)) { _ in
            Text(Self.formatTime(state.presentationClock.playbackTime(at: ProcessInfo.processInfo.systemUptime)))
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

/// One shared surface keeps the player legible over detailed artwork without
/// turning every individual action into a separate floating object.
struct V3PlaybackSurface: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.24))
    }
}

struct StageHUDView: View {
    @V3ContentPlaybackState var state: PlaybackState
    let width: CGFloat

    var body: some View {
        HStack(spacing: 20) {
            TrackMetadataView(
                track: state.currentTrack, titleSize: 16,
                alignment: .leading, presentation: .v3Immersive
            )
            .frame(width: max(1, (width - 32) * 0.38), alignment: .leading)

            V3PlaybackButtons(state: state)

            VStack(spacing: 0) {
                AppleMusicImmersiveV3PlaybackProgress(state: state, density: .small, maxWidth: nil)
                HStack {
                    V3TransportClockLabel(state: state)
                    Spacer()
                    Text(formatTime(state.currentTrack.duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: width, height: 96)
        .background(V3PlaybackSurface())
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct V3PlaybackButtons: View {
    @V3ContentPlaybackState var state: PlaybackState
    @State private var showsPlaylistPicker = false

    var body: some View {
        HStack(spacing: 12) {
            V3PlayerModeButton(state: state, shuffle: true)
            heartButton
            V3TransportIconButton(systemImage: "backward.fill", label: "上一首", enabled: state.canControlSpotify) {
                state.previousTrack()
            }
            V3TransportIconButton(
                systemImage: state.isPlaying ? "pause.fill" : "play.fill",
                label: state.isPlaying ? "暂停" : "播放",
                enabled: state.canInteractWithPlayback, prominent: true
            ) {
                state.togglePlayPause()
            }
            V3TransportIconButton(systemImage: "forward.fill", label: "下一首", enabled: state.canControlSpotify) {
                state.nextTrack()
            }
            V3PlayerModeButton(state: state, shuffle: false)
        }
        .fixedSize()
    }

    /// A liked song turns the heart into the way into playlists; an unliked
    /// one still just likes it. Right-click always opens the picker.
    private var heartButton: some View {
        V3TransportIconButton(systemImage: state.isTrackLiked == true ? "heart.fill" : "heart",
                              label: state.isTrackLiked == true ? "加入播放列表" : "加入喜欢 (S)",
                              enabled: state.hasLiveTrack) {
            if state.canPickPlaylists, state.isTrackLiked == true {
                showsPlaylistPicker = true
            } else {
                state.toggleTrackLike()
            }
        }
        .overlay {
            if state.canPickPlaylists {
                V3RightClickCatcher { showsPlaylistPicker = true }
            }
        }
        .popover(isPresented: $showsPlaylistPicker, arrowEdge: .bottom) {
            PlaylistPickerPopover(model: state.playlistPicker)
        }
    }
}

struct V3PlayerModeButton: View {
    @V3ContentPlaybackState var state: PlaybackState
    let shuffle: Bool
    @Environment(\.v3CoverAccent) private var accent
    private var active: Bool { shuffle ? state.playerModes?.shuffle == true : (state.playerModes?.repeatMode ?? .off) != .off }
    private var unknown: Bool { shuffle ? state.playerModes?.shuffle == nil && state.playerModes?.smartShuffle != true : state.playerModes?.repeatMode == nil }
    /// 未知 is not 关闭: neither the glyph nor the tint may use the off
    /// treatment, or a connected player with an unreadable state looks off.
    private var glyphColor: Color {
        if active { return accent }
        return unknown ? .white.opacity(0.68) : .white.opacity(0.45)
    }
    var body: some View {
        IslandTransportButton(
            systemImage: shuffle ? "shuffle" : state.playerModes?.repeatMode == .one ? "repeat.1" : "repeat",
            label: shuffle ? (state.playerModes?.shuffleLabel ?? "随机播放 · 未知") : (state.playerModes?.repeatLabel ?? "循环 · 未知"),
            enabled: state.canControlSpotify, primary: false,
            tint: glyphColor, glyph: glyphColor
        ) { state.togglePlayerMode(shuffle: shuffle) }
        .overlay(alignment: .bottom) {
            if unknown {
                Text("未知").font(.system(size: 8)).foregroundStyle(.white.opacity(0.65))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if shuffle && state.playerModes?.smartShuffle == true {
                Image(systemName: "sparkle").font(.system(size: 8)).foregroundStyle(accent)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

private struct V3TransportIconButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        // Same look as the window-edge and menu-bar transport.
        IslandTransportButton(
            systemImage: systemImage, label: label, enabled: enabled,
            primary: prominent, tint: .white, glyph: .white, action: action
        )
    }
}

struct V3BounceButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(
                LyricsDesignTokens.Motion.animation(
                    reduceMotion: reduceMotion,
                    duration: LyricsDesignTokens.Motion.quickDuration
                ),
                value: configuration.isPressed
            )
    }
}

struct AppleMusicImmersiveV3FocusTransportControls: View {
    @V3ContentPlaybackState var state: PlaybackState
    let reduceMotion: Bool
    @State private var showsPlaylistPicker = false

    var body: some View {
        HStack(spacing: LyricsDesignTokens.Spacing.sm) {
            V3PlayerModeButton(state: state, shuffle: true)
            V3TransportIconButton(systemImage: state.isTrackLiked == true ? "heart.fill" : "heart",
                                 label: state.isTrackLiked == true ? "加入播放列表" : "喜欢 (S)",
                                 enabled: state.hasLiveTrack) {
                if state.canPickPlaylists, state.isTrackLiked == true {
                    showsPlaylistPicker = true
                } else {
                    state.toggleTrackLike()
                }
            }
            .overlay {
                if state.canPickPlaylists {
                    V3RightClickCatcher { showsPlaylistPicker = true }
                }
            }
            .popover(isPresented: $showsPlaylistPicker, arrowEdge: .bottom) {
                PlaylistPickerPopover(model: state.playlistPicker)
            }
            Button {
                state.togglePlayPause()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(!state.canInteractWithPlayback)
            .opacity(state.canInteractWithPlayback ? 1 : 0.42)
            .accessibilityLabel(state.isPlaying ? "暂停" : "播放")

            V3PlayerModeButton(state: state, shuffle: false)

            // No 「正在播放 / 已暂停」 caption: the play/pause glyph already
            // tells the state, and on a 460pt 内页 footer the caption was
            // squeezed into a vertical 「已…」.
            AppleMusicImmersiveV3PlaybackProgress(
                state: state,
                density: .focus,
                maxWidth: nil
            )

            HStack(spacing: 4) {
                V3TransportClockLabel(state: state)
                Text("/ \(formatTime(state.currentTrack.duration))")
            }
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.46))
                // The compact player is the first thing a narrow canvas
                // squeezes; reserve the clock's full width so 「0:35 / 3:13」
                // stays on one line and the progress rail gives way instead.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, LyricsDesignTokens.Spacing.sm)
        .padding(.vertical, LyricsDesignTokens.Spacing.xs)
        .background(Color.black.opacity(0.16), in: Capsule())
        .animation(
            LyricsDesignTokens.Motion.animation(reduceMotion: reduceMotion, duration: 0.16),
            value: state.isPlaying
        )
        .accessibilityElement(children: .contain)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct AppleMusicImmersiveV3LyricProgressStatus: View {
    enum Mode: Equatable {
        case synchronized
        case plainText
    }

    let mode: Mode
    let currentIndex: Int?
    var isInstrumental: Bool = false
    var pureImmersion: Bool = false

    private var title: String {
        if isInstrumental {
            return pureImmersion ? "纯音乐 · 极简通透沉浸" : "纯音乐"
        }
        switch mode {
        case .synchronized:
            return currentIndex == nil ? "同步歌词 · 前奏" : "同步歌词"
        case .plainText:
            return "纯文本 · 未排轴"
        }
    }

    private var icon: String {
        if isInstrumental { return "music.note" }
        switch mode {
        case .synchronized: return "waveform"
        case .plainText: return "text.alignleft"
        }
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(
                isInstrumental
                    ? 0.75
                    : (mode == .synchronized
                        ? LyricsDesignTokens.Material.secondaryTextOpacity
                        : LyricsDesignTokens.Material.mutedTextOpacity)
            ))
            .accessibilityLabel(title)
    }
}
