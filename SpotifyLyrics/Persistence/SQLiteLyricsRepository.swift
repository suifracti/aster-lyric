import Foundation
import SQLite3

/// SQLite-backed lyrics cache. The actor is deliberately not MainActor:
/// sqlite3 calls, migrations, and transactions are serialized here without
/// blocking SwiftUI or Spotify playback state.
public actor SQLiteLyricsRepository: LyricsRepository, TranslationRepository, LyricsEditingRepository, ReadingRepository {
    public nonisolated let databaseURL: URL

    private var database: OpaquePointer?
    private var prepared = false
    private var redirectResolver: TrackIdentityRedirectResolver?
    private var manualAdoptionRequestIDs: [String: UUID] = [:]
    private let alignmentProvenanceStore: AlignmentProvenanceStore

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static var defaultDatabaseURL: URL {
#if DEBUG
        // Test-only isolation for signed Debug acceptance runs. Release builds
        // always use the user Application Support database below.
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpotifyLyrics/SpotifyLyrics.sqlite3")
    }

    public init(
        databaseURL: URL = SQLiteLyricsRepository.defaultDatabaseURL,
        alignmentProvenanceDirectory: URL = AlignmentProvenanceStore.defaultDirectory
    ) {
        self.databaseURL = databaseURL
        self.alignmentProvenanceStore = AlignmentProvenanceStore(directory: alignmentProvenanceDirectory)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func prepare() throws {
        guard !prepared else { return }

        let databaseAlreadyExisted = FileManager.default.fileExists(atPath: databaseURL.path)

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw LyricsRepositoryError.databaseOpenFailed(error.localizedDescription)
        }

        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, openFlags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error \(openResult)"
            if let handle { sqlite3_close(handle) }
            throw LyricsRepositoryError.databaseOpenFailed(message)
        }

        database = handle
#if DEBUG
        DebugDatabaseSafety.logRepositoryOpen(databaseURL: databaseURL)
#endif
        sqlite3_busy_timeout(handle, 3_000)
        do {
            try execute("PRAGMA foreign_keys = ON;")
            guard try scalarInt("PRAGMA foreign_keys;") == 1 else {
                throw LyricsRepositoryError.sqlite("foreign_keys 未启用")
            }
            // Request reservations must commit durably before the engine runs.
            try execute("PRAGMA synchronous=FULL;")
            let existingVersion = try scalarInt("PRAGMA user_version;")
            // Existing user databases follow the same forward migration path as
            // fresh installs. A consistent snapshot is required before any upgrade.
            if databaseAlreadyExisted, existingVersion < DatabaseMigrator.currentVersion {
                try createMigrationBackup(label: "pre-v\(DatabaseMigrator.currentVersion)")
            }
            try DatabaseMigrator.migrate(handle)
            guard try scalarInt("PRAGMA user_version;") == DatabaseMigrator.currentVersion else {
                throw LyricsRepositoryError.migrationFailed(
                    DatabaseMigrator.currentVersion, "数据库升级未完成，原有数据已保留。"
                )
            }
            try reloadRedirectResolver()
            prepared = true
        } catch let error as LyricsRepositoryError {
            sqlite3_close(handle)
            database = nil
            if case .sqlite = error {
                throw LyricsRepositoryError.migrationFailed(
                    DatabaseMigrator.currentVersion,
                    error.localizedDescription
                )
            }
            throw error
        } catch {
            sqlite3_close(handle)
            database = nil
            throw LyricsRepositoryError.unavailable(error.localizedDescription)
        }
    }

    public func isLyricsSelectionRevoked(identity: TrackIdentity) async throws -> Bool {
        try ensurePrepared()
        return try hasRevokedLyricsSelection(stableKey: identity.stableKey)
    }

    private func hasRevokedLyricsSelection(stableKey: String) throws -> Bool {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let query = try prepare("SELECT 1 FROM lyrics_selection_revocations WHERE track_stable_key IN (\(placeholders(count: family.count))) LIMIT 1;")
        defer { sqlite3_finalize(query) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: query) }
        let result = sqlite3_step(query)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result == SQLITE_ROW
    }

    /// Revoke the binding, never the asset. One transaction prevents either
    /// preferred fallback or a pending manual-adoption token from reviving it.
    public func revokeLyricsVersionSelection(trackStableKey: String, lyricsVersionID: UUID) async throws {
        try ensurePrepared()
        let family = try resolvedIdentityFamily(stableKey: trackStableKey)
        let canonical = try resolvedCanonicalStableKey(trackStableKey)
        guard let version = try fetchLyricsVersion(versionID: lyricsVersionID), family.contains(version.trackStableKey) else {
            throw LyricsEditingRepositoryError.identityMismatch
        }
        try withTransaction {
            let preferred = try prepare("SELECT id FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count))) AND is_preferred = 1;")
            defer { sqlite3_finalize(preferred) }
            for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: preferred) }
            var step = sqlite3_step(preferred)
            while step == SQLITE_ROW {
                guard columnText(preferred, index: 0) == lyricsVersionID.uuidString else {
                    throw LyricsRepositoryError.invalidData("当前采用版本已变化，请刷新后再取消")
                }
                step = sqlite3_step(preferred)
            }
            guard step == SQLITE_DONE else { throw lastError() }
            let clear = try prepare("UPDATE lyrics_versions SET is_preferred = 0 WHERE track_stable_key IN (\(placeholders(count: family.count)));")
            defer { sqlite3_finalize(clear) }
            for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: clear) }
            try stepDone(clear)
            let revoke = try prepare("INSERT INTO lyrics_selection_revocations(track_stable_key, revoked_version_id, updated_at) VALUES (?, ?, ?) ON CONFLICT(track_stable_key) DO UPDATE SET revoked_version_id=excluded.revoked_version_id, updated_at=excluded.updated_at;")
            defer { sqlite3_finalize(revoke) }
            try bindText(canonical, at: 1, to: revoke)
            try bindText(lyricsVersionID.uuidString, at: 2, to: revoke)
            try bindDouble(Date().timeIntervalSince1970, at: 3, to: revoke)
            try stepDone(revoke)
        }
        for key in Array(manualAdoptionRequestIDs.keys) where family.contains((try? resolvedCanonicalStableKey(key)) ?? key) {
            manualAdoptionRequestIDs.removeValue(forKey: key)
        }
    }

    public func loadBest(track: Track, identity: TrackIdentity) async throws -> LyricsDocument? {
        try await loadBestStored(track: track, identity: identity)?.document
    }

    public func loadBestStored(track: Track, identity: TrackIdentity) async throws -> StoredLyricsDocument? {
        try ensurePrepared()
        _ = track

        let canonicalKey = try resolvedCanonicalStableKey(identity.stableKey)
        guard let trackRecord = try fetchTrack(stableKey: canonicalKey) else {
            return nil
        }
        guard let version = try fetchBestVersion(stableKey: canonicalKey) else {
            return nil
        }
        let lines = try fetchLines(versionID: version.id)
        guard !lines.isEmpty else {
            // Empty rows are invalid cache state; do not expose them as lyrics.
            return nil
        }
        let sourceContentHash = LyricsSourceContentHasher.hash(
            isSynchronized: version.isSynced,
            lines: lines
        )
        var document = LyricsPersistenceMapper.document(
            identity: identity,
            track: trackRecord,
            version: version,
            lines: lines
        )
        let timingRecord = try fetchBestTimingVersion(
            lyricsVersionID: version.id,
            sourceContentHash: sourceContentHash,
            document: document
        )
        let timingMap = timingRecord.flatMap { DocumentTimingPayload.decode($0.spansPayload) }
        if let timingMap, !timingMap.isEmpty {
            var updatedLines = document.lines
            for i in updatedLines.indices {
                if let timing = timingMap[i] {
                    updatedLines[i].performerID = timing.performerID
                    updatedLines[i].timedSpans = timing.spans
                }
            }
            document = LyricsDocument(
                identity: document.identity,
                title: document.title,
                artist: document.artist,
                album: document.album,
                duration: document.duration,
                lines: updatedLines,
                isSynchronized: document.isSynchronized,
                source: document.source,
                confidence: document.confidence,
                providerSourceID: document.providerSourceID,
                spotifyTrackID: document.spotifyTrackID,
                isrc: document.isrc,
                language: document.language,
                explicitlyTimedLineIndices: document.explicitlyTimedLineIndices,
                timingVersionID: timingRecord?.id
            )
        }

        let preferenceQuery = try prepare("SELECT is_preferred FROM lyrics_versions WHERE id = ?;")
        defer { sqlite3_finalize(preferenceQuery) }
        try bindText(version.id.uuidString, at: 1, to: preferenceQuery)
        guard sqlite3_step(preferenceQuery) == SQLITE_ROW else { throw lastError() }
        let isPreferred = sqlite3_column_int(preferenceQuery, 0) != 0
        return StoredLyricsDocument(
            document: document,
            versionID: version.id,
            sourceContentHash: sourceContentHash,
            alignmentProvenanceAvailability: version.source == DatabaseSourceIdentifier.identifier(for: .automaticAlignment)
                ? alignmentProvenanceStore.availability(for: version.id)
                : .unavailable,
            isUserProtected: isPreferred || version.isLocked || version.isManuallyEdited
                || ["local", "manual", "manualEdit", "manualImport", "manualCreate"].contains(version.source)
        )
    }

    public func upsertListeningHistory(_ entry: ListeningHistoryEntry) async throws {
        try prepare()
        if entry.artworkURL != nil {
            let key = try resolvedCanonicalStableKey(entry.stableKey)
            if try fetchTrack(stableKey: key)?.artworkURL == nil {
                try upsertTrack(DatabaseTrackRecord(stableKey: key, spotifyID: nil, spotifyURI: nil, isrc: nil,
                    title: entry.title, artistDisplay: entry.artist, album: entry.album,
                    duration: entry.trackDuration ?? 0, artworkURL: entry.artworkURL?.absoluteString,
                    createdAt: entry.startedAt, updatedAt: entry.lastObservedAt))
            }
        }
        let statement = try prepare("""
            INSERT INTO listening_history_sessions(
                session_id, track_stable_key, title, artist, album,
                started_at, last_observed_at, observed_playback_duration,
                track_duration, completion_ratio
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                track_stable_key = excluded.track_stable_key,
                title = excluded.title,
                artist = excluded.artist,
                album = excluded.album,
                started_at = MIN(listening_history_sessions.started_at, excluded.started_at),
                last_observed_at = MAX(listening_history_sessions.last_observed_at, excluded.last_observed_at),
                observed_playback_duration = MAX(
                    listening_history_sessions.observed_playback_duration,
                    excluded.observed_playback_duration
                ),
                track_duration = COALESCE(excluded.track_duration, listening_history_sessions.track_duration),
                completion_ratio = COALESCE(excluded.completion_ratio, listening_history_sessions.completion_ratio);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(entry.sessionID.uuidString, at: 1, to: statement)
        try bindText(entry.stableKey, at: 2, to: statement)
        try bindText(entry.title, at: 3, to: statement)
        try bindText(entry.artist, at: 4, to: statement)
        try bindText(entry.album, at: 5, to: statement)
        try bindDouble(entry.startedAt.timeIntervalSince1970, at: 6, to: statement)
        try bindDouble(entry.lastObservedAt.timeIntervalSince1970, at: 7, to: statement)
        try bindDouble(entry.observedPlaybackDuration, at: 8, to: statement)
        try bindDouble(entry.trackDuration, at: 9, to: statement)
        try bindDouble(entry.completionRatio, at: 10, to: statement)
        try stepDone(statement)
    }

    /// Never turn a locked, interrupted or otherwise failed read into an empty/partial success.
    private func stepListeningHistoryRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw lastError()
        }
    }

    private func listeningArtworkURL(stableKey: String) throws -> URL? {
        for key in try resolvedIdentityFamily(stableKey: stableKey) {
            if let text = try fetchTrack(stableKey: key)?.artworkURL, let url = URL(string: text) { return url }
        }
        return nil
    }

    public func loadListeningHistory(limit: Int) async throws -> [ListeningHistoryEntry] {
        try prepare()
        let statement = try prepare("""
            SELECT session_id, track_stable_key, title, artist, album,
                   started_at, last_observed_at, observed_playback_duration,
                   track_duration, completion_ratio
            FROM listening_history_sessions
            ORDER BY started_at DESC, last_observed_at DESC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bindInt(max(1, min(limit, 500)), at: 1, to: statement)

        var entries: [ListeningHistoryEntry] = []
        while try stepListeningHistoryRow(statement) {
            guard let sessionIDText = columnText(statement, index: 0),
                  let sessionID = UUID(uuidString: sessionIDText),
                  let stableKey = columnText(statement, index: 1),
                  let title = columnText(statement, index: 2),
                  let artist = columnText(statement, index: 3),
                  let album = columnText(statement, index: 4) else {
                continue
            }
            entries.append(ListeningHistoryEntry(
                sessionID: sessionID,
                stableKey: stableKey,
                title: title,
                artist: artist,
                album: album,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                observedPlaybackDuration: sqlite3_column_double(statement, 7),
                trackDuration: columnDouble(statement, index: 8),
                completionRatio: columnDouble(statement, index: 9),
                artworkURL: try listeningArtworkURL(stableKey: stableKey)
            ))
        }
        return entries
    }

    public func loadListeningStatistics(
        for timeRange: ListeningStatisticsTimeRange
    ) async throws -> ListeningStatistics {
        try prepare()
        let lowerBound = timeRange.lowerBound.timeIntervalSince1970

        let summaryStatement = try prepare("""
            SELECT COALESCE(SUM(observed_playback_duration), 0), COUNT(*), COUNT(DISTINCT track_stable_key)
            FROM listening_history_sessions
            WHERE last_observed_at >= ?;
            """)
        defer { sqlite3_finalize(summaryStatement) }
        try bindDouble(lowerBound, at: 1, to: summaryStatement)
        guard sqlite3_step(summaryStatement) == SQLITE_ROW else { throw lastError() }
        let totalListeningTime = sqlite3_column_double(summaryStatement, 0)
        let sessionCount = Int(sqlite3_column_int(summaryStatement, 1))
        let uniqueSongCount = Int(sqlite3_column_int(summaryStatement, 2))
        guard sqlite3_step(summaryStatement) == SQLITE_DONE else { throw lastError() }

        let songsStatement = try prepare("""
            SELECT track_stable_key, MIN(title), MIN(artist),
                   SUM(observed_playback_duration), COUNT(*)
            FROM listening_history_sessions
            WHERE last_observed_at >= ?
            GROUP BY track_stable_key
            ORDER BY SUM(observed_playback_duration) DESC, track_stable_key ASC
            LIMIT 50;
            """)
        defer { sqlite3_finalize(songsStatement) }
        try bindDouble(lowerBound, at: 1, to: songsStatement)
        var topSongs: [ListeningStatisticsSong] = []
        while try stepListeningHistoryRow(songsStatement) {
            guard let stableKey = columnText(songsStatement, index: 0),
                  let title = columnText(songsStatement, index: 1),
                  let artist = columnText(songsStatement, index: 2) else {
                continue
            }
            topSongs.append(ListeningStatisticsSong(
                stableKey: stableKey,
                title: title,
                artist: artist,
                observedListeningTime: sqlite3_column_double(songsStatement, 3),
                sessionCount: Int(sqlite3_column_int(songsStatement, 4)),
                artworkURL: try listeningArtworkURL(stableKey: stableKey)
            ))
        }

        let artistsStatement = try prepare("""
            SELECT artist, SUM(observed_playback_duration), COUNT(*)
            FROM listening_history_sessions
            WHERE last_observed_at >= ?
            GROUP BY artist
            ORDER BY SUM(observed_playback_duration) DESC, artist ASC
            LIMIT 50;
            """)
        defer { sqlite3_finalize(artistsStatement) }
        try bindDouble(lowerBound, at: 1, to: artistsStatement)
        var topArtists: [ListeningStatisticsArtist] = []
        while try stepListeningHistoryRow(artistsStatement) {
            guard let artist = columnText(artistsStatement, index: 0) else { continue }
            topArtists.append(ListeningStatisticsArtist(
                artist: artist,
                observedListeningTime: sqlite3_column_double(artistsStatement, 1),
                sessionCount: Int(sqlite3_column_int(artistsStatement, 2))
            ))
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        let trendLowerBound = sevenDaysAgo.timeIntervalSince1970
        let trendStatement = try prepare("""
            SELECT strftime('%Y-%m-%d', started_at, 'unixepoch', 'localtime'), COUNT(*)
            FROM listening_history_sessions
            WHERE started_at >= ?
            GROUP BY 1;
            """)
        defer { sqlite3_finalize(trendStatement) }
        try bindDouble(trendLowerBound, at: 1, to: trendStatement)
        var countsByDateString: [String: Int] = [:]
        while try stepListeningHistoryRow(trendStatement) {
            if let dateString = columnText(trendStatement, index: 0) {
                countsByDateString[dateString] = Int(sqlite3_column_int(trendStatement, 1))
            }
        }

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoFormatter.timeZone = .current

        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "M/d"
        labelFormatter.locale = Locale(identifier: "zh_CN")
        labelFormatter.timeZone = .current

        var dailyPlayCounts: [ListeningStatisticsDailyCount] = []
        for offset in 0..<7 {
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: sevenDaysAgo) else { continue }
            let key = isoFormatter.string(from: dayDate)
            let count = countsByDateString[key] ?? 0
            let label = labelFormatter.string(from: dayDate)
            dailyPlayCounts.append(ListeningStatisticsDailyCount(date: dayDate, dayLabel: label, count: count))
        }

        return ListeningStatistics(
            timeRange: timeRange,
            totalListeningTime: totalListeningTime,
            sessionCount: sessionCount,
            uniqueSongCount: uniqueSongCount,
            topSongs: topSongs,
            topArtists: topArtists,
            dailyPlayCounts: dailyPlayCounts
        )
    }

    public func loadAliases(stableKey: String) async throws -> [TrackAlias] {
        try loadTrackAliases(stableKey: stableKey).compactMap { record in
            guard let field = TrackAliasField(rawValue: record.field),
                  let kind = TrackAliasKind(rawValue: record.kind),
                  let script = TrackAliasScript(rawValue: record.script),
                  let source = TrackAliasSource(rawValue: record.source) else {
                return nil
            }
            let id = "db-alias:\(record.trackStableKey):\(record.field):\(record.kind):\(record.value)"
            return TrackAlias(
                id: id,
                field: field,
                kind: kind,
                value: record.value,
                language: record.language,
                script: script,
                source: source,
                confidence: record.confidence,
                isOfficial: record.isOfficial
            )
        }
    }

    public func alignmentProvenanceAvailability(versionID: UUID) async -> AlignmentProvenanceAvailability {
        alignmentProvenanceStore.availability(for: versionID)
    }

    public func saveTrackMetadata(_ metadata: TrackMetadata) throws {
        try ensurePrepared()
        let canonicalKey = try resolvedCanonicalStableKey(metadata.identity.stableKey)
        let now = Date()
        let rawTrackRecord = LyricsPersistenceMapper.trackRecord(
            track: metadata.track,
            identity: metadata.identity,
            now: now
        )
        let trackRecord = canonicalTrackRecord(rawTrackRecord, stableKey: canonicalKey)
        let aliases = LyricsPersistenceMapper.aliasRecords(metadata: metadata, now: now)
            .map { canonicalAliasRecord($0, stableKey: canonicalKey) }
        try withTransaction {
            try upsertTrack(trackRecord)
            for alias in aliases {
                try insertAlias(alias)
            }
        }
    }

    public func save(
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument
    ) throws -> LyricsPersistenceSaveResult {
        try saveValidated(track: track, identity: identity, document: document, automaticSelection: false)
    }

    public func saveAutomaticallySelected(track: Track, identity: TrackIdentity, document: LyricsDocument, decision: LyricsAutomaticSelectionEvidence) async throws -> LyricsPersistenceSaveResult {
        guard (decision.tier == "autoHigh" || decision.tier == "autoMedium"), !decision.hardReject, !decision.versionConflict, decision.identity == identity,
              TrackIdentity(track: track) == identity, document.confidence.isFinite, (0...1).contains(document.confidence) else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("自动选择缺少有效匹配证据"))
        }
        return try saveValidated(track: track, identity: identity, document: document, automaticSelection: true)
    }

    private func saveValidated(track: Track, identity: TrackIdentity, document: LyricsDocument, automaticSelection: Bool) throws -> LyricsPersistenceSaveResult {
        try ensurePrepared()

        guard document.identity == identity else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("歌词身份与当前 TrackIdentity 不一致")
            )
        }
        guard !document.lines.isEmpty,
              document.lines.contains(where: {
                  !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("空歌词不写入"))
        }
        guard document.source != .mock else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("Mock 歌词不写入"))
        }
        guard automaticSelection || LyricsMatcher.isHighConfidence(document.confidence) else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("低置信度歌词不写入")
            )
        }

        let canonicalKey = try resolvedCanonicalStableKey(identity.stableKey)
        guard !Task.isCancelled, !(try hasRevokedLyricsSelection(stableKey: canonicalKey)) else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("已取消采用，不自动恢复歌词"))
        }
        let now = Date()
        let rawTrackRecord = LyricsPersistenceMapper.trackRecord(track: track, identity: identity, now: now)
        let trackRecord = canonicalTrackRecord(rawTrackRecord, stableKey: canonicalKey)
        let versionID = UUID()
        let rawVersionRecord = LyricsPersistenceMapper.versionRecord(
            document: document,
            identity: identity,
            versionID: versionID,
            now: now
        )
        let versionRecord = canonicalVersionRecord(rawVersionRecord, stableKey: canonicalKey)
        let aliases = LyricsPersistenceMapper.aliasRecords(
            track: track,
            identity: identity,
            document: document,
            now: now
        ).map { canonicalAliasRecord($0, stableKey: canonicalKey) }
        let lines = LyricsPersistenceMapper.lineRecords(document: document, versionID: versionID)
        let sourceContentHash = LyricsSourceContentHasher.hash(
            isSynchronized: document.isSynchronized,
            lines: lines
        )

        return try withTransaction {
            try upsertTrack(trackRecord)
            for alias in aliases {
                try insertAlias(alias)
            }

            if let duplicateID = try findVersionID(
                stableKey: canonicalKey,
                source: versionRecord.source,
                providerSourceID: versionRecord.providerSourceID,
                contentHash: versionRecord.contentHash
            ) {
                try attachTimingVersionIfNeeded(
                    document: document,
                    lyricsVersionID: duplicateID,
                    source: versionRecord.source,
                    sourceContentHash: sourceContentHash,
                    now: now
                )
                return LyricsPersistenceSaveResult(
                    versionID: duplicateID,
                    disposition: .duplicate,
                    sourceContentHash: sourceContentHash
                )
            }

            if try hasLockedVersion(stableKey: canonicalKey) {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .skippedLocked)
            }

            try insertVersion(versionRecord)
            if automaticSelection && document.isSynchronized {
                let prefer = try prepare("UPDATE lyrics_versions SET is_preferred = 1 WHERE id = ? AND NOT EXISTS (SELECT 1 FROM lyrics_versions WHERE track_stable_key = ? AND (is_preferred = 1 OR is_locked = 1 OR is_manually_edited = 1));")
                defer { sqlite3_finalize(prefer) }
                try bindText(versionID.uuidString, at: 1, to: prefer)
                try bindText(canonicalKey, at: 2, to: prefer)
                try stepDone(prefer)
            }
            for line in lines {
                try insertLine(line)
            }
            try attachTimingVersionIfNeeded(
                document: document,
                lyricsVersionID: versionID,
                source: versionRecord.source,
                sourceContentHash: sourceContentHash,
                now: now
            )
            return LyricsPersistenceSaveResult(
                versionID: versionID,
                disposition: .inserted,
                sourceContentHash: sourceContentHash
            )
        }
    }

    /// Persists an explicit user choice. Automatic `save` deliberately keeps
    /// its high-confidence gate; only this user-intent path may save a lower
    /// provider confidence, and it commits the preferred selection together
    /// with the lyric rows and any timing attachment.
    public func saveAndAdoptManually(
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument,
        requestID: UUID,
        confirmedLockedVersionIDs: [UUID]?
    ) async throws -> LyricsPersistenceSaveResult {
        try ensurePrepared()
        guard document.identity == identity,
              TrackIdentity(track: track) == identity else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("歌词身份与当前歌曲不一致")
            )
        }
        guard !document.lines.isEmpty,
              document.lines.contains(where: {
                  !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("空歌词不写入"))
        }
        guard document.source != .mock else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("Mock 歌词不写入"))
        }
        guard document.confidence.isFinite, (0.0...1.0).contains(document.confidence) else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("歌词置信度无效"))
        }
        if let declaredSpotifyID = document.spotifyTrackID,
           !declaredSpotifyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalizedID = TrackIdentity.canonicalSpotifyTrackID(declaredSpotifyID) else {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("候选 Spotify 歌曲身份无效"))
            }
            if let expectedID = identity.spotifyTrackID, normalizedID != expectedID {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("候选 Spotify 歌曲身份与当前歌曲不一致"))
            }
        }
        if let declaredISRC = document.isrc,
           let expectedISRC = identity.isrc,
           TrackIdentity.normalizeIdentifier(declaredISRC) != expectedISRC {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("候选 ISRC 与当前歌曲不一致"))
        }
        guard !Task.isCancelled else { throw CancellationError() }
        guard manualAdoptionRequestIDs[identity.stableKey] == requestID else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("歌词采用请求已被更新或取消")
            )
        }

        let canonicalKey = try resolvedCanonicalStableKey(identity.stableKey)
        let now = Date()
        let trackRecord = canonicalTrackRecord(
            LyricsPersistenceMapper.trackRecord(track: track, identity: identity, now: now),
            stableKey: canonicalKey
        )
        let rawVersionRecord = LyricsPersistenceMapper.versionRecord(
            document: document,
            identity: identity,
            versionID: UUID(),
            now: now
        )
        let versionRecord = canonicalVersionRecord(rawVersionRecord, stableKey: canonicalKey)
        let aliases = LyricsPersistenceMapper.aliasRecords(
            track: track,
            identity: identity,
            document: document,
            now: now
        ).map { canonicalAliasRecord($0, stableKey: canonicalKey) }
        let lines = LyricsPersistenceMapper.lineRecords(document: document, versionID: versionRecord.id)
        let sourceContentHash = LyricsSourceContentHasher.hash(
            isSynchronized: document.isSynchronized,
            lines: lines
        )

        let result = try withTransaction {
            guard !Task.isCancelled else { throw CancellationError() }
            guard manualAdoptionRequestIDs[identity.stableKey] == requestID else {
                return LyricsPersistenceSaveResult(
                    versionID: nil,
                    disposition: .rejected("歌词采用请求已被更新或取消")
                )
            }
            let duplicateID = try findVersionID(
                stableKey: canonicalKey,
                source: versionRecord.source,
                providerSourceID: versionRecord.providerSourceID,
                contentHash: versionRecord.contentHash
            )
            let lockedIDs = try fetchLockedVersionIDs(stableKey: canonicalKey)
            let conflictingLockedIDs = lockedIDs.filter { $0 != duplicateID }
            let confirmedIDs = Set(confirmedLockedVersionIDs ?? [])
            let newlyLockedIDs = conflictingLockedIDs.filter { !confirmedIDs.contains($0) }
            if confirmedLockedVersionIDs == nil, !conflictingLockedIDs.isEmpty {
                return LyricsPersistenceSaveResult(
                    versionID: nil,
                    disposition: .lockedConflict,
                    conflictingLockedVersionIDs: conflictingLockedIDs
                )
            }
            if confirmedLockedVersionIDs != nil, !newlyLockedIDs.isEmpty {
                return LyricsPersistenceSaveResult(
                    versionID: nil,
                    disposition: .lockedConflict,
                    conflictingLockedVersionIDs: conflictingLockedIDs
                )
            }

            try upsertTrack(trackRecord)
            for alias in aliases {
                try insertAlias(alias)
            }

            let versionID = duplicateID ?? versionRecord.id
            if duplicateID == nil {
                try insertVersion(versionRecord)
                for line in lines {
                    try insertLine(line)
                }
            }
            var attachmentDocument = document
            if let suppliedTimingID = document.timingVersionID,
               let suppliedTiming = try fetchTimingVersion(id: suppliedTimingID),
               suppliedTiming.lyricsVersionID != versionID {
                // A timing attachment is immutable and belongs to its parent
                // lyrics version. Copy its validated spans into a fresh child
                // attachment instead of reusing the parent's identity.
                attachmentDocument = document.replacingLines(document.lines, timingVersionID: nil)
            }
            let persistedTimingVersionID = try attachTimingVersionIfNeeded(
                document: attachmentDocument,
                lyricsVersionID: versionID,
                source: versionRecord.source,
                sourceContentHash: sourceContentHash,
                now: now
            )
            try setPreferredLyricsVersion(trackStableKey: canonicalKey, lyricsVersionID: versionID, clearRevocation: true)
            return LyricsPersistenceSaveResult(
                versionID: versionID,
                disposition: duplicateID == nil ? .inserted : .duplicate,
                sourceContentHash: sourceContentHash,
                timingVersionID: persistedTimingVersionID
            )
        }
        if result.versionID != nil,
           manualAdoptionRequestIDs[identity.stableKey] == requestID {
            manualAdoptionRequestIDs.removeValue(forKey: identity.stableKey)
        }
        return result
    }

    public func registerManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws {
        try prepare()
        manualAdoptionRequestIDs[identity.stableKey] = requestID
    }

    public func cancelManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws {
        guard manualAdoptionRequestIDs[identity.stableKey] == requestID else { return }
        manualAdoptionRequestIDs.removeValue(forKey: identity.stableKey)
    }

    public func saveAlignedVersion(_ request: AlignmentPersistenceRequest) async throws -> LyricsPersistenceSaveResult {
        try ensurePrepared()
        let canonicalKey = try resolvedCanonicalStableKey(request.identity.stableKey)
        guard request.document.identity == request.identity,
              request.report.identity == request.identity,
              TrackIdentity(track: request.track) == request.identity else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("排轴身份与当前歌曲不一致")
            )
        }
        guard request.document.isSynchronized else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴结果必须包含有效时间轴"))
        }
        guard request.report.sourceVersionID == request.parentVersionID,
              request.report.sourceContentHash == request.parentSourceContentHash,
              !request.parentSourceContentHash.isEmpty else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴来源版本指纹不一致"))
        }
        let hasUnresolvedReportLine = request.report.lines.contains {
            $0.startTime < 0 || $0.evidence.kind == .noEvidence
        }
        guard request.report.lines.count == request.document.lines.count,
              request.report.lines.count > 0,
              !hasUnresolvedReportLine else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴结果不完整，未写入"))
        }
        if request.lockResult, request.report.lowConfidenceCount > 0 {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("低置信度排轴必须先人工修正，不能直接锁定"))
        }

        guard let parent = try fetchLyricsVersion(versionID: request.parentVersionID),
              try resolvedCanonicalStableKey(parent.trackStableKey) == canonicalKey,
              !parent.isSynced else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴父版本不存在或已经有时间轴"))
        }
        let parentLines = try fetchLines(versionID: request.parentVersionID)
        guard !parentLines.isEmpty,
              parentLines.count == request.document.lines.count else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴父版本行集合不一致"))
        }
        let parentHash = LyricsSourceContentHasher.hash(isSynchronized: false, lines: parentLines)
        guard parentHash == request.parentSourceContentHash else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴父歌词内容已经变化"))
        }

        for index in request.document.lines.indices {
            let source = parentLines[index]
            let aligned = request.document.lines[index]
            guard source.lineIndex == index,
                  source.originalText == aligned.originalText,
                  source.kanaText == aligned.kanaText,
                  source.romajiText == aligned.romajiText,
                  aligned.timestamp.isFinite,
                  aligned.timestamp >= 0,
                  aligned.timestamp <= request.report.audioDuration,
                  aligned.endTime.map({ $0.isFinite && $0 >= aligned.timestamp && $0 <= request.report.audioDuration }) ?? true else {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴行内容或时间无效"))
            }
            if index > 0, aligned.timestamp < request.document.lines[index - 1].timestamp {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("排轴时间必须单调不减"))
            }
        }

        let now = Date()
        let versionID = UUID()
        let lines = LyricsPersistenceMapper.lineRecords(document: request.document, versionID: versionID)
        let sourceContentHash = LyricsSourceContentHasher.hash(isSynchronized: true, lines: lines)
        let providerSourceID = [
            "alignment", request.report.modelID, request.report.parameters.algorithmVersion,
            request.report.audioSHA256, request.parentSourceContentHash
        ].joined(separator: ":")
        let versionRecord = DatabaseLyricsVersionRecord(
            id: versionID,
            trackStableKey: canonicalKey,
            parentVersionID: request.parentVersionID,
            source: DatabaseSourceIdentifier.identifier(for: .automaticAlignment),
            providerSourceID: providerSourceID,
            language: "und",
            isSynced: true,
            rawText: request.document.lines.map(\.originalText).joined(separator: "\n"),
            contentHash: sourceContentHash,
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: true,
            isManuallyEdited: true,
            isLocked: request.lockResult,
            confidence: request.report.overallConfidence
        )
        let rawTrackRecord = LyricsPersistenceMapper.trackRecord(track: request.track, identity: request.identity, now: now)
        let trackRecord = canonicalTrackRecord(rawTrackRecord, stableKey: canonicalKey)
        let aliases = LyricsPersistenceMapper.aliasRecords(
            track: request.track,
            identity: request.identity,
            document: request.document,
            now: now
        ).map { canonicalAliasRecord($0, stableKey: canonicalKey) }

        let disposition = try withTransaction {
            try upsertTrack(trackRecord)
            for alias in aliases { try insertAlias(alias) }
            if let duplicate = try findVersionID(
                stableKey: canonicalKey,
                source: versionRecord.source,
                providerSourceID: versionRecord.providerSourceID,
                contentHash: versionRecord.contentHash
            ) {
                return LyricsPersistenceSaveResult(
                    versionID: duplicate,
                    disposition: .duplicate,
                    sourceContentHash: sourceContentHash
                )
            }
            try insertVersion(versionRecord)
            for line in lines { try insertLine(line) }
            return LyricsPersistenceSaveResult(
                versionID: versionID,
                disposition: .inserted,
                sourceContentHash: sourceContentHash
            )
        }

        guard disposition.disposition == .inserted else {
            if let id = disposition.versionID { try setPersonalLibraryActiveLyrics(trackStableKey: canonicalKey, lyricsVersionID: id) }
            return disposition
        }
        do {
            _ = try alignmentProvenanceStore.write(
                versionID: versionID,
                parentVersionID: request.parentVersionID,
                report: request.report
            )
        } catch {
            try? deleteVersionRows(versionID: versionID)
            try? alignmentProvenanceStore.remove(versionID: versionID)
            throw LyricsRepositoryError.unavailable("排轴 provenance 保存失败：\(error.localizedDescription)")
        }
        try setPersonalLibraryActiveLyrics(trackStableKey: canonicalKey, lyricsVersionID: versionID)
        return disposition
    }

    public func deleteLyricsVersion(versionID: UUID) async throws {
        try ensurePrepared()
        try withTransaction { try deleteVersionRows(versionID: versionID) }
        try alignmentProvenanceStore.remove(versionID: versionID)
    }

    public func markLocked(versionID: UUID, locked: Bool) throws {
        try ensurePrepared()
        if locked,
           let record = try fetchLyricsVersion(versionID: versionID),
           record.source == DatabaseSourceIdentifier.identifier(for: .automaticAlignment),
           !alignmentProvenanceStore.isLockable(versionID: versionID) {
            throw LyricsRepositoryError.invalidData("排轴 provenance 不可用或存在低置信行，不能锁定")
        }
        let statement = try prepare("UPDATE lyrics_versions SET is_locked = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindInt(locked ? 1 : 0, at: 1, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 2, to: statement)
        try bindText(versionID.uuidString, at: 3, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else {
            throw LyricsRepositoryError.invalidData("找不到歌词版本 \(versionID.uuidString)")
        }
    }

    // Contract/audit helpers. They remain storage-only and do not form part
    // of the playback/UI API.
    public func schemaVersion() throws -> Int {
        try ensurePrepared()
        return try scalarInt("PRAGMA user_version;")
    }

    public func foreignKeysEnabled() throws -> Bool {
        try ensurePrepared()
        return try scalarInt("PRAGMA foreign_keys;") == 1
    }

    public func versionCount(trackStableKey: String) throws -> Int {
        try ensurePrepared()
        let family = try resolvedIdentityFamily(stableKey: trackStableKey)
        let statement = try prepare("SELECT COUNT(*) FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count)));")
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Storage-only identity helpers used by migration and black-box
    /// acceptance tests. They intentionally expose no SQL handles.
    public func resolveStableKey(_ stableKey: String) throws -> String {
        try ensurePrepared()
        return try resolvedCanonicalStableKey(stableKey)
    }

    /// Returns a canonical offset scope only when the requested saved version
    /// belongs to the supplied track identity family. This is a read-only
    /// validation path; it does not create track/version rows or redirects.
    public func canonicalStableKeyForSavedLyricsVersion(
        trackStableKey: String,
        versionID: UUID
    ) async throws -> String? {
        try ensurePrepared()
        let requestedCanonicalKey = try resolvedCanonicalStableKey(trackStableKey)
        let statement = try prepare("SELECT track_stable_key FROM lyrics_versions WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw lastError()
        }
        guard let storedTrackKey = columnText(statement, index: 0),
              try resolvedCanonicalStableKey(storedTrackKey) == requestedCanonicalKey else {
            return nil
        }
        return requestedCanonicalKey
    }

    public func identityFamily(stableKey: String) throws -> [String] {
        try ensurePrepared()
        return try resolvedIdentityFamily(stableKey: stableKey)
    }

    public func redirectCount() throws -> Int {
        try ensurePrepared()
        guard try hasTable("track_identity_redirects") else { return 0 }
        return try scalarInt("SELECT COUNT(*) FROM track_identity_redirects;")
    }

    public func loadTrackAliases(stableKey: String) throws -> [DatabaseTrackAliasRecord] {
        try ensurePrepared()
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("""
            SELECT track_stable_key, field, kind, value, language, script,
                   source, confidence, is_official
            FROM track_aliases
            WHERE track_stable_key IN (\(placeholders(count: family.count)))
            ORDER BY CASE WHEN track_stable_key = ? THEN 0 ELSE 1 END,
                     track_stable_key, field, kind, value;
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        try bindText(family[0], at: Int32(family.count + 1), to: statement)

        var result: [DatabaseTrackAliasRecord] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, index: 0),
                  let field = columnText(statement, index: 1),
                  let kind = columnText(statement, index: 2),
                  let value = columnText(statement, index: 3),
                  let script = columnText(statement, index: 5),
                  let source = columnText(statement, index: 6) else {
                throw LyricsRepositoryError.invalidData("TrackAliasRecord 字段缺失")
            }
            let dedupeKey = [field, kind, value].joined(separator: "\u{1f}")
            guard seen.insert(dedupeKey).inserted else { continue }
            result.append(DatabaseTrackAliasRecord(
                trackStableKey: key,
                field: field,
                kind: kind,
                value: value,
                language: columnText(statement, index: 4),
                script: script,
                source: source,
                confidence: sqlite3_column_double(statement, 7),
                isOfficial: sqlite3_column_int(statement, 8) != 0
            ))
        }
        return result
    }

    public func hasUniqueTranslationVersionIndex() throws -> Bool {
        try ensurePrepared()
        let statement = try prepare("PRAGMA index_list('translation_versions');")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            // PRAGMA index_list columns: seq, name, unique, origin, partial.
            // The primary-key auto-index is required for version IDs and does
            // not constrain model/host/prompt retranslation. Reject only
            // additional unique indexes.
            let origin = columnText(statement, index: 3) ?? ""
            if sqlite3_column_int(statement, 2) != 0, origin != "pk" { return true }
        }
        return false
    }

    public func statistics() throws -> LyricsDatabaseStats {
        try prepare()
        let trackCount = try scalarInt("SELECT COUNT(*) FROM tracks;")
        let lyricsVersionCount = try scalarInt("SELECT COUNT(*) FROM lyrics_versions;")
        let lyricLineCount = try scalarInt("SELECT COUNT(*) FROM lyric_lines;")
        let lastUpdatedSeconds = try scalarOptionalDouble("""
            SELECT MAX(updated_at) FROM (
                SELECT updated_at FROM tracks
                UNION ALL
                SELECT updated_at FROM lyrics_versions
            );
            """)
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return LyricsDatabaseStats(
            databaseURL: databaseURL,
            schemaVersion: try schemaVersion(),
            trackCount: trackCount,
            lyricsVersionCount: lyricsVersionCount,
            lyricLineCount: lyricLineCount,
            fileSize: fileSize,
            lastUpdated: lastUpdatedSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    public func createBackup() throws -> URL {
        try prepare()
        // Checkpoint before copying so a usable backup does not depend on a
        // separate -wal sidecar file.
        try execute("PRAGMA wal_checkpoint(FULL);")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = databaseURL.deletingPathExtension().lastPathComponent
        var backupURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).backup-\(formatter.string(from: Date())).sqlite3")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL.deleteLastPathComponent()
            backupURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName).backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlite3")
        }
        do {
            try FileManager.default.copyItem(at: databaseURL, to: backupURL)
        } catch {
            throw LyricsRepositoryError.unavailable("数据库备份失败：\(error.localizedDescription)")
        }
        return backupURL
    }

    public func clearLyricsCache() throws {
        try prepare()
        let versionIDs = try fetchAllVersionIDs()
        try withTransaction {
            try execute("DELETE FROM lyric_lines;")
            try execute("DELETE FROM lyrics_versions;")
        }
        for versionID in versionIDs {
            try? alignmentProvenanceStore.remove(versionID: versionID)
        }
    }

    // MARK: - TranslationRepository

    public func loadTranslationRequest(key: String) async throws -> StoredTranslationRequest? {
        try readTranslationRequest(key: key)
    }

    private func readTranslationRequest(key: String) throws -> StoredTranslationRequest? {
        try ensurePrepared()
        let statement = try prepare("SELECT attempt_id, phase, result_json, updated_at FROM translation_requests WHERE request_key = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(key, at: 1, to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)),
              let phase = columnText(statement, index: 1).flatMap(TranslationRequestPhase.init(rawValue:)),
              let time = columnDouble(statement, index: 3) else {
            throw TranslationRepositoryError.database("请求状态不可读；未重新发送")
        }
        let draft = try columnText(statement, index: 2).map { try JSONDecoder().decode(AITranslationDraft.self, from: Data($0.utf8)) }
        return StoredTranslationRequest(key: key, attemptID: id, phase: phase, result: draft, updatedAt: Date(timeIntervalSince1970: time))
    }

    public func beginTranslationRequest(key: String, explicitRetry: Bool) async throws -> StoredTranslationRequest {
        try ensurePrepared()
        return try withTransaction {
            if let prior = try readTranslationRequest(key: key), prior.phase != .prepared, !explicitRetry {
                throw TranslationRepositoryError.database("上次翻译已发起，结果尚未确认；请主动重试，不会自动重发")
            }
            let request = StoredTranslationRequest(key: key)
            let statement = try prepare("INSERT OR REPLACE INTO translation_requests(request_key, attempt_id, phase, result_json, updated_at) VALUES (?, ?, 'prepared', NULL, ?);")
            defer { sqlite3_finalize(statement) }
            try bindText(key, at: 1, to: statement)
            try bindText(request.attemptID.uuidString, at: 2, to: statement)
            try bindDouble(request.updatedAt.timeIntervalSince1970, at: 3, to: statement)
            try stepDone(statement)
            return request
        }
    }

    public func updateTranslationRequest(_ request: StoredTranslationRequest) async throws {
        try ensurePrepared()
        try withTransaction {
            guard let previous = try readTranslationRequest(key: request.key), previous.attemptID == request.attemptID,
                  (previous.phase == .prepared && request.phase == .dispatching) ||
                  (previous.phase == .dispatching && request.phase == .received && request.result != nil) ||
                  (previous.phase == .received && request.phase == .saved) else {
                throw TranslationRepositoryError.database("请求代次或阶段已改变；拒绝迟到结果")
            }
            let statement = try prepare("UPDATE translation_requests SET phase = ?, result_json = ?, updated_at = ? WHERE request_key = ? AND attempt_id = ?;")
            defer { sqlite3_finalize(statement) }
            try bindText(request.phase.rawValue, at: 1, to: statement)
            let payload = try request.result.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            try bindText(payload, at: 2, to: statement)
            try bindDouble(request.updatedAt.timeIntervalSince1970, at: 3, to: statement)
            try bindText(request.key, at: 4, to: statement)
            try bindText(request.attemptID.uuidString, at: 5, to: statement)
            try stepDone(statement)
        }
    }

    public func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) throws -> [StoredTranslationVersion] {
        try ensurePrepared()
        guard let source = try fetchSourceLyrics(versionID: lyricsVersionID) else {
            throw TranslationRepositoryError.sourceLyricsNotFound
        }
        guard source.hash == sourceContentHash else {
            throw TranslationRepositoryError.sourceContentMismatch
        }

        let statement = try prepare("""
            SELECT id, lyrics_version_id, parent_version_id, source_kind, target_language, model,
                   base_url_host, prompt_hash, source_content_hash, created_at,
                   updated_at, is_machine_generated, is_manually_edited,
                   is_locked, status, confidence, engine_id, prompt_preset_id,
                   profile_id, profile_snapshot, temperature, workflow_id,
                   fallback_strategy, is_draft, is_archived, provider_execution_metadata_json
            FROM translation_versions
            WHERE lyrics_version_id = ? AND target_language = ?
              AND source_content_hash = ?
            ORDER BY is_locked DESC, updated_at DESC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(lyricsVersionID.uuidString, at: 1, to: statement)
        try bindText(targetLanguage, at: 2, to: statement)
        try bindText(sourceContentHash, at: 3, to: statement)

        var result: [StoredTranslationVersion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let record = try translationVersionRecord(from: statement)
            let lines = try fetchTranslationLines(versionID: record.id)
            guard validateStoredTranslation(
                record: record,
                lines: lines,
                sourceLines: source.lines
            ) else { continue }
            result.append(StoredTranslationVersion(record: record, lines: lines))
        }
        return result
    }

    public func saveTranslation(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        originalLines: [String],
        draft: AITranslationDraft,
        forceNewVersion: Bool
    ) throws -> StoredTranslationVersion {
        try ensurePrepared()
        _ = forceNewVersion // Every completed explicit request gets a new ID.
        guard let source = try fetchSourceLyrics(versionID: lyricsVersionID) else {
            throw TranslationRepositoryError.sourceLyricsNotFound
        }
        guard source.hash == sourceContentHash,
              source.lines.map(\.originalText) == originalLines,
              draft.sourceContentHash == sourceContentHash else {
            throw TranslationRepositoryError.sourceContentMismatch
        }
        guard draft.lines.count == source.lines.count,
              draft.lines.map(\.index) == Array(source.lines.indices) else {
            throw TranslationRepositoryError.invalidLines("行数或 index 不匹配")
        }
        for line in draft.lines {
            let sourceText = source.lines[line.index].originalText
            let sourceBlank = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let translationBlank = line.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard sourceBlank == translationBlank,
                  !sourceBlank || line.translation.isEmpty,
                  !line.translation.contains("\n"),
                  !line.translation.contains("\r") else {
                throw TranslationRepositoryError.invalidLines("空白行或换行规则不匹配")
            }
        }

        let now = Date()
        let versionID = UUID()
        let record = DatabaseTranslationVersionRecord(
            id: versionID,
            lyricsVersionID: lyricsVersionID,
            sourceKind: draft.sourceKind,
            targetLanguage: draft.targetLanguage,
            model: draft.model,
            baseURLHost: draft.baseURLHost,
            promptHash: draft.promptHash,
            sourceContentHash: sourceContentHash,
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: draft.isMachineGenerated,
            isManuallyEdited: draft.isManuallyEdited,
            isLocked: false,
            status: .complete,
            confidence: draft.confidence,
            engineID: draft.engineID,
            promptPresetID: draft.promptPresetID,
            profileID: draft.profileID,
            profileSnapshot: draft.profileSnapshot,
            temperature: draft.temperature,
            workflowID: draft.workflowID,
            fallbackStrategy: draft.fallbackStrategy,
            providerExecutionMetadata: AITranslationProviderExecutionMetadata(
                reasoningSetting: draft.providerReasoningSetting, tokenUsage: draft.tokenUsage, cacheIdentity: draft.providerCacheIdentity
            ),
            isDraft: draft.isDraft,
            isArchived: draft.isArchived
        )
        let lines = draft.lines.map {
            DatabaseTranslationLineRecord(
                translationVersionID: versionID,
                lineIndex: $0.index,
                translatedText: $0.translation
            )
        }

        try withTransaction {
            try insertTranslationVersion(record)
            for line in lines { try insertTranslationLine(line) }
        }
        return StoredTranslationVersion(record: record, lines: lines)
    }

    public func markTranslationLocked(versionID: UUID, locked: Bool) throws {
        try ensurePrepared()
        let statement = try prepare("UPDATE translation_versions SET is_locked = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindInt(locked ? 1 : 0, at: 1, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 2, to: statement)
        try bindText(versionID.uuidString, at: 3, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw TranslationRepositoryError.versionNotFound }
    }

    public func deleteTranslation(versionID: UUID) throws {
        try ensurePrepared()
        let statement = try prepare("DELETE FROM translation_versions WHERE id = ? AND is_locked = 0;")
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw TranslationRepositoryError.lockedVersion }
    }

    public func adoptTranslation(versionID: UUID) throws {
        try ensurePrepared()
        let statement = try prepare("UPDATE translation_versions SET is_draft = 0, is_archived = 0, updated_at = ? WHERE id = ? AND status = 'complete' AND is_locked = 0;")
        defer { sqlite3_finalize(statement) }
        try bindDouble(Date().timeIntervalSince1970, at: 1, to: statement)
        try bindText(versionID.uuidString, at: 2, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw TranslationRepositoryError.versionNotFound }
    }

    public func archiveTranslation(versionID: UUID, archived: Bool) throws {
        try ensurePrepared()
        let statement = try prepare("UPDATE translation_versions SET is_archived = ?, updated_at = ? WHERE id = ? AND is_locked = 0;")
        defer { sqlite3_finalize(statement) }
        try bindInt(archived ? 1 : 0, at: 1, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 2, to: statement)
        try bindText(versionID.uuidString, at: 3, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw TranslationRepositoryError.versionNotFound }
    }

    // MARK: - ReadingRepository

    public func loadReadingVersions(
        lyricsVersionID: UUID,
        representationID: String?,
        sourceContentHash: String
    ) async throws -> [StoredReadingVersion] {
        try ensurePrepared()
        guard let source = try fetchSourceLyrics(versionID: lyricsVersionID) else {
            throw ReadingRepositoryError.sourceLyricsNotFound
        }
        guard source.hash == sourceContentHash else {
            throw ReadingRepositoryError.sourceContentMismatch
        }

        let statement = try prepare("""
            SELECT id, lyrics_version_id, source_content_hash, engine_id,
                   representation_id, source_kind, language, created_at, updated_at,
                   is_machine_generated, is_manually_edited, is_current, is_locked,
                   is_archived, parent_version_id, confidence, warning_metadata,
                   context_hash
            FROM reading_versions
            WHERE lyrics_version_id = ? AND source_content_hash = ?
              AND (? IS NULL OR representation_id = ?)
            ORDER BY is_locked DESC, is_current DESC, updated_at DESC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(lyricsVersionID.uuidString, at: 1, to: statement)
        try bindText(sourceContentHash, at: 2, to: statement)
        try bindText(representationID, at: 3, to: statement)
        try bindText(representationID, at: 4, to: statement)

        var result: [StoredReadingVersion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let record = try readingVersionRecord(from: statement)
            let storedLines = try fetchReadingLines(versionID: record.id)
            guard validateStoredReading(record: record, lines: storedLines, sourceLines: source.lines) else { continue }
            // Older manual versions may contain a token map saved beside a
            // different whole-line reading. Keep the immutable version and
            // its readingText, but fail closed on the unusable token layer.
            let isKana = record.representationID == ReadingRepresentationID.kana.rawValue
            let lines = storedLines.map { line -> ReadingLineResult in
                guard !line.tokens.isEmpty else { return line }
                let rangesMatch = line.hasExactTokenSurfaceCoverage
                let readingMatches = !isKana || line.hasConsistentKanaTokenProjection
                return rangesMatch && readingMatches ? line : line.replacingTokens([])
            }
            result.append(StoredReadingVersion(record: record, lines: lines))
        }
        return result
    }

    public func saveReadingVersion(_ request: ReadingVersionSaveRequest) async throws -> StoredReadingVersion {
        try ensurePrepared()
        guard let source = try fetchSourceLyrics(versionID: request.record.lyricsVersionID) else {
            throw ReadingRepositoryError.sourceLyricsNotFound
        }
        guard source.hash == request.record.sourceContentHash else {
            throw ReadingRepositoryError.sourceContentMismatch
        }
        guard request.record.sourceContentHash == source.hash,
              request.lines.count == source.lines.count,
              request.lines.map(\.lineIndex) == Array(source.lines.indices) else {
            throw ReadingRepositoryError.invalidLines("行数或 index 不匹配")
        }
        for line in request.lines {
            let sourceLine = source.lines[line.lineIndex]
            let originalMatches = line.originalText == sourceLine.originalText
            let sourceBlank = sourceLine.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let readingBlank = line.readingText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            guard originalMatches,
                  sourceBlank == readingBlank,
                  !(line.readingText ?? "").contains("\n"),
                  !(line.readingText ?? "").contains("\r") else {
                throw ReadingRepositoryError.invalidLines("原文映射或空白行规则不匹配")
            }
            if request.record.representationID == ReadingRepresentationID.kana.rawValue,
               !line.tokens.isEmpty,
               !line.hasConsistentKanaTokenProjection {
                throw ReadingRepositoryError.invalidLines("假名与逐词 token 不一致；请清除失效 token 后保存")
            }
        }
        if let existing = try fetchReadingVersion(versionID: request.record.id) {
            if existing.isLocked { throw ReadingRepositoryError.lockedVersion }
            throw ReadingRepositoryError.database("读音版本 ID 已存在；显式保存必须创建新版本")
        }

        let record = request.record
        try withTransaction {
            try insertReadingVersion(record)
            for line in request.lines {
                try insertReadingLine(line, versionID: record.id)
            }
        }
        return StoredReadingVersion(record: record, lines: request.lines)
    }

    public func adoptReadingVersion(versionID: UUID) async throws {
        try ensurePrepared()
        guard let record = try fetchReadingVersion(versionID: versionID),
              let source = try fetchSourceLyrics(versionID: record.lyricsVersionID) else {
            throw ReadingRepositoryError.versionNotFound
        }
        guard source.hash == record.sourceContentHash else { throw ReadingRepositoryError.sourceContentMismatch }
        guard !record.isArchived else { throw ReadingRepositoryError.versionNotFound }
        try withTransaction {
            let clear = try prepare("""
                UPDATE reading_versions SET is_current = 0, updated_at = ?
                WHERE lyrics_version_id = ? AND representation_id = ?;
                """)
            defer { sqlite3_finalize(clear) }
            try bindDouble(Date().timeIntervalSince1970, at: 1, to: clear)
            try bindText(record.lyricsVersionID.uuidString, at: 2, to: clear)
            try bindText(record.representationID, at: 3, to: clear)
            try stepDone(clear)

            let adopt = try prepare("""
                UPDATE reading_versions SET is_current = 1, is_archived = 0, updated_at = ?
                WHERE id = ?;
                """)
            defer { sqlite3_finalize(adopt) }
            try bindDouble(Date().timeIntervalSince1970, at: 1, to: adopt)
            try bindText(versionID.uuidString, at: 2, to: adopt)
            try stepDone(adopt)
        }
    }

    public func markReadingLocked(versionID: UUID, locked: Bool) async throws {
        try ensurePrepared()
        guard let record = try fetchReadingVersion(versionID: versionID) else {
            throw ReadingRepositoryError.versionNotFound
        }
        if !locked && record.sourceKind == .legacyImported {
            // Legacy imports may be unlocked for an explicit replacement, but
            // they remain immutable rows; the replacement gets a new ID.
        }
        let statement = try prepare("UPDATE reading_versions SET is_locked = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindInt(locked ? 1 : 0, at: 1, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 2, to: statement)
        try bindText(versionID.uuidString, at: 3, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw ReadingRepositoryError.versionNotFound }
    }

    public func archiveReadingVersion(versionID: UUID, archived: Bool) async throws {
        try ensurePrepared()
        guard let record = try fetchReadingVersion(versionID: versionID) else {
            throw ReadingRepositoryError.versionNotFound
        }
        guard !record.isLocked else { throw ReadingRepositoryError.lockedVersion }
        let statement = try prepare("""
            UPDATE reading_versions SET is_archived = ?, is_current = CASE WHEN ? = 1 THEN 0 ELSE is_current END,
                   updated_at = ? WHERE id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try bindInt(archived ? 1 : 0, at: 1, to: statement)
        try bindInt(archived ? 1 : 0, at: 2, to: statement)
        try bindDouble(Date().timeIntervalSince1970, at: 3, to: statement)
        try bindText(versionID.uuidString, at: 4, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw ReadingRepositoryError.versionNotFound }
    }

    public func deleteReadingVersion(versionID: UUID) async throws {
        try ensurePrepared()
        guard let record = try fetchReadingVersion(versionID: versionID) else {
            throw ReadingRepositoryError.versionNotFound
        }
        guard !record.isLocked else { throw ReadingRepositoryError.lockedVersion }
        let statement = try prepare("DELETE FROM reading_versions WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else { throw ReadingRepositoryError.versionNotFound }
    }

    // MARK: - LyricsEditingRepository

    public func loadEditableVersions(track: Track, identity: TrackIdentity) throws -> [StoredEditableLyricsVersion] {
        try ensurePrepared()
        let canonicalKey = try resolvedCanonicalStableKey(identity.stableKey)
        guard let trackRecord = try fetchTrack(stableKey: canonicalKey) else { return [] }
        let records = try fetchVersionRecords(stableKey: canonicalKey)
        return try records.compactMap { record in
            let lines = try fetchLines(versionID: record.id)
            guard !lines.isEmpty else { return nil }
            let readings = try fetchReadingLayers(versionID: record.id).filter(\.isLocked)
            let sourceContentHash = LyricsSourceContentHasher.hash(
                isSynchronized: record.isSynced,
                lines: lines
            )
            var baseDoc = LyricsPersistenceMapper.document(identity: identity, track: trackRecord, version: record, lines: lines)
            let timingRecord = try fetchBestTimingVersion(
                lyricsVersionID: record.id,
                sourceContentHash: sourceContentHash,
                document: baseDoc
            )
            let timingMap = timingRecord.flatMap { DocumentTimingPayload.decode($0.spansPayload) }
            if let timingMap, !timingMap.isEmpty {
                var updatedLines = baseDoc.lines
                for i in updatedLines.indices {
                    if let timing = timingMap[i] {
                        updatedLines[i].performerID = timing.performerID
                        updatedLines[i].timedSpans = timing.spans
                    }
                }
                baseDoc = baseDoc.replacingLines(updatedLines, timingVersionID: timingRecord?.id)
            }
            let document = applyingLockedReadings(
                to: baseDoc,
                readings: readings
            )
            _ = track
            return StoredEditableLyricsVersion(record: record, lines: lines, document: document, lockedReadingLayers: readings)
        }
        .sorted {
            if $0.record.isLocked != $1.record.isLocked { return $0.record.isLocked }
            return $0.record.updatedAt > $1.record.updatedAt
        }
    }

    public func loadEditableVersion(versionID: UUID, track: Track, identity: TrackIdentity) throws -> StoredEditableLyricsVersion? {
        try ensurePrepared()
        let canonicalKey = try resolvedCanonicalStableKey(identity.stableKey)
        guard let trackRecord = try fetchTrack(stableKey: canonicalKey),
              let record = try fetchLyricsVersion(versionID: versionID),
              try resolvedCanonicalStableKey(record.trackStableKey) == canonicalKey else { return nil }
        let lines = try fetchLines(versionID: versionID)
        guard !lines.isEmpty else { return nil }
        let readings = try fetchReadingLayers(versionID: versionID).filter(\.isLocked)
        let sourceContentHash = LyricsSourceContentHasher.hash(
            isSynchronized: record.isSynced,
            lines: lines
        )
        var baseDoc = LyricsPersistenceMapper.document(identity: identity, track: trackRecord, version: record, lines: lines)
        let timingRecord = try fetchBestTimingVersion(
            lyricsVersionID: record.id,
            sourceContentHash: sourceContentHash,
            document: baseDoc
        )
        let timingMap = timingRecord.flatMap { DocumentTimingPayload.decode($0.spansPayload) }
        if let timingMap, !timingMap.isEmpty {
            var updatedLines = baseDoc.lines
            for i in updatedLines.indices {
                if let timing = timingMap[i] {
                    updatedLines[i].performerID = timing.performerID
                    updatedLines[i].timedSpans = timing.spans
                }
            }
            baseDoc = baseDoc.replacingLines(updatedLines, timingVersionID: timingRecord?.id)
        }
        let document = applyingLockedReadings(
            to: baseDoc,
            readings: readings
        )
        _ = track
        return StoredEditableLyricsVersion(record: record, lines: lines, document: document, lockedReadingLayers: readings)
    }

    public func saveManualEdit(_ request: LyricsEditSaveRequest) throws -> LyricsEditSaveResult {
        try ensurePrepared()
        guard request.document.identity == request.identity else {
            throw LyricsEditingRepositoryError.identityMismatch
        }
        guard TrackIdentity(track: request.track) == request.identity else {
            // The editor session normally catches a track change on the
            // MainActor. Keep the repository boundary defensive as well so a
            // stale request cannot attach A's text to B's metadata.
            throw LyricsEditingRepositoryError.identityMismatch
        }
        guard !request.document.lines.isEmpty,
              request.document.lines.contains(where: {
                  !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw LyricsEditingRepositoryError.invalidDocument("不能保存空歌词")
        }
        guard !request.isNewSource || request.createLyricsVersion else {
            throw LyricsEditingRepositoryError.invalidDocument("新的人工歌词必须创建独立版本")
        }

        let canonicalKey = try resolvedCanonicalStableKey(request.identity.stableKey)

        let sourceLines: [DatabaseLyricLineRecord]
        let sourceVersionRecord: DatabaseLyricsVersionRecord?
        if request.isNewSource {
            sourceLines = []
            sourceVersionRecord = nil
        } else {
            guard let existing = try fetchLyricsVersion(versionID: request.sourceVersionID),
                  try resolvedCanonicalStableKey(existing.trackStableKey) == canonicalKey else {
                throw LyricsEditingRepositoryError.sourceNotFound
            }
            sourceVersionRecord = existing
            sourceLines = try fetchLines(versionID: request.sourceVersionID)
            let sourceHash = LyricsSourceContentHasher.hash(
                isSynchronized: existing.isSynced,
                lines: sourceLines
            )
            guard sourceHash == request.sourceContentHash else {
                throw LyricsEditingRepositoryError.sourceContentMismatch
            }
        }

        let draftLines = request.document.lines.enumerated().map { index, line in
            LyricsEditorLineDraft(
                line: line,
                startTimeIsMeaningful: request.document.lineHasExplicitTiming(index)
            )
        }
        let timeline = LyricsTimelineValidator.validate(lines: draftLines, duration: request.document.duration)
        guard timeline.isSaveAllowed else {
            throw LyricsEditingRepositoryError.invalidTimeline(timeline.errors.map(\.message).joined(separator: "；"))
        }
        guard request.createLyricsVersion || request.translation != nil else {
            throw LyricsEditingRepositoryError.noChanges
        }

        let projectedLines = request.document.lines.enumerated().map { index, line in
            LyricsEditorLineDraft(
                line: line,
                startTimeIsMeaningful: request.document.lineHasExplicitTiming(index)
            )
        }
        var sourceTimingMap: [Int: (performerID: String?, spans: [TimedTextSpan])] = [:]
        if request.createLyricsVersion {
            if let sourceVersionRecord {
                let sourceDocument = Self.documentForTimingValidation(
                    identity: request.identity,
                    track: request.track,
                    version: sourceVersionRecord,
                    lines: sourceLines
                )
                let sourceHash = LyricsSourceContentHasher.hash(
                    isSynchronized: sourceVersionRecord.isSynced,
                    lines: sourceLines
                )
                let record = try fetchBestTimingVersion(
                    lyricsVersionID: sourceVersionRecord.id,
                    sourceContentHash: sourceHash,
                    document: sourceDocument
                )
                sourceTimingMap = record.flatMap { DocumentTimingPayload.decode($0.spansPayload) } ?? [:]
            }
        }
        let sanitizedProjectedLines = request.createLyricsVersion
            ? Self.sanitizedTimingLines(projectedLines, sourceMap: sourceTimingMap, sourceRows: sourceLines)
            : projectedLines
        if request.createLyricsVersion {
            let timingLoss = Self.timingLossSummary(
                sourceMap: sourceTimingMap,
                proposedLines: sanitizedProjectedLines,
                originalProposedLines: projectedLines
            )
            guard !timingLoss.requiresConfirmation || request.confirmedTimingLoss else {
                throw LyricsEditingRepositoryError.timingLossRequiresConfirmation(timingLoss)
            }
        }

        let now = Date()
        let newLyricsID = request.createLyricsVersion ? UUID() : nil
        let explicitTimingMask: Set<Int>? = {
            guard !timeline.isSynchronized else { return nil }
            let timed = Set(sanitizedProjectedLines.indices.filter { sanitizedProjectedLines[$0].startTime != nil })
            if request.document.explicitlyTimedLineIndices != nil { return timed }
            return timed.isEmpty ? nil : timed
        }()
        let projectedDocument = LyricsDocument(
            identity: request.document.identity,
            title: request.document.title,
            artist: request.document.artist,
            album: request.document.album,
            duration: request.document.duration,
            lines: request.createLyricsVersion ? sanitizedProjectedLines.map { $0.asLyricLine() } : request.document.lines,
            isSynchronized: timeline.isSynchronized,
            source: request.document.source,
            confidence: request.document.confidence,
            providerSourceID: request.document.providerSourceID,
            spotifyTrackID: request.document.spotifyTrackID,
            isrc: request.document.isrc,
            language: request.document.language,
            explicitlyTimedLineIndices: request.createLyricsVersion ? explicitTimingMask : request.document.explicitlyTimedLineIndices,
            timingVersionID: request.createLyricsVersion ? nil : request.document.timingVersionID
        )
        let targetDocument = projectedDocument
        // Translation versions are the canonical home for translations after
        // v2. Keep lyric_lines.translation_text as a read-only compatibility
        // field instead of duplicating a new manual translation there.
        let storageDocument = request.createLyricsVersion
            ? Self.documentWithoutTranslations(
                Self.removingLockedReadingProjection(targetDocument, layers: request.readingLayers)
            )
            : targetDocument
        let targetRecords = newLyricsID.map {
            LyricsPersistenceMapper.lineRecords(document: storageDocument, versionID: $0)
        } ?? sourceLines
        let targetHash = LyricsSourceContentHasher.hash(isSynchronized: storageDocument.isSynchronized, lines: targetRecords)
        let rawTrackRecord = LyricsPersistenceMapper.trackRecord(
            track: request.track,
            identity: request.identity,
            now: now
        )
        let trackRecord = canonicalTrackRecord(rawTrackRecord, stableKey: canonicalKey)
        let aliases = LyricsPersistenceMapper.aliasRecords(
            track: request.track,
            identity: request.identity,
            document: request.document,
            now: now
        ).map { canonicalAliasRecord($0, stableKey: canonicalKey) }
        let parentVersionID = request.isNewSource ? nil : request.sourceVersionID
        let preservedSelection = request.preserveCurrentLyricsSelection
            ? (try fetchBestVersion(stableKey: canonicalKey)?.id ?? request.sourceVersionID) : nil

        guard let translation = request.translation else {
            try withTransaction {
                if let preservedSelection { try setPreferredLyricsVersion(trackStableKey: canonicalKey, lyricsVersionID: preservedSelection) }
                try upsertTrack(trackRecord)
                for alias in aliases { try insertAlias(alias) }
                if let newLyricsID {
                    let record = try manualLyricsVersionRecord(
                        document: storageDocument,
                        identity: request.identity,
                        versionID: newLyricsID,
                        parentVersionID: parentVersionID,
                        source: request.targetSource,
                        now: now,
                        isLocked: request.lockLyricsVersion
                    )
                    try insertVersion(canonicalVersionRecord(record, stableKey: canonicalKey))
                    for line in targetRecords { try insertLine(line) }
                    try insertReadingLayers(request.readingLayers, versionID: newLyricsID, now: now)
                    try attachTimingVersionIfNeeded(
                        document: storageDocument,
                        lyricsVersionID: newLyricsID,
                        source: DatabaseSourceIdentifier.identifier(for: request.targetSource),
                        sourceContentHash: targetHash,
                        now: now
                    )
                    if !request.preserveCurrentLyricsSelection {
                        try setPreferredLyricsVersion(trackStableKey: canonicalKey, lyricsVersionID: newLyricsID)
                    }
                }
                return ()
            }
            let storedLyrics: StoredEditableLyricsVersion?
            if let newLyricsID {
                storedLyrics = try loadEditableVersion(versionID: newLyricsID, track: request.track, identity: request.identity)
            } else {
                storedLyrics = nil
            }
            return LyricsEditSaveResult(lyricsVersion: storedLyrics, translationVersion: nil)
        }

        guard translation.lines.count == targetDocument.lines.count else {
            throw LyricsEditingRepositoryError.invalidTranslation("翻译行数与歌词不一致")
        }
        for index in targetDocument.lines.indices {
            let originalBlank = targetDocument.lines[index].originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let translationText = translation.lines[index]
            let translationBlank = translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard originalBlank == translationBlank,
                  (!originalBlank || translationText.isEmpty),
                  !translationText.contains("\n"), !translationText.contains("\r") else {
                throw LyricsEditingRepositoryError.invalidTranslation("第 \(index + 1) 行为空白或包含换行")
            }
        }

        let translationID = UUID()
        let lyricsID = newLyricsID ?? request.sourceVersionID
        let translationRecord = DatabaseTranslationVersionRecord(
            id: translationID,
            lyricsVersionID: lyricsID,
            parentVersionID: translation.parentVersionID,
            sourceKind: .manualEdit,
            targetLanguage: translation.targetLanguage,
            model: translation.model,
            baseURLHost: translation.baseURLHost,
            promptHash: translation.promptHash,
            sourceContentHash: targetHash,
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: false,
            isManuallyEdited: true,
            isLocked: translation.isLocked,
            status: .complete,
            confidence: 1
        )

        try withTransaction {
            if let preservedSelection { try setPreferredLyricsVersion(trackStableKey: canonicalKey, lyricsVersionID: preservedSelection) }
            try upsertTrack(trackRecord)
            for alias in aliases { try insertAlias(alias) }
            if let newLyricsID {
                let record = try manualLyricsVersionRecord(
                    document: storageDocument,
                    identity: request.identity,
                    versionID: newLyricsID,
                    parentVersionID: parentVersionID,
                    source: request.targetSource,
                    now: now,
                    isLocked: request.lockLyricsVersion
                )
                try insertVersion(canonicalVersionRecord(record, stableKey: canonicalKey))
                for line in targetRecords { try insertLine(line) }
                try insertReadingLayers(request.readingLayers, versionID: newLyricsID, now: now)
                try attachTimingVersionIfNeeded(
                    document: storageDocument,
                    lyricsVersionID: newLyricsID,
                    source: DatabaseSourceIdentifier.identifier(for: request.targetSource),
                    sourceContentHash: targetHash,
                    now: now
                )
                if !request.preserveCurrentLyricsSelection {
                    try setPreferredLyricsVersion(trackStableKey: canonicalKey, lyricsVersionID: newLyricsID)
                }
            }
            try insertTranslationVersion(translationRecord)
            for (index, text) in translation.lines.enumerated() {
                try insertTranslationLine(DatabaseTranslationLineRecord(
                    translationVersionID: translationID,
                    lineIndex: index,
                    translatedText: text
                ))
            }
        }

        let storedLyrics: StoredEditableLyricsVersion?
        if let newLyricsID {
            storedLyrics = try loadEditableVersion(versionID: newLyricsID, track: request.track, identity: request.identity)
        } else {
            storedLyrics = nil
        }
        let storedTranslation = StoredTranslationVersion(
            record: translationRecord,
            lines: translation.lines.enumerated().map {
                DatabaseTranslationLineRecord(translationVersionID: translationID, lineIndex: $0.offset, translatedText: $0.element)
            }
        )
        return LyricsEditSaveResult(lyricsVersion: storedLyrics, translationVersion: storedTranslation)
    }

    public func markLyricsVersionLocked(versionID: UUID, locked: Bool) throws {
        try markLocked(versionID: versionID, locked: locked)
    }

    private func manualLyricsVersionRecord(
        document: LyricsDocument,
        identity: TrackIdentity,
        versionID: UUID,
        parentVersionID: UUID?,
        source: LyricsSource,
        now: Date,
        isLocked: Bool
    ) throws -> DatabaseLyricsVersionRecord {
        let base = LyricsPersistenceMapper.versionRecord(
            document: document,
            identity: identity,
            versionID: versionID,
            now: now
        )
        let lines = LyricsPersistenceMapper.lineRecords(document: document, versionID: versionID)
        return DatabaseLyricsVersionRecord(
            id: base.id,
            trackStableKey: base.trackStableKey,
            parentVersionID: parentVersionID,
            source: DatabaseSourceIdentifier.identifier(for: source),
            // Every explicit manual save is a new version.  The provider/source
            // discriminator must not collide with the v1 content uniqueness key.
            providerSourceID: "\(DatabaseSourceIdentifier.identifier(for: source)):\(versionID.uuidString)",
            language: base.language,
            isSynced: document.isSynchronized,
            rawText: document.lines.map(\.originalText).joined(separator: "\n"),
            contentHash: LyricsSourceContentHasher.hash(isSynchronized: document.isSynchronized, lines: lines),
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: false,
            isManuallyEdited: source == .manualEdit || source == .manualImport || source == .manualCreate,
            isLocked: isLocked,
            confidence: 1
        )
    }

    private static func documentWithoutTranslations(_ document: LyricsDocument) -> LyricsDocument {
        let lines = document.lines.map { line in
            LyricLine(
                id: line.id,
                timestamp: line.timestamp,
                originalText: line.originalText,
                endTime: line.endTime,
                translationText: nil,
                romajiText: line.romajiText,
                kanaText: line.kanaText,
                rubyTokens: line.rubyTokens,
                performerID: line.performerID,
                timedSpans: line.timedSpans,
                readingRepresentationID: line.readingRepresentationID,
                readingSurfaceText: line.readingSurfaceText
            )
        }
        return LyricsDocument(
            identity: document.identity,
            title: document.title,
            artist: document.artist,
            album: document.album,
            duration: document.duration,
            lines: lines,
            isSynchronized: document.isSynchronized,
            source: document.source,
            confidence: document.confidence,
            providerSourceID: document.providerSourceID,
            language: document.language,
            // Preserve Assist partial-timeline mask; dropping it zeroed all
            // start_time values on manual save of partially timed drafts.
            explicitlyTimedLineIndices: document.explicitlyTimedLineIndices,
            // A child timing attachment is created independently in the
            // save transaction. Never carry the parent's attachment identity.
            timingVersionID: nil
        )
    }

    private static func removingLockedReadingProjection(
        _ document: LyricsDocument,
        layers: [LyricsReadingLayerDraft]
    ) -> LyricsDocument {
        guard !layers.isEmpty else { return document }
        var lines = document.lines
        for layer in layers where lines.indices.contains(layer.lineIndex) {
            if layer.kanaText != nil { lines[layer.lineIndex].kanaText = nil }
            if layer.romajiText != nil { lines[layer.lineIndex].romajiText = nil }
        }
        return document.replacingLines(lines)
    }

    private static func sanitizedTimingLines(
        _ proposedLines: [LyricsEditorLineDraft],
        sourceMap: [Int: (performerID: String?, spans: [TimedTextSpan])],
        sourceRows: [DatabaseLyricLineRecord]
    ) -> [LyricsEditorLineDraft] {
        proposedLines.enumerated().map { index, original in
            var line = original
            guard line.timedSpans != nil else { return line }
            let matchingSourceIndex = sourceMap.first(where: { sourceIndex, timing in
                sourceRows.first(where: { $0.lineIndex == sourceIndex })?.originalText == line.originalText &&
                    timing.spans.contains(where: { line.timedSpans?.contains($0) == true })
            })?.key
            let sourceIndex = matchingSourceIndex ?? index
            let priorEndTime = sourceRows.first(where: { $0.lineIndex == sourceIndex })?.endTime
            let endChanged = priorEndTime != line.endTime
            line.timedSpans = LyricsTimingCompatibility.compatibleSpans(
                in: line,
                enforceLineEndBoundary: endChanged && line.endTime != nil
            )
            return line
        }
    }

    private static func documentForTimingValidation(
        identity: TrackIdentity,
        track: Track,
        version: DatabaseLyricsVersionRecord,
        lines: [DatabaseLyricLineRecord]
    ) -> LyricsDocument {
        let sorted = lines.sorted { $0.lineIndex < $1.lineIndex }
        let lyricLines = sorted.map { line in
            LyricLine(
                timestamp: line.startTime ?? 0,
                originalText: line.originalText,
                endTime: line.endTime,
                translationText: line.translationText,
                romajiText: line.romajiText,
                kanaText: line.kanaText
            )
        }
        let timedIndices: Set<Int>? = {
            guard !version.isSynced else { return nil }
            let values = Set(sorted.compactMap { $0.startTime == nil ? nil : $0.lineIndex })
            return values.isEmpty ? nil : values
        }()
        return LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: lyricLines,
            isSynchronized: version.isSynced,
            source: DatabaseSourceIdentifier.source(for: version.source),
            confidence: version.confidence,
            providerSourceID: version.providerSourceID,
            language: version.language,
            explicitlyTimedLineIndices: timedIndices
        )
    }

    private static func timingLossSummary(
        sourceMap: [Int: (performerID: String?, spans: [TimedTextSpan])],
        proposedLines: [LyricsEditorLineDraft],
        originalProposedLines: [LyricsEditorLineDraft]
    ) -> LyricsTimingLossSummary {
        var targetSpans = proposedLines.flatMap { LyricsTimingCompatibility.compatibleSpans(in: $0) }
        let sourceEntries = sourceMap.sorted { $0.key < $1.key }
        var missingSpanCount = 0
        var affectedSourceLineIndices = Set<Int>()
        var missingPerformerCount = 0

        for (sourceIndex, entry) in sourceEntries {
            var lineLoss = 0
            for span in entry.spans {
                if let match = targetSpans.firstIndex(of: span) {
                    targetSpans.remove(at: match)
                } else {
                    lineLoss += 1
                }
            }
            if lineLoss > 0 {
                missingSpanCount += lineLoss
                affectedSourceLineIndices.insert(sourceIndex)
            }
            if entry.performerID != nil {
                let retainsPerformer = proposedLines.contains { line in
                    line.performerID == entry.performerID &&
                        entry.spans.contains(where: { LyricsTimingCompatibility.compatibleSpans(in: line).contains($0) })
                }
                if !retainsPerformer { missingPerformerCount += 1 }
            }
        }

        let invalidTargetSpanCount = originalProposedLines.reduce(into: 0) { count, line in
            count += max(0, (line.timedSpans?.count ?? 0) - LyricsTimingCompatibility.compatibleSpans(in: line).count)
        }
        let lostSpans = max(missingSpanCount, invalidTargetSpanCount)
        let invalidTargetLineCount = originalProposedLines.filter {
            ($0.timedSpans?.count ?? 0) > LyricsTimingCompatibility.compatibleSpans(in: $0).count
        }.count
        return LyricsTimingLossSummary(
            lostSpanCount: lostSpans,
            affectedLineCount: max(affectedSourceLineIndices.count, invalidTargetLineCount),
            lostPerformerMetadataLineCount: missingPerformerCount
        )
    }

    private func fetchVersionRecords(stableKey: String) throws -> [DatabaseLyricsVersionRecord] {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("""
            SELECT id, track_stable_key, parent_version_id, source, provider_source_id, language,
                   is_synced, raw_text, content_hash, created_at, updated_at,
                   is_machine_generated, is_manually_edited, is_locked, confidence
            FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count)))
            ORDER BY is_locked DESC, updated_at DESC;
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        var result: [DatabaseLyricsVersionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try lyricsVersionRecord(from: statement))
        }
        return result
    }

    private func fetchReadingVersion(versionID: UUID) throws -> ReadingVersionRecord? {
        let statement = try prepare("""
            SELECT id, lyrics_version_id, source_content_hash, engine_id,
                   representation_id, source_kind, language, created_at, updated_at,
                   is_machine_generated, is_manually_edited, is_current, is_locked,
                   is_archived, parent_version_id, confidence, warning_metadata,
                   context_hash
            FROM reading_versions WHERE id = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try readingVersionRecord(from: statement)
    }

    private func readingVersionRecord(from statement: OpaquePointer) throws -> ReadingVersionRecord {
        guard let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)),
              let lyricsVersionID = columnText(statement, index: 1).flatMap(UUID.init(uuidString:)),
              let sourceHash = columnText(statement, index: 2),
              let engineID = columnText(statement, index: 3),
              let representationID = columnText(statement, index: 4),
              let languageRaw = columnText(statement, index: 6) else {
            throw LyricsRepositoryError.invalidData("ReadingVersionRecord 字段缺失")
        }
        return ReadingVersionRecord(
            id: id,
            lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceHash,
            engineID: engineID,
            representationID: representationID,
            sourceKind: ReadingVersionSourceKind(rawValue: columnText(statement, index: 5) ?? "generated") ?? .generated,
            language: ReadingLanguage(rawValue: languageRaw) ?? .unknown,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            isMachineGenerated: sqlite3_column_int(statement, 9) != 0,
            isManuallyEdited: sqlite3_column_int(statement, 10) != 0,
            isCurrent: sqlite3_column_int(statement, 11) != 0,
            isLocked: sqlite3_column_int(statement, 12) != 0,
            isArchived: sqlite3_column_int(statement, 13) != 0,
            parentVersionID: columnText(statement, index: 14).flatMap(UUID.init(uuidString:)),
            confidence: sqlite3_column_double(statement, 15),
            warningMetadata: decodeWarnings(columnText(statement, index: 16)),
            contextHash: columnText(statement, index: 17) ?? ""
        )
    }

    private func fetchReadingLines(versionID: UUID) throws -> [ReadingLineResult] {
        let statement = try prepare("""
            SELECT line_index, original_text, reading_text, tokens_json, language,
                   source, confidence, warning_metadata
            FROM reading_lines WHERE reading_version_id = ? ORDER BY line_index ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        var result: [ReadingLineResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let original = columnText(statement, index: 1) else {
                throw LyricsRepositoryError.invalidData("ReadingLineRecord 原文缺失")
            }
            result.append(ReadingLineResult(
                lineIndex: Int(sqlite3_column_int(statement, 0)),
                originalText: original,
                readingText: columnText(statement, index: 2),
                language: ReadingLanguage(rawValue: columnText(statement, index: 4) ?? "unknown") ?? .unknown,
                tokens: decodeTokens(columnText(statement, index: 3)),
                warnings: decodeWarnings(columnText(statement, index: 7)),
                confidence: sqlite3_column_double(statement, 6)
            ))
        }
        return result
    }

    private func validateStoredReading(
        record: ReadingVersionRecord,
        lines: [ReadingLineResult],
        sourceLines: [DatabaseLyricLineRecord]
    ) -> Bool {
        guard lines.count == sourceLines.count,
              lines.map(\.lineIndex) == Array(sourceLines.indices) else { return false }
        return lines.enumerated().allSatisfy { index, line in
            let source = sourceLines[index].originalText
            let sourceBlank = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let readingBlank = line.readingText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return line.originalText == source && sourceBlank == readingBlank
        }
    }

    private func insertReadingVersion(_ record: ReadingVersionRecord) throws {
        let statement = try prepare("""
            INSERT INTO reading_versions(
                id, lyrics_version_id, source_content_hash, engine_id,
                representation_id, source_kind, language, created_at, updated_at,
                is_machine_generated, is_manually_edited, is_current, is_locked,
                is_archived, parent_version_id, confidence, warning_metadata, context_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.id.uuidString, at: 1, to: statement)
        try bindText(record.lyricsVersionID.uuidString, at: 2, to: statement)
        try bindText(record.sourceContentHash, at: 3, to: statement)
        try bindText(record.engineID, at: 4, to: statement)
        try bindText(record.representationID, at: 5, to: statement)
        try bindText(record.sourceKind.rawValue, at: 6, to: statement)
        try bindText(record.language.rawValue, at: 7, to: statement)
        try bindDouble(record.createdAt.timeIntervalSince1970, at: 8, to: statement)
        try bindDouble(record.updatedAt.timeIntervalSince1970, at: 9, to: statement)
        try bindInt(record.isMachineGenerated ? 1 : 0, at: 10, to: statement)
        try bindInt(record.isManuallyEdited ? 1 : 0, at: 11, to: statement)
        try bindInt(record.isCurrent ? 1 : 0, at: 12, to: statement)
        try bindInt(record.isLocked ? 1 : 0, at: 13, to: statement)
        try bindInt(record.isArchived ? 1 : 0, at: 14, to: statement)
        try bindText(record.parentVersionID?.uuidString, at: 15, to: statement)
        try bindDouble(record.confidence, at: 16, to: statement)
        try bindText(encodeWarnings(record.warningMetadata), at: 17, to: statement)
        try bindText(record.contextHash, at: 18, to: statement)
        try stepDone(statement)
    }

    private func insertReadingLine(_ line: ReadingLineResult, versionID: UUID) throws {
        let statement = try prepare("""
            INSERT INTO reading_lines(
                reading_version_id, line_index, original_text, reading_text,
                tokens_json, language, source, confidence, warning_metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        try bindInt(line.lineIndex, at: 2, to: statement)
        try bindText(line.originalText, at: 3, to: statement)
        try bindText(line.readingText, at: 4, to: statement)
        try bindText(encodeTokens(line.tokens), at: 5, to: statement)
        try bindText(line.language.rawValue, at: 6, to: statement)
        try bindText(line.tokens.first?.source.rawValue ?? "unknown", at: 7, to: statement)
        try bindDouble(line.confidence, at: 8, to: statement)
        try bindText(encodeWarnings(line.warnings), at: 9, to: statement)
        try stepDone(statement)
    }

    private func encodeTokens(_ tokens: [ReadingToken]) -> String {
        guard let data = try? JSONEncoder().encode(tokens) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeTokens(_ value: String?) -> [ReadingToken] {
        guard let value, let data = value.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([ReadingToken].self, from: data) else { return [] }
        return tokens
    }

    private func encodeWarnings(_ warnings: [ReadingWarningCode]) -> String {
        guard let data = try? JSONEncoder().encode(warnings) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeWarnings(_ value: String?) -> [ReadingWarningCode] {
        guard let value, let data = value.data(using: .utf8),
              let warnings = try? JSONDecoder().decode([ReadingWarningCode].self, from: data) else { return [] }
        return warnings
    }

    private func fetchLyricsVersion(versionID: UUID) throws -> DatabaseLyricsVersionRecord? {
        let statement = try prepare("""
            SELECT id, track_stable_key, parent_version_id, source, provider_source_id, language,
                   is_synced, raw_text, content_hash, created_at, updated_at,
                   is_machine_generated, is_manually_edited, is_locked, confidence
            FROM lyrics_versions WHERE id = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try lyricsVersionRecord(from: statement)
    }

    private func lyricsVersionRecord(from statement: OpaquePointer) throws -> DatabaseLyricsVersionRecord {
        guard let idText = columnText(statement, index: 0),
              let id = UUID(uuidString: idText),
              let key = columnText(statement, index: 1),
              let source = columnText(statement, index: 3),
              let provider = columnText(statement, index: 4),
              let language = columnText(statement, index: 5),
              let rawText = columnText(statement, index: 7),
              let contentHash = columnText(statement, index: 8) else {
            throw LyricsRepositoryError.invalidData("LyricsVersionRecord 字段缺失")
        }
        return DatabaseLyricsVersionRecord(
            id: id,
            trackStableKey: key,
            parentVersionID: columnText(statement, index: 2).flatMap(UUID.init(uuidString:)),
            source: source,
            providerSourceID: provider,
            language: language,
            isSynced: sqlite3_column_int(statement, 6) != 0,
            rawText: rawText,
            contentHash: contentHash,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            isMachineGenerated: sqlite3_column_int(statement, 11) != 0,
            isManuallyEdited: sqlite3_column_int(statement, 12) != 0,
            isLocked: sqlite3_column_int(statement, 13) != 0,
            confidence: sqlite3_column_double(statement, 14)
        )
    }

    private func fetchReadingLayers(versionID: UUID) throws -> [DatabaseReadingLayerRecord] {
        let statement = try prepare("""
            SELECT lyrics_version_id, line_index, kana_text, romaji_text, source,
                   is_locked, created_at, updated_at
            FROM lyric_reading_layers WHERE lyrics_version_id = ? ORDER BY line_index ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        var result: [DatabaseReadingLayerRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let source = columnText(statement, index: 4) else {
                throw LyricsRepositoryError.invalidData("ReadingLayerRecord 字段缺失")
            }
            result.append(DatabaseReadingLayerRecord(
                lyricsVersionID: id,
                lineIndex: Int(sqlite3_column_int(statement, 1)),
                kanaText: columnText(statement, index: 2),
                romajiText: columnText(statement, index: 3),
                source: source,
                isLocked: sqlite3_column_int(statement, 5) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            ))
        }
        return result
    }

    private func applyingLockedReadings(
        to document: LyricsDocument,
        readings: [DatabaseReadingLayerRecord]
    ) -> LyricsDocument {
        guard !readings.isEmpty else { return document }
        var lines = document.lines
        for reading in readings where lines.indices.contains(reading.lineIndex) {
            var projected = lines[reading.lineIndex]
            projected.romajiText = reading.romajiText ?? projected.romajiText
            projected.kanaText = reading.kanaText ?? projected.kanaText
            lines[reading.lineIndex] = projected
        }
        return document.replacingLines(lines)
    }

    private func insertReadingLayers(
        _ layers: [LyricsReadingLayerDraft],
        versionID: UUID,
        now: Date
    ) throws {
        for layer in layers {
            guard layer.kanaText != nil || layer.romajiText != nil else { continue }
            let record = DatabaseReadingLayerRecord(
                lyricsVersionID: versionID,
                lineIndex: layer.lineIndex,
                kanaText: layer.kanaText,
                romajiText: layer.romajiText,
                source: layer.source,
                isLocked: layer.isLocked,
                createdAt: now,
                updatedAt: now
            )
            let statement = try prepare("""
                INSERT INTO lyric_reading_layers(
                    lyrics_version_id, line_index, kana_text, romaji_text, source,
                    is_locked, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(statement) }
            try bindText(record.lyricsVersionID.uuidString, at: 1, to: statement)
            try bindInt(record.lineIndex, at: 2, to: statement)
            try bindText(record.kanaText, at: 3, to: statement)
            try bindText(record.romajiText, at: 4, to: statement)
            try bindText(record.source, at: 5, to: statement)
            try bindInt(record.isLocked ? 1 : 0, at: 6, to: statement)
            try bindDouble(record.createdAt.timeIntervalSince1970, at: 7, to: statement)
            try bindDouble(record.updatedAt.timeIntervalSince1970, at: 8, to: statement)
            try stepDone(statement)
        }
    }

    private struct SourceLyricsSnapshot {
        let isSynchronized: Bool
        let lines: [DatabaseLyricLineRecord]
        let hash: String
    }

    private func fetchSourceLyrics(versionID: UUID) throws -> SourceLyricsSnapshot? {
        let statement = try prepare("SELECT is_synced FROM lyrics_versions WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let synchronized = sqlite3_column_int(statement, 0) != 0
        let lines = try fetchLines(versionID: versionID)
        guard !lines.isEmpty else { return nil }
        let hash = LyricsSourceContentHasher.hash(isSynchronized: synchronized, lines: lines)
        return SourceLyricsSnapshot(isSynchronized: synchronized, lines: lines, hash: hash)
    }

    private func fetchTranslationLines(versionID: UUID) throws -> [DatabaseTranslationLineRecord] {
        let statement = try prepare("""
            SELECT translation_version_id, line_index, translated_text
            FROM translation_lines WHERE translation_version_id = ? ORDER BY line_index ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        var result: [DatabaseTranslationLineRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let text = columnText(statement, index: 2) else {
                throw LyricsRepositoryError.invalidData("TranslationLineRecord 字段缺失")
            }
            result.append(DatabaseTranslationLineRecord(
                translationVersionID: id,
                lineIndex: Int(sqlite3_column_int(statement, 1)),
                translatedText: text
            ))
        }
        return result
    }

    private func translationVersionRecord(from statement: OpaquePointer) throws -> DatabaseTranslationVersionRecord {
        guard let idText = columnText(statement, index: 0),
              let id = UUID(uuidString: idText),
              let lyricsIDText = columnText(statement, index: 1),
              let lyricsID = UUID(uuidString: lyricsIDText),
              let sourceKind = AITranslationSourceKind(rawValue: columnText(statement, index: 3) ?? ""),
              let target = columnText(statement, index: 4),
              let model = columnText(statement, index: 5),
              let host = columnText(statement, index: 6),
              let promptHash = columnText(statement, index: 7),
              let sourceHash = columnText(statement, index: 8),
              let status = AITranslationVersionStatus(rawValue: columnText(statement, index: 14) ?? "") else {
            throw LyricsRepositoryError.invalidData("TranslationVersionRecord 字段缺失")
        }
        return DatabaseTranslationVersionRecord(
            id: id,
            lyricsVersionID: lyricsID,
            parentVersionID: columnText(statement, index: 2).flatMap(UUID.init(uuidString:)),
            sourceKind: sourceKind,
            targetLanguage: target,
            model: model,
            baseURLHost: host,
            promptHash: promptHash,
            sourceContentHash: sourceHash,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            isMachineGenerated: sqlite3_column_int(statement, 11) != 0,
            isManuallyEdited: sqlite3_column_int(statement, 12) != 0,
            isLocked: sqlite3_column_int(statement, 13) != 0,
            status: status,
            confidence: sqlite3_column_double(statement, 15),
            engineID: columnText(statement, index: 16) ?? "",
            promptPresetID: columnText(statement, index: 17) ?? "",
            profileID: columnText(statement, index: 18).flatMap(UUID.init(uuidString:)),
            profileSnapshot: columnText(statement, index: 19) ?? "",
            temperature: sqlite3_column_double(statement, 20),
            workflowID: columnText(statement, index: 21) ?? TranslationWorkflowID.classicV1.rawValue,
            fallbackStrategy: TranslationFallbackStrategy(rawValue: columnText(statement, index: 22) ?? "none") ?? .none,
            providerExecutionMetadata: decodeProviderExecutionMetadata(columnText(statement, index: 25)),
            isDraft: sqlite3_column_int(statement, 23) != 0,
            isArchived: sqlite3_column_int(statement, 24) != 0
        )
    }

    private func decodeProviderExecutionMetadata(_ json: String?) -> AITranslationProviderExecutionMetadata {
        guard let json, let data = json.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(AITranslationProviderExecutionMetadata.self, from: data) else {
            return AITranslationProviderExecutionMetadata()
        }
        return metadata
    }

    private func validateStoredTranslation(
        record: DatabaseTranslationVersionRecord,
        lines: [DatabaseTranslationLineRecord],
        sourceLines: [DatabaseLyricLineRecord]
    ) -> Bool {
        guard record.status == .complete,
              lines.count == sourceLines.count,
              lines.map(\.lineIndex) == Array(sourceLines.indices) else { return false }
        return lines.allSatisfy { translation in
            let original = sourceLines[translation.lineIndex].originalText
            let sourceBlank = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let translationBlank = translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return sourceBlank == translationBlank &&
                (!sourceBlank || translation.translatedText.isEmpty) &&
                !translation.translatedText.contains("\n") &&
                !translation.translatedText.contains("\r")
        }
    }

    private func insertTranslationVersion(_ record: DatabaseTranslationVersionRecord) throws {
        let statement = try prepare("""
            INSERT INTO translation_versions(
                id, lyrics_version_id, parent_version_id, source_kind, target_language, model,
                base_url_host, prompt_hash, source_content_hash, created_at,
                updated_at, is_machine_generated, is_manually_edited,
                   is_locked, status, confidence, engine_id, prompt_preset_id,
                   profile_id, profile_snapshot, temperature, workflow_id,
                   fallback_strategy, is_draft, is_archived, provider_execution_metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.id.uuidString, at: 1, to: statement)
        try bindText(record.lyricsVersionID.uuidString, at: 2, to: statement)
        try bindText(record.parentVersionID?.uuidString, at: 3, to: statement)
        try bindText(record.sourceKind.rawValue, at: 4, to: statement)
        try bindText(record.targetLanguage, at: 5, to: statement)
        try bindText(record.model, at: 6, to: statement)
        try bindText(record.baseURLHost, at: 7, to: statement)
        try bindText(record.promptHash, at: 8, to: statement)
        try bindText(record.sourceContentHash, at: 9, to: statement)
        try bindDouble(record.createdAt.timeIntervalSince1970, at: 10, to: statement)
        try bindDouble(record.updatedAt.timeIntervalSince1970, at: 11, to: statement)
        try bindInt(record.isMachineGenerated ? 1 : 0, at: 12, to: statement)
        try bindInt(record.isManuallyEdited ? 1 : 0, at: 13, to: statement)
        try bindInt(record.isLocked ? 1 : 0, at: 14, to: statement)
        try bindText(record.status.rawValue, at: 15, to: statement)
        try bindDouble(record.confidence, at: 16, to: statement)
        try bindText(record.engineID, at: 17, to: statement)
        try bindText(record.promptPresetID, at: 18, to: statement)
        try bindText(record.profileID?.uuidString, at: 19, to: statement)
        try bindText(record.profileSnapshot, at: 20, to: statement)
        try bindDouble(record.temperature, at: 21, to: statement)
        try bindText(record.workflowID, at: 22, to: statement)
        try bindText(record.fallbackStrategy.rawValue, at: 23, to: statement)
        try bindInt(record.isDraft ? 1 : 0, at: 24, to: statement)
        try bindInt(record.isArchived ? 1 : 0, at: 25, to: statement)
        let metadataData = try JSONEncoder().encode(record.providerExecutionMetadata)
        try bindText(String(data: metadataData, encoding: .utf8) ?? "{}", at: 26, to: statement)
        try stepDone(statement)
    }

    private func insertTranslationLine(_ record: DatabaseTranslationLineRecord) throws {
        let statement = try prepare("""
            INSERT INTO translation_lines(translation_version_id, line_index, translated_text)
            VALUES (?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.translationVersionID.uuidString, at: 1, to: statement)
        try bindInt(record.lineIndex, at: 2, to: statement)
        try bindText(record.translatedText, at: 3, to: statement)
        try stepDone(statement)
    }

    private func createMigrationBackup(label: String) throws {
        guard let database else { throw LyricsRepositoryError.unavailable("SQLite handle 已关闭") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = databaseURL.deletingLastPathComponent()
        let base = databaseURL.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent("\(base).\(label)-\(formatter.string(from: Date())).sqlite3")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base).\(label)-\(UUID().uuidString.prefix(8)).sqlite3")
        }
        // SQLite's online backup includes committed WAL pages even while a
        // reader holds a snapshot. Copying only the main file can lose them.
        let temporary = destination.appendingPathExtension("\(UUID().uuidString).partial")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: temporary.path + suffix)
            }
        }
        do {
            var backupDatabase: OpaquePointer?
            guard sqlite3_open_v2(temporary.path, &backupDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let backupDatabase else {
                if let backupDatabase { sqlite3_close(backupDatabase) }
                throw LyricsRepositoryError.unavailable("migration \(label) 备份无法创建")
            }
            defer { sqlite3_close(backupDatabase) }
            guard let backup = sqlite3_backup_init(backupDatabase, "main", database, "main") else {
                throw LyricsRepositoryError.unavailable("migration \(label) 备份初始化失败")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                // Preserve the source and abort; never migrate after a failed backup.
                throw LyricsRepositoryError.unavailable("migration \(label) 备份失败 (\(step)/\(finish))")
            }
            // Make the snapshot a standalone read-only recovery file, even
            // when the source database uses WAL journaling.
            guard sqlite3_exec(backupDatabase, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
                throw LyricsRepositoryError.unavailable("migration \(label) 备份日志整理失败")
            }
        }
        // Only a completed, closed snapshot receives the recovery filename.
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func ensurePrepared() throws {
        guard prepared, database != nil else {
            throw LyricsRepositoryError.unavailable("数据库尚未准备")
        }
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    private func reloadRedirectResolver() throws {
        guard database != nil else { throw LyricsRepositoryError.unavailable("SQLite handle 已关闭") }

        let keyStatement = try prepare("SELECT stable_key, spotify_id, spotify_uri, title, artist_display, album, duration FROM tracks;")
        defer { sqlite3_finalize(keyStatement) }
        var knownKeys = Set<String>()
        var recordingGroups: [String: [(key: String, duration: Double)]] = [:]
        while sqlite3_step(keyStatement) == SQLITE_ROW {
            guard let key = columnText(keyStatement, index: 0) else {
                throw LyricsRepositoryError.invalidData("Track stable_key 缺失")
            }
            knownKeys.insert(key)
            // Older playback snapshots used integer seconds while edited or
            // refreshed snapshots retained fractions. Treat that drift as one
            // recording only with a shared provider ID AND matching metadata.
            if let id = TrackIdentity.canonicalSpotifyTrackID(columnText(keyStatement, index: 1))
                ?? TrackIdentity.canonicalSpotifyTrackID(columnText(keyStatement, index: 2)) {
                let title = TrackIdentity.normalizedComponent(columnText(keyStatement, index: 3) ?? "")
                let artist = TrackIdentity.normalizedComponent(columnText(keyStatement, index: 4) ?? "")
                let album = TrackIdentity.normalizedComponent(columnText(keyStatement, index: 5) ?? "")
                let duration = sqlite3_column_double(keyStatement, 6)
                if !title.isEmpty, !artist.isEmpty, duration.isFinite, duration > 0 {
                    recordingGroups[[id, title, artist, album].joined(separator: "|"), default: []].append((key, duration))
                }
            }
        }

        var redirects: [String: String] = [:]
        if try hasTable("track_identity_redirects") {
            let redirectStatement = try prepare("""
                SELECT source_stable_key, canonical_stable_key
                FROM track_identity_redirects;
                """)
            defer { sqlite3_finalize(redirectStatement) }
            while sqlite3_step(redirectStatement) == SQLITE_ROW {
                guard let source = columnText(redirectStatement, index: 0),
                      let canonical = columnText(redirectStatement, index: 1) else {
                    throw LyricsRepositoryError.invalidData("identity redirect 字段缺失")
                }
                if let existing = redirects[source], existing != canonical {
                    throw LyricsRepositoryError.invalidData("identity redirect 冲突：\(source)")
                }
                redirects[source] = canonical
            }
        } else {
            // Keep an existing formal v3 database logically compatible while
            // v4 remains opt-in. This is read-only: no redirect table or row
            // is written until the user explicitly authorizes migration.
            redirects = DatabaseMigrator.readOnlyInitialRedirects(knownStableKeys: knownKeys)
        }

        let resolver = TrackIdentityRedirectResolver(
            redirects: redirects,
            knownStableKeys: knownKeys
        )
        for source in redirects.keys {
            _ = try resolver.resolve(source)
        }
        // This is an in-memory equivalence only: all physical rows, version
        // IDs and explicit redirects remain intact. A wider duration spread
        // is ambiguous, so never build a transitive chain of near matches.
        for group in recordingGroups.values where group.count > 1 {
            guard let minimum = group.map(\.duration).min(), let maximum = group.map(\.duration).max(),
                  maximum - minimum <= 1 else { continue }
            let explicitTargets = try Set(group.compactMap { member -> String? in
                guard redirects[member.key] != nil else { return nil }
                return try resolver.resolve(member.key)
            })
            // An explicit cross-recording redirect outranks automatic grouping.
            guard explicitTargets.count <= 1, explicitTargets.isSubset(of: Set(group.map(\.key))),
                  let canonical = explicitTargets.first ?? group.map(\.key).sorted().first else { continue }
            for member in group where member.key != canonical && redirects[member.key] == nil {
                redirects[member.key] = canonical
            }
        }
        redirectResolver = TrackIdentityRedirectResolver(redirects: redirects, knownStableKeys: knownKeys)
    }

    private func hasTable(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(name, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func resolvedCanonicalStableKey(_ stableKey: String) throws -> String {
        guard let redirectResolver else { return stableKey }
        return try redirectResolver.resolve(stableKey)
    }

    private func resolvedIdentityFamily(stableKey: String) throws -> [String] {
        guard let redirectResolver else { return [stableKey] }
        return try redirectResolver.identityFamily(for: stableKey)
    }

    private func placeholders(count: Int) -> String {
        Array(repeating: "?", count: max(1, count)).joined(separator: ",")
    }

    private func canonicalTrackRecord(_ record: DatabaseTrackRecord, stableKey: String) -> DatabaseTrackRecord {
        guard record.stableKey != stableKey else { return record }
        return DatabaseTrackRecord(
            stableKey: stableKey,
            spotifyID: record.spotifyID,
            spotifyURI: record.spotifyURI,
            isrc: record.isrc,
            title: record.title,
            artistDisplay: record.artistDisplay,
            album: record.album,
            duration: record.duration,
            artworkURL: record.artworkURL,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func canonicalAliasRecord(_ record: DatabaseTrackAliasRecord, stableKey: String) -> DatabaseTrackAliasRecord {
        DatabaseTrackAliasRecord(
            trackStableKey: stableKey,
            field: record.field,
            kind: record.kind,
            value: record.value,
            language: record.language,
            script: record.script,
            source: record.source,
            confidence: record.confidence,
            isOfficial: record.isOfficial
        )
    }

    private func canonicalVersionRecord(_ record: DatabaseLyricsVersionRecord, stableKey: String) -> DatabaseLyricsVersionRecord {
        guard record.trackStableKey != stableKey else { return record }
        return DatabaseLyricsVersionRecord(
            id: record.id,
            trackStableKey: stableKey,
            parentVersionID: record.parentVersionID,
            source: record.source,
            providerSourceID: record.providerSourceID,
            language: record.language,
            isSynced: record.isSynced,
            rawText: record.rawText,
            contentHash: record.contentHash,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            isMachineGenerated: record.isMachineGenerated,
            isManuallyEdited: record.isManuallyEdited,
            isLocked: record.isLocked,
            confidence: record.confidence
        )
    }

    private func upsertTrack(_ record: DatabaseTrackRecord) throws {
        let statement = try prepare("""
            INSERT INTO tracks(
                stable_key, spotify_id, spotify_uri, isrc, title, artist_display,
                album, duration, artwork_url, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(stable_key) DO UPDATE SET
                spotify_id = CASE WHEN tracks.spotify_id IS NULL OR length(trim(tracks.spotify_id)) = 0 THEN excluded.spotify_id ELSE tracks.spotify_id END,
                spotify_uri = CASE WHEN tracks.spotify_uri IS NULL OR length(trim(tracks.spotify_uri)) = 0 THEN excluded.spotify_uri ELSE tracks.spotify_uri END,
                isrc = CASE WHEN tracks.isrc IS NULL OR length(trim(tracks.isrc)) = 0 THEN excluded.isrc ELSE tracks.isrc END,
                title = CASE WHEN length(trim(tracks.title)) = 0 THEN excluded.title ELSE tracks.title END,
                artist_display = CASE WHEN length(trim(tracks.artist_display)) = 0 THEN excluded.artist_display ELSE tracks.artist_display END,
                album = CASE WHEN length(trim(tracks.album)) = 0 THEN excluded.album ELSE tracks.album END,
                duration = CASE WHEN tracks.duration <= 0 THEN excluded.duration ELSE tracks.duration END,
                artwork_url = CASE WHEN tracks.artwork_url IS NULL OR length(trim(tracks.artwork_url)) = 0 THEN excluded.artwork_url ELSE tracks.artwork_url END,
                updated_at = excluded.updated_at;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.stableKey, at: 1, to: statement)
        try bindText(record.spotifyID, at: 2, to: statement)
        try bindText(record.spotifyURI, at: 3, to: statement)
        try bindText(record.isrc, at: 4, to: statement)
        try bindText(record.title, at: 5, to: statement)
        try bindText(record.artistDisplay, at: 6, to: statement)
        try bindText(record.album, at: 7, to: statement)
        try bindDouble(record.duration, at: 8, to: statement)
        try bindText(record.artworkURL, at: 9, to: statement)
        try bindDouble(record.createdAt.timeIntervalSince1970, at: 10, to: statement)
        try bindDouble(record.updatedAt.timeIntervalSince1970, at: 11, to: statement)
        try stepDone(statement)
    }

    private func insertAlias(_ record: DatabaseTrackAliasRecord) throws {
        let statement = try prepare("""
            INSERT OR IGNORE INTO track_aliases(
                track_stable_key, field, kind, value, language, script,
                source, confidence, is_official
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.trackStableKey, at: 1, to: statement)
        try bindText(record.field, at: 2, to: statement)
        try bindText(record.kind, at: 3, to: statement)
        try bindText(record.value, at: 4, to: statement)
        try bindText(record.language, at: 5, to: statement)
        try bindText(record.script, at: 6, to: statement)
        try bindText(record.source, at: 7, to: statement)
        try bindDouble(record.confidence, at: 8, to: statement)
        try bindInt(record.isOfficial ? 1 : 0, at: 9, to: statement)
        try stepDone(statement)
    }

    private func insertVersion(_ record: DatabaseLyricsVersionRecord) throws {
        let statement = try prepare("""
            INSERT INTO lyrics_versions(
                id, track_stable_key, parent_version_id, source, provider_source_id, language,
                is_synced, raw_text, content_hash, created_at, updated_at,
                is_machine_generated, is_manually_edited, is_locked, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.id.uuidString, at: 1, to: statement)
        try bindText(record.trackStableKey, at: 2, to: statement)
        try bindText(record.parentVersionID?.uuidString, at: 3, to: statement)
        try bindText(record.source, at: 4, to: statement)
        try bindText(record.providerSourceID, at: 5, to: statement)
        try bindText(record.language, at: 6, to: statement)
        try bindInt(record.isSynced ? 1 : 0, at: 7, to: statement)
        try bindText(record.rawText, at: 8, to: statement)
        try bindText(record.contentHash, at: 9, to: statement)
        try bindDouble(record.createdAt.timeIntervalSince1970, at: 10, to: statement)
        try bindDouble(record.updatedAt.timeIntervalSince1970, at: 11, to: statement)
        try bindInt(record.isMachineGenerated ? 1 : 0, at: 12, to: statement)
        try bindInt(record.isManuallyEdited ? 1 : 0, at: 13, to: statement)
        try bindInt(record.isLocked ? 1 : 0, at: 14, to: statement)
        try bindDouble(record.confidence, at: 15, to: statement)
        try stepDone(statement)
    }

    private func insertLine(_ record: DatabaseLyricLineRecord) throws {
        let statement = try prepare("""
            INSERT INTO lyric_lines(
                lyrics_version_id, line_index, start_time, end_time,
                original_text, kana_text, romaji_text, translation_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.lyricsVersionID.uuidString, at: 1, to: statement)
        try bindInt(record.lineIndex, at: 2, to: statement)
        try bindDouble(record.startTime, at: 3, to: statement)
        try bindDouble(record.endTime, at: 4, to: statement)
        try bindText(record.originalText, at: 5, to: statement)
        try bindText(record.kanaText, at: 6, to: statement)
        try bindText(record.romajiText, at: 7, to: statement)
        try bindText(record.translationText, at: 8, to: statement)
        try stepDone(statement)
    }

    private func deleteVersionRows(versionID: UUID) throws {
        let statement = try prepare("DELETE FROM lyrics_versions WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) > 0 else {
            throw LyricsRepositoryError.invalidData("找不到歌词版本 \(versionID.uuidString)")
        }
    }

    private func fetchAllVersionIDs() throws -> [UUID] {
        let statement = try prepare("SELECT id FROM lyrics_versions;")
        defer { sqlite3_finalize(statement) }
        var result: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = columnText(statement, index: 0),
                  let id = UUID(uuidString: text) else {
                throw LyricsRepositoryError.invalidData("歌词版本 UUID 无效")
            }
            result.append(id)
        }
        return result
    }

    private func findVersionID(
        stableKey: String,
        source: String,
        providerSourceID: String,
        contentHash: String
    ) throws -> UUID? {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("""
            SELECT id FROM lyrics_versions
            WHERE track_stable_key IN (\(placeholders(count: family.count))) AND source = ?
              AND provider_source_id = ? AND content_hash = ?
            LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        let offset = Int32(family.count)
        try bindText(source, at: offset + 1, to: statement)
        try bindText(providerSourceID, at: offset + 2, to: statement)
        try bindText(contentHash, at: offset + 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let value = columnText(statement, index: 0), let id = UUID(uuidString: value) else {
            throw LyricsRepositoryError.invalidData("歌词版本 UUID 无效")
        }
        return id
    }

    private func hasLockedVersion(stableKey: String) throws -> Bool {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("SELECT 1 FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count))) AND is_locked = 1 LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func fetchLockedVersionIDs(stableKey: String) throws -> [UUID] {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("SELECT id FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count))) AND is_locked = 1 ORDER BY id;")
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = columnText(statement, index: 0), let id = UUID(uuidString: value) else {
                throw LyricsRepositoryError.invalidData("锁定歌词版本 UUID 无效")
            }
            ids.append(id)
        }
        return ids
    }

    private func fetchTrack(stableKey: String) throws -> DatabaseTrackRecord? {
        let statement = try prepare("""
            SELECT stable_key, spotify_id, spotify_uri, isrc, title, artist_display,
                   album, duration, artwork_url, created_at, updated_at
            FROM tracks WHERE stable_key = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(stableKey, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let key = columnText(statement, index: 0),
              let title = columnText(statement, index: 4),
              let artist = columnText(statement, index: 5),
              let album = columnText(statement, index: 6) else {
            throw LyricsRepositoryError.invalidData("TrackRecord 字段缺失")
        }
        return DatabaseTrackRecord(
            stableKey: key,
            spotifyID: columnText(statement, index: 1),
            spotifyURI: columnText(statement, index: 2),
            isrc: columnText(statement, index: 3),
            title: title,
            artistDisplay: artist,
            album: album,
            duration: sqlite3_column_double(statement, 7),
            artworkURL: columnText(statement, index: 8),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    private func hasValidWordTiming(version: DatabaseLyricsVersionRecord) throws -> Bool {
        let lines = try fetchLines(versionID: version.id)
        guard !lines.isEmpty else { return false }
        let sourceContentHash = LyricsSourceContentHasher.hash(
            isSynchronized: version.isSynced,
            lines: lines
        )
        guard let trackRecord = try fetchTrack(stableKey: version.trackStableKey) else { return false }
        let track = Track(
            title: trackRecord.title,
            artist: trackRecord.artistDisplay,
            album: trackRecord.album,
            duration: trackRecord.duration,
            isrc: trackRecord.isrc,
            spotifyId: trackRecord.spotifyID
        )
        let document = Self.documentForTimingValidation(
            identity: TrackIdentity(track: track),
            track: track,
            version: version,
            lines: lines
        )
        guard let timingRecord = try fetchBestTimingVersion(
            lyricsVersionID: version.id,
            sourceContentHash: sourceContentHash,
            document: document
        ) else {
            return false
        }
        guard let timingMap = DocumentTimingPayload.decode(timingRecord.spansPayload),
              LyricsTimingCompatibility.validatedTimingMap(timingMap, for: document) != nil else {
            return false
        }
        return timingMap.values.contains { !$0.spans.isEmpty }
    }

    private func fetchBestVersion(stableKey: String) throws -> DatabaseLyricsVersionRecord? {
        guard !(try hasRevokedLyricsSelection(stableKey: stableKey)) else { return nil }
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("""
            SELECT id, track_stable_key, source, provider_source_id, language,
                   parent_version_id, is_synced, raw_text, content_hash, created_at, updated_at,
                   is_machine_generated, is_manually_edited, is_locked, confidence, is_preferred
            FROM lyrics_versions
            WHERE track_stable_key IN (\(placeholders(count: family.count)))
              AND (is_preferred = 1 OR is_locked = 1 OR confidence >= ?)
            -- A confirmed alignment is a user-selected child version. Keep it
            -- ahead of its plain-text parent after the lock decision, while
            -- preserving the existing confidence filter for untrusted rows.
            ORDER BY is_preferred DESC, is_locked DESC,
                     CASE WHEN source = 'automaticAlignment' THEN 1 ELSE 0 END DESC,
                     updated_at DESC,
                     confidence DESC;
        """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        try bindDouble(LyricsMatcher.highConfidenceThreshold, at: Int32(family.count + 1), to: statement)

        var candidates: [(record: DatabaseLyricsVersionRecord, isPreferred: Bool)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let key = columnText(statement, index: 1),
                  let source = columnText(statement, index: 2),
                  let provider = columnText(statement, index: 3),
                  let language = columnText(statement, index: 4),
                  let rawText = columnText(statement, index: 7),
                  let contentHash = columnText(statement, index: 8) else {
                throw LyricsRepositoryError.invalidData("LyricsVersionRecord 字段缺失")
            }
            let record = DatabaseLyricsVersionRecord(
                id: id,
                trackStableKey: key,
                parentVersionID: columnText(statement, index: 5).flatMap(UUID.init(uuidString:)),
                source: source,
                providerSourceID: provider,
                language: language,
                isSynced: sqlite3_column_int(statement, 6) != 0,
                rawText: rawText,
                contentHash: contentHash,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isMachineGenerated: sqlite3_column_int(statement, 11) != 0,
                isManuallyEdited: sqlite3_column_int(statement, 12) != 0,
                isLocked: sqlite3_column_int(statement, 13) != 0,
                confidence: sqlite3_column_double(statement, 14)
            )
            let isPreferred = sqlite3_column_int(statement, 15) != 0
            candidates.append((record, isPreferred))
        }

        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0].record }

        // User explicit preference or locked status takes top priority
        if candidates[0].isPreferred || candidates[0].record.isLocked {
            return candidates[0].record
        }

        // Reuse the exact timing loading validity rules (matching content hash & decoded word spans).
        // A version with verified word-level timing takes precedence over plain line-timed versions.
        for candidate in candidates {
            if try hasValidWordTiming(version: candidate.record) {
                return candidate.record
            }
        }

        return candidates[0].record
    }

    private func fetchLines(versionID: UUID) throws -> [DatabaseLyricLineRecord] {
        let statement = try prepare("""
            SELECT lyrics_version_id, line_index, start_time, end_time,
                   original_text, kana_text, romaji_text, translation_text
            FROM lyric_lines WHERE lyrics_version_id = ? ORDER BY line_index ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 1, to: statement)

        var result: [DatabaseLyricLineRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let original = columnText(statement, index: 4) else {
                throw LyricsRepositoryError.invalidData("LyricLineRecord 字段缺失")
            }
            result.append(
                DatabaseLyricLineRecord(
                    lyricsVersionID: id,
                    lineIndex: Int(sqlite3_column_int(statement, 1)),
                    startTime: columnDouble(statement, index: 2),
                    endTime: columnDouble(statement, index: 3),
                    originalText: original,
                    kanaText: columnText(statement, index: 5),
                    romajiText: columnText(statement, index: 6),
                    translationText: columnText(statement, index: 7)
                )
            )
        }
        return result
    }

    private func insertTimingVersion(_ record: DatabaseLyricsTimingVersionRecord) throws {
        let statement = try prepare("""
            INSERT INTO lyrics_timing_versions(
                id, lyrics_version_id, source, granularity,
                source_content_hash, spans_payload, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(record.id.uuidString, at: 1, to: statement)
        try bindText(record.lyricsVersionID.uuidString, at: 2, to: statement)
        try bindText(record.source, at: 3, to: statement)
        try bindText(record.granularity, at: 4, to: statement)
        try bindText(record.sourceContentHash, at: 5, to: statement)
        try bindText(record.spansPayload, at: 6, to: statement)
        try bindDouble(record.createdAt.timeIntervalSince1970, at: 7, to: statement)
        try stepDone(statement)
    }

    private func fetchTimingVersion(id: UUID) throws -> DatabaseLyricsTimingVersionRecord? {
        let statement = try prepare("""
            SELECT id, lyrics_version_id, source, granularity,
                   source_content_hash, spans_payload, created_at
            FROM lyrics_timing_versions
            WHERE id = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(id.uuidString, at: 1, to: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let idText = columnText(statement, index: 0),
              let id = UUID(uuidString: idText),
              let versionIDText = columnText(statement, index: 1),
              let versionID = UUID(uuidString: versionIDText),
              let source = columnText(statement, index: 2),
              let granularity = columnText(statement, index: 3),
              let hash = columnText(statement, index: 4),
              let payload = columnText(statement, index: 5) else {
            return nil
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        return DatabaseLyricsTimingVersionRecord(
            id: id,
            lyricsVersionID: versionID,
            source: source,
            granularity: granularity,
            sourceContentHash: hash,
            spansPayload: payload,
            createdAt: createdAt
        )
    }

    @discardableResult
    private func attachTimingVersionIfNeeded(
        document: LyricsDocument,
        lyricsVersionID: UUID,
        source: String,
        sourceContentHash: String,
        now: Date
    ) throws -> UUID? {
        guard LyricsTimingCompatibility.hasOnlyCompatibleSpans(in: document) else {
            throw LyricsRepositoryError.dataIntegrityViolation("Timed spans do not match the document text or valid time order")
        }
        guard let payload = DocumentTimingPayload.encode(document.lines) else { return nil }
        let granularity = document.lines.compactMap(\.timedSpans).flatMap { $0 }.first?.granularity.rawValue ?? "timedUnit"

        if document.timingVersionID == nil,
           let existing = try fetchBestTimingVersion(
               lyricsVersionID: lyricsVersionID,
               sourceContentHash: sourceContentHash,
               document: document
           ),
           existing.source == source,
           existing.granularity == granularity,
           existing.spansPayload == payload {
            return existing.id
        }

        if let existingTimingID = document.timingVersionID {
            if let existing = try fetchTimingVersion(id: existingTimingID) {
                if existing.lyricsVersionID == lyricsVersionID &&
                    existing.sourceContentHash == sourceContentHash &&
                    existing.source == source &&
                    existing.granularity == granularity &&
                    existing.spansPayload == payload {
                    // Safe idempotent no-op for re-saving exact identical immutable timing version
                    return existingTimingID
                } else {
                    throw LyricsRepositoryError.dataIntegrityViolation(
                        "Timing version data integrity violation for \(existingTimingID): existing record differs from incoming payload (immutable timing identity mismatch)"
                    )
                }
            } else {
                let timingRecord = DatabaseLyricsTimingVersionRecord(
                    id: existingTimingID,
                    lyricsVersionID: lyricsVersionID,
                    source: source,
                    granularity: granularity,
                    sourceContentHash: sourceContentHash,
                    spansPayload: payload,
                    createdAt: now
                )
                try insertTimingVersion(timingRecord)
                return existingTimingID
            }
        } else {
            let timingRecord = DatabaseLyricsTimingVersionRecord(
                id: UUID(),
                lyricsVersionID: lyricsVersionID,
                source: source,
                granularity: granularity,
                sourceContentHash: sourceContentHash,
                spansPayload: payload,
                createdAt: now
            )
            try insertTimingVersion(timingRecord)
            return timingRecord.id
        }
    }

    /// Phase 1 policy:
    /// Latest compatible timing version wins for identical `(lyrics_version_id, source_content_hash)`.
    /// Historical timing versions remain immutable in `lyrics_timing_versions` and are neither overwritten nor deleted.
    private func fetchBestTimingVersion(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        document: LyricsDocument
    ) throws -> DatabaseLyricsTimingVersionRecord? {
        let statement = try prepare("""
            SELECT id, lyrics_version_id, source, granularity,
                   source_content_hash, spans_payload, created_at
            FROM lyrics_timing_versions
            WHERE lyrics_version_id = ? AND source_content_hash = ?
            ORDER BY created_at DESC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(lyricsVersionID.uuidString, at: 1, to: statement)
        try bindText(sourceContentHash, at: 2, to: statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, index: 0),
                  let id = UUID(uuidString: idText),
                  let versionIDText = columnText(statement, index: 1),
                  let versionID = UUID(uuidString: versionIDText),
                  let source = columnText(statement, index: 2),
                  let granularity = columnText(statement, index: 3),
                  let hash = columnText(statement, index: 4),
                  let payload = columnText(statement, index: 5) else {
                continue
            }
            guard let timingMap = DocumentTimingPayload.decode(payload),
                  LyricsTimingCompatibility.validatedTimingMap(timingMap, for: document) != nil else {
                continue
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            return DatabaseLyricsTimingVersionRecord(
                id: id,
                lyricsVersionID: versionID,
                source: source,
                granularity: granularity,
                sourceContentHash: hash,
                spansPayload: payload,
                createdAt: createdAt
            )
        }
        return nil
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw LyricsRepositoryError.unavailable("SQLite handle 已关闭") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw LyricsRepositoryError.sqlite(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarOptionalDouble(_ sql: String) throws -> Double? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return columnDouble(statement, index: 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw LyricsRepositoryError.unavailable("SQLite handle 已关闭") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw lastError(result)
        }
        return statement
    }

    private func bindText(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw lastError(result) }
    }

    private func bindInt(_ value: Int, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else { throw lastError() }
    }

    private func bindDouble(_ value: TimeInterval?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw lastError(result) }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnDouble(_ statement: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func lastError(_ result: Int32? = nil) -> LyricsRepositoryError {
        if let result, result != SQLITE_OK {
            return .sqlite("SQLite error (\(result))")
        }
        guard let database else { return .unavailable("SQLite handle 已关闭") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    // MARK: - Personal Asset Definition & Library Query

    /// Returns tracks that have user local assets:
    /// - Manually edited or locally imported lyrics (`is_manually_edited = 1` or `source = 'local'` or `source = 'manual'`)
    /// - User locked lyrics version (`is_locked = 1`)
    /// - Adopted or locked translation versions (`is_locked = 1` or `is_manually_edited = 1` or active complete translation)
    /// - Saved reading versions (`reading_versions` attached to lyrics)
    /// - Saved fine timing versions (`lyrics_timing_versions` attached to lyrics)
    public func loadPersonalLibraryEntries(searchQuery: String? = nil) throws -> [PersonalLyricsLibraryEntry] {
        try prepare()
        // Newly saved keys must join their recording family without a restart.
        try reloadRedirectResolver()
        let statement = try prepare("""
            SELECT stable_key FROM tracks AS t
            WHERE EXISTS (SELECT 1 FROM lyrics_versions WHERE track_stable_key = t.stable_key)
            ORDER BY stable_key;
            """)
        defer { sqlite3_finalize(statement) }
        var seen = Set<String>()
        var results: [PersonalLyricsLibraryEntry] = []
        let filter = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, index: 0) else { continue }
            let canonical = try resolvedCanonicalStableKey(key)
            guard seen.insert(canonical).inserted,
                  let track = try fetchTrack(stableKey: canonical) else { continue }
            if !filter.isEmpty, try !libraryFamilyMatches(stableKey: canonical, query: filter) { continue }
            results.append(try compileLibraryEntry(
                stableKey: canonical, spotifyID: track.spotifyID, spotifyURI: track.spotifyURI,
                isrc: track.isrc, title: track.title, artist: track.artistDisplay, album: track.album,
                duration: track.duration, artworkURL: track.artworkURL.flatMap(URL.init(string:)), fallbackDate: track.updatedAt
            ))
        }
        return results.sorted {
            if $0.lastModifiedAt != $1.lastModifiedAt { return $0.lastModifiedAt > $1.lastModifiedAt }
            return $0.trackStableKey < $1.trackStableKey
        }
    }

    /// Search every saved version, including auxiliary layers on historical
    /// identity keys. The query is compared as literal text, never SQL syntax.
    private func libraryFamilyMatches(stableKey: String, query: String) throws -> Bool {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("""
            WITH family AS (SELECT * FROM tracks WHERE stable_key IN (\(placeholders(count: family.count)))),
                 versions AS (SELECT * FROM lyrics_versions WHERE track_stable_key IN (SELECT stable_key FROM family))
            SELECT title || ' ' || artist_display || ' ' || album || ' ' || COALESCE(spotify_id, '') || ' ' || COALESCE(spotify_uri, '') || ' ' || COALESCE(isrc, '') AS text, 0 AS is_reading FROM family
            UNION ALL SELECT value, 0 FROM track_aliases WHERE track_stable_key IN (SELECT stable_key FROM family)
            UNION ALL SELECT raw_text, 0 FROM versions
            UNION ALL SELECT original_text || ' ' || COALESCE(kana_text, '') || ' ' || COALESCE(romaji_text, '') || ' ' || COALESCE(translation_text, ''), 0
                FROM lyric_lines WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT kana_text, 1 FROM lyric_lines WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT COALESCE(kana_text, '') || ' ' || COALESCE(romaji_text, ''), 1
                FROM lyric_reading_layers WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT rl.reading_text, 1 FROM reading_lines rl JOIN reading_versions rv ON rv.id = rl.reading_version_id
                WHERE rv.lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT tl.translated_text, 0 FROM translation_lines tl JOIN translation_versions tv ON tv.id = tl.translation_version_id
                WHERE tv.lyrics_version_id IN (SELECT id FROM versions);
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = columnText(statement, index: 0) else { continue }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            if text.range(of: query, options: options) != nil { return true }
            if sqlite3_column_int(statement, 1) == 1,
               JapaneseRomanizer.romanizeConfirmedKana(text).range(of: query, options: options) != nil { return true }
        }
        return false
    }

    private func compileLibraryEntry(
        stableKey: String,
        spotifyID: String?,
        spotifyURI: String?,
        isrc: String?,
        title: String,
        artist: String,
        album: String?,
        duration: Double,
        artworkURL: URL?,
        fallbackDate: Date
    ) throws -> PersonalLyricsLibraryEntry {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let lyricsStmt = try prepare("""
            SELECT id, is_manually_edited, is_locked, confidence, updated_at, source
            FROM lyrics_versions
            WHERE track_stable_key IN (\(placeholders(count: family.count)))
            ORDER BY is_preferred DESC, is_locked DESC, confidence DESC, updated_at DESC;
            """)
        defer { sqlite3_finalize(lyricsStmt) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: lyricsStmt) }

        var lyricsVersionCount = 0
        var hasLockedLyrics = false
        var hasManualLyrics = false
        let selectionRevoked = try hasRevokedLyricsSelection(stableKey: stableKey)
        var activeLyricsVersionID: UUID?
        var lyricsVersionIDs: [UUID] = []
        var maxDate = fallbackDate

        while sqlite3_step(lyricsStmt) == SQLITE_ROW {
            guard let idText = columnText(lyricsStmt, index: 0),
                  let id = UUID(uuidString: idText) else { continue }
            lyricsVersionCount += 1
            lyricsVersionIDs.append(id)
            if activeLyricsVersionID == nil, !selectionRevoked {
                activeLyricsVersionID = id
            }
            let isManual = sqlite3_column_int(lyricsStmt, 1) == 1
            let isLocked = sqlite3_column_int(lyricsStmt, 2) == 1
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(lyricsStmt, 4))
            let source = columnText(lyricsStmt, index: 5) ?? ""

            if isLocked { hasLockedLyrics = true }
            if isManual || source == "local" || source == "manual" { hasManualLyrics = true }
            if updatedAt > maxDate { maxDate = updatedAt }
        }

        var translationVersionCount = 0
        var hasLockedTranslation = false
        var hasManualTranslation = false
        var activeTranslationVersionID: UUID?

        var readingVersionCount = 0
        var hasReading = false
        var activeReadingVersionIDs: [String: UUID] = [:]

        var timingVersionCount = 0
        var hasFineTiming = false
        var activeTimingVersionID: UUID?

        if !lyricsVersionIDs.isEmpty {
            let idPlaceholders = lyricsVersionIDs.map { _ in "?" }.joined(separator: ",")

            let transStmt = try prepare("""
                SELECT id, is_locked, is_manually_edited, is_archived, status, updated_at, lyrics_version_id
                FROM translation_versions
                WHERE lyrics_version_id IN (\(idPlaceholders))
                ORDER BY is_locked DESC, is_archived ASC, updated_at DESC;
                """)
            defer { sqlite3_finalize(transStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: transStmt)
            }

            while sqlite3_step(transStmt) == SQLITE_ROW {
                guard let idText = columnText(transStmt, index: 0),
                      let id = UUID(uuidString: idText) else { continue }
                translationVersionCount += 1
                let isLocked = sqlite3_column_int(transStmt, 1) == 1
                let isManual = sqlite3_column_int(transStmt, 2) == 1
                let isArchived = sqlite3_column_int(transStmt, 3) == 1
                let status = columnText(transStmt, index: 4) ?? ""
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(transStmt, 5))
                let lvidText = columnText(transStmt, index: 6)
                let lvid = lvidText.flatMap { UUID(uuidString: $0) }

                if isLocked { hasLockedTranslation = true }
                if isManual { hasManualTranslation = true }
                if activeTranslationVersionID == nil && !isArchived && (status == "complete" || isLocked) {
                    if lvid == activeLyricsVersionID || activeLyricsVersionID == nil {
                        activeTranslationVersionID = id
                    }
                }
                if updatedAt > maxDate { maxDate = updatedAt }
            }

            let readStmt = try prepare("""
                SELECT id, representation_id, is_current, is_locked, is_archived, updated_at, lyrics_version_id
                FROM reading_versions
                WHERE lyrics_version_id IN (\(idPlaceholders))
                ORDER BY is_locked DESC, is_current DESC, updated_at DESC;
                """)
            defer { sqlite3_finalize(readStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: readStmt)
            }

            while sqlite3_step(readStmt) == SQLITE_ROW {
                guard let idText = columnText(readStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let repID = columnText(readStmt, index: 1) else { continue }
                readingVersionCount += 1
                hasReading = true
                let isArchived = sqlite3_column_int(readStmt, 4) == 1
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(readStmt, 5))
                let lvidText = columnText(readStmt, index: 6)
                let lvid = lvidText.flatMap { UUID(uuidString: $0) }

                if !isArchived && activeReadingVersionIDs[repID] == nil {
                    if lvid == activeLyricsVersionID || activeLyricsVersionID == nil {
                        activeReadingVersionIDs[repID] = id
                    }
                }
                if updatedAt > maxDate { maxDate = updatedAt }
            }

            let timeStmt = try prepare("""
                SELECT id, created_at, lyrics_version_id
                FROM lyrics_timing_versions
                WHERE lyrics_version_id IN (\(idPlaceholders))
                ORDER BY created_at DESC;
                """)
            defer { sqlite3_finalize(timeStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: timeStmt)
            }

            while sqlite3_step(timeStmt) == SQLITE_ROW {
                guard let idText = columnText(timeStmt, index: 0),
                      let id = UUID(uuidString: idText) else { continue }
                timingVersionCount += 1
                hasFineTiming = true
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(timeStmt, 1))
                let lvidText = columnText(timeStmt, index: 2)
                let lvid = lvidText.flatMap { UUID(uuidString: $0) }

                if activeTimingVersionID == nil {
                    if lvid == activeLyricsVersionID || activeLyricsVersionID == nil {
                        activeTimingVersionID = id
                    }
                }
                if createdAt > maxDate { maxDate = createdAt }
            }
        }

        return PersonalLyricsLibraryEntry(
            trackStableKey: stableKey,
            spotifyTrackID: spotifyID,
            spotifyURI: spotifyURI,
            isrc: isrc,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            lyricsVersionCount: lyricsVersionCount,
            translationVersionCount: translationVersionCount,
            readingVersionCount: readingVersionCount,
            timingVersionCount: timingVersionCount,
            hasLockedLyrics: hasLockedLyrics,
            hasLockedTranslation: hasLockedTranslation,
            hasManualLyrics: hasManualLyrics,
            hasManualTranslation: hasManualTranslation,
            hasReading: hasReading,
            hasFineTiming: hasFineTiming,
            lastModifiedAt: maxDate,
            activeLyricsVersionID: activeLyricsVersionID,
            activeTranslationVersionID: activeTranslationVersionID,
            activeReadingVersionIDs: activeReadingVersionIDs,
            activeTimingVersionID: activeTimingVersionID
        )
    }

    // MARK: - Track Detail Query

    public func loadPersonalLibraryTrackDetail(stableKey: String) throws -> PersonalLyricsLibraryTrackDetail? {
        try prepare()
        try reloadRedirectResolver()
        let stableKey = try resolvedCanonicalStableKey(stableKey)
        let family = try resolvedIdentityFamily(stableKey: stableKey)

        let trackStmt = try prepare("""
            SELECT stable_key, spotify_id, spotify_uri, isrc, title, artist_display,
                   album, duration, artwork_url, updated_at
            FROM tracks
            WHERE stable_key = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(trackStmt) }
        try bindText(stableKey, at: 1, to: trackStmt)

        guard sqlite3_step(trackStmt) == SQLITE_ROW,
              let title = columnText(trackStmt, index: 4),
              let artist = columnText(trackStmt, index: 5) else {
            return nil
        }

        let spotifyID = columnText(trackStmt, index: 1)
        let spotifyURI = columnText(trackStmt, index: 2)
        let isrc = columnText(trackStmt, index: 3)
        let album = columnText(trackStmt, index: 6)
        let duration = sqlite3_column_double(trackStmt, 7)
        let artworkURLText = columnText(trackStmt, index: 8)
        let artworkURL = artworkURLText.flatMap { URL(string: $0) }
        let trackUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(trackStmt, 9))

        let entry = try compileLibraryEntry(
            stableKey: stableKey,
            spotifyID: spotifyID,
            spotifyURI: spotifyURI,
            isrc: isrc,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            fallbackDate: trackUpdatedAt
        )

        var lyricsItems: [PersonalLyricsVersionItem] = []
        let lyricsStmt = try prepare("""
            SELECT lv.id, lv.parent_version_id, lv.source, lv.provider_source_id, lv.language,
                   lv.is_synced, lv.is_machine_generated, lv.is_manually_edited, lv.is_locked,
                   lv.confidence, lv.created_at, lv.updated_at,
                   (SELECT COUNT(*) FROM lyric_lines WHERE lyrics_version_id = lv.id)
            FROM lyrics_versions AS lv
            WHERE lv.track_stable_key IN (\(placeholders(count: family.count)))
            ORDER BY lv.is_preferred DESC, lv.is_locked DESC, lv.confidence DESC, lv.updated_at DESC;
            """)
        defer { sqlite3_finalize(lyricsStmt) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: lyricsStmt) }

        var isFirstLyrics = true
        var lyricsVersionIDs: [UUID] = []

        while sqlite3_step(lyricsStmt) == SQLITE_ROW {
            guard let idText = columnText(lyricsStmt, index: 0),
                  let id = UUID(uuidString: idText) else { continue }
            lyricsVersionIDs.append(id)
            let parentID = columnText(lyricsStmt, index: 1).flatMap { UUID(uuidString: $0) }
            let source = columnText(lyricsStmt, index: 2) ?? ""
            let providerSourceID = columnText(lyricsStmt, index: 3) ?? ""
            let language = columnText(lyricsStmt, index: 4) ?? "und"
            let isSynced = sqlite3_column_int(lyricsStmt, 5) == 1
            let isMachine = sqlite3_column_int(lyricsStmt, 6) == 1
            let isManual = sqlite3_column_int(lyricsStmt, 7) == 1
            let isLocked = sqlite3_column_int(lyricsStmt, 8) == 1
            let confidence = sqlite3_column_double(lyricsStmt, 9)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(lyricsStmt, 10))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(lyricsStmt, 11))
            let lineCount = Int(sqlite3_column_int(lyricsStmt, 12))

            let isCurrent = isFirstLyrics
            isFirstLyrics = false

            lyricsItems.append(PersonalLyricsVersionItem(
                id: id,
                parentVersionID: parentID,
                source: source,
                providerSourceID: providerSourceID,
                language: language,
                isSynced: isSynced,
                lineCount: lineCount,
                isMachineGenerated: isMachine,
                isManuallyEdited: isManual,
                isLocked: isLocked,
                isCurrent: isCurrent,
                confidence: confidence,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }

        var translationItems: [PersonalTranslationVersionItem] = []
        if !lyricsVersionIDs.isEmpty {
            let idPlaceholders = lyricsVersionIDs.map { _ in "?" }.joined(separator: ",")
            let transStmt = try prepare("""
                SELECT tv.id, tv.lyrics_version_id, tv.parent_version_id, tv.source_kind,
                       tv.target_language, tv.is_machine_generated, tv.is_manually_edited,
                       tv.is_locked, tv.is_archived, tv.status, tv.confidence,
                       tv.engine_id, tv.created_at, tv.updated_at,
                       (SELECT COUNT(*) FROM translation_lines WHERE translation_version_id = tv.id)
                FROM translation_versions AS tv
                WHERE tv.lyrics_version_id IN (\(idPlaceholders))
                ORDER BY tv.is_locked DESC, tv.is_archived ASC, tv.updated_at DESC;
                """)
            defer { sqlite3_finalize(transStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: transStmt)
            }

            var isFirstTrans = true
            while sqlite3_step(transStmt) == SQLITE_ROW {
                guard let idText = columnText(transStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let lvidText = columnText(transStmt, index: 1),
                      let lvid = UUID(uuidString: lvidText) else { continue }
                let parentID = columnText(transStmt, index: 2).flatMap { UUID(uuidString: $0) }
                let sourceKind = columnText(transStmt, index: 3) ?? ""
                let targetLang = columnText(transStmt, index: 4) ?? ""
                let isMachine = sqlite3_column_int(transStmt, 5) == 1
                let isManual = sqlite3_column_int(transStmt, 6) == 1
                let isLocked = sqlite3_column_int(transStmt, 7) == 1
                let isArchived = sqlite3_column_int(transStmt, 8) == 1
                let status = columnText(transStmt, index: 9) ?? ""
                let confidence = sqlite3_column_double(transStmt, 10)
                let engineID = columnText(transStmt, index: 11) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(transStmt, 12))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(transStmt, 13))
                let lineCount = Int(sqlite3_column_int(transStmt, 14))

                let isCurrent = isFirstTrans && !isArchived
                if isCurrent { isFirstTrans = false }

                translationItems.append(PersonalTranslationVersionItem(
                    id: id,
                    lyricsVersionID: lvid,
                    parentVersionID: parentID,
                    sourceKind: sourceKind,
                    targetLanguage: targetLang,
                    lineCount: lineCount,
                    isMachineGenerated: isMachine,
                    isManuallyEdited: isManual,
                    isLocked: isLocked,
                    isArchived: isArchived,
                    isCurrent: isCurrent,
                    status: status,
                    confidence: confidence,
                    engineID: engineID,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ))
            }
        }

        var readingItems: [PersonalReadingVersionItem] = []
        if !lyricsVersionIDs.isEmpty {
            let idPlaceholders = lyricsVersionIDs.map { _ in "?" }.joined(separator: ",")
            let readStmt = try prepare("""
                SELECT rv.id, rv.lyrics_version_id, rv.parent_version_id, rv.representation_id,
                       rv.source_kind, rv.language, rv.is_machine_generated, rv.is_manually_edited,
                       rv.is_current, rv.is_locked, rv.is_archived, rv.engine_id,
                       rv.created_at, rv.updated_at,
                       (SELECT COUNT(*) FROM reading_lines WHERE reading_version_id = rv.id)
                FROM reading_versions AS rv
                WHERE rv.lyrics_version_id IN (\(idPlaceholders))
                ORDER BY rv.is_locked DESC, rv.is_current DESC, rv.updated_at DESC;
                """)
            defer { sqlite3_finalize(readStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: readStmt)
            }

            while sqlite3_step(readStmt) == SQLITE_ROW {
                guard let idText = columnText(readStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let lvidText = columnText(readStmt, index: 1),
                      let lvid = UUID(uuidString: lvidText),
                      let repID = columnText(readStmt, index: 3) else { continue }
                let parentID = columnText(readStmt, index: 2).flatMap { UUID(uuidString: $0) }
                let sourceKind = columnText(readStmt, index: 4) ?? ""
                let lang = columnText(readStmt, index: 5) ?? "und"
                let isMachine = sqlite3_column_int(readStmt, 6) == 1
                let isManual = sqlite3_column_int(readStmt, 7) == 1
                let isCurrent = sqlite3_column_int(readStmt, 8) == 1
                let isLocked = sqlite3_column_int(readStmt, 9) == 1
                let isArchived = sqlite3_column_int(readStmt, 10) == 1
                let engineID = columnText(readStmt, index: 11) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(readStmt, 12))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(readStmt, 13))
                let lineCount = Int(sqlite3_column_int(readStmt, 14))

                readingItems.append(PersonalReadingVersionItem(
                    id: id,
                    lyricsVersionID: lvid,
                    parentVersionID: parentID,
                    representationID: repID,
                    sourceKind: sourceKind,
                    language: lang,
                    lineCount: lineCount,
                    isMachineGenerated: isMachine,
                    isManuallyEdited: isManual,
                    isCurrent: isCurrent,
                    isLocked: isLocked,
                    isArchived: isArchived,
                    engineID: engineID,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ))
            }
        }

        var timingItems: [PersonalTimingVersionItem] = []
        if !lyricsVersionIDs.isEmpty {
            let idPlaceholders = lyricsVersionIDs.map { _ in "?" }.joined(separator: ",")
            let timeStmt = try prepare("""
                SELECT id, lyrics_version_id, source, granularity, created_at
                FROM lyrics_timing_versions
                WHERE lyrics_version_id IN (\(idPlaceholders))
                ORDER BY created_at DESC;
                """)
            defer { sqlite3_finalize(timeStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: timeStmt)
            }

            var isFirstTiming = true
            while sqlite3_step(timeStmt) == SQLITE_ROW {
                guard let idText = columnText(timeStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let lvidText = columnText(timeStmt, index: 1),
                      let lvid = UUID(uuidString: lvidText) else { continue }
                let source = columnText(timeStmt, index: 2) ?? ""
                let granularity = columnText(timeStmt, index: 3) ?? "timedUnit"
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(timeStmt, 4))

                let isCurrent = isFirstTiming
                isFirstTiming = false

                timingItems.append(PersonalTimingVersionItem(
                    id: id,
                    lyricsVersionID: lvid,
                    source: source,
                    granularity: granularity,
                    isCurrent: isCurrent,
                    createdAt: createdAt
                ))
            }
        }

        return PersonalLyricsLibraryTrackDetail(
            entry: entry,
            lyricsVersions: lyricsItems,
            translationVersions: translationItems,
            readingVersions: readingItems,
            timingVersions: timingItems
        )
    }

    // MARK: - Export Standard Package v1

    public func exportPersonalLibraryPackage(stableKey: String) throws -> PersonalLyricsLibraryPackage {
        try prepare()
        try reloadRedirectResolver()
        let stableKey = try resolvedCanonicalStableKey(stableKey)
        let family = try resolvedIdentityFamily(stableKey: stableKey)

        let trackStmt = try prepare("""
            SELECT stable_key, spotify_id, spotify_uri, isrc, title, artist_display,
                   album, duration, artwork_url
            FROM tracks WHERE stable_key = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(trackStmt) }
        try bindText(stableKey, at: 1, to: trackStmt)

        guard sqlite3_step(trackStmt) == SQLITE_ROW,
              let title = columnText(trackStmt, index: 4),
              let artist = columnText(trackStmt, index: 5) else {
            throw LyricsRepositoryError.invalidData("找不到要导出的歌曲")
        }

        let pkgTrack = PersonalLyricsLibraryPackage.PackageTrack(
            stableKey: stableKey,
            spotifyID: columnText(trackStmt, index: 1),
            spotifyURI: columnText(trackStmt, index: 2),
            isrc: columnText(trackStmt, index: 3),
            title: title,
            artist: artist,
            album: columnText(trackStmt, index: 6) ?? "",
            duration: sqlite3_column_double(trackStmt, 7),
            artworkURL: columnText(trackStmt, index: 8)
        )

        let lyricsStmt = try prepare("""
            SELECT id, parent_version_id, source, provider_source_id, language,
                   is_synced, raw_text, content_hash, is_machine_generated,
                   is_manually_edited, is_locked, confidence, created_at, updated_at, is_preferred
            FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count)))
            ORDER BY created_at ASC;
            """)
        defer { sqlite3_finalize(lyricsStmt) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: lyricsStmt) }

        var preferredLyricsVersionID: UUID?
        var pkgLyrics: [PersonalLyricsLibraryPackage.PackageLyricsVersion] = []
        var lyricsVersionIDs: [UUID] = []

        while sqlite3_step(lyricsStmt) == SQLITE_ROW {
            guard let idText = columnText(lyricsStmt, index: 0),
                  let id = UUID(uuidString: idText),
                  let source = columnText(lyricsStmt, index: 2),
                  let rawText = columnText(lyricsStmt, index: 6),
                  let contentHash = columnText(lyricsStmt, index: 7) else { continue }
            lyricsVersionIDs.append(id)
            if sqlite3_column_int(lyricsStmt, 14) == 1 { preferredLyricsVersionID = id }
            let parentID = columnText(lyricsStmt, index: 1).flatMap { UUID(uuidString: $0) }
            let providerSourceID = columnText(lyricsStmt, index: 3) ?? ""
            let language = columnText(lyricsStmt, index: 4) ?? "und"
            let isSynced = sqlite3_column_int(lyricsStmt, 5) == 1
            let isMachine = sqlite3_column_int(lyricsStmt, 8) == 1
            let isManual = sqlite3_column_int(lyricsStmt, 9) == 1
            let isLocked = sqlite3_column_int(lyricsStmt, 10) == 1
            let confidence = sqlite3_column_double(lyricsStmt, 11)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(lyricsStmt, 12))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(lyricsStmt, 13))

            let lineStmt = try prepare("""
                SELECT line_index, start_time, end_time, original_text,
                       kana_text, romaji_text, translation_text
                FROM lyric_lines WHERE lyrics_version_id = ?
                ORDER BY line_index ASC;
                """)
            try bindText(id.uuidString, at: 1, to: lineStmt)
            var lines: [PersonalLyricsLibraryPackage.PackageLyricLine] = []
            while sqlite3_step(lineStmt) == SQLITE_ROW {
                let idx = Int(sqlite3_column_int(lineStmt, 0))
                let st = sqlite3_column_type(lineStmt, 1) != SQLITE_NULL ? sqlite3_column_double(lineStmt, 1) : nil
                let et = sqlite3_column_type(lineStmt, 2) != SQLITE_NULL ? sqlite3_column_double(lineStmt, 2) : nil
                let orig = columnText(lineStmt, index: 3) ?? ""
                let kana = columnText(lineStmt, index: 4)
                let romaji = columnText(lineStmt, index: 5)
                let trans = columnText(lineStmt, index: 6)
                lines.append(PersonalLyricsLibraryPackage.PackageLyricLine(
                    lineIndex: idx,
                    startTime: st,
                    endTime: et,
                    originalText: orig,
                    kanaText: kana,
                    romajiText: romaji,
                    translationText: trans
                ))
            }
            sqlite3_finalize(lineStmt)

            pkgLyrics.append(PersonalLyricsLibraryPackage.PackageLyricsVersion(
                id: id,
                trackStableKey: stableKey,
                parentVersionID: parentID,
                source: source,
                providerSourceID: providerSourceID,
                language: language,
                isSynced: isSynced,
                rawText: rawText,
                contentHash: contentHash,
                isMachineGenerated: isMachine,
                isManuallyEdited: isManual,
                isLocked: isLocked,
                confidence: confidence,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lines: lines
            ))
        }

        var pkgTranslations: [PersonalLyricsLibraryPackage.PackageTranslationVersion] = []
        for lvid in lyricsVersionIDs {
            let transStmt = try prepare("""
                SELECT id, parent_version_id, source_kind, target_language,
                       model, source_content_hash, is_machine_generated,
                       is_manually_edited, is_locked, is_archived, status,
                       confidence, engine_id, prompt_preset_id, created_at, updated_at
                FROM translation_versions WHERE lyrics_version_id = ?
                ORDER BY created_at ASC;
                """)
            try bindText(lvid.uuidString, at: 1, to: transStmt)
            while sqlite3_step(transStmt) == SQLITE_ROW {
                guard let idText = columnText(transStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let sourceKind = columnText(transStmt, index: 2),
                      let targetLang = columnText(transStmt, index: 3),
                      let hash = columnText(transStmt, index: 5) else { continue }
                let parentID = columnText(transStmt, index: 1).flatMap { UUID(uuidString: $0) }
                let model = columnText(transStmt, index: 4) ?? ""
                let isMachine = sqlite3_column_int(transStmt, 6) == 1
                let isManual = sqlite3_column_int(transStmt, 7) == 1
                let isLocked = sqlite3_column_int(transStmt, 8) == 1
                let isArchived = sqlite3_column_int(transStmt, 9) == 1
                let status = columnText(transStmt, index: 10) ?? ""
                let confidence = sqlite3_column_double(transStmt, 11)
                let engineID = columnText(transStmt, index: 12) ?? ""
                let promptPresetID = columnText(transStmt, index: 13) ?? ""
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(transStmt, 14))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(transStmt, 15))

                let tlStmt = try prepare("SELECT line_index, translated_text FROM translation_lines WHERE translation_version_id = ? ORDER BY line_index ASC;")
                try bindText(id.uuidString, at: 1, to: tlStmt)
                var tlines: [PersonalLyricsLibraryPackage.PackageTranslationLine] = []
                while sqlite3_step(tlStmt) == SQLITE_ROW {
                    let lidx = Int(sqlite3_column_int(tlStmt, 0))
                    let txt = columnText(tlStmt, index: 1) ?? ""
                    tlines.append(PersonalLyricsLibraryPackage.PackageTranslationLine(lineIndex: lidx, translatedText: txt))
                }
                sqlite3_finalize(tlStmt)

                pkgTranslations.append(PersonalLyricsLibraryPackage.PackageTranslationVersion(
                    id: id,
                    lyricsVersionID: lvid,
                    parentVersionID: parentID,
                    sourceKind: sourceKind,
                    targetLanguage: targetLang,
                    model: model,
                    sourceContentHash: hash,
                    isMachineGenerated: isMachine,
                    isManuallyEdited: isManual,
                    isLocked: isLocked,
                    isArchived: isArchived,
                    status: status,
                    confidence: confidence,
                    engineID: engineID,
                    promptPresetID: promptPresetID,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lines: tlines
                ))
            }
            sqlite3_finalize(transStmt)
        }

        var pkgReadings: [PersonalLyricsLibraryPackage.PackageReadingVersion] = []
        for lvid in lyricsVersionIDs {
            let readStmt = try prepare("""
                SELECT id, parent_version_id, source_content_hash, engine_id,
                       representation_id, source_kind, language, is_machine_generated,
                       is_manually_edited, is_current, is_locked, is_archived,
                       confidence, created_at, updated_at
                FROM reading_versions WHERE lyrics_version_id = ?
                ORDER BY created_at ASC;
                """)
            try bindText(lvid.uuidString, at: 1, to: readStmt)
            while sqlite3_step(readStmt) == SQLITE_ROW {
                guard let idText = columnText(readStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let hash = columnText(readStmt, index: 2),
                      let engineID = columnText(readStmt, index: 3),
                      let repID = columnText(readStmt, index: 4) else { continue }
                let parentID = columnText(readStmt, index: 1).flatMap { UUID(uuidString: $0) }
                let sourceKind = columnText(readStmt, index: 5) ?? "generated"
                let lang = columnText(readStmt, index: 6) ?? "und"
                let isMachine = sqlite3_column_int(readStmt, 7) == 1
                let isManual = sqlite3_column_int(readStmt, 8) == 1
                let isCurrent = sqlite3_column_int(readStmt, 9) == 1
                let isLocked = sqlite3_column_int(readStmt, 10) == 1
                let isArchived = sqlite3_column_int(readStmt, 11) == 1
                let confidence = sqlite3_column_double(readStmt, 12)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(readStmt, 13))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(readStmt, 14))

                let rlStmt = try prepare("SELECT line_index, original_text, reading_text, tokens_json, language, source FROM reading_lines WHERE reading_version_id = ? ORDER BY line_index ASC;")
                try bindText(id.uuidString, at: 1, to: rlStmt)
                var rlines: [PersonalLyricsLibraryPackage.PackageReadingLine] = []
                while sqlite3_step(rlStmt) == SQLITE_ROW {
                    let lidx = Int(sqlite3_column_int(rlStmt, 0))
                    let orig = columnText(rlStmt, index: 1) ?? ""
                    let rtxt = columnText(rlStmt, index: 2)
                    let tok = columnText(rlStmt, index: 3) ?? "[]"
                    let rlang = columnText(rlStmt, index: 4) ?? "und"
                    let rsrc = columnText(rlStmt, index: 5) ?? "unknown"
                    rlines.append(PersonalLyricsLibraryPackage.PackageReadingLine(
                        lineIndex: lidx,
                        originalText: orig,
                        readingText: rtxt,
                        tokensJSON: tok,
                        language: rlang,
                        source: rsrc
                    ))
                }
                sqlite3_finalize(rlStmt)

                pkgReadings.append(PersonalLyricsLibraryPackage.PackageReadingVersion(
                    id: id,
                    lyricsVersionID: lvid,
                    parentVersionID: parentID,
                    sourceContentHash: hash,
                    engineID: engineID,
                    representationID: repID,
                    sourceKind: sourceKind,
                    language: lang,
                    isMachineGenerated: isMachine,
                    isManuallyEdited: isManual,
                    isCurrent: isCurrent,
                    isLocked: isLocked,
                    isArchived: isArchived,
                    confidence: confidence,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lines: rlines
                ))
            }
            sqlite3_finalize(readStmt)
        }

        var pkgTimings: [PersonalLyricsLibraryPackage.PackageTimingVersion] = []
        for lvid in lyricsVersionIDs {
            let timeStmt = try prepare("""
                SELECT id, source, granularity, source_content_hash, spans_payload, created_at
                FROM lyrics_timing_versions WHERE lyrics_version_id = ?
                ORDER BY created_at ASC;
                """)
            try bindText(lvid.uuidString, at: 1, to: timeStmt)
            while sqlite3_step(timeStmt) == SQLITE_ROW {
                guard let idText = columnText(timeStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let source = columnText(timeStmt, index: 1),
                      let gran = columnText(timeStmt, index: 2),
                      let hash = columnText(timeStmt, index: 3),
                      let payload = columnText(timeStmt, index: 4) else { continue }
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(timeStmt, 5))
                pkgTimings.append(PersonalLyricsLibraryPackage.PackageTimingVersion(
                    id: id,
                    lyricsVersionID: lvid,
                    source: source,
                    granularity: gran,
                    sourceContentHash: hash,
                    spansPayload: payload,
                    createdAt: createdAt
                ))
            }
            sqlite3_finalize(timeStmt)
        }

        return PersonalLyricsLibraryPackage(
            track: pkgTrack,
            lyricsVersions: pkgLyrics,
            translationVersions: pkgTranslations,
            readingVersions: pkgReadings,
            timingVersions: pkgTimings, preferredLyricsVersionID: preferredLyricsVersionID
        )
    }

    // MARK: - Export Standard Personal Data Package v1

    public func exportPersonalDataPackage() throws -> PersonalDataPackage {
        try prepare()
        let entries = try loadPersonalLibraryEntries(searchQuery: nil)
        let packages = try entries
            .map { try exportPersonalLibraryPackage(stableKey: $0.trackStableKey) }
            .sorted { $0.track.stableKey < $1.track.stableKey }

        return PersonalDataPackage(tracks: packages)
    }

    // MARK: - Preview Import Package

    public func previewImportPersonalLibraryPackage(_ package: PersonalLyricsLibraryPackage) throws -> PersonalLibraryImportPreview {
        try prepare()

        var lyricsToAdd = 0
        var lyricsToSkip = 0
        var lyricsConflicts: [String] = []

        var translationsToAdd = 0
        var translationsToSkip = 0
        var translationsConflicts: [String] = []

        var readingsToAdd = 0
        var readingsToSkip = 0
        var readingsConflicts: [String] = []

        var timingsToAdd = 0
        var timingsToSkip = 0
        var timingsConflicts: [String] = []

        for lv in package.lyricsVersions {
            let checkStmt = try prepare("SELECT content_hash FROM lyrics_versions WHERE id = ? LIMIT 1;")
            try bindText(lv.id.uuidString, at: 1, to: checkStmt)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingHash = columnText(checkStmt, index: 0) ?? ""
                if existingHash == lv.contentHash {
                    lyricsToSkip += 1
                } else {
                    lyricsConflicts.append("Lyrics version \(lv.id) exists with differing content hash")
                }
            } else {
                lyricsToAdd += 1
            }
            sqlite3_finalize(checkStmt)
        }

        for tv in package.translationVersions {
            let checkStmt = try prepare("SELECT source_content_hash FROM translation_versions WHERE id = ? LIMIT 1;")
            try bindText(tv.id.uuidString, at: 1, to: checkStmt)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingHash = columnText(checkStmt, index: 0) ?? ""
                if existingHash == tv.sourceContentHash {
                    translationsToSkip += 1
                } else {
                    translationsConflicts.append("Translation version \(tv.id) exists with differing content hash")
                }
            } else {
                translationsToAdd += 1
            }
            sqlite3_finalize(checkStmt)
        }

        for rv in package.readingVersions {
            let checkStmt = try prepare("SELECT source_content_hash, representation_id FROM reading_versions WHERE id = ? LIMIT 1;")
            try bindText(rv.id.uuidString, at: 1, to: checkStmt)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingHash = columnText(checkStmt, index: 0) ?? ""
                if existingHash == rv.sourceContentHash {
                    readingsToSkip += 1
                } else {
                    readingsConflicts.append("Reading version \(rv.id) (\(rv.representationID)) exists with differing content hash")
                }
            } else {
                readingsToAdd += 1
            }
            sqlite3_finalize(checkStmt)
        }

        for tv in package.timingVersions {
            let checkStmt = try prepare("SELECT spans_payload FROM lyrics_timing_versions WHERE id = ? LIMIT 1;")
            try bindText(tv.id.uuidString, at: 1, to: checkStmt)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingPayload = columnText(checkStmt, index: 0) ?? ""
                if existingPayload == tv.spansPayload {
                    timingsToSkip += 1
                } else {
                    timingsConflicts.append("Timing version \(tv.id) exists with differing payload")
                }
            } else {
                timingsToAdd += 1
            }
            sqlite3_finalize(checkStmt)
        }

        return PersonalLibraryImportPreview(
            trackTitle: package.track.title,
            trackArtist: package.track.artist,
            trackStableKey: package.track.stableKey,
            lyricsToAdd: lyricsToAdd,
            lyricsToSkip: lyricsToSkip,
            lyricsConflicts: lyricsConflicts,
            translationsToAdd: translationsToAdd,
            translationsToSkip: translationsToSkip,
            translationsConflicts: translationsConflicts,
            readingsToAdd: readingsToAdd,
            readingsToSkip: readingsToSkip,
            readingsConflicts: readingsConflicts,
            timingsToAdd: timingsToAdd,
            timingsToSkip: timingsToSkip,
            timingsConflicts: timingsConflicts
        )
    }

    // MARK: - Preview / Apply Standard Personal Data Package

    public func previewImportPersonalDataPackage(_ package: PersonalDataPackage) throws -> PersonalDataImportPreview {
        try package.validate()
        let previews = try package.tracks.map { try previewImportPersonalLibraryPackage($0) }
        return PersonalDataImportPreview(trackPreviews: previews)
    }

    public func importPersonalDataPackage(_ package: PersonalDataPackage) throws {
        try package.validate()
        let preview = try previewImportPersonalDataPackage(package)
        guard !preview.hasConflicts else {
            let conflicts = preview.trackPreviews.flatMap { $0.allConflicts }
            throw LyricsRepositoryError.dataIntegrityViolation(
                "存在冲突版本，无法导入个人数据包：" + conflicts.joined(separator: "; ")
            )
        }
        guard !package.tracks.isEmpty else { return }

        for trackPackage in package.tracks {
            try importPersonalLibraryPackage(trackPackage)
        }
    }

    // MARK: - Execute Import Package

    public func importPersonalLibraryPackage(_ package: PersonalLyricsLibraryPackage) throws {
        try prepare()
        if let preferred = package.preferredLyricsVersionID,
           !package.lyricsVersions.contains(where: { $0.id == preferred }) {
            throw LyricsRepositoryError.invalidData("资产包采用版本不存在")
        }
        let preferenceFamily = try resolvedIdentityFamily(stableKey: package.track.stableKey)
        let preferenceQuery = try prepare("SELECT COUNT(*) FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: preferenceFamily.count))) AND is_preferred = 1;")
        defer { sqlite3_finalize(preferenceQuery) }
        for (index, key) in preferenceFamily.enumerated() { try bindText(key, at: Int32(index + 1), to: preferenceQuery) }
        guard sqlite3_step(preferenceQuery) == SQLITE_ROW else { throw lastError() }
        let hasLocalPreference = sqlite3_column_int(preferenceQuery, 0) > 0
        guard sqlite3_step(preferenceQuery) == SQLITE_DONE else { throw lastError() }

        let preview = try previewImportPersonalLibraryPackage(package)
        guard !preview.hasConflicts else {
            throw LyricsRepositoryError.dataIntegrityViolation("存在冲突版本，无法直接覆盖已有资产：\(preview.lyricsConflicts + preview.translationsConflicts + preview.readingsConflicts + preview.timingsConflicts)")
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let targetStableKey = try redirectResolver?.resolve(package.track.stableKey) ?? package.track.stableKey
            let trackInsert = try prepare("""
                INSERT INTO tracks(
                    stable_key, spotify_id, spotify_uri, isrc, title, artist_display,
                    album, duration, artwork_url, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(stable_key) DO UPDATE SET
                    title = excluded.title,
                    artist_display = excluded.artist_display,
                    album = excluded.album,
                    artwork_url = COALESCE(excluded.artwork_url, tracks.artwork_url),
                    updated_at = excluded.updated_at;
                """)
            defer { sqlite3_finalize(trackInsert) }

            try bindText(targetStableKey, at: 1, to: trackInsert)
            try bindText(package.track.spotifyID, at: 2, to: trackInsert)
            try bindText(package.track.spotifyURI, at: 3, to: trackInsert)
            try bindText(package.track.isrc, at: 4, to: trackInsert)
            try bindText(package.track.title, at: 5, to: trackInsert)
            try bindText(package.track.artist, at: 6, to: trackInsert)
            try bindText(package.track.album, at: 7, to: trackInsert)
            try bindDouble(package.track.duration, at: 8, to: trackInsert)
            try bindText(package.track.artworkURL, at: 9, to: trackInsert)
            try bindDouble(Date().timeIntervalSince1970, at: 10, to: trackInsert)
            try bindDouble(Date().timeIntervalSince1970, at: 11, to: trackInsert)
            try stepDone(trackInsert)

            for lv in package.lyricsVersions {
                let lvInsert = try prepare("""
                    INSERT OR IGNORE INTO lyrics_versions(
                        id, track_stable_key, parent_version_id, source, provider_source_id,
                        language, is_synced, raw_text, content_hash, is_machine_generated,
                        is_manually_edited, is_locked, confidence, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """)
                try bindText(lv.id.uuidString, at: 1, to: lvInsert)
                try bindText(targetStableKey, at: 2, to: lvInsert)
                try bindText(lv.parentVersionID?.uuidString, at: 3, to: lvInsert)
                try bindText(lv.source, at: 4, to: lvInsert)
                try bindText(lv.providerSourceID, at: 5, to: lvInsert)
                try bindText(lv.language, at: 6, to: lvInsert)
                try bindInt(lv.isSynced ? 1 : 0, at: 7, to: lvInsert)
                try bindText(lv.rawText, at: 8, to: lvInsert)
                try bindText(lv.contentHash, at: 9, to: lvInsert)
                try bindInt(lv.isMachineGenerated ? 1 : 0, at: 10, to: lvInsert)
                try bindInt(lv.isManuallyEdited ? 1 : 0, at: 11, to: lvInsert)
                try bindInt(lv.isLocked ? 1 : 0, at: 12, to: lvInsert)
                try bindDouble(lv.confidence, at: 13, to: lvInsert)
                try bindDouble(lv.createdAt.timeIntervalSince1970, at: 14, to: lvInsert)
                try bindDouble(lv.updatedAt.timeIntervalSince1970, at: 15, to: lvInsert)
                try stepDone(lvInsert)
                sqlite3_finalize(lvInsert)

                for line in lv.lines {
                    let lineInsert = try prepare("""
                        INSERT OR IGNORE INTO lyric_lines(
                            lyrics_version_id, line_index, start_time, end_time,
                            original_text, kana_text, romaji_text, translation_text
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                        """)
                    try bindText(lv.id.uuidString, at: 1, to: lineInsert)
                    try bindInt(line.lineIndex, at: 2, to: lineInsert)
                    if let st = line.startTime { try bindDouble(st, at: 3, to: lineInsert) } else { sqlite3_bind_null(lineInsert, 3) }
                    if let et = line.endTime { try bindDouble(et, at: 4, to: lineInsert) } else { sqlite3_bind_null(lineInsert, 4) }
                    try bindText(line.originalText, at: 5, to: lineInsert)
                    try bindText(line.kanaText, at: 6, to: lineInsert)
                    try bindText(line.romajiText, at: 7, to: lineInsert)
                    try bindText(line.translationText, at: 8, to: lineInsert)
                    try stepDone(lineInsert)
                    sqlite3_finalize(lineInsert)
                }
            }

            for tv in package.translationVersions {
                let tvInsert = try prepare("""
                    INSERT OR IGNORE INTO translation_versions(
                        id, lyrics_version_id, parent_version_id, source_kind, target_language,
                        model, base_url_host, prompt_hash, source_content_hash,
                        is_machine_generated, is_manually_edited, is_locked, is_archived,
                        status, confidence, engine_id, prompt_preset_id, profile_id,
                        profile_snapshot, temperature, workflow_id, fallback_strategy,
                        is_draft, created_at, updated_at
                    ) VALUES (
                        ?, ?, ?, ?, ?,
                        ?, '', '', ?,
                        ?, ?, ?, ?,
                        ?, ?, ?, ?, NULL,
                        '', 0.2, 'translationWorkflow.classicV1', 'none',
                        0, ?, ?
                    );
                    """)
                try bindText(tv.id.uuidString, at: 1, to: tvInsert)
                try bindText(tv.lyricsVersionID.uuidString, at: 2, to: tvInsert)
                try bindText(tv.parentVersionID?.uuidString, at: 3, to: tvInsert)
                try bindText(tv.sourceKind, at: 4, to: tvInsert)
                try bindText(tv.targetLanguage, at: 5, to: tvInsert)
                try bindText(tv.model, at: 6, to: tvInsert)
                try bindText(tv.sourceContentHash, at: 7, to: tvInsert)
                try bindInt(tv.isMachineGenerated ? 1 : 0, at: 8, to: tvInsert)
                try bindInt(tv.isManuallyEdited ? 1 : 0, at: 9, to: tvInsert)
                try bindInt(tv.isLocked ? 1 : 0, at: 10, to: tvInsert)
                try bindInt(tv.isArchived ? 1 : 0, at: 11, to: tvInsert)
                try bindText(tv.status, at: 12, to: tvInsert)
                try bindDouble(tv.confidence, at: 13, to: tvInsert)
                try bindText(tv.engineID, at: 14, to: tvInsert)
                try bindText(tv.promptPresetID, at: 15, to: tvInsert)
                try bindDouble(tv.createdAt.timeIntervalSince1970, at: 16, to: tvInsert)
                try bindDouble(tv.updatedAt.timeIntervalSince1970, at: 17, to: tvInsert)
                try stepDone(tvInsert)
                sqlite3_finalize(tvInsert)

                for line in tv.lines {
                    let tlInsert = try prepare("INSERT OR IGNORE INTO translation_lines(translation_version_id, line_index, translated_text) VALUES (?, ?, ?);")
                    try bindText(tv.id.uuidString, at: 1, to: tlInsert)
                    try bindInt(line.lineIndex, at: 2, to: tlInsert)
                    try bindText(line.translatedText, at: 3, to: tlInsert)
                    try stepDone(tlInsert)
                    sqlite3_finalize(tlInsert)
                }
            }

            for rv in package.readingVersions {
                let rvInsert = try prepare("""
                    INSERT OR IGNORE INTO reading_versions(
                        id, lyrics_version_id, parent_version_id, source_content_hash,
                        engine_id, representation_id, source_kind, language,
                        is_machine_generated, is_manually_edited, is_current,
                        is_locked, is_archived, confidence, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """)
                try bindText(rv.id.uuidString, at: 1, to: rvInsert)
                try bindText(rv.lyricsVersionID.uuidString, at: 2, to: rvInsert)
                try bindText(rv.parentVersionID?.uuidString, at: 3, to: rvInsert)
                try bindText(rv.sourceContentHash, at: 4, to: rvInsert)
                try bindText(rv.engineID, at: 5, to: rvInsert)
                try bindText(rv.representationID, at: 6, to: rvInsert)
                try bindText(rv.sourceKind, at: 7, to: rvInsert)
                try bindText(rv.language, at: 8, to: rvInsert)
                try bindInt(rv.isMachineGenerated ? 1 : 0, at: 9, to: rvInsert)
                try bindInt(rv.isManuallyEdited ? 1 : 0, at: 10, to: rvInsert)
                try bindInt(rv.isCurrent ? 1 : 0, at: 11, to: rvInsert)
                try bindInt(rv.isLocked ? 1 : 0, at: 12, to: rvInsert)
                try bindInt(rv.isArchived ? 1 : 0, at: 13, to: rvInsert)
                try bindDouble(rv.confidence, at: 14, to: rvInsert)
                try bindDouble(rv.createdAt.timeIntervalSince1970, at: 15, to: rvInsert)
                try bindDouble(rv.updatedAt.timeIntervalSince1970, at: 16, to: rvInsert)
                try stepDone(rvInsert)
                sqlite3_finalize(rvInsert)

                for line in rv.lines {
                    let rlInsert = try prepare("""
                        INSERT OR IGNORE INTO reading_lines(
                            reading_version_id, line_index, original_text, reading_text,
                            tokens_json, language, source
                        ) VALUES (?, ?, ?, ?, ?, ?, ?);
                        """)
                    try bindText(rv.id.uuidString, at: 1, to: rlInsert)
                    try bindInt(line.lineIndex, at: 2, to: rlInsert)
                    try bindText(line.originalText, at: 3, to: rlInsert)
                    try bindText(line.readingText, at: 4, to: rlInsert)
                    try bindText(line.tokensJSON, at: 5, to: rlInsert)
                    try bindText(line.language, at: 6, to: rlInsert)
                    try bindText(line.source, at: 7, to: rlInsert)
                    try stepDone(rlInsert)
                    sqlite3_finalize(rlInsert)
                }
            }

            for tv in package.timingVersions {
                let timeInsert = try prepare("""
                    INSERT OR IGNORE INTO lyrics_timing_versions(
                        id, lyrics_version_id, source, granularity,
                        source_content_hash, spans_payload, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?);
                    """)
                try bindText(tv.id.uuidString, at: 1, to: timeInsert)
                try bindText(tv.lyricsVersionID.uuidString, at: 2, to: timeInsert)
                try bindText(tv.source, at: 3, to: timeInsert)
                try bindText(tv.granularity, at: 4, to: timeInsert)
                try bindText(tv.sourceContentHash, at: 5, to: timeInsert)
                try bindText(tv.spansPayload, at: 6, to: timeInsert)
                try bindDouble(tv.createdAt.timeIntervalSince1970, at: 7, to: timeInsert)
                try stepDone(timeInsert)
                sqlite3_finalize(timeInsert)
            }

            if !hasLocalPreference, let preferred = package.preferredLyricsVersionID {
                try setPreferredLyricsVersion(trackStableKey: package.track.stableKey, lyricsVersionID: preferred)
            }
            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Active / Locked Mutations

    public func adoptLyricsVersion(trackStableKey: String, lyricsVersionID: UUID) throws {
        try setPersonalLibraryActiveLyrics(
            trackStableKey: trackStableKey,
            lyricsVersionID: lyricsVersionID
        )
    }

    public func setPersonalLibraryActiveLyrics(trackStableKey: String, lyricsVersionID: UUID) throws {
        try prepare()
        try withTransaction {
            try setPreferredLyricsVersion(trackStableKey: trackStableKey, lyricsVersionID: lyricsVersionID, clearRevocation: true)
        }
    }

    private func setPreferredLyricsVersion(trackStableKey: String, lyricsVersionID: UUID, clearRevocation: Bool = false) throws {
        if !clearRevocation, try hasRevokedLyricsSelection(stableKey: trackStableKey) { return }
        let family = try resolvedIdentityFamily(stableKey: trackStableKey)
        guard let version = try fetchLyricsVersion(versionID: lyricsVersionID), family.contains(version.trackStableKey) else {
            throw LyricsEditingRepositoryError.identityMismatch
        }
        let clear = try prepare("UPDATE lyrics_versions SET is_preferred = 0 WHERE track_stable_key IN (\(placeholders(count: family.count)));")
        defer { sqlite3_finalize(clear) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: clear) }
        try stepDone(clear)
        if clearRevocation {
            let reset = try prepare("DELETE FROM lyrics_selection_revocations WHERE track_stable_key IN (\(placeholders(count: family.count)));")
            defer { sqlite3_finalize(reset) }
            for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: reset) }
            try stepDone(reset)
        }
        let choose = try prepare("UPDATE lyrics_versions SET is_preferred = 1 WHERE id = ?;")
        defer { sqlite3_finalize(choose) }
        try bindText(lyricsVersionID.uuidString, at: 1, to: choose)
        try stepDone(choose)
    }

    public func toggleLyricsLocked(versionID: UUID, locked: Bool) throws {
        try prepare()
        let now = Date().timeIntervalSince1970
        let stmt = try prepare("UPDATE lyrics_versions SET is_locked = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindInt(locked ? 1 : 0, at: 1, to: stmt)
        try bindDouble(now, at: 2, to: stmt)
        try bindText(versionID.uuidString, at: 3, to: stmt)
        try stepDone(stmt)
    }
}
