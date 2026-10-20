import Foundation
import SQLite3
import XCTest
@testable import SpotifyLyrics

final class LibraryIdentitySearchContractTests: XCTestCase {
    func testIdentityGroupingSearchExportAndCrossKeySelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-identity-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("test.sqlite3")
        let repo = SQLiteLyricsRepository(
            databaseURL: databaseURL,
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await repo.prepare()
        func save(_ track: Track, text: String) async throws -> UUID {
            let identity = TrackIdentity(track: track)
            let document = LyricsDocument(
                identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
                lines: [LyricLine(timestamp: 1, originalText: text, translationText: "legacytranslation", romajiText: "legacyromaji", kanaText: "れがしーかな")],
                isSynchronized: true, source: .lrclib, confidence: 0.95, providerSourceID: text
            )
            let saved = try await repo.save(track: track, identity: identity, document: document)
            return try XCTUnwrap(saved.versionID)
        }

        let a = Track(title: "Family fixture", artist: "Singer", album: "Album", duration: 170, spotifyId: "family-song")
        let b = Track(title: a.title, artist: a.artist, album: a.album, duration: 170.72, spotifyId: "family-song")
        let unrelated = Track(title: a.title, artist: a.artist, album: a.album, duration: 170, spotifyId: "different-song")
        let conflict = Track(title: a.title, artist: "Different singer", album: a.album, duration: 170, spotifyId: "family-song")
        let aID = try await save(a, text: "原版独有歌词")
        let bID = try await save(b, text: "新版独有歌词")
        let unrelatedID = try await save(unrelated, text: "unrelated")
        _ = try await save(conflict, text: "conflict")
        let historical = Track(title: "Historical metadata", artist: "Historical singer", album: "Old album", duration: 99, spotifyId: "historical-id")
        let historicalID = try await save(historical, text: "historical-only")
        _ = try await save(Track(title: "Duration conflict", artist: "Singer", album: "Album", duration: 100, spotifyId: "duration-conflict"), text: "short recording")
        _ = try await save(Track(title: "Duration conflict", artist: "Singer", album: "Album", duration: 130, spotifyId: "duration-conflict"), text: "long recording")
        _ = try await save(Track(title: a.title, artist: a.artist, album: a.album, duration: a.duration), text: "metadata-only")

        let readingID = UUID()
        let translationID = UUID()
        let fixtureSQL = """
        INSERT INTO track_identity_redirects VALUES ('\(TrackIdentity(track: historical).stableKey)', '\(TrackIdentity(track: a).stableKey)', 'fixture', 'fixture', 'fixture', 1);
        INSERT INTO reading_versions(id,lyrics_version_id,source_content_hash,engine_id,representation_id,created_at,updated_at)
        VALUES ('\(readingID)','\(bID)','fixture','fixture','readingRepresentation.kana',1,1);
        INSERT INTO reading_lines(reading_version_id,line_index,original_text,reading_text)
        VALUES ('\(readingID)',0,'新版独有歌词','からだ savedreadingneedle');
        INSERT INTO translation_versions(id,lyrics_version_id,source_kind,target_language,source_content_hash,created_at,updated_at,status)
        VALUES ('\(translationID)','\(aID)','manualEdit','zh','fixture',1,1,'complete');
        INSERT INTO translation_lines VALUES ('\(translationID)',0,'保存译文独有词');
        INSERT INTO track_aliases(track_stable_key,field,kind,value,script,source,confidence,is_official)
        VALUES ('\(TrackIdentity(track: b).stableKey)','title','userAlias','Alternative title','latin','user',1,0);
        """
        try executeSQL(fixtureSQL, at: databaseURL)

        let entries = try await repo.loadPersonalLibraryEntries()
        XCTAssertEqual(entries.count, 6, "Same Spotify recording with subsecond duration drift must occupy one row; conflicting identities stay separate")
        let family = try XCTUnwrap(entries.first { $0.lyricsVersionCount == 3 })
        let loadedDetail = try await repo.loadPersonalLibraryTrackDetail(stableKey: family.trackStableKey)
        let detail = try XCTUnwrap(loadedDetail)
        XCTAssertEqual(Set(detail.lyricsVersions.map(\.id)), Set([aID, bID, historicalID]), "Grouping must retain both physical keys' versions")
        XCTAssertTrue(detail.readingVersions.contains { $0.id == readingID })
        XCTAssertTrue(detail.translationVersions.contains { $0.id == translationID })
        let oldDetailResult = try await repo.loadPersonalLibraryTrackDetail(stableKey: TrackIdentity(track: b).stableKey)
        let oldDetail = try XCTUnwrap(oldDetailResult)
        XCTAssertEqual(oldDetail.entry.trackStableKey, family.trackStableKey)
        XCTAssertEqual(oldDetail.lyricsVersions.count, 3)

        for query in ["原版独有", "新版独有", "historical-only", "SAVEDREADINGNEEDLE", "SÁVEDREADINGNEEDLE", "karada", "ＫＡＲＡＤＡ", "保存译文独有", "Alternative title"] {
            let found = try await repo.loadPersonalLibraryEntries(searchQuery: query)
            XCTAssertEqual(found.map(\.trackStableKey), [family.trackStableKey], "Search must cover all versions and aliases: \(query)")
        }
        for query in ["legacyromaji", "れがしーかな", "legacytranslation", "Singer", "Album"] {
            let found = try await repo.loadPersonalLibraryEntries(searchQuery: query)
            XCTAssertTrue(found.contains { $0.trackStableKey == family.trackStableKey }, "Search must include legacy fields: \(query)")
        }
        let injection = try await repo.loadPersonalLibraryEntries(searchQuery: "' OR 1=1 --")
        XCTAssertTrue(injection.isEmpty)

        let package = try await repo.exportPersonalLibraryPackage(stableKey: family.trackStableKey)
        XCTAssertEqual(Set(package.lyricsVersions.map(\.id)), Set([aID, bID, historicalID]), "Export must not lose versions hidden by grouping")
        try await repo.setPersonalLibraryActiveLyrics(trackStableKey: family.trackStableKey, lyricsVersionID: bID)
        let best = try await repo.loadBestStored(track: a, identity: TrackIdentity(track: a))
        XCTAssertEqual(best?.versionID, bID, "Selecting a sibling-key version must affect playback")
        let editable = try await repo.loadEditableVersion(versionID: bID, track: a, identity: TrackIdentity(track: a))
        XCTAssertEqual(editable?.record.id, bID, "Sibling-key versions must remain editable")

        let reopened = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: root.appendingPathComponent("reopened"))
        let reopenedEntries = try await reopened.loadPersonalLibraryEntries()
        XCTAssertEqual(reopenedEntries.count, 6)
        let redirects = try await reopened.redirectCount()
        XCTAssertEqual(redirects, 1, "Read-time grouping must not write redirect migrations")
        let beforeNormalization = await repo.searchNormalizationCounts()
        _ = try await save(a, text: "newly-saved-cache-needle")
        let updatedSearch = try await repo.loadPersonalLibraryEntries(searchQuery: "NEWLY-SAVED-CACHE-NEEDLE")
        XCTAssertEqual(updatedSearch.map(\.trackStableKey), [family.trackStableKey])
        let afterNormalization = await repo.searchNormalizationCounts()
        for (key, count) in beforeNormalization where key != family.trackStableKey {
            XCTAssertEqual(afterNormalization[key], count, "An edit must leave other songs' cached versions intact")
        }
        XCTAssertGreaterThan(afterNormalization[family.trackStableKey] ?? 0, beforeNormalization[family.trackStableKey] ?? 0)
        _ = try await repo.loadPersonalLibraryEntries(searchQuery: "another search")
        let repeatedNormalization = await repo.searchNormalizationCounts()
        XCTAssertEqual(repeatedNormalization, afterNormalization, "Search itself only matches substrings")
        try await reopened.toggleLyricsLocked(versionID: unrelatedID, locked: true)
        let externallyChanged = try await repo.loadPersonalLibraryEntries(searchQuery: "unrelated")
        XCTAssertEqual(externallyChanged.first?.hasLockedLyrics, true, "Edits from the library's separate connection invalidate its song")


    }

    private func executeSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LibraryIdentitySearchContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open temporary SQLite database"])
        }
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite fixture statement failed"
            sqlite3_free(error)
            throw NSError(domain: "LibraryIdentitySearchContractTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
