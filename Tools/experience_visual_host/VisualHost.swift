// Appended only to a temporary Main.swift by build.py. Production entry is retained
// as an ordinary type; this test-only App is the sole executable entry point.
import SQLite3

private enum ExperienceArguments {
    static func value(_ key: String, fallback: String) -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return fallback }
        return args[index + 1]
    }
    static let root = URL(fileURLWithPath: "/tmp/lyrics-experience-visual-host/fixtures/run-\(UUID().uuidString)", isDirectory: true)
    static var databaseURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"]
            ?? root.appendingPathComponent("fixture.sqlite3").path)
    }
    static let surface = value("--surface", fallback: "main")
    static let size = CGSize(width: Double(value("--width", fallback: "1152")) ?? 1152, height: Double(value("--height", fallback: "720")) ?? 720)
    /// Optional real-song fixture exported read-only from the production
    /// database. Without it the host keeps its generated song and lyrics.
    static let fixture: ExperienceFixture? = {
        let path = value("--fixture-json", fallback: "")
        guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ExperienceFixture.self, from: data)
    }()
}

private struct ExperienceFixture: Decodable {
    struct Track: Decodable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let spotifyID: String?
    }
    struct Line: Decodable {
        let start: Double
        let end: Double?
        let original: String
        let kana: String?
        let romaji: String?
        let translation: String?
    }
    let track: Track
    let language: String?
    let lines: [Line]
}

@MainActor
private final class ExperiencePlaybackProvider: PlaybackProvider {
    let displayName = "Isolated visual fixture"
    var position: TimeInterval = Double(ExperienceArguments.value("--time", fallback: "18")) ?? 18
    var playing = false
    var track: ProviderTrack
    init(artwork: URL?) {
        if let fixture = ExperienceArguments.fixture {
            let spotifyID = fixture.track.spotifyID.map {
                $0.hasPrefix("spotify:") ? $0 : "spotify:track:\($0)"
            }
            track = ProviderTrack(id: spotifyID, title: fixture.track.title, artist: fixture.track.artist,
                                  album: fixture.track.album, duration: fixture.track.duration,
                                  artworkURL: artwork)
        } else {
            track = ProviderTrack(id: "spotify:track:visualfixture", title: "夜を越えて · After the rain", artist: "Visual Fixture", album: "Native rendering study", duration: 240, artworkURL: artwork)
        }
    }
    func refresh() async -> PlaybackSnapshot { PlaybackSnapshot(status: .ready, track: track, position: position, isPlaying: playing) }
    func play() async throws { playing = true }
    func pause() async throws { playing = false }
    func previous() async throws { position = 8 }
    func next() async throws { position = 28 }
    func seek(to position: TimeInterval) async throws { self.position = position; print("VISUAL_SEEK", position); fflush(stdout) }
}
private struct ExperienceLyricsProvider: LyricsProvider {
    let name = "Generated fixture lyrics"
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if let fixture = ExperienceArguments.fixture {
            let lines = fixture.lines.map {
                LyricLine(timestamp: $0.start, originalText: $0.original, endTime: $0.end,
                          translationText: $0.translation, romajiText: $0.romaji, kanaText: $0.kana)
            }
            return .match(LyricsDocument(identity: identity, title: track.title, artist: track.artist,
                                         album: track.album, duration: track.duration, lines: lines,
                                         isSynchronized: true, source: .local, confidence: 1,
                                         language: fixture.language ?? "ja"))
        }
        let rows = [
            "窓の向こうで 雨が静かにほどけてゆく",
            "灯りをたどって 僕らは歩き出す",
            "この夜を越えて、まだ見ぬ朝へ",
            "让每一句歌词，都能被安静地读完",
            "We keep the whole picture, even when the world grows small.",
            "そして また 会える日まで"
        ]
        var lines = rows.enumerated().map { index, text in
            var line = LyricLine(timestamp: Double(index) * 8, originalText: text)
            line.translationText = ["窗外的雨正在静静散去", "沿着灯光，我们开始前行", "越过今夜，走向未见的清晨", "Every line deserves a little room to breathe.", "即使世界变小，也保留完整的画面。", "直到我们再次相见"][index]
            return line
        }
        if ExperienceArguments.value("--countdown", fallback: "false") == "true" {
            for index in lines.indices { lines[index].timestamp += 10 }
        }
        if ExperienceArguments.value("--language", fallback: "japanese") == "chinese" {
            lines[2].originalText = "沿着微光前行，让歌声陪你到天明"
            lines[2].translationText = "Follow the light, let the song carry you to dawn."
        }
        if ProcessInfo.processInfo.arguments.contains("--long-line") {
            lines[2].originalText =  "この夜を越えて、まだ見ぬ朝へ。長い歌詞が表示領域を越えて切り落とされることなく、静かな読みやすさを保ちながら流れていく。"
        }
        if ProcessInfo.processInfo.arguments.contains("--aux-layers") {
            lines[2].kanaText = "このよるをこえて、まだみぬあさへ"
            lines[2].romajiText = "Kono yoru o koete, mada minu asa e"
        }
        if ProcessInfo.processInfo.arguments.contains("--ruby-correction") {
            lines[2].originalText = "身体にしてあげよう"
            lines[2].kanaText = "しんたいにしてあげよう"
        }
        if ProcessInfo.processInfo.arguments.contains("--missing-ruby") {
            lines[2].originalText = "既読の速度で愛はかって"
            lines[2].kanaText = nil
            lines[2].romajiText = nil
        }
        if ProcessInfo.processInfo.arguments.contains("--timed") {
            var offset = 0
            lines[2].timedSpans = lines[2].originalText.enumerated().map { index, character in
                let text = String(character)
                defer { offset += text.utf16.count }
                return TimedTextSpan(id: index, text: text, startTime: 16 + Double(index) * 0.4,
                                     endTime: 16 + Double(index + 1) * 0.4,
                                     utf16Start: offset, utf16Length: text.utf16.count)
            }
        }
        return .match(LyricsDocument(identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration, lines: lines, isSynchronized: true, source: ProcessInfo.processInfo.arguments.contains("--source-provenance") ? .neteaseExperimental : .local, confidence: 1))
    }
}

@MainActor
private enum ExperienceArtwork {
    static func make() -> URL? {
        let artworkPath = ExperienceArguments.value("--artwork-path", fallback: "")
        if !artworkPath.isEmpty {
            let source = URL(fileURLWithPath: artworkPath)
            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
            let destination = ExperienceArguments.root.appendingPathComponent("cover." + ext)
            do { try FileManager.default.copyItem(at: source, to: destination) } catch { return nil }
            guard let base = ProcessInfo.processInfo.environment["VISUAL_ARTWORK_BASE_URL"] else { return nil }
            return URL(string: base + "/" + ExperienceArguments.root.lastPathComponent + "/" + destination.lastPathComponent)
        }
        let kind = ExperienceArguments.value("--artwork", fallback: "square")
        guard kind != "none" else { return nil }
        let size: CGSize = kind == "panorama" ? CGSize(width: 1800, height: 360) : kind == "portrait" ? CGSize(width: 600, height: 900) : kind == "landscape" ? CGSize(width: 900, height: 540) : CGSize(width: 800, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = CGRect(origin: .zero, size: size)
        let bright = kind == "bright"
        NSColor(calibratedRed: bright ? 0.97 : 0.08, green: bright ? 0.94 : 0.12, blue: bright ? 0.86 : 0.20, alpha: 1).setFill()
        bounds.fill()
        let colors: [NSColor] = [.systemOrange, .systemPink, .systemIndigo]
        for (index, color) in colors.enumerated() {
            color.withAlphaComponent(0.72).setFill()
            NSBezierPath(ovalIn: CGRect(x: size.width * (0.05 + Double(index) * 0.19), y: size.height * (0.10 + Double(index) * 0.11), width: size.width * 0.73, height: size.height * 0.65)).fill()
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 5, dy: 5)); border.lineWidth = 10; border.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .bold), .foregroundColor: bright ? NSColor.black : NSColor.white]
        for (text, point) in [("TOP LEFT", CGPoint(x: 18, y: size.height-46)), ("TOP RIGHT", CGPoint(x:size.width-186,y:size.height-46)),("BOTTOM LEFT",CGPoint(x:18,y:18)),("BOTTOM RIGHT",CGPoint(x:size.width-230,y:18))] {
            (text as NSString).draw(at: point, withAttributes: attrs)
        }
        ("AFTER\nTHE RAIN" as NSString).draw(in: CGRect(x: 50, y: size.height*0.36, width: size.width-100, height: 210), withAttributes: [.font:NSFont.systemFont(ofSize:56,weight:.black),.foregroundColor:NSColor.white])
        if kind == "white" { NSColor.white.setFill(); bounds.fill() }
        if kind == "dark" { NSColor(calibratedWhite: 0.04, alpha: 1).setFill(); bounds.fill() }
        image.unlockFocus()
        guard let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) else { return nil }
        let url=ExperienceArguments.root.appendingPathComponent("\(kind).png")
        try? png.write(to:url)
        guard let base = ProcessInfo.processInfo.environment["VISUAL_ARTWORK_BASE_URL"] else { return nil }
        return URL(string: base + "/" + ExperienceArguments.root.lastPathComponent + "/" + url.lastPathComponent)
    }
}

private final class ExperienceVisualHostDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Offscreen capture must never take focus: a batch of snapshots would
        // otherwise shove the user's windows aside on every launch. An
        // accessory app still creates the WindowGroup window for cacheDisplay.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct ExperienceVisualHostApp: App {
    @NSApplicationDelegateAdaptor(ExperienceVisualHostDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettingsStore
    @StateObject private var playback: PlaybackState
    @StateObject private var adapter = DirectionDProductStateAdapter()
    init() {
        let root=ExperienceArguments.root
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults=UserDefaults(suiteName:"com.lyricsq.visual-fixture.\(UUID().uuidString)")!
        defaults.set(false,forKey:AppSettingsStore.Key.restoreWindowState)
        defaults.set(false,forKey:AppSettingsStore.Key.automaticAlignmentEnabled)
        if ProcessInfo.processInfo.arguments.contains("--aux-layers") {
            defaults.set(KanaDisplayMode.independentLine.rawValue, forKey: AppSettingsStore.Key.kanaDisplayMode)
        }
        for (argument, key) in [("--desktop-mode", "desktopLyrics.lineMode"), ("--desktop-theme", "desktopLyrics.theme"), ("--desktop-companion", "desktopLyrics.companion")] {
            let value = ExperienceArguments.value(argument, fallback: "")
            if !value.isEmpty { defaults.set(value, forKey: key) }
        }
        if let font = Double(ExperienceArguments.value("--desktop-font", fallback: "")) { defaults.set(font, forKey: "desktopLyrics.fontSize") }
        // Tool panels read the system appearance; this sets it for this
        // fixture process only (its own defaults domain).
        switch ExperienceArguments.value("--appearance", fallback: "") {
        case "dark": UserDefaults.standard.set("Dark", forKey: "AppleInterfaceStyle")
        case "light": UserDefaults.standard.set("Light", forKey: "AppleInterfaceStyle")
        default: break
        }
        let protection = ExperienceArguments.value("--reading-protection", fallback: "")
        if !protection.isEmpty { defaults.set(protection, forKey: AppSettingsStore.Key.v3ReadingProtection) }
        let settings=AppSettingsStore(defaults:defaults)
        if ProcessInfo.processInfo.arguments.contains("--model-fixture") {
            var configuration = settings.aiTranslationConfiguration
            configuration.engineID = TranslationEngineID.codexChatGPT.rawValue
            configuration.model = "fixture-alpha"
            settings.aiTranslationConfiguration = configuration
            let models = [TranslationModelDescriptor(id: "fixture-alpha", displayName: "Fixture Alpha", reasoningEfforts: ["medium"]),
                          TranslationModelDescriptor(id: "fixture-beta", displayName: "Fixture Beta", reasoningEfforts: ["high"])]
            defaults.set(try! JSONEncoder().encode([configuration.engineID: models]), forKey: TranslationModelSettingsStore.directoriesKey)
            _ = settings.translationModelSettings
        }
        settings.floatingWindowAlwaysOnTop = true
        precondition(!settings.v3StageReadabilityEnabled)
        settings.v3StageReadabilityEnabled = true
        precondition(AppSettingsStore(defaults: defaults).v3StageReadabilityEnabled)
        settings.v3StageReadabilityEnabled = ProcessInfo.processInfo.arguments.contains("--stage-readability")
        precondition(AppSettingsStore(defaults: defaults).v3StageReadabilityEnabled == settings.v3StageReadabilityEnabled)
        settings.v3PlaybackDetailsOnHover = ProcessInfo.processInfo.arguments.contains("--hover-details")
        precondition(AppSettingsStore(defaults: defaults).v3PlaybackDetailsOnHover == settings.v3PlaybackDetailsOnHover)
        if ProcessInfo.processInfo.arguments.contains("--desktop-custom") {
            settings.floatingDesktopOriginalColorHex = "FFFFFF"
            settings.floatingDesktopHighlightColorHex = "41FFB6"
            settings.floatingDesktopRubyColorHex = "FFE082"
            settings.floatingDesktopTranslationColorHex = "D2E5FF"
            settings.floatingDesktopOutlineColorHex = "121820"
        }
        if ProcessInfo.processInfo.arguments.contains("--ruby-correction") || ProcessInfo.processInfo.arguments.contains("--ruby-display") {
            var display = settings.displayPreferences
            display.showKana = true
            display.showRomaji = true
            display.kanaDisplayMode = .inlineRuby
            settings.displayPreferences = display
        }
        settings.v3ArtworkPresentation = V3ArtworkPresentation.allCases.first { $0.title == ExperienceArguments.value("--style-title",fallback:"") } ?? (ExperienceArguments.value("--style",fallback:"ambient") == "stage" ? .stage : ExperienceArguments.value("--style",fallback:"ambient") == "classic" ? .classic : .ambient)
        settings.v3BigLineModeEnabled = ExperienceArguments.value("--big-line", fallback: "false") == "true"
        if let preset = DisplayPreferences.ListeningLayerPreset(rawValue: ExperienceArguments.value("--layers", fallback: "")) {
            var preferences = settings.displayPreferences
            preferences.listeningLayerPreset = preset
            settings.displayPreferences = preferences
        }
        settings.v3ArtworkPosition=ExperienceArguments.value("--position",fallback:"left")
        let lyricPosition = ExperienceArguments.value("--lyric-position", fallback: "automatic")
        settings.v3LyricsPosition = lyricPosition
        precondition(AppSettingsStore(defaults: defaults).v3LyricsPosition == lyricPosition)
        let selectedStyle = settings.v3ArtworkPresentation
        settings.v3ArtworkPresentation = selectedStyle == .stage ? .ambient : .stage
        precondition(settings.v3LyricsPosition == "automatic")
        settings.v3ArtworkPresentation = selectedStyle
        precondition(settings.v3LyricsPosition == lyricPosition)
        if let scene = V3ListeningScene.allCases.first(where: { $0.rawValue == ExperienceArguments.value("--scene", fallback: "") || $0.rawValue == "scene.\(ExperienceArguments.value("--scene", fallback: "")).v1" }) {
            let renderer = V3ArtworkPresentation(rawValue: ExperienceArguments.value("--renderer", fallback: "")) ?? scene.defaultRenderer
            settings.selectV3Scene(scene, renderer: renderer)
        } else if let classic = V3ArtworkPresentation(rawValue: ExperienceArguments.value("--classic", fallback: "")) {
            settings.selectLegacyV3Presentation(classic)
        }
        if let scale=Double(ExperienceArguments.value("--scale",fallback:"")) { settings.v3ArtworkSizeScale=scale }
        if let blur=Double(ExperienceArguments.value("--blur",fallback:"")) { settings.v3BackdropBlurRadius=blur }
        let provider=ExperiencePlaybackProvider(artwork:ExperienceArtwork.make())
        let repository=SQLiteLyricsRepository(databaseURL:ExperienceArguments.databaseURL, alignmentProvenanceDirectory:root.appendingPathComponent("provenance"))
        _settings=StateObject(wrappedValue:settings)
        _playback=StateObject(wrappedValue:PlaybackState(provider:provider,lyricsProvider:ExperienceLyricsProvider(),lyricsRepository:repository,settings:settings))
        print("VISUAL_FIXTURE_ROOT",root.path)
    }
    var body: some Scene {
        WindowGroup("Experience visual fixture",id:"fixture-main") {
            ExperienceFixtureRoot(playback:playback,settings:settings)
                .environmentObject(settings)
                .environmentObject(playback)
                .environmentObject(adapter)
        }
        .defaultSize(width:ExperienceArguments.size.width,height:ExperienceArguments.size.height)
        .windowStyle(.hiddenTitleBar)
        Window("歌词库与收听记录", id: "personal-library-activity") {
            UnifiedLibraryHistoryWindowView().environmentObject(playback).environmentObject(settings)
                .environmentObject(SettingsDataController())
        }
        .defaultSize(width: 1000, height: 680)
        Window("歌词编辑", id: "lyrics-editor") {
            LyricsEditorWindowView().environmentObject(playback).environmentObject(settings)
        }
        Settings { SettingsRootView().environmentObject(settings).environmentObject(playback).environmentObject(SettingsDataController()) }
    }
}
private struct ExperienceFixtureRoot: View {
    @ObservedObject var playback:PlaybackState
    @ObservedObject var settings:AppSettingsStore
    @StateObject private var floatingController = FloatingLyricsWindowController()
    @StateObject private var capsuleController = CapsuleLyricsWindowController()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var layout=MainWindowLayoutStyle.appleMusicImmersiveV3.rawValue
    private var targetWindow: NSWindow? {
        NSApp.windows.first {
            switch ExperienceArguments.surface {
            case "floating": return String(describing: type(of: $0)).contains("FloatingLyricsPanel")
            case "capsule": return String(describing: type(of: $0)).contains("CapsuleLyricsPanel")
            case "fullscreen": return $0.title == "全屏歌词"
            default: return $0.title == "Experience visual fixture"
            }
        }
    }
    var body:some View {
        AppleMusicImmersiveV3WindowView(state:playback,settings:settings,layoutStyleRawValue:$layout)
            .preferredColorScheme(.dark)
            .onChange(of: floatingController.interactionMode) { mode in
                print("FLOATING_MODE", mode.rawValue)
                fflush(stdout)
            }
            .onChange(of: capsuleController.presentationState) { state in
                print("CAPSULE_STATE", String(describing: state))
                fflush(stdout)
            }
            .task {
                MenuBarLyricsController.shared.setOpenEditorHandler { openWindow(id: "lyrics-editor") }
                MenuBarLyricsController.shared.setOpenSettingsHandler { openSettings() }
                MenuBarLyricsController.shared.setOpenMainWindowHandler { openWindow(id: "fixture-main") }
                if ["library", "search"].contains(where: { ExperienceArguments.value("--panel", fallback: "").contains($0) }) {
                    let track = Track(id: "spotify:track:visualfixture", title: "夜を越えて · After the rain",
                        artist: "Visual Fixture", album: "Native rendering study", duration: 240,
                        spotifyId: "visualfixture", artworkURL: ExperienceArtwork.make())
                    let identity = TrackIdentity(track: track)
                    if case .match(let document) = await ExperienceLyricsProvider().lookup(track: track, identity: identity) {
                        let repository = SQLiteLyricsRepository(databaseURL: ExperienceArguments.databaseURL,
                            alignmentProvenanceDirectory: ExperienceArguments.root.appendingPathComponent("provenance"))
                        try! await repository.prepare()
                        let saved = try! await repository.save(track: track, identity: identity, document: document)
                        try! await repository.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey,
                                                                             lyricsVersionID: saved.versionID!)
                        let source = try! await repository.loadEditableVersion(versionID: saved.versionID!, track: track, identity: identity)!
                        for label in ["译文一", "译文二"] {
                            _ = try! await repository.saveTranslation(lyricsVersionID: source.record.id,
                                sourceContentHash: source.sourceContentHash,
                                originalLines: document.lines.map(\.originalText),
                                draft: AITranslationDraft(lines: document.lines.indices.map {
                                    AITranslationLine(index: $0, translation: label + " · " + String($0))
                                }, targetLanguage: "zh-Hans", model: label, baseURLHost: "", promptHash: label,
                                sourceContentHash: source.sourceContentHash, sourceKind: .manualImport,
                                isMachineGenerated: false, isManuallyEdited: true, engineID: label),
                                forceNewVersion: true)
                        }

                    }
                }
                playback.startProvider()
                try? await Task.sleep(for:.seconds(1))
                if ProcessInfo.processInfo.arguments.contains("--fullscreen-preview-isolation") {
                    let previewTrack = Track(id: "spotify:track:unplayedpreview",
                        title: "UNPLAYED PREVIEW — MUST NOT APPEAR FULLSCREEN", artist: "Preview artist",
                        album: "Preview album", duration: 240)
                    let previewLine = LyricLine(timestamp: 0, originalText: "PREVIEW LYRICS — MUST NOT APPEAR FULLSCREEN")
                    let previewDocument = LyricsDocument(identity: TrackIdentity(track: previewTrack), title: previewTrack.title,
                        artist: previewTrack.artist, album: previewTrack.album, duration: previewTrack.duration,
                        lines: [previewLine], isSynchronized: false, source: .local, confidence: 1)
                    playback.loadSearchResult(SongSearchResult(id: "fixture-preview", source: .local, track: previewTrack,
                        confidence: 1, lyrics: previewDocument))
                    try? await Task.sleep(for: .milliseconds(500))
                    precondition(playback.isShowingSearchPreview && playback.liveLyrics != playback.lyrics)
                }
                if ExperienceArguments.surface == "fullscreen" {
                    WindowManager.shared.showFullScreen(state: playback, settings: settings)
                    for _ in 0..<60 {
                        if WindowManager.shared.fullScreenWindow?.styleMask.contains(.fullScreen) == true { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    precondition(WindowManager.shared.fullScreenWindow?.styleMask.contains(.fullScreen) == true)
                    print("FULLSCREEN_NATIVE_ENTERED", settings.v3ArtworkPresentation.rawValue)
                }
                if ExperienceArguments.surface == "floating" { floatingController.show(state: playback, settings: settings) }
                if ExperienceArguments.surface == "capsule" {
                    capsuleController.show(state: playback, settings: settings)
                    if ExperienceArguments.value("--capsule-state", fallback: "collapsed") == "expanded" { capsuleController.expand() }
                }
                if ProcessInfo.processInfo.arguments.contains("--copy-contract") {
                    var first = LyricLine(timestamp: 68, originalText: "身体にしてあげよう")
                    first.kanaText = "からだにしてあげよう"
                    first.romajiText = "karada ni shite ageyou"
                    first.translationText = "让身体…"
                    let last = LyricLine(timestamp: 72, originalText: "またね")
                    let lines = [first, last]
                    precondition(LyricsCopyText.format(lines) == "身体にしてあげよう\nまたね")
                    precondition(LyricsCopyText.format(lines, original: false, kana: true) == "からだにしてあげよう")
                    precondition(LyricsCopyText.format(lines, romaji: true, translation: true) == "身体にしてあげよう\nkarada ni shite ageyou\n让身体…\n\nまたね")
                    precondition(LyricsCopyText.format(lines, original: false).isEmpty)
                    precondition(LyricsCopyText.format([]).isEmpty)
                    precondition(lines[0].timestamp == 68 && lines[0].originalText == first.originalText)
                    precondition(LyricsCopyText.format(lines, selectedIndices: [1]) == "またね")
                    precondition(LyricsCopyText.format(lines, selectedIndices: []).isEmpty)
                    precondition(LyricsCopyText.format(lines, kana: true, selectedIndices: [0, 99]) == "身体にしてあげよう\nからだにしてあげよう")
                    let scope = "spotify-id:copy-fixture|metadata:copy|singer|album|170"
                    let correction = try! ReadingRubyCorrection.entry(surface: "身体", reading: "からだ", trackStableKey: scope)
                    let raw = LyricLine(timestamp: 68, originalText: "身体にしてあげよう", translationText: "保留翻译")
                    let automatic = LyricsCopyText.resolvingReadings([raw], trackStableKey: scope, artistDisplay: "Singer", language: "ja", userEntries: [correction])
                    precondition(automatic[0].kanaText == "からだにしてあげよう")
                    precondition(automatic[0].romajiText?.contains("karada") == true)
                    precondition(automatic[0].translationText == "保留翻译" && automatic[0].timestamp == raw.timestamp)
                    precondition(raw.kanaText == nil && raw.romajiText == nil)
                    let confirmed = LyricsCopyText.resolvingReadings([first], trackStableKey: scope, artistDisplay: "Singer", language: "ja", userEntries: [])
                    precondition(confirmed[0].kanaText == first.kanaText && confirmed[0].romajiText == first.romajiText && confirmed[0].translationText == first.translationText)
                    let chinese = LyricsCopyText.resolvingReadings([LyricLine(timestamp: 0, originalText: "你好世界")], trackStableKey: nil, artistDisplay: nil, language: "zh", userEntries: [])
                    precondition(chinese[0].kanaText == nil && chinese[0].romajiText == nil)
                    let unknownHan = LyricsCopyText.resolvingReadings([LyricLine(timestamp: 0, originalText: "身体")], trackStableKey: nil, artistDisplay: nil, language: nil, userEntries: [])
                    precondition(unknownHan[0].kanaText == nil && unknownHan[0].romajiText == nil)
                    print("LYRICS_COPY_CONTRACT_PASS")
                }
                try? await Task.sleep(for:.seconds(2))
                if ProcessInfo.processInfo.arguments.contains("--ruby-save-contract") {
                    do {
                        guard let versionID = playback.liveLyricsVersionID,
                              let trackKey = playback.currentTrackIdentity?.stableKey else { fatalError("Missing persisted fixture") }
                        let before = playback.liveLyrics
                        try await playback.readingSession.correctRuby(surface: "身体", reading: "からだ", trackKey: trackKey,
                            lyricsVersionID: versionID, visibleLines: before, expectedReadingVersionID: playback.readingSession.selectedVersion?.record.id)
                        guard let saved = playback.readingSession.selectedVersion else { fatalError("No saved manual version") }
                        precondition(saved.record.isManuallyEdited)
                        precondition(saved.lines[2].readingText == "からだにしてあげよう")
                        precondition(playback.liveLyrics[2].kanaText == "からだにしてあげよう", "Playback projection cache did not update")
                        let projected = playback.readingSession.project(onto: before)
                        precondition(projected[2].romajiText?.contains("karada") == true)
                        precondition(projected[2].originalText == before[2].originalText && projected[2].timestamp == before[2].timestamp)
                        precondition(settings.readingUserDictionary.load().contains { $0.trackStableKey == trackKey && $0.reading == "からだ" })
                        do {
                            try await playback.readingSession.correctRuby(surface: "身体", reading: "からだ", trackKey: "wrong-song",
                                lyricsVersionID: versionID, visibleLines: before, expectedReadingVersionID: playback.readingSession.selectedVersion?.record.id)
                            fatalError("Stale song accepted")
                        } catch ReadingRepositoryError.sourceContentMismatch {}
                        playback.readingSession.reload()
                        try? await Task.sleep(for: .seconds(1))
                        precondition(playback.readingSession.selectedVersion?.record.id == saved.record.id)
                        try await playback.readingSession.correctRuby(surface: "身体", reading: "カラダ", trackKey: trackKey,
                            lyricsVersionID: versionID, visibleLines: playback.liveLyrics, expectedReadingVersionID: saved.record.id)
                        let secondID = playback.readingSession.selectedVersion!.record.id
                        precondition(secondID != saved.record.id)
                        playback.readingSession.restoreRecommended()
                        precondition(playback.readingSession.selectedVersion?.record.id == secondID)
                        precondition(playback.readingSession.availableVersions.first(where: { $0.record.id == saved.record.id })?.lines == saved.lines)
                        do {
                            try await playback.readingSession.correctRuby(surface: "身体", reading: "からだ", trackKey: trackKey,
                                lyricsVersionID: versionID, visibleLines: before, expectedReadingVersionID: saved.record.id)
                            fatalError("Stale reading accepted")
                        } catch ReadingRepositoryError.invalidLines(_) {}
                        print("RUBY_SAVE_CONTRACT_PASS")
                        fflush(stdout)
                    } catch { fatalError("Ruby save failed: \(error)") }
                }
                for window in NSApp.windows where window.title == "Experience visual fixture" {
                    window.setContentSize(ExperienceArguments.size)
                    window.center()
                }
                if ExperienceArguments.surface == "floating", let panel = targetWindow as? NSPanel {
                    panel.setContentSize(ExperienceArguments.size)
                    panel.center()
                    if ExperienceArguments.value("--desktop-backdrop", fallback: "") == "light", let content = panel.contentView {
                        let backing = NSView(frame: content.frame)
                        backing.wantsLayer = true
                        backing.layer?.backgroundColor = NSColor.white.cgColor
                        panel.contentView = backing
                        content.frame = backing.bounds
                        content.autoresizingMask = [.width, .height]
                        backing.addSubview(content)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--floating-behavior-checks") {
                        floatingController.setInteractionMode(.locked)
                        precondition(!panel.isMovable && !panel.isMovableByWindowBackground && !panel.styleMask.contains(.resizable) && !panel.ignoresMouseEvents)
                        floatingController.setInteractionMode(.passThrough)
                        precondition(panel.ignoresMouseEvents && !panel.isMovable && !panel.styleMask.contains(.resizable))
                        floatingController.restoreInteractiveMode()
                        precondition(panel.isMovable && panel.isMovableByWindowBackground && panel.styleMask.contains(.resizable) && !panel.ignoresMouseEvents)
                        let visible = NSRect(x: -1280, y: -200, width: 1280, height: 800)
                        let safe = FloatingLyricsWindowPersistence.shared.clamp(NSRect(x: -2000, y: -400, width: 2000, height: 1000), to: visible)
                        precondition(visible.contains(safe) && safe.width == 960 && safe.height == 640)
                        print("FLOATING_BEHAVIOR_CHECKS_PASSED")
                    }
                    floatingController.setInteractionMode(FloatingLyricsInteractionMode(rawValue: ExperienceArguments.value("--floating-mode", fallback: "interactive")) ?? .interactive)
                }
                try? await Task.sleep(for:.seconds(1))
                if ProcessInfo.processInfo.arguments.contains("--fullscreen-behavior-checks") {
                    let originalWindow = WindowManager.shared.fullScreenWindow!
                    precondition(originalWindow.level == .normal && originalWindow.collectionBehavior.contains(.fullScreenPrimary))
                    WindowManager.shared.hideFullScreen()
                    for _ in 0..<80 {
                        if !WindowManager.shared.fullScreenWindowIsVisible { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    precondition(!WindowManager.shared.fullScreenWindowIsVisible && !playback.showFullScreen)
                    WindowManager.shared.showFullScreen(state: playback, settings: settings)
                    for _ in 0..<80 {
                        if originalWindow.styleMask.contains(.fullScreen) { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    precondition(WindowManager.shared.fullScreenWindow === originalWindow && originalWindow.styleMask.contains(.fullScreen))
                    print("FULLSCREEN_BEHAVIOR_CHECKS_PASSED")
                    fflush(stdout)
                }
                // Toolbar states normally need a real pointer; the main view
                // accepts these through a DEBUG-only notification.
                let toolbar = ExperienceArguments.value("--toolbar", fallback: "")
                let panel = ExperienceArguments.value("--panel", fallback: "")   // hover/pin: library, search, translation, text, picture, more
                if !toolbar.isEmpty {
                    NotificationCenter.default.post(name: .v3ToolbarDebugCommand, object: nil, userInfo: ["command": toolbar])
                }
                if panel.contains(":") {
                    let parts = panel.split(separator: ":").map(String.init)
                    NotificationCenter.default.post(name: .v3ToolbarDebugCommand, object: nil,
                                                    userInfo: ["command": parts[0], "panel": parts[1]])
                }
                if !toolbar.isEmpty || !panel.isEmpty { try? await Task.sleep(for: .milliseconds(800)) }
                let drawer = ExperienceArguments.value("--drawer", fallback: "")
                if !drawer.isEmpty {
                    NotificationCenter.default.post(name: .v3ToolbarDebugCommand, object: nil,
                        userInfo: ["command": "drawer", "panel": drawer])
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if !panel.isEmpty {
                    // Popovers and the pinned panel appear asynchronously.
                    for _ in 0..<40 {
                        let main = targetWindow
                        if NSApp.windows.contains(where: { $0 !== main && $0.isVisible && $0.frame.width > 120 && $0.frame.height > 120 }) { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                var extraWindow: NSWindow?
                if ["menubar", "settings", "models", "search-panel", "search-full"].contains(ExperienceArguments.surface) {
                    MenuBarLyricsController.shared.bind(playbackState: playback)
                    let root: AnyView
                    if ExperienceArguments.surface == "search-panel" {
                        root = AnyView(V3ToolbarQuickControls(panel: .search, state: playback,
                            search: playback.songSearchManager, openLibrary: {}, openSearch: {}) { EmptyView() }
                            .background(Color(nsColor: .windowBackgroundColor)))
                    } else if ExperienceArguments.surface == "search-full" {
                        root = AnyView(SongSearchPopover(manager: playback.songSearchManager, playbackState: playback)
                            .background(Color(nsColor: .windowBackgroundColor)))
                    } else if ExperienceArguments.surface == "models" {
                        root = AnyView(TranslationProviderControls(settings: settings)
                            .padding(16).frame(width: 360)
                            .background(Color(nsColor: .windowBackgroundColor)))
                    } else if ExperienceArguments.surface == "menubar" {
                        root = AnyView(MenuBarLyricsPopoverView(controller: MenuBarLyricsController.shared))
                    } else {
                        root = AnyView(SettingsRootView().environmentObject(settings).environmentObject(playback).environmentObject(SettingsDataController()))
                    }
                    let hosting = NSHostingView(rootView: root.environment(\.colorScheme, ExperienceArguments.value("--appearance", fallback: "dark") == "light" ? .light : .dark))
                    let size = ExperienceArguments.surface == "search-full" ? CGSize(width: 440, height: 470)
                        : ["models", "search-panel"].contains(ExperienceArguments.surface) ? CGSize(width: 360, height: 520)
                        : ExperienceArguments.surface == "menubar" ? CGSize(width: 340, height: 560) : ExperienceArguments.size
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                    window.title = "Experience extra surface"
                    window.appearance = NSAppearance(named: ExperienceArguments.value("--appearance", fallback: "dark") == "light" ? .aqua : .darkAqua)
                    window.contentView = hosting
                    window.orderFront(nil)
                    extraWindow = window
                    try? await Task.sleep(for: .milliseconds(1500))
                }
                let output=ExperienceArguments.value("--output",fallback:"")
                func render(_ view: NSView, to path: String) {
                    print("CAPTURING", path); fflush(stdout)
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path)); print("RENDERED", path)
                    }
                }
                if !output.isEmpty {
                    let primary = extraWindow ?? targetWindow
                    if let view = primary?.contentView { render(view, to: output) }
                    // Also capture tool windows (hover popover, pinned panel).
                    let base = (output as NSString).deletingPathExtension
                    var index = 0
                    for window in NSApp.windows where window.isVisible && window !== primary
                        && window !== targetWindow && window.frame.width > 120 && window.frame.height > 120 {
                        index += 1
                        if let view = window.contentView {
                            render(view, to: "\(base)-panel\(index).png")
                        }
                    }
                }
                print("WINDOWS",NSApp.windows.map { "\($0.windowNumber):\($0.title):\($0.frame)" })
                if ProcessInfo.processInfo.arguments.contains("--keep-open"), ExperienceArguments.surface != "main", let panel = extraWindow ?? targetWindow {
                    NSApp.windows.first { $0.title == "Experience visual fixture" }?.orderOut(nil)
                    panel.makeKeyAndOrderFront(nil)
                } else if !ProcessInfo.processInfo.arguments.contains("--keep-open") { NSApp.terminate(nil) }
            }
    }
}
