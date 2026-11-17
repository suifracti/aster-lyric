import Foundation
import CoreGraphics

@main
struct CapsuleV4ShapeContract {
    static func main() {
        precondition(CapsuleDynamicIslandDarkV4.collapsedSize == CGSize(width: 312, height: 40))
        precondition(CapsuleDynamicIslandDarkV4.hoverSize == CGSize(width: 332, height: 44))
        precondition(CapsuleDynamicIslandDarkV4.expandedSize == CGSize(width: 600, height: 188))

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let collapsed = CapsuleDynamicIslandDarkV4.topCenteredFrame(
            for: .collapsed,
            visibleFrame: visible,
            safeTopInset: 24
        )
        let expanded = CapsuleDynamicIslandDarkV4.topCenteredFrame(
            for: .expanded,
            visibleFrame: visible,
            safeTopInset: 24
        )

        precondition(collapsed.midX == visible.midX)
        precondition(expanded.midX == visible.midX)
        precondition(collapsed.maxY == expanded.maxY)
        precondition(expanded.minY < collapsed.minY)

        let clamped = CapsuleDynamicIslandDarkV4.topCenteredFrame(
            for: .expanded,
            visibleFrame: CGRect(x: 40, y: 20, width: 280, height: 120),
            safeTopInset: 20,
            horizontalOffset: 500
        )
        precondition(clamped.width == 280)
        precondition(clamped.height == 100)
        precondition(clamped.minX == 40)
        precondition(clamped.maxY == 120)

        print("capsule v4 shape contract passed")
    }
}
