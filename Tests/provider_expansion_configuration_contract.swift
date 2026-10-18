import Foundation

@main struct ProviderExpansionConfigurationContract {
    static func main() {
        let legacyOrder: [LyricsProviderID] = [.localFiles, .sqliteDatabase, .amll, .lrclib, .netEaseExperimental, .qqExperimental]
        let legacyEnabled: Set<LyricsProviderID> = [.localFiles, .sqliteDatabase, .lrclib]
        let added: Set<LyricsProviderID> = [.lyricsOVH, .kuwoExperimental, .kugouExperimental, .linkcore]
        let experimental: Set<LyricsProviderID> = [.netEaseExperimental, .qqExperimental, .kuwoExperimental, .kugouExperimental, .linkcore]
        let migrated = LyricsProviderConfiguration(enabled: legacyEnabled, order: legacyOrder)
        precondition(migrated.enabled == legacyEnabled.union(added), "Migration preserves explicit existing disables")
        precondition(Array(migrated.order.prefix(legacyOrder.count)) == legacyOrder, "Existing provider order must survive")
        var disabled = migrated
        for id in added { disabled.enabled.remove(id) }
        disabled.normalize()
        precondition(disabled.enabled == legacyEnabled, "New-source explicit disables must survive normalization")
        let restored = LyricsProviderConfiguration(enabled: disabled.enabled, order: disabled.order)
        precondition(restored == disabled, "Reload must not interpret an explicit disable as a missing provider")
        var repeated = restored
        repeated.normalize()
        precondition(repeated == restored)
        precondition(Set(LyricsProviderConfiguration.default.orderedEnabledIDs(for: .standardFree)).isDisjoint(with: experimental),
                     "Standard mode must block every experimental source even if preference-enabled")
        precondition(LyricsProviderConfiguration.default.orderedEnabledIDs(for: .standardFree).contains(.lyricsOVH))
        precondition(Set(LyricsProviderConfiguration.default.orderedEnabledIDs(for: .experimentalFree)).isSuperset(of: experimental))
        precondition(Set(restored.orderedEnabledIDs(for: .experimentalFree)) == legacyEnabled, "Changing mode must not enable disabled providers")
        precondition(Set(restored.order).count == restored.order.count)
        print("Provider expansion configuration contract PASS")
    }
}
