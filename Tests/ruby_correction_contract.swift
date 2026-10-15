import Foundation

@main struct RubyCorrectionContract {
    static func main() async throws {
        let entry = try ReadingRubyCorrection.entry(surface: "身体", reading: "カラダ", trackStableKey: "song-a")
        precondition(entry.reading == "からだ")
        for invalid in ["", "karada", "身体", "からだ1"] {
            do { _ = try ReadingRubyCorrection.entry(surface: "身体", reading: invalid, trackStableKey: "song-a"); fatalError("accepted invalid kana") } catch {}
        }
        let line = LyricLine(timestamp: 68, originalText: "身体にしてあげよう", kanaText: "しんたいにしてあげよう")
        let corrected = try ReadingRubyCorrection.lines([line], entry: entry)
        precondition(corrected[0].readingText == "からだにしてあげよう")
        precondition(corrected[0].originalText == line.originalText)
        let projected = ReadingRubyCorrection.project(corrected[0], onto: line)
        precondition(projected.rubyTokens?.contains { $0.surface == "身体" && $0.ruby == "からだ" } == true)
        precondition(projected.romajiText?.contains("karada") == true)
        precondition(projected.timestamp == line.timestamp)
        precondition(line.kanaText == "しんたいにしてあげよう")
        let scoped = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: [entry], trackStableKey: "song-a")
        precondition(scoped.kanaText == "からだにしてあげよう")
        precondition(scoped.romajiText?.contains("karada") == true)
        let other = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: [entry], trackStableKey: "song-b")
        precondition(other.kanaText?.contains("しんたい") == true)
        let broad = ReadingDictionaryEntry(surface: "身体", reading: "しんたい", language: .japanese, priority: 999)
        let artist = ReadingDictionaryEntry(surface: "身体", reading: "み", language: .japanese, artistScope: "Synthetic Artist", priority: 100)
        let song = ReadingDictionaryEntry(surface: "身体", reading: "からだ", language: .japanese, trackStableKey: "song-a", priority: -100)
        let rules = [broad, artist, song]
        let exactSong = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: rules, trackStableKey: "song-a", artistDisplay: "Synthetic Artist")
        precondition(exactSong.kanaText == "からだにしてあげよう", "A song correction must override broader high-priority rules")
        let sameArtist = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: rules, trackStableKey: "song-b", artistDisplay: "Synthetic Artist")
        precondition(sameArtist.kanaText == "みにしてあげよう", "An artist correction must override global rules only for that artist")
        let unrelatedArtist = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: rules, trackStableKey: "song-c", artistDisplay: "Other")
        precondition(unrelatedArtist.kanaText == "しんたいにしてあげよう", "Song and artist rules must not leak")
        let originalScope = "spotify-id:recording-a|metadata:夜の合図|kawasakirio|夜の合図|170"
        let driftedScope = "spotify-id:recording-a|metadata:夜の合図|kawasakirio|夜の合図|171"
        let remembered = try ReadingRubyCorrection.entry(surface: "身体", reading: "からだ", trackStableKey: originalScope)
        let regenerated = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: [remembered], trackStableKey: driftedScope)
        precondition(regenerated.kanaText == "からだにしてあげよう", "Subsecond playback duration drift must retain the same song's correction")
        precondition(regenerated.romajiText?.contains("karada") == true)
        for unrelatedScope in [
            "spotify-id:recording-b|metadata:夜の合図|kawasakirio|夜の合図|170",
            "spotify-id:recording-a|metadata:夜の合図|anotherartist|夜の合図|170",
            "spotify-id:recording-a|metadata:夜の合図|kawasakirio|anotheralbum|170",
            "spotify-id:recording-a|metadata:anothertrack|kawasakirio|夜の合図|170",
            "spotify-id:recording-a|metadata:夜の合図|kawasakirio|夜の合図|173",
            "metadata:夜の合図|kawasakirio|夜の合図|170"
        ] {
            precondition(ReadingEngineSupport.applicableUserEntries([remembered], trackStableKey: unrelatedScope, artistDisplay: nil).isEmpty,
                         "Do not leak a remembered correction into another song or ambiguous metadata")
        }
        let unaligned = ReadingLineResult(lineIndex: 0, originalText: "未知の歌詞", readingText: "とくべつなうた", language: .japanese,
            tokens: [ReadingToken(id: 0, surface: "未知の歌詞", reading: "とくべつなうた", startOffset: 0, endOffset: 5, source: .provider, confidence: 1)], confidence: 1)
        precondition(ReadingRubyCorrection.project(unaligned, onto: LyricLine(timestamp: 0, originalText: unaligned.originalText)).rubyTokens == nil)
        let manual = LyricLine(timestamp: 0, originalText: "身体 私", kanaText: "しんたい あたし")
        let preserved = try ReadingRubyCorrection.lines([manual], entry: entry)
        precondition(preserved[0].readingText == "からだ あたし", "Unrelated provider reading changed")
        let suite = "ruby-correction-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ReadingUserDictionaryStore(defaults: defaults).upsert(entry)
        precondition(ReadingUserDictionaryStore(defaults: defaults).load() == [entry])
        let dictionary = ReadingUserDictionaryStore(defaults: defaults)
        let global = ReadingDictionaryEntry(surface: "身体", reading: "しんたい", language: .japanese)
        dictionary.upsert(global)
        dictionary.rememberSongCorrection(remembered)
        let replacement = try ReadingRubyCorrection.entry(surface: "身体", reading: "み", trackStableKey: driftedScope)
        dictionary.rememberSongCorrection(replacement)
        let persisted = dictionary.load()
        precondition(persisted.contains(entry) && persisted.contains(global), "Other song and global rules must survive replacement")
        precondition(!persisted.contains(remembered) && persisted.contains(replacement), "Updating through a duration alias must replace the previous song rule")
        let replaced = JapaneseContextualReadingEngine.analyze(text: line.originalText, userEntries: persisted, trackStableKey: originalScope)
        precondition(replaced.kanaText == "みにしてあげよう", "The newest song correction must win from either key")
        precondition(ReadingEngineSupport.matchesSongScope(originalScope,
            trackStableKey: "spotify-id:spotify:track:recording-a|metadata:夜の合図|kawasakirio|夜の合図|171"))
        precondition(!ReadingEngineSupport.matchesSongScope(originalScope, trackStableKey: nil))
        print("ruby correction PASS")
    }
}
