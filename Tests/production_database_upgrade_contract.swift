import Foundation
import SQLite3
import Darwin

@main struct ProductionDatabaseUpgradeContract {
    static func sql(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
    static func scalar(_ db: OpaquePointer, _ sql: String, caller: Int = #line) -> Int {
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sql)
        defer { sqlite3_finalize(statement) }
        precondition(sqlite3_step(statement) == SQLITE_ROW, "line \(caller) \(sql): \(String(cString: sqlite3_errmsg(db)))")
        return Int(sqlite3_column_int(statement, 0))
    }
    // Synthetic v10/v11 schemas remove every later additive table, not just user_version.
    static func m1MigrationContracts() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
        precondition(root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for version in [10, 11, 12] {
            let url = root.appendingPathComponent("v\(version).sqlite3")
            precondition(!FileManager.default.fileExists(atPath: url.path))
            var db: OpaquePointer?
            precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
            let handle = db!
            defer { sqlite3_close(handle) }
            try DatabaseMigrator.migrate(handle)
            try sql(handle, """
                INSERT INTO tracks(stable_key,title,artist_display,album,created_at,updated_at)
                    VALUES ('m1-fixture','Synthetic title','Synthetic artist','Synthetic album',1,1);
                INSERT INTO lyrics_versions(id,track_stable_key,source,raw_text,content_hash,created_at,updated_at,confidence,is_manually_edited,is_locked,is_preferred)
                    VALUES ('m1-parent','m1-fixture','manual','Self-authored original','hash',1,1,1,1,1,1);
                INSERT INTO lyrics_versions(id,track_stable_key,source,raw_text,content_hash,created_at,updated_at,confidence,parent_version_id)
                    VALUES ('m1-child','m1-fixture','manual','Self-authored revision','hash2',2,2,1,'m1-parent');
                INSERT INTO lyric_lines(lyrics_version_id,line_index,original_text,kana_text,romaji_text)
                    VALUES ('m1-parent',0,'Self-authored original','synthetic reading','synthetic romaji');
                INSERT INTO translation_versions(id,lyrics_version_id,source_kind,target_language,source_content_hash,created_at,updated_at,is_manually_edited,is_locked,status,provider_execution_metadata_json)
                    VALUES ('m1-translation','m1-parent','manual','zh-Hans','hash',1,1,1,1,'accepted','{"fixture":true}');
                INSERT INTO translation_versions(id,lyrics_version_id,source_kind,target_language,source_content_hash,created_at,updated_at,status,parent_version_id)
                    VALUES ('m1-translation-child','m1-parent','manual','zh-Hans','hash',2,2,'accepted','m1-translation');
                INSERT INTO translation_lines(translation_version_id,line_index,translated_text)
                    VALUES ('m1-translation',0,'Self-authored translation');
                INSERT INTO reading_versions(id,lyrics_version_id,source_content_hash,engine_id,representation_id,created_at,updated_at,is_manually_edited,is_current,is_locked)
                    VALUES ('m1-reading','m1-parent','hash','fixture','fixture-reading',1,1,1,1,1);
                INSERT INTO reading_lines(reading_version_id,line_index,original_text,reading_text)
                    VALUES ('m1-reading',0,'Self-authored original','Self-authored reading');
                INSERT INTO lyrics_timing_versions(id,lyrics_version_id,source,granularity,source_content_hash,spans_payload,created_at)
                    VALUES ('m1-timing','m1-parent','fixture','word','hash','[]',1);

                """)
            try sql(handle, "DROP INDEX translation_requests_completion_id; ALTER TABLE translation_requests DROP COLUMN completion_version_id;")
            if version < 12 { try sql(handle, "DROP TABLE lyrics_selection_revocations;") }
            else { try sql(handle, "INSERT INTO lyrics_selection_revocations VALUES ('m1-fixture','m1-parent',1);") }
            if version == 10 { try sql(handle, "DROP TABLE translation_requests;") }
            else { try sql(handle, "INSERT INTO translation_requests VALUES ('fixture-request','fixture-attempt','received','{\"fixture\":true}',1);") }
            try sql(handle, "DELETE FROM schema_migrations WHERE version>\(version); PRAGMA user_version=\(version);")
            precondition(scalar(handle, "SELECT count(*) FROM sqlite_master WHERE name='lyrics_selection_revocations'") == (version == 12 ? 1 : 0))
            precondition(scalar(handle, "SELECT count(*) FROM sqlite_master WHERE name='translation_requests'") == (version == 10 ? 0 : 1))
            let tables = ["tracks", "lyrics_versions", "lyric_lines", "translation_versions", "translation_lines", "reading_versions", "reading_lines", "lyrics_timing_versions"] + (version >= 11 ? ["translation_requests"] : []) + (version == 12 ? ["lyrics_selection_revocations"] : [])
            func snapshot() -> [String: [[String]]] {
                var result: [String: [[String]]] = [:]
                for table in tables {
                    var statement: OpaquePointer?
                    precondition(sqlite3_prepare_v2(handle, "SELECT \(table == "translation_requests" ? "request_key,attempt_id,phase,result_json,updated_at" : "*") FROM \(table) ORDER BY rowid", -1, &statement, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(statement) }
                    var rows: [[String]] = []
                    while sqlite3_step(statement) == SQLITE_ROW {
                        rows.append((0..<sqlite3_column_count(statement)).map { index in
                            let type = sqlite3_column_type(statement, index)
                            return "\(type):" + (sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "<null>")
                        })
                    }
                    result[table] = rows
                }
                return result
            }
            let before = snapshot()
            try DatabaseMigrator.migrate(handle)
            precondition(scalar(handle, "PRAGMA user_version") == 13)
            precondition(snapshot() == before, "v\(version) migration changed manual/locked/preferred/parent/translation/reading/timing/request assets")
            precondition(scalar(handle, "SELECT count(*) FROM schema_migrations WHERE version=11") == 1)
            precondition(scalar(handle, "SELECT count(*) FROM schema_migrations WHERE version=12") == 1)
            try DatabaseMigrator.migrate(handle)
            precondition(snapshot() == before, "repeated prepare changed assets")
            precondition(scalar(handle, "SELECT count(*) FROM schema_migrations WHERE version IN (11,12,13)") == 3)
            precondition(scalar(handle, "SELECT count(*) FROM translation_requests WHERE completion_version_id IS NOT NULL") == 0, "legacy association must not be guessed")
            print("PASS actual v\(version) schema to v13; exact asset rows/parent chains/meta preserved; ordered ledger and idempotence")
        }
    }

    static func main() async throws {
        guard let taskRootPath = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_CONTRACT_ROOT"],
              let homePath = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { fatalError("private runner root/home required") }
        let taskRoot = URL(fileURLWithPath: taskRootPath).resolvingSymlinksInPath()
        let privateHome = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        let executableRoot = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        precondition(taskRoot == executableRoot && privateHome.deletingLastPathComponent() == taskRoot)
        for directory in [taskRoot, privateHome] {
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            precondition((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
            precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        print("ISOLATION root=\(taskRoot.path) home=\(privateHome.path) owner=\(geteuid()) mode=0700 modelRequests=0")
        if CommandLine.arguments.contains("--m1-migrations") {
            try m1MigrationContracts()
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        precondition(home.path.hasPrefix("/tmp/") || home.path.hasPrefix("/private/tmp/"), "Never run against user home")
        let path = SQLiteLyricsRepository.defaultDatabaseURL
        precondition(path.path.hasPrefix(home.path + "/"))
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let useExisting = CommandLine.arguments.contains("--existing")
        var db: OpaquePointer?
        precondition(sqlite3_open(path.path, &db) == SQLITE_OK)
        let handle = db!
        var reader: OpaquePointer?
        defer { if let reader { sqlite3_close(reader) } }
        if !useExisting {
            try DatabaseMigrator.migrate(handle, allowV6Migration: false)
            precondition(scalar(handle, "PRAGMA user_version") == 5)
            try sql(handle, "PRAGMA journal_mode=WAL;")
            precondition(sqlite3_open(path.path, &reader) == SQLITE_OK)
            try sql(reader!, "BEGIN; SELECT count(*) FROM tracks;")
            // Pin an older read snapshot so the new fixture remains in WAL.
            try sql(handle, """
                INSERT INTO tracks(stable_key,title,artist_display,album,created_at,updated_at) VALUES ('fixture','Fixture','Artist','Album',1,1);
                INSERT INTO lyrics_versions(id,track_stable_key,source,raw_text,content_hash,created_at,updated_at,confidence,language,is_manually_edited,is_locked)
                  VALUES ('11111111-1111-1111-1111-111111111111','fixture','manual','歌','fixture-hash',1,1,1,'ja',1,1);
                INSERT INTO lyric_lines(lyrics_version_id,line_index,original_text,kana_text,romaji_text)
                  VALUES ('11111111-1111-1111-1111-111111111111',0,'歌','うた','uta');
                """)
        }
        let sourceVersion = scalar(handle, "PRAGMA user_version")
        sqlite3_close(handle)
        let repository = SQLiteLyricsRepository(alignmentProvenanceDirectory: home.appendingPathComponent("provenance"))
        if CommandLine.arguments.contains("--expect-failure") {
            do {
                try await repository.prepare()
                fatalError("Expected upgrade failure")
            } catch {
                if sourceVersion > DatabaseMigrator.currentVersion {
                    guard case LyricsRepositoryError.unsupportedSchema(let version) = error, version == sourceVersion else { fatalError("Wrong future-schema error: \(error)") }
                }
                print("Upgrade rejected safely: \(error)"); return
            }
        }
        try await repository.prepare()
        precondition(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(scalar(db!, "PRAGMA user_version") == DatabaseMigrator.currentVersion, "Existing DEFAULT-PATH database must upgrade")
        let stats = try await repository.loadListeningStatistics(for: .allTime)
        let library = try await repository.loadPersonalLibraryEntries()
        if !useExisting {
            precondition(stats.sessionCount == 0)
            precondition(library.count == 1)
            precondition(scalar(db!, "SELECT count(*) FROM lyric_lines WHERE original_text='歌' AND kana_text='うた' AND romaji_text='uta'") == 1)
            precondition(scalar(db!, "SELECT count(*) FROM lyrics_versions WHERE is_locked=1 AND is_manually_edited=1") == 1)
            precondition(scalar(db!, "SELECT count(*) FROM reading_versions") == 2)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("pre-v") }
        if sourceVersion == DatabaseMigrator.currentVersion {
            precondition(backups.isEmpty, "Current database needs no migration backup")
            print("Current database opens without upgrade PASS")
            return
        }
        precondition(backups.count == 1, "One consistent backup before upgrading: \(backups.map(\.lastPathComponent))")
        var backup: OpaquePointer?
        precondition(sqlite3_open_v2(backups[0].path, &backup, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        precondition(scalar(backup!, "PRAGMA user_version") == sourceVersion)
        if !useExisting {
            precondition(scalar(backup!, "SELECT count(*) FROM tracks WHERE stable_key='fixture'") == 1, "Backup includes committed WAL data")
            precondition(scalar(backup!, "SELECT count(*) FROM lyric_lines") == 1)
        }
        sqlite3_close(backup)
        if let export = ProcessInfo.processInfo.environment["UPGRADE_FIXTURE_EXPORT"] {
            try FileManager.default.copyItem(at: backups[0], to: URL(fileURLWithPath: export))
        }
        let reopened = SQLiteLyricsRepository(alignmentProvenanceDirectory: home.appendingPathComponent("provenance"))
        try await reopened.prepare()
        let afterReopen = try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        precondition(afterReopen.filter { $0.contains("pre-v") }.count == 1)
        print("Production default-path upgrade PASS; library entries: \(library.count); sessions: \(stats.sessionCount)")
    }
}
