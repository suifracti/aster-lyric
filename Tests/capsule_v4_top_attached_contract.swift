import Foundation
import CoreGraphics

@main
struct CapsuleV4TopAttachedContract {
    static func main() {
        precondition(CapsuleLyricsPresentationVersion.current == .dynamicIslandDarkV4, "Product default must restore the island")
        var interaction = CapsuleExpansionInteraction()
        interaction.expanded(explicit: true, pointerInside: false)
        precondition(!interaction.permitsHoverCollapse, "AX expansion must survive pointer-out without an entry")
        interaction.pointerEntered()
        precondition(interaction.permitsHoverCollapse, "After actual entry, ordinary hover exit resumes")
        precondition(!interaction.permitsHoverCollapse(menuPresented: true), "More popover holds expansion regardless of pointer position")
        precondition(interaction.permitsHoverCollapse(menuPresented: false))
        interaction.expanded(explicit: false, pointerInside: true)
        precondition(interaction.permitsHoverCollapse, "Dwell expansion never pins hover")
        interaction.expanded(explicit: true, pointerInside: true)
        precondition(interaction.permitsHoverCollapse, "Mouse click expansion exits normally")
        interaction.expanded(explicit: true, pointerInside: false)
        interaction.reset()
        precondition(interaction.permitsHoverCollapse)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let envelope = CapsuleDynamicIslandDarkV4.debugEnvelopeSize

        precondition(envelope == CGSize(width: 680, height: 240))

        let windowFrame = CapsuleDynamicIslandDarkV4.topAttachedEnvelopeFrame(
            screenFrame: screen
        )
        precondition(windowFrame.width == envelope.width)
        precondition(windowFrame.height == envelope.height)
        precondition(windowFrame.midX == screen.midX)
        precondition(windowFrame.maxY == screen.maxY)
        precondition(windowFrame.minY == screen.maxY - envelope.height)

        let collapsed = CapsuleDynamicIslandDarkV4.topAttachedIslandFrame(
            for: .collapsed,
            envelopeSize: envelope
        )
        let hover = CapsuleDynamicIslandDarkV4.topAttachedIslandFrame(
            for: .hover,
            envelopeSize: envelope
        )
        let expanded = CapsuleDynamicIslandDarkV4.topAttachedIslandFrame(
            for: .expanded,
            envelopeSize: envelope
        )

        for island in [collapsed, hover, expanded] {
            precondition(island.midX == envelope.width / 2)
            precondition(island.maxY == envelope.height)
        }
        precondition(expanded.minY < hover.minY)
        precondition(hover.minY < collapsed.minY)

        let narrowScreen = CGRect(x: -100, y: 20, width: 320, height: 150)
        let clampedFrame = CapsuleDynamicIslandDarkV4.topAttachedEnvelopeFrame(
            screenFrame: narrowScreen
        )
        precondition(clampedFrame.width == 320)
        precondition(clampedFrame.height == 150)
        precondition(clampedFrame.midX == narrowScreen.midX)
        precondition(clampedFrame.maxY == narrowScreen.maxY)

        let notch = CapsuleNotchGeometry(screenFrame: screen, safeTopInset: 32,
            auxiliaryLeft: CGRect(x: 0, y: 868, width: 620, height: 32),
            auxiliaryRight: CGRect(x: 820, y: 868, width: 620, height: 32))
        precondition(notch.reservedWidth == 216)
        precondition(notch.expandedContentTop >= 40)
        precondition(notch.size(for: .collapsed).height >= notch.depth + 22,
                     "The compact lyric must fit completely below the physical camera")
        precondition(notch.size(for: .collapsed).width >= notch.reservedWidth + 88)
        precondition(notch.size(for: .expanded).height >= notch.expandedContentTop + CapsuleDynamicIslandDarkV4.expandedSize.height)
        let external = CGRect(x: -1800, y: -300, width: 1800, height: 1000)
        let externalGeometry = CapsuleNotchGeometry(screenFrame: external, safeTopInset: 0)
        let externalEnvelope = CapsuleDynamicIslandDarkV4.topAttachedEnvelopeFrame(screenFrame: external)
        precondition(externalEnvelope.midX == -900 && externalEnvelope.maxY == 700)
        precondition(externalGeometry.depth == 0)
        let missingAuxiliary = CapsuleNotchGeometry(screenFrame: screen, safeTopInset: 32)
        precondition(missingAuxiliary.reservedWidth >= 200, "Missing auxiliary regions must fail safe")
        let fallback = CapsuleNotchGeometry(screenFrame: screen, safeTopInset: 0)
        precondition(fallback.reservedWidth == 0)
        precondition(fallback.expandedContentTop == 0)
        let grown = notch.islandFrame(for: .expanded, envelopeSize: envelope)
        precondition(!notch.contains(CGPoint(x: grown.midX, y: grown.minY + 30),
            state: .expanded, restrictingTo: .collapsed, envelopeSize: envelope),
            "Expanding transparent region cannot become clickable before rendered")
        let hit = notch.islandFrame(for: .collapsed, envelopeSize: envelope)
        precondition(notch.contains(CGPoint(x: hit.midX, y: hit.midY), state: .collapsed, envelopeSize: envelope))
        precondition(!notch.contains(CGPoint(x: 1, y: 1), state: .collapsed, envelopeSize: envelope))
        precondition(!notch.contains(CGPoint(x: hit.minX, y: hit.minY), state: .collapsed, envelopeSize: envelope))
        print("capsule v4 top-attached contract passed")
    }
}
