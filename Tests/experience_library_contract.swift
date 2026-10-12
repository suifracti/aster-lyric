import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ExperienceLibraryContract {
    static func main() {
        let catalog = PresentationCatalog.shared
        let registry = PresentationPreviewRendererRegistry.shared

        for entry in catalog.entries where entry.supportsMockPreview {
            require(registry.hasRenderer(for: entry.stableID), "mock-preview entry has no renderer: \(entry.stableID)")
        }

        require(
            catalog.metadata(for: "capsule.immersiveCompact.v3")?.availability == .designOnly,
            "immersive compact v3 remains design-only"
        )
        require(
            catalog.metadata(for: "capsule.immersiveCompact.v3")?.isPreviewable == false,
            "design-only capsule must not claim runnable preview"
        )
        require(
            catalog.metadata(for: "capsule.controlFocused.v2")?.availability == .release
                && catalog.metadata(for: "capsule.controlFocused.v2")?.isPreviewable == true,
            "explicit control-focused v2 selections must remain runnable"
        )
        require(
            catalog.metadata(for: "capsule.dynamicIslandDark.v4")?.availability == .release,
            "dynamic-island dark v4 must be Release-capable"
        )
        require(
            catalog.metadata(for: "capsule.dynamicIslandDark.v4")?.status == .current,
            "dynamic-island dark v4 must remain the current capsule"
        )
        require(
            catalog.recommended(for: .capsule)?.stableID == "capsule.dynamicIslandDark.v4",
            "unset capsule selection must fall back to the current v4"
        )

        let mainIDs = [
            "mainWindow.lyricsFocus.v1",
            "mainWindow.immersiveSplit.v2",
            "mainWindow.appleMusicImmersiveV3.v3"
        ]
        let mainSignatures = Set(mainIDs.compactMap { registry.signature(for: $0) })
        require(mainSignatures.count == 3, "main window adapters must have distinct signatures")

        let capsuleIDs = ["capsule.controlFocused.v2", "capsule.dynamicIslandDark.v4"]
        let capsuleSignatures = Set(capsuleIDs.compactMap { registry.signature(for: $0) })
        require(capsuleSignatures.count == 2, "v2 and v4 capsule adapters must differ")

        let backdropIDs = ["backdrop.clear.v1", "backdrop.immersive.v1"]
        let backdropSignatures = Set(backdropIDs.compactMap { registry.signature(for: $0) })
        require(backdropSignatures.count == 2, "clear and immersive backdrop adapters must differ")

        let context = PresentationPreviewContext.mock()
        let comparison = PresentationPreviewEngine().compare(
            leftID: "capsule.controlFocused.v2",
            rightID: "capsule.dynamicIslandDark.v4",
            context: context
        )
        require(comparison?.usesSameSnapshot == true, "A/B preview must share one immutable context")
        require(comparison?.context == context, "A/B preview must preserve the same context")

        require(
            SettingsCenterPresentationID.current.rawValue == "settingsCenter.experienceIntegrated.v2",
            "experience-integrated settings center must remain the current shell"
        )
        require(
            SettingsCenterPresentationID.allCases.contains(.classicNavigationV1),
            "classic settings center identity must remain resolvable"
        )

        print("experience library contract: PASS")
    }
}
