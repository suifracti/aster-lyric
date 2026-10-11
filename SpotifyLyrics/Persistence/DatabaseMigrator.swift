import Foundation
import SQLite3

/// Forward-only SQLite schema migrations. The repository calls this from its
/// actor, so no migration work runs on MainActor.
public enum DatabaseMigrator {
    public static let currentVersion = 13
    public static let v4MigrationID = "track-identity-v4-initial"
    private static let waterSourceStableKey = "spotify-id:spotify:track:5mqkkcsrujqyakvolven0w|metadata:水曜日の約束|kawasakirio|水曜日の約束|171"
    private static let waterCanonicalStableKey = "spotify-id:5mqkkcsrujqyakvolven0w|metadata:水曜日の約束|kawasakirio|水曜日の約束|171"
    private static let waterRedirectReason = "same Spotify track identity in canonical and URI-shaped historical keys"
    private static let waterRedirectEvidence = "canonicalSpotifyIDSame;spotifyURIEqual;titleEqual;artistEqual;albumEqual;durationClose;noVersionTraitConflict;canonicalISRCTrusted"

    public static func migrate(
        _ database: OpaquePointer,
        allowV4Migration: Bool = true,
        allowV6Migration: Bool = true
    ) throws {
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at REAL NOT NULL
                );
                """)

            var version = try integerValue(database, sql: "PRAGMA user_version;")
            guard version <= currentVersion else {
                throw LyricsRepositoryError.unsupportedSchema(version)
            }

            if version < 1 {
                try migrateV1(database)
                version = 1
            }
            if version < 2 {
                try migrateV2(database)
                version = 2
            }
            if version < 3 {
                try migrateV3(database)
                version = 3
            }
            if version < 4 {
                // A caller can deliberately open an existing production v3
                // database in read-only-v4 compatibility mode. This is used
                // while the redirect-first migration is being audited so a
                // normal app launch cannot silently change the user's formal
                // database before explicit confirmation.
                if allowV4Migration {
                    try migrateV4(database)
                    version = 4
                }
            } else {
                try validateV4(database)
            }
            // v5, v6, v7 are additive local schemas. A formal v4 database is
            // intentionally left untouched when the caller has not opted in
            // to a disposable copy.
            if version >= 4, version < 5, allowV4Migration,
               try hasTable(database, name: "translation_versions"),
               try hasTable(database, name: "lyrics_versions") {
                try migrateV5(database)
                version = 5
            }
            if version >= 5, version < 6, allowV6Migration,
               try hasTable(database, name: "lyrics_versions"),
               try hasTable(database, name: "lyric_lines") {
                try migrateV6(database)
                version = 6
            }
            if version >= 6, version < 7,
               try hasTable(database, name: "lyrics_versions") {
                try migrateV7(database)
                version = 7
            }
            if version >= 7, version < 8,
               try hasTable(database, name: "tracks") {
                try migrateV8(database)
                version = 8
            }
            if version >= 8, version < 9 {
                try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
                do {
                    try execute(database, sql: "ALTER TABLE lyrics_versions ADD COLUMN is_preferred INTEGER NOT NULL DEFAULT 0;")
                    try execute(database, sql: "CREATE UNIQUE INDEX lyrics_versions_one_preferred ON lyrics_versions(track_stable_key) WHERE is_preferred = 1;")
                    try execute(database, sql: "INSERT INTO schema_migrations(version, applied_at) VALUES (9, strftime('%s','now')); PRAGMA user_version = 9;")
                    try execute(database, sql: "COMMIT;")
                } catch {
                    _ = try? execute(database, sql: "ROLLBACK;")
                    throw error
                }
                version = 9
            }
            if version >= 9, version < 10,
               try hasTable(database, name: "translation_versions") {
                try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
                do {
                    try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN provider_execution_metadata_json TEXT NOT NULL DEFAULT '';" )
                    try execute(database, sql: "INSERT INTO schema_migrations(version, applied_at) VALUES (10, strftime('%s','now')); PRAGMA user_version = 10;")
                    try execute(database, sql: "COMMIT;")
                } catch {
                    _ = try? execute(database, sql: "ROLLBACK;")
                    throw error
                }
                version = 10
            }
            if version == 10 {
                try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
                do {
                    try execute(database, sql: """
                        CREATE TABLE translation_requests (
                            request_key TEXT PRIMARY KEY,
                            attempt_id TEXT NOT NULL,
                            phase TEXT NOT NULL CHECK(phase IN ('prepared','dispatching','received','saved')),
                            result_json TEXT,
                            updated_at REAL NOT NULL
                        );
                        INSERT INTO schema_migrations(version, applied_at) VALUES (11, strftime('%s','now'));
                        PRAGMA user_version = 11;
                        """)
                    try execute(database, sql: "COMMIT;")
                } catch {
                    _ = try? execute(database, sql: "ROLLBACK;")
                    throw error
                }
            }
            if try integerValue(database, sql: "PRAGMA user_version;") == 11 {
                try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
                do {
                    try execute(database, sql: """
                        CREATE TABLE lyrics_selection_revocations (
                            track_stable_key TEXT PRIMARY KEY REFERENCES tracks(stable_key) ON DELETE CASCADE,
                            revoked_version_id TEXT REFERENCES lyrics_versions(id) ON DELETE SET NULL,
                            updated_at REAL NOT NULL
                        );
                        INSERT INTO schema_migrations(version, applied_at) VALUES (12, strftime('%s','now'));
                        PRAGMA user_version = 12;
                        """)
                    try execute(database, sql: "COMMIT;")
                } catch {
                    _ = try? execute(database, sql: "ROLLBACK;")
                    throw error
                }
            }
            if try integerValue(database, sql: "PRAGMA user_version;") == 12 {
                try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
                do {
                    try execute(database, sql: """
                        ALTER TABLE translation_requests ADD COLUMN completion_version_id TEXT;
                        CREATE UNIQUE INDEX translation_requests_completion_id
                            ON translation_requests(completion_version_id) WHERE completion_version_id IS NOT NULL;
                        INSERT INTO schema_migrations(version, applied_at) VALUES (13, strftime('%s','now'));
                        PRAGMA user_version = 13;
                        """)
                    try execute(database, sql: "COMMIT;")
                } catch {
                    _ = try? execute(database, sql: "ROLLBACK;")
                    throw error
                }
            }
        } catch let error as LyricsRepositoryError {
            // A corrupt/partially readable SQLite file must be reported as a
            // migration failure, not leaked as a generic database error. This
            // gives the caller one actionable startup failure path while still
            // preserving an explicitly unsupported future schema version.
            switch error {
            case .migrationFailed, .unsupportedSchema:
                throw error
            default:
                throw LyricsRepositoryError.migrationFailed(currentVersion, error.localizedDescription)
            }
        } catch {
            throw LyricsRepositoryError.migrationFailed(currentVersion, error.localizedDescription)
        }
    }

    /// The initial v4 redirect is also available as an in-memory fallback for
    /// an existing v3 database. It lets the repository preserve logical Water
    /// identity-family reads without writing v4 tables before migration is
    /// explicitly enabled.
    public static func readOnlyInitialRedirects(knownStableKeys: Set<String>) -> [String: String] {
        guard knownStableKeys.contains(waterSourceStableKey),
              knownStableKeys.contains(waterCanonicalStableKey) else {
            return [:]
        }
        return [waterSourceStableKey: waterCanonicalStableKey]
    }

    private static func migrateV1(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS tracks (
                    stable_key TEXT PRIMARY KEY NOT NULL,
                    spotify_id TEXT,
                    spotify_uri TEXT,
                    isrc TEXT,
                    title TEXT NOT NULL,
                    artist_display TEXT NOT NULL,
                    album TEXT NOT NULL,
                    duration REAL NOT NULL DEFAULT 0,
                    artwork_url TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS track_aliases (
                    track_stable_key TEXT NOT NULL,
                    field TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    value TEXT NOT NULL,
                    language TEXT,
                    script TEXT NOT NULL,
                    source TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    is_official INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (track_stable_key, field, kind, value),
                    FOREIGN KEY (track_stable_key) REFERENCES tracks(stable_key) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS lyrics_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    track_stable_key TEXT NOT NULL,
                    source TEXT NOT NULL,
                    provider_source_id TEXT NOT NULL DEFAULT '',
                    language TEXT NOT NULL DEFAULT 'und',
                    is_synced INTEGER NOT NULL DEFAULT 0,
                    raw_text TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    is_machine_generated INTEGER NOT NULL DEFAULT 0,
                    is_manually_edited INTEGER NOT NULL DEFAULT 0,
                    is_locked INTEGER NOT NULL DEFAULT 0,
                    confidence REAL NOT NULL,
                    FOREIGN KEY (track_stable_key) REFERENCES tracks(stable_key) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS lyric_lines (
                    lyrics_version_id TEXT NOT NULL,
                    line_index INTEGER NOT NULL,
                    start_time REAL,
                    end_time REAL,
                    original_text TEXT NOT NULL,
                    kana_text TEXT,
                    romaji_text TEXT,
                    translation_text TEXT,
                    PRIMARY KEY (lyrics_version_id, line_index),
                    FOREIGN KEY (lyrics_version_id) REFERENCES lyrics_versions(id) ON DELETE CASCADE
                );

                CREATE UNIQUE INDEX IF NOT EXISTS lyrics_versions_dedup
                    ON lyrics_versions(track_stable_key, source, provider_source_id, content_hash);
                CREATE INDEX IF NOT EXISTS lyrics_versions_best
                    ON lyrics_versions(track_stable_key, is_locked, confidence, updated_at);
                CREATE INDEX IF NOT EXISTS track_aliases_lookup
                    ON track_aliases(track_stable_key, field, kind);
                CREATE INDEX IF NOT EXISTS lyric_lines_version_order
                    ON lyric_lines(lyrics_version_id, line_index);
                """)
            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (1, strftime('%s','now'));")
            try execute(database, sql: "PRAGMA user_version = 1;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private struct LegacyGroup {
        let versionID: String
        let isSynchronized: Bool
        let lines: [DatabaseLyricLineRecord]
    }

    private static func migrateV2(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS translation_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    lyrics_version_id TEXT NOT NULL,
                    source_kind TEXT NOT NULL,
                    target_language TEXT NOT NULL,
                    model TEXT NOT NULL DEFAULT '',
                    base_url_host TEXT NOT NULL DEFAULT '',
                    prompt_hash TEXT NOT NULL DEFAULT '',
                    source_content_hash TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    is_machine_generated INTEGER NOT NULL DEFAULT 0,
                    is_manually_edited INTEGER NOT NULL DEFAULT 0,
                    is_locked INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL,
                    confidence REAL NOT NULL DEFAULT 0,
                    FOREIGN KEY (lyrics_version_id) REFERENCES lyrics_versions(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS translation_lines (
                    translation_version_id TEXT NOT NULL,
                    line_index INTEGER NOT NULL,
                    translated_text TEXT NOT NULL,
                    PRIMARY KEY (translation_version_id, line_index),
                    FOREIGN KEY (translation_version_id) REFERENCES translation_versions(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS translation_versions_lookup
                    ON translation_versions(lyrics_version_id, target_language, source_content_hash, status, updated_at);
                CREATE INDEX IF NOT EXISTS translation_versions_selection
                    ON translation_versions(lyrics_version_id, is_locked, updated_at);
                CREATE INDEX IF NOT EXISTS translation_lines_version_order
                    ON translation_lines(translation_version_id, line_index);
                """)

            for group in try legacyGroups(database) {
                guard !group.lines.isEmpty else { continue }
                let sourceHash = LyricsSourceContentHasher.hash(
                    isSynchronized: group.isSynchronized,
                    lines: group.lines
                )
                guard try !translationVersionExists(
                    database,
                    lyricsVersionID: group.versionID,
                    sourceContentHash: sourceHash
                ) else { continue }

                let versionID = UUID().uuidString
                let complete = group.lines.allSatisfy { row in
                    let originalBlank = row.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let translationBlank = row.translationText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                    return originalBlank == translationBlank
                }
                try insertTranslationVersion(
                    database,
                    id: versionID,
                    lyricsVersionID: group.versionID,
                    sourceHash: sourceHash,
                    status: complete ? "complete" : "incomplete"
                )
                for row in group.lines {
                    try insertTranslationLine(
                        database,
                        versionID: versionID,
                        index: row.lineIndex,
                        text: row.translationText ?? ""
                    )
                }
            }

            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (2, strftime('%s','now'));")
            try execute(database, sql: "PRAGMA user_version = 2;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func migrateV3(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            // These ALTERs run only while user_version is 2. If any statement
            // fails, the transaction rolls back and the next launch retries
            // the complete migration rather than leaving a half-versioned DB.
            try execute(database, sql: "ALTER TABLE lyrics_versions ADD COLUMN parent_version_id TEXT;")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN parent_version_id TEXT;")
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS lyric_reading_layers (
                    lyrics_version_id TEXT NOT NULL,
                    line_index INTEGER NOT NULL,
                    kana_text TEXT,
                    romaji_text TEXT,
                    source TEXT NOT NULL,
                    is_locked INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (lyrics_version_id, line_index),
                    FOREIGN KEY (lyrics_version_id) REFERENCES lyrics_versions(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS lyrics_versions_parent_lookup
                    ON lyrics_versions(parent_version_id, updated_at);
                CREATE INDEX IF NOT EXISTS translation_versions_parent_lookup
                    ON translation_versions(parent_version_id, updated_at);
                CREATE INDEX IF NOT EXISTS lyric_reading_layers_version_order
                    ON lyric_reading_layers(lyrics_version_id, line_index);
                """)
            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (3, strftime('%s','now'));")
            try execute(database, sql: "PRAGMA user_version = 3;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func migrateV4(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            // v4 is redirect-first. It adds logical identity metadata only;
            // no Track, LyricsVersion, TranslationVersion, or UUID row is
            // moved or deleted by this migration.
            if try !hasColumn(database, table: "schema_migrations", column: "migration_id") {
                try execute(database, sql: "ALTER TABLE schema_migrations ADD COLUMN migration_id TEXT;")
            }
            try execute(database, sql: """
                UPDATE schema_migrations
                SET migration_id = 'schema-v' || CAST(version AS TEXT)
                WHERE migration_id IS NULL OR length(trim(migration_id)) = 0;

                CREATE UNIQUE INDEX IF NOT EXISTS schema_migrations_migration_id
                    ON schema_migrations(migration_id);

                CREATE TABLE IF NOT EXISTS track_identity_redirects (
                    source_stable_key TEXT PRIMARY KEY NOT NULL,
                    canonical_stable_key TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    evidence_kind TEXT NOT NULL,
                    migration_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY (canonical_stable_key) REFERENCES tracks(stable_key)
                );

                CREATE INDEX IF NOT EXISTS track_identity_redirects_canonical
                    ON track_identity_redirects(canonical_stable_key);

                CREATE TABLE IF NOT EXISTS track_identity_merge_audit (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    migration_id TEXT NOT NULL,
                    source_stable_key TEXT NOT NULL,
                    canonical_stable_key TEXT NOT NULL,
                    source_spotify_id TEXT,
                    source_spotify_uri TEXT,
                    source_isrc TEXT,
                    source_title TEXT,
                    source_artist_display TEXT,
                    source_album TEXT,
                    source_duration REAL,
                    evidence TEXT NOT NULL,
                    action TEXT NOT NULL,
                    created_at REAL NOT NULL
                );

                CREATE INDEX IF NOT EXISTS track_identity_merge_audit_source
                    ON track_identity_merge_audit(source_stable_key, created_at);
                """)

            try ensureRedirect(
                database,
                source: waterSourceStableKey,
                canonical: waterCanonicalStableKey,
                reason: waterRedirectReason,
                evidenceKind: waterRedirectEvidence,
                migrationID: v4MigrationID
            )

            let existingMigration = try scalarOptionalText(
                database,
                sql: "SELECT migration_id FROM schema_migrations WHERE version = 4 LIMIT 1;"
            )
            if let existingMigration, existingMigration != v4MigrationID {
                throw LyricsRepositoryError.invalidData("schema v4 migration_id 冲突")
            }
            let migrationInsert = try prepare(database, sql: """
                INSERT INTO schema_migrations(version, applied_at, migration_id)
                VALUES (4, strftime('%s','now'), ?)
                ON CONFLICT(version) DO UPDATE SET migration_id = excluded.migration_id;
                """)
            defer { sqlite3_finalize(migrationInsert) }
            try bindText(v4MigrationID, at: 1, to: migrationInsert)
            try stepDone(database, statement: migrationInsert)
            try execute(database, sql: "PRAGMA user_version = 4;")
            try validateV4(database)
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func validateV4(_ database: OpaquePointer) throws {
        guard try hasTable(database, name: "track_identity_redirects"),
              try hasTable(database, name: "track_identity_merge_audit"),
              try hasColumn(database, table: "schema_migrations", column: "migration_id") else {
            throw LyricsRepositoryError.invalidData("schema v4 identity redirect 表结构不完整")
        }

        let statement = try prepare(database, sql: """
            SELECT r.source_stable_key, r.canonical_stable_key
            FROM track_identity_redirects AS r
            LEFT JOIN tracks AS t ON t.stable_key = r.canonical_stable_key
            WHERE t.stable_key IS NULL;
            """)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            let source = columnText(statement, index: 0) ?? ""
            let target = columnText(statement, index: 1) ?? ""
            throw LyricsRepositoryError.invalidData("redirect target 不存在：\(source) -> \(target)")
        }

        let redirects = try rows(database, sql: "SELECT source_stable_key, canonical_stable_key FROM track_identity_redirects;")
        let keys = Set(try rows(database, sql: "SELECT stable_key, stable_key FROM tracks;").flatMap { [$0.0, $0.1] })
        let resolver = TrackIdentityRedirectResolver(
            redirects: Dictionary(uniqueKeysWithValues: redirects),
            knownStableKeys: keys
        )
        for (source, _) in redirects {
            _ = try resolver.resolve(source)
        }

        let migration = try scalarOptionalText(
            database,
            sql: "SELECT migration_id FROM schema_migrations WHERE version = 4 LIMIT 1;"
        )
        guard migration == v4MigrationID else {
            throw LyricsRepositoryError.invalidData("schema v4 migration_id 缺失或不匹配")
        }

        let hasWaterSource = try exists(
            database,
            sql: "SELECT 1 FROM tracks WHERE stable_key = ? LIMIT 1;",
            value: waterSourceStableKey
        )
        let hasWaterCanonical = try exists(
            database,
            sql: "SELECT 1 FROM tracks WHERE stable_key = ? LIMIT 1;",
            value: waterCanonicalStableKey
        )
        if hasWaterSource && hasWaterCanonical {
            guard let waterRedirect = try redirectRow(database, source: waterSourceStableKey),
                  waterRedirect.canonical == waterCanonicalStableKey,
                  waterRedirect.reason == waterRedirectReason,
                  waterRedirect.evidenceKind == waterRedirectEvidence,
                  waterRedirect.migrationID == v4MigrationID else {
                throw LyricsRepositoryError.invalidData("水曜日 redirect 缺失或证据不匹配")
            }
        }
    }

    /// Translation execution metadata is additive. Existing provider and
    /// legacy-imported versions receive neutral values; no old prompt, model,
    /// or engine is guessed. The migration is transactional and only the
    /// temporary database is used by Phase 2.5 validation.
    private static func migrateV5(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN engine_id TEXT NOT NULL DEFAULT '';")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN prompt_preset_id TEXT NOT NULL DEFAULT '';")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN profile_id TEXT;")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN profile_snapshot TEXT NOT NULL DEFAULT '';")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN temperature REAL NOT NULL DEFAULT 0.2;")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN workflow_id TEXT NOT NULL DEFAULT 'translationWorkflow.classicV1';")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN fallback_strategy TEXT NOT NULL DEFAULT 'none';")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN is_draft INTEGER NOT NULL DEFAULT 0;")
            try execute(database, sql: "ALTER TABLE translation_versions ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;")
            try execute(database, sql: "CREATE INDEX IF NOT EXISTS translation_versions_engine_lookup ON translation_versions(lyrics_version_id, engine_id, prompt_preset_id, updated_at);")
            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (5, strftime('%s','now'));" )
            try execute(database, sql: "PRAGMA user_version = 5;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    /// Reading versions are additive and intentionally live in their own
    /// tables.  The migration imports the legacy per-line kana/romaji values
    /// as traceable legacy versions; it never edits lyric_lines or removes
    /// the compatibility columns.
    private static func migrateV6(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS reading_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    lyrics_version_id TEXT NOT NULL,
                    source_content_hash TEXT NOT NULL,
                    engine_id TEXT NOT NULL,
                    representation_id TEXT NOT NULL,
                    source_kind TEXT NOT NULL DEFAULT 'generated',
                    language TEXT NOT NULL DEFAULT 'und',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    is_machine_generated INTEGER NOT NULL DEFAULT 0,
                    is_manually_edited INTEGER NOT NULL DEFAULT 0,
                    is_current INTEGER NOT NULL DEFAULT 0,
                    is_locked INTEGER NOT NULL DEFAULT 0,
                    is_archived INTEGER NOT NULL DEFAULT 0,
                    parent_version_id TEXT,
                    confidence REAL NOT NULL DEFAULT 0,
                    warning_metadata TEXT NOT NULL DEFAULT '[]',
                    context_hash TEXT NOT NULL DEFAULT '',
                    FOREIGN KEY (lyrics_version_id) REFERENCES lyrics_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (parent_version_id) REFERENCES reading_versions(id) ON DELETE SET NULL
                );

                CREATE TABLE IF NOT EXISTS reading_lines (
                    reading_version_id TEXT NOT NULL,
                    line_index INTEGER NOT NULL,
                    original_text TEXT NOT NULL,
                    reading_text TEXT,
                    tokens_json TEXT NOT NULL DEFAULT '[]',
                    language TEXT NOT NULL DEFAULT 'und',
                    source TEXT NOT NULL DEFAULT 'unknown',
                    confidence REAL NOT NULL DEFAULT 0,
                    warning_metadata TEXT NOT NULL DEFAULT '[]',
                    PRIMARY KEY (reading_version_id, line_index),
                    FOREIGN KEY (reading_version_id) REFERENCES reading_versions(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS reading_versions_lookup
                    ON reading_versions(lyrics_version_id, representation_id, source_content_hash, updated_at);
                CREATE INDEX IF NOT EXISTS reading_versions_selection
                    ON reading_versions(lyrics_version_id, representation_id, is_locked, is_current, is_archived, updated_at);
                CREATE INDEX IF NOT EXISTS reading_lines_version_order
                    ON reading_lines(reading_version_id, line_index);
                """)

            for group in try legacyReadingGroups(database) {
                guard !group.lines.isEmpty else { continue }
                let sourceHash = LyricsSourceContentHasher.hash(
                    isSynchronized: group.isSynchronized,
                    lines: group.lines.map { line in
                        DatabaseLyricLineRecord(
                            lyricsVersionID: UUID(uuidString: group.versionID) ?? UUID(),
                            lineIndex: line.lineIndex,
                            startTime: line.startTime,
                            endTime: line.endTime,
                            originalText: line.original,
                            kanaText: line.kana.isEmpty ? nil : line.kana,
                            romajiText: line.romaji.isEmpty ? nil : line.romaji,
                            translationText: nil
                        )
                    }
                )
                let language = group.language.lowercased().hasPrefix("ja") ? "ja" : "und"
                if group.lines.contains(where: { !$0.kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    try insertLegacyReadingVersion(
                        database,
                        group: group,
                        sourceHash: sourceHash,
                        language: language,
                        representationID: "readingRepresentation.kana.v1"
                    )
                }
                if group.lines.contains(where: { !$0.romaji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    try insertLegacyReadingVersion(
                        database,
                        group: group,
                        sourceHash: sourceHash,
                        language: language,
                        representationID: "readingRepresentation.romaji.v1"
                    )
                }
            }

            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (6, strftime('%s','now'));")
            try execute(database, sql: "PRAGMA user_version = 6;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    /// Word / Syllable timing versions are immutable attachments that bind to
    /// an existing lyrics_version_id and base source_content_hash.
    private static func migrateV7(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS lyrics_timing_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    lyrics_version_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    granularity TEXT NOT NULL,
                    source_content_hash TEXT NOT NULL,
                    spans_payload TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY (lyrics_version_id) REFERENCES lyrics_versions(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS lyrics_timing_versions_lookup
                    ON lyrics_timing_versions(lyrics_version_id, source_content_hash, created_at);
                """)
            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (7, strftime('%s','now'));")
            try execute(database, sql: "PRAGMA user_version = 7;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    /// Listening history stores only playback sessions observed by this app.
    /// It is independent from lyrics versions and can be added without
    /// changing any existing lyrics tables.
    private static func migrateV8(_ database: OpaquePointer) throws {
        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS listening_history_sessions (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    track_stable_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL,
                    album TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    last_observed_at REAL NOT NULL,
                    observed_playback_duration REAL NOT NULL DEFAULT 0,
                    track_duration REAL,
                    completion_ratio REAL
                );

                CREATE INDEX IF NOT EXISTS listening_history_recent
                    ON listening_history_sessions(last_observed_at DESC, started_at DESC);
                """)
            try execute(database, sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (8, strftime('%s','now'));")
            try execute(database, sql: "PRAGMA user_version = 8;")
            try execute(database, sql: "COMMIT;")
        } catch {
            _ = try? execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private struct LegacyReadingGroup {
        let versionID: String
        let language: String
        let isSynchronized: Bool
        let lines: [LegacyReadingLine]
    }

    private struct LegacyReadingLine {
        let lineIndex: Int
        let startTime: Double?
        let endTime: Double?
        let original: String
        let kana: String
        let romaji: String
    }

    private static func legacyReadingGroups(_ database: OpaquePointer) throws -> [LegacyReadingGroup] {
        let statement = try prepare(database, sql: """
            SELECT lv.id, lv.language, lv.is_synced, ll.line_index,
                   ll.start_time, ll.end_time, ll.original_text,
                   COALESCE(ll.kana_text, ''), COALESCE(ll.romaji_text, '')
            FROM lyrics_versions AS lv
            JOIN lyric_lines AS ll ON ll.lyrics_version_id = lv.id
            WHERE (ll.kana_text IS NOT NULL AND length(trim(ll.kana_text)) > 0)
               OR (ll.romaji_text IS NOT NULL AND length(trim(ll.romaji_text)) > 0)
            ORDER BY lv.id, ll.line_index;
            """)
        defer { sqlite3_finalize(statement) }

        var groups: [LegacyReadingGroup] = []
        var currentID: String?
        var currentLanguage = "und"
        var currentSynchronized = false
        var currentLines: [LegacyReadingLine] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let id = columnText(statement, index: 0),
                  let original = columnText(statement, index: 6) else {
                throw LyricsRepositoryError.invalidData("legacy reading line 字段缺失")
            }
            if currentID != id {
                if let currentID, !currentLines.isEmpty {
                    groups.append(LegacyReadingGroup(
                        versionID: currentID,
                        language: currentLanguage,
                        isSynchronized: currentSynchronized,
                        lines: currentLines
                    ))
                }
                currentID = id
                currentLanguage = columnText(statement, index: 1) ?? "und"
                currentSynchronized = sqlite3_column_int(statement, 2) != 0
                currentLines = []
            }
            currentLines.append(LegacyReadingLine(
                lineIndex: Int(sqlite3_column_int(statement, 3)),
                startTime: columnDouble(statement, index: 4),
                endTime: columnDouble(statement, index: 5),
                original: original,
                kana: columnText(statement, index: 7) ?? "",
                romaji: columnText(statement, index: 8) ?? ""
            ))
        }
        if let currentID, !currentLines.isEmpty {
            groups.append(LegacyReadingGroup(
                versionID: currentID,
                language: currentLanguage,
                isSynchronized: currentSynchronized,
                lines: currentLines
            ))
        }
        return groups
    }

    private static func insertLegacyReadingVersion(
        _ database: OpaquePointer,
        group: LegacyReadingGroup,
        sourceHash: String,
        language: String,
        representationID: String
    ) throws {
        guard try !exists(database, sql: """
            SELECT 1 FROM reading_versions
            WHERE lyrics_version_id = ? AND representation_id = ? AND source_content_hash = ?
            LIMIT 1;
            """, values: [group.versionID, representationID, sourceHash]) else { return }

        let versionID = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let insert = try prepare(database, sql: """
            INSERT INTO reading_versions(
                id, lyrics_version_id, source_content_hash, engine_id,
                representation_id, source_kind, language, created_at, updated_at,
                is_machine_generated, is_manually_edited, is_current, is_locked,
                is_archived, confidence, warning_metadata, context_hash
            ) VALUES (?, ?, ?, 'readingEngine.japaneseDictionary.v1', ?,
                      'legacyImported', ?, ?, ?, 0, 0, 0, 0, 0, 0.5, '[]', '');
            """)
        defer { sqlite3_finalize(insert) }
        try bindText(versionID, at: 1, to: insert)
        try bindText(group.versionID, at: 2, to: insert)
        try bindText(sourceHash, at: 3, to: insert)
        try bindText(representationID, at: 4, to: insert)
        try bindText(language, at: 5, to: insert)
        try bindDouble(now, at: 6, to: insert)
        try bindDouble(now, at: 7, to: insert)
        try stepDone(database, statement: insert)

        for line in group.lines {
            let value = representationID == "readingRepresentation.kana.v1" ? line.kana : line.romaji
            let lineInsert = try prepare(database, sql: """
                INSERT INTO reading_lines(
                    reading_version_id, line_index, original_text, reading_text,
                    tokens_json, language, source, confidence, warning_metadata
                ) VALUES (?, ?, ?, ?, '[]', ?, 'preserved', 0.5, '[]');
                """)
            defer { sqlite3_finalize(lineInsert) }
            try bindText(versionID, at: 1, to: lineInsert)
            try bindInt(line.lineIndex, at: 2, to: lineInsert)
            try bindText(line.original, at: 3, to: lineInsert)
            try bindText(value, at: 4, to: lineInsert)
            try bindText(language, at: 5, to: lineInsert)
            try stepDone(database, statement: lineInsert)
        }
    }

    private static func ensureRedirect(
        _ database: OpaquePointer,
        source: String,
        canonical: String,
        reason: String,
        evidenceKind: String,
        migrationID: String
    ) throws {
        guard source != canonical else { return }
        guard try exists(database, sql: "SELECT 1 FROM tracks WHERE stable_key = ? LIMIT 1;", value: canonical) else {
            // The mapping is only applicable to databases that contain both
            // historical rows. Fresh installations simply have no redirect.
            return
        }
        guard try exists(database, sql: "SELECT 1 FROM tracks WHERE stable_key = ? LIMIT 1;", value: source) else {
            return
        }

        if let existing = try redirectRow(database, source: source) {
            guard existing.canonical == canonical,
                  existing.reason == reason,
                  existing.evidenceKind == evidenceKind,
                  existing.migrationID == migrationID else {
                throw LyricsRepositoryError.invalidData("redirect 已存在但证据或目标冲突：\(source)")
            }
            return
        }

        let now = Date().timeIntervalSince1970
        let insert = try prepare(database, sql: """
            INSERT INTO track_identity_redirects(
                source_stable_key, canonical_stable_key, reason, evidence_kind,
                migration_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(insert) }
        try bindText(source, at: 1, to: insert)
        try bindText(canonical, at: 2, to: insert)
        try bindText(reason, at: 3, to: insert)
        try bindText(evidenceKind, at: 4, to: insert)
        try bindText(migrationID, at: 5, to: insert)
        try bindDouble(now, at: 6, to: insert)
        try stepDone(database, statement: insert)

        let audit = try prepare(database, sql: """
            INSERT INTO track_identity_merge_audit(
                migration_id, source_stable_key, canonical_stable_key,
                source_spotify_id, source_spotify_uri, source_isrc,
                source_title, source_artist_display, source_album, source_duration,
                evidence, action, created_at
            )
            SELECT ?, stable_key, ?, spotify_id, spotify_uri, isrc,
                   title, artist_display, album, duration, ?, 'redirect-only', ?
            FROM tracks WHERE stable_key = ?;
            """)
        defer { sqlite3_finalize(audit) }
        try bindText(migrationID, at: 1, to: audit)
        try bindText(canonical, at: 2, to: audit)
        try bindText(evidenceKind, at: 3, to: audit)
        try bindDouble(now, at: 4, to: audit)
        try bindText(source, at: 5, to: audit)
        try stepDone(database, statement: audit)
    }

    private struct RedirectRow {
        let canonical: String
        let reason: String
        let evidenceKind: String
        let migrationID: String
    }

    private static func redirectRow(_ database: OpaquePointer, source: String) throws -> RedirectRow? {
        let statement = try prepare(database, sql: """
            SELECT canonical_stable_key, reason, evidence_kind, migration_id
            FROM track_identity_redirects WHERE source_stable_key = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(source, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let canonical = columnText(statement, index: 0),
              let reason = columnText(statement, index: 1),
              let evidence = columnText(statement, index: 2),
              let migration = columnText(statement, index: 3) else {
            throw LyricsRepositoryError.invalidData("redirect 字段缺失")
        }
        return RedirectRow(canonical: canonical, reason: reason, evidenceKind: evidence, migrationID: migration)
    }

    private static func hasTable(_ database: OpaquePointer, name: String) throws -> Bool {
        try exists(database, sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;", value: name)
    }

    private static func hasColumn(_ database: OpaquePointer, table: String, column: String) throws -> Bool {
        let statement = try prepare(database, sql: "PRAGMA table_info(\(quoteIdentifier(table)));" )
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, index: 1) == column { return true }
        }
        return false
    }

    private static func quoteIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func exists(_ database: OpaquePointer, sql: String, value: String) throws -> Bool {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        try bindText(value, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func exists(_ database: OpaquePointer, sql: String, values: [String]) throws -> Bool {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            try bindText(value, at: Int32(index + 1), to: statement)
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func scalarOptionalText(_ database: OpaquePointer, sql: String) throws -> String? {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, index: 0)
    }

    private static func rows(_ database: OpaquePointer, sql: String) throws -> [(String, String)] {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        var result: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let first = columnText(statement, index: 0),
                  let second = columnText(statement, index: 1) else {
                throw LyricsRepositoryError.invalidData("SQLite identity row 字段缺失")
            }
            result.append((first, second))
        }
        return result
    }

    private static func legacyGroups(_ database: OpaquePointer) throws -> [LegacyGroup] {
        let statement = try prepare(database, sql: """
            SELECT lv.id, lv.is_synced,
                   ll.line_index, ll.start_time, ll.end_time,
                   ll.original_text, ll.kana_text, ll.romaji_text, ll.translation_text
            FROM lyrics_versions AS lv
            JOIN lyric_lines AS ll ON ll.lyrics_version_id = lv.id
            WHERE EXISTS (
                SELECT 1 FROM lyric_lines AS nonempty
                WHERE nonempty.lyrics_version_id = lv.id
                  AND nonempty.translation_text IS NOT NULL
                  AND length(trim(nonempty.translation_text)) > 0
            )
            ORDER BY lv.id, ll.line_index;
            """)
        defer { sqlite3_finalize(statement) }

        var grouped: [LegacyGroup] = []
        var currentID: String?
        var current: [DatabaseLyricLineRecord] = []
        var currentSynchronized = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteError(database) }
            guard let versionID = columnText(statement, index: 0),
                  let original = columnText(statement, index: 5) else {
                throw LyricsRepositoryError.migrationFailed(2, "legacy lyric line 字段缺失")
            }
            if currentID != versionID {
                if let currentID, !current.isEmpty {
                    grouped.append(LegacyGroup(versionID: currentID, isSynchronized: currentSynchronized, lines: current))
                }
                current = []
                currentID = versionID
                currentSynchronized = sqlite3_column_int(statement, 1) != 0
            }
            let line = DatabaseLyricLineRecord(
                lyricsVersionID: UUID(uuidString: versionID) ?? UUID(),
                lineIndex: Int(sqlite3_column_int(statement, 2)),
                startTime: columnDouble(statement, index: 3),
                endTime: columnDouble(statement, index: 4),
                originalText: original,
                kanaText: columnText(statement, index: 6),
                romajiText: columnText(statement, index: 7),
                translationText: columnText(statement, index: 8)
            )
            current.append(line)
        }
        if let currentID, !current.isEmpty {
            grouped.append(LegacyGroup(versionID: currentID, isSynchronized: currentSynchronized, lines: current))
        }
        return grouped
    }

    private static func translationVersionExists(
        _ database: OpaquePointer,
        lyricsVersionID: String,
        sourceContentHash: String
    ) throws -> Bool {
        let statement = try prepare(database, sql: """
            SELECT 1 FROM translation_versions
            WHERE lyrics_version_id = ? AND source_kind = 'legacyImported'
              AND target_language = 'und' AND source_content_hash = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(lyricsVersionID, at: 1, to: statement)
        try bindText(sourceContentHash, at: 2, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func insertTranslationVersion(
        _ database: OpaquePointer,
        id: String,
        lyricsVersionID: String,
        sourceHash: String,
        status: String
    ) throws {
        let statement = try prepare(database, sql: """
            INSERT INTO translation_versions(
                id, lyrics_version_id, source_kind, target_language, model,
                base_url_host, prompt_hash, source_content_hash, created_at,
                updated_at, is_machine_generated, is_manually_edited,
                is_locked, status, confidence
            ) VALUES (?, ?, 'legacyImported', 'und', '', '', '', ?, ?, ?, 0, 0, 0, ?, 0.5);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(id, at: 1, to: statement)
        try bindText(lyricsVersionID, at: 2, to: statement)
        try bindText(sourceHash, at: 3, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 4, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 5, to: statement)
        try bindText(status, at: 6, to: statement)
        try stepDone(database, statement: statement)
    }

    private static func insertTranslationLine(
        _ database: OpaquePointer,
        versionID: String,
        index: Int,
        text: String
    ) throws {
        let statement = try prepare(database, sql: """
            INSERT INTO translation_lines(translation_version_id, line_index, translated_text)
            VALUES (?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID, at: 1, to: statement)
        try bindInt(index, at: 2, to: statement)
        try bindText(text, at: 3, to: statement)
        try stepDone(database, statement: statement)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error (result \(result))"
            sqlite3_free(errorMessage)
            throw LyricsRepositoryError.migrationFailed(currentVersion, message)
        }
    }

    private static func integerValue(_ database: OpaquePointer, sql: String) throws -> Int {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LyricsRepositoryError.migrationFailed(currentVersion, "无法读取 schema version")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }
        return statement
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transientDestructor) }
        guard result == SQLITE_OK else { throw LyricsRepositoryError.sqlite("绑定文本失败") }
    }

    private static func bindInt(_ value: Int, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw LyricsRepositoryError.sqlite("绑定整数失败")
        }
    }

    private static func bindDouble(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw LyricsRepositoryError.sqlite("绑定数字失败")
        }
    }

    private static func stepDone(_ database: OpaquePointer, statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func columnDouble(_ statement: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private static func sqliteError(_ database: OpaquePointer) -> LyricsRepositoryError {
        LyricsRepositoryError.migrationFailed(currentVersion, String(cString: sqlite3_errmsg(database)))
    }
}
