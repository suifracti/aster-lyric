import Combine

// Route-only host: no UserDefaults access or persistence is needed.
public final class AppSettingsStore: ObservableObject {
    public static let shared = AppSettingsStore()
    @Published public var menuBarLyricsEnabled = true
    @Published public var menuBarLyricsShowsFullLine = false
    @Published public var menuBarLyricsShowsOriginal = true
    @Published public var menuBarLyricsShowsTranslation = false
    @Published public var menuBarLyricsShowsKana = false
    @Published public var menuBarLyricsShowsRomaji = false
    @Published public var menuBarLyricsReadingsAbove = true
    @Published public var menuBarLyricsFontSize = 13.0
}
