import Foundation
import XCTest
@testable import SpotifyLyrics

final class ExperienceLibraryPresentationTests: XCTestCase {
    func testCatalogPreviewAndSelectionBehavior() {
        let catalog = PresentationCatalog.shared
        let registry = PresentationPreviewRendererRegistry.shared

        for entry in catalog.entries where entry.supportsMockPreview {
            XCTAssertTrue(registry.hasRenderer(for: entry.stableID), "mock-preview entry has no renderer: \(entry.stableID)")
        }

        XCTAssertEqual(catalog.metadata(for: "capsule.immersiveCompact.v3")?.availability, .designOnly)
        XCTAssertEqual(catalog.metadata(for: "capsule.immersiveCompact.v3")?.isPreviewable, false)
        XCTAssertEqual(catalog.metadata(for: "capsule.controlFocused.v2")?.availability, .release)
        XCTAssertEqual(catalog.metadata(for: "capsule.controlFocused.v2")?.isPreviewable, true)
        XCTAssertEqual(catalog.metadata(for: "capsule.dynamicIslandDark.v4")?.availability, .release)
        XCTAssertEqual(catalog.metadata(for: "capsule.dynamicIslandDark.v4")?.status, .current)
        XCTAssertEqual(catalog.recommended(for: .capsule)?.stableID, "capsule.dynamicIslandDark.v4")

        let mainIDs = [
            "mainWindow.lyricsFocus.v1",
            "mainWindow.immersiveSplit.v2",
            "mainWindow.appleMusicImmersiveV3.v3"
        ]
        let mainSignatures = Set(mainIDs.compactMap { registry.signature(for: $0) })
        XCTAssertEqual(mainSignatures.count, 3, "main window adapters must have distinct signatures")

        let capsuleIDs = ["capsule.controlFocused.v2", "capsule.dynamicIslandDark.v4"]
        let capsuleSignatures = Set(capsuleIDs.compactMap { registry.signature(for: $0) })
        XCTAssertEqual(capsuleSignatures.count, 2, "v2 and v4 capsule adapters must differ")

        let backdropIDs = ["backdrop.clear.v1", "backdrop.immersive.v1"]
        let backdropSignatures = Set(backdropIDs.compactMap { registry.signature(for: $0) })
        XCTAssertEqual(backdropSignatures.count, 2, "clear and immersive backdrop adapters must differ")

        let context = PresentationPreviewContext.mock()
        let comparison = PresentationPreviewEngine().compare(
            leftID: "capsule.controlFocused.v2",
            rightID: "capsule.dynamicIslandDark.v4",
            context: context
        )
        XCTAssertEqual(comparison?.usesSameSnapshot, true, "A/B preview must share one immutable context")
        XCTAssertEqual(comparison?.context, context)

        XCTAssertEqual(SettingsCenterPresentationID.current.rawValue, "settingsCenter.experienceIntegrated.v2")
        XCTAssertTrue(SettingsCenterPresentationID.allCases.contains(.classicNavigationV1))
    }
}
