import Foundation

@main
struct Phase25AContract {
    static func main() async throws {
        precondition(TranslationEngineID.openAICompatible.rawValue == "translationEngine.openAICompatible.v1")
        precondition(TranslationEngineID.appleSystem.rawValue == "translationEngine.appleSystem.v1")
        precondition(TranslationPromptPresetID.naturalSong.rawValue == "translationPrompt.naturalSong.v1")

        let defaults = AITranslationConfiguration()
        precondition(defaults.targetLanguage == "zh-Hans")
        precondition(defaults.style == "natural_song")
        precondition(defaults.temperature == 0.2)
        precondition(defaults.timeout == 60)
        precondition(defaults.autoTranslateNewLyrics == false)
        precondition(defaults.engineID == TranslationEngineID.openAICompatible.rawValue)
        precondition(defaults.fallbackStrategy == .none)

        let endpointCases: [(String, String)] = [
            ("https://example.test", "https://example.test/v1/models"),
            ("https://example.test/v1", "https://example.test/v1/models"),
            ("https://example.test/v1/chat/completions", "https://example.test/v1/models"),
            ("https://proxy.test/api/openai/v1/", "https://proxy.test/api/openai/v1/models")
        ]
        for (base, expected) in endpointCases {
            precondition(AITranslationEndpoint(baseURL: base).modelsURL.absoluteString == expected)
        }

        let catalog = TranslationEngineCatalog.all
        precondition(Set(catalog.map(\.stableID)).count == catalog.count)
        precondition(catalog.contains { $0.stableID == TranslationEngineID.appleSystem.rawValue })
        precondition(TranslationPromptPresetCatalog.all.count >= 5)
        precondition(TranslationPromptPresetCatalog.defaultPreset.id == .personalV2)
        print("phase 2.5A contracts passed")
    }
}
