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
    private var adoptedMusicPlaybackKeys: [String: String] = [:]
    private var manualAdoptionRequestIDs: [String: UUID] = [:]
    private struct SearchVersionText {
        let original: String
        let reading: String
        let normalized: Data
    }
    private struct SearchSong {
        let signature: [String: String]
        let versions: [String: SearchVersionText]
        let entry: PersonalLyricsLibraryEntry
    }
    private var librarySearchCache: [String: SearchSong] = [:]
    private var librarySearchDataVersion: Int32 = -1
    private var librarySearchTotalChanges: Int32 = -1
#if DEBUG
    private var librarySearchNormalizationCounts: [String: Int] = [:]
    func searchNormalizationCounts() -> [String: Int] { librarySearchNormalizationCounts }
#endif

    private let alignmentProvenanceStore: AlignmentProvenanceStore

#if DEBUG
    // Contract-only synchronous checkpoints; no environment-driven production hook.
    private var translationCompletionCheckpoint: (@Sendable (String) -> Void)?
    public func setTranslationCompletionCheckpoint(_ checkpoint: (@Sendable (String) -> Void)?) {
        translationCompletionCheckpoint = checkpoint
    }
#endif

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
#if DEBUG
        DebugAcceptanceDataIsolation.requireStorage(databaseURL)
        DebugAcceptanceDataIsolation.requireStorage(alignmentProvenanceDirectory)
#endif
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
            try DatabaseMigrator.migrate(handle) { version in
                // A fresh file may already have been opened by another window.
                if version == 0 {
                    let hasTables = try scalarInt("""
                        SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*');
                        """) == 1
                    guard hasTables else { return }
                }
                try writePreUpgradeSnapshot()
            }
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
        try bestStored(track: track, identity: identity)
    }

    private func bestStored(track: Track, identity: TrackIdentity) throws -> StoredLyricsDocument? {
        try ensurePrepared()
        // Older nonstandard Music identifiers still use the historical metadata keys.
        if TrackIdentity.appleMusicPersistentID(track.spotifyId) == nil, let key = try adoptedAppleMusicStableKey(for: track) {
            adoptedMusicPlaybackKeys.removeValue(forKey: key)
            if identity.stableKey != key { adoptedMusicPlaybackKeys[identity.stableKey] = key }
        }
        // An adopted recording is authoritative even when the player refreshes its display metadata.
        var canonicalKey = try resolvedCanonicalStableKey(identity.stableKey)
        if try fetchTrack(stableKey: canonicalKey) == nil || fetchBestVersion(stableKey: canonicalKey) == nil,
           let sameSong = try adoptedSameSpotifyTrackStableKey(stableKey: identity.stableKey, title: track.title) {
            canonicalKey = sameSong
        }
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
        document = try applyingBestTiming(to: document, lyricsID: version.id, hash: sourceContentHash)

        let preferenceQuery = try prepare("SELECT is_preferred FROM lyrics_versions WHERE id = ?;")
        defer { sqlite3_finalize(preferenceQuery) }
        try bindText(version.id.uuidString, at: 1, to: preferenceQuery)
        guard sqlite3_step(preferenceQuery) == SQLITE_ROW else { throw lastError() }
        let isPreferred = sqlite3_column_int(preferenceQuery, 0) != 0
        let lockedOrEdited = version.isLocked || version.isManuallyEdited
        return StoredLyricsDocument(
            document: document,
            versionID: version.id,
            sourceContentHash: sourceContentHash,
            alignmentProvenanceAvailability: version.source == DatabaseSourceIdentifier.identifier(for: .automaticAlignment)
                ? alignmentProvenanceStore.availability(for: version.id)
                : .unavailable,
            isUserProtected: isPreferred || lockedOrEdited
                || ["local", "manual", "manualEdit", "manualImport", "manualCreate"].contains(version.source),
            isLockedOrEdited: lockedOrEdited
        )
    }

    public func attachWordTiming(from candidate: LyricsDocument, to versionID: UUID, track: Track) async throws -> LyricsDocument? {
        try ensurePrepared()
        return try withTransaction {
            guard !Task.isCancelled, try !hasRevokedLyricsSelection(stableKey: candidate.identity.stableKey),
                  let held = try bestStored(track: track, identity: candidate.identity),
                  held.versionID == versionID, !held.isLockedOrEdited, let hash = held.sourceContentHash,
                  let timed = LyricsWordTimingUpgrade.addingTiming(from: candidate, to: held.document),
                  let timingID = try attachTimingVersionIfNeeded(document: timed, lyricsVersionID: versionID,
                      source: DatabaseSourceIdentifier.identifier(for: candidate.source), sourceContentHash: hash, now: Date())
            else { return nil }
            return timed.replacingLines(timed.lines, timingVersionID: timingID)
        }
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

    private func archiveTrack(stableKey: String) throws -> DatabaseTrackRecord? {
        if let existing = try fetchTrack(stableKey: resolvedCanonicalStableKey(stableKey)) { return existing }

        // Older history rows can predate any artwork or lyrics stored for the recording.
        let statement = try prepare("""
            SELECT title, artist, album, track_duration, started_at, last_observed_at
            FROM listening_history_sessions WHERE track_stable_key = ?
            ORDER BY last_observed_at DESC, started_at DESC, session_id DESC LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(stableKey, at: 1, to: statement)
        guard try stepListeningHistoryRow(statement),
              let title = columnText(statement, index: 0),
              let artist = columnText(statement, index: 1),
              let album = columnText(statement, index: 2) else { return nil }
        return DatabaseTrackRecord(
            stableKey: stableKey, spotifyID: nil, spotifyURI: nil, isrc: nil,
            title: title, artistDisplay: artist, album: album, duration: sqlite3_column_double(statement, 3), artworkURL: nil,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        )
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
        try saveValidated(track: track, identity: identity, document: document, intent: .provider)
    }

    public func saveAutomaticallySelected(track: Track, identity: TrackIdentity, document: LyricsDocument, decision: LyricsAutomaticSelectionEvidence) async throws -> LyricsPersistenceSaveResult {
        guard (decision.tier == "autoHigh" || decision.tier == "autoMedium"), !decision.hardReject, !decision.versionConflict, decision.identity == identity,
              TrackIdentity(track: track) == identity, document.confidence.isFinite, (0...1).contains(document.confidence) else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("自动选择缺少有效匹配证据"))
        }
        return try saveValidated(track: track, identity: identity, document: document, intent: .automaticSelection)
    }

    /// The user filed a particular lyric file with this recording. Keep its selected version and any revocation.
    func storeImportedFile(track: Track, document: LyricsDocument, locked: Bool,
                           archiveKey: String? = nil, manuscriptID: UUID? = nil, manuscriptParentID: UUID? = nil) throws -> LyricsPersistenceSaveResult {
        try prepare()
        guard document.source == (manuscriptID == nil ? .manualImport : .manualCreate) else { throw LyricsEditingRepositoryError.identityMismatch }
        if let archiveKey {
            guard let record = try archiveTrack(stableKey: archiveKey),
                  TrackIdentity(track: record.libraryTrack) == TrackIdentity(track: track) else {
                throw LyricsEditingRepositoryError.identityMismatch
            }
        }
        return try saveValidated(track: track, identity: TrackIdentity(track: track), document: document,
                                 intent: .file(locked: locked), archiveKey: archiveKey, manuscriptID: manuscriptID, manuscriptParentID: manuscriptParentID)
    }

    private enum SaveIntent: Equatable { case provider, automaticSelection, file(locked: Bool) }

    private func saveValidated(track: Track, identity: TrackIdentity, document: LyricsDocument, intent: SaveIntent,
                               archiveKey: String? = nil, manuscriptID: UUID? = nil, manuscriptParentID: UUID? = nil) throws -> LyricsPersistenceSaveResult {
        try ensurePrepared()
        let importedLock: Bool?
        if case let .file(locked) = intent { importedLock = locked } else { importedLock = nil }

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
        guard intent == .automaticSelection || LyricsMatcher.isHighConfidence(document.confidence) else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("低置信度歌词不写入")
            )
        }

        let canonicalKey = try resolvedCanonicalStableKey(archiveKey ?? identity.stableKey)
        guard !Task.isCancelled else {
            return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("歌词保存已取消"))
        }
        let now = Date()
        let rawTrackRecord = LyricsPersistenceMapper.trackRecord(track: track, identity: identity, now: now)
        let trackRecord = canonicalTrackRecord(rawTrackRecord, stableKey: canonicalKey)
        let versionID = UUID()
        let rawVersionRecord = LyricsPersistenceMapper.versionRecord(
            document: document,
            identity: identity,
            versionID: versionID,
            now: now, isManuallyEdited: importedLock != nil, isLocked: importedLock == true
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
            if importedLock == nil, try hasRevokedLyricsSelection(stableKey: canonicalKey) {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("已取消采用，不自动恢复歌词"))
            }
            try upsertTrack(trackRecord)
            for alias in aliases {
                try insertAlias(alias)
            }

            let isFingerprintedFile = importedLock != nil && versionRecord.providerSourceID.hasPrefix(LyricsPersistenceMapper.lyricFileSourcePrefix)
            let duplicateID = try findVersionID(stableKey: canonicalKey, source: versionRecord.source,
                providerSourceID: versionRecord.providerSourceID, contentHash: versionRecord.contentHash,
                fileSourceHash: isFingerprintedFile ? sourceContentHash : nil)
            if let duplicateID {
                if isFingerprintedFile {
                    try restoreFileVoices(document.lines, versionID: duplicateID)
                }
                try storeSourceTranslations(document, versionID: duplicateID, sourceHash: sourceContentHash)
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

            if importedLock != nil {
                if let existing = try fetchBestVersion(stableKey: canonicalKey) {
                    try setPreferredLyricsVersion(trackStableKey: canonicalKey, lyricsVersionID: existing.id)
                }
            } else if try hasLockedVersion(stableKey: canonicalKey) {
                return LyricsPersistenceSaveResult(versionID: nil, disposition: .skippedLocked)
            }

            let parent = try manuscriptID.flatMap { try manuscriptParent($0, trackKey: canonicalKey, preferred: manuscriptParentID) }
            try insertVersion(canonicalVersionRecord(versionRecord, stableKey: canonicalKey, parentVersionID: parent))
            if intent == .automaticSelection && document.isSynchronized {
                let prefer = try prepare("UPDATE lyrics_versions SET is_preferred = 1 WHERE id = ? AND NOT EXISTS (SELECT 1 FROM lyrics_versions WHERE track_stable_key = ? AND (is_preferred = 1 OR is_locked = 1 OR is_manually_edited = 1));")
                defer { sqlite3_finalize(prefer) }
                try bindText(versionID.uuidString, at: 1, to: prefer)
                try bindText(canonicalKey, at: 2, to: prefer)
                try stepDone(prefer)
            }
            for line in lines {
                try insertLine(line)
            }
            try storeSourceTranslations(document, versionID: versionID, sourceHash: sourceContentHash,
                                        preserveUntagged: importedLock != nil)
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
    func adoptBatchCandidate(_ candidate: LyricsCandidate, for entry: PersonalLyricsLibraryEntry) async throws -> LyricsPersistenceSaveResult {
        try ensurePrepared()
        let track = entry.libraryTrack
        let identity = TrackIdentity(track: track)
        guard candidate.identity == identity, let recording = try archiveTrack(stableKey: entry.trackStableKey),
              try resolvedCanonicalStableKey(recording.stableKey) == resolvedCanonicalStableKey(identity.stableKey) else {
            return .init(versionID: nil, disposition: .rejected("候选与这个歌曲档案的录音不一致。"))
        }
        let requestID = UUID()
        try await registerManualAdoptionRequest(identity: identity, requestID: requestID)
        defer {
            if manualAdoptionRequestIDs[identity.stableKey] == requestID {
                manualAdoptionRequestIDs.removeValue(forKey: identity.stableKey)
            }
        }
        let saved = try await saveAndAdoptManually(track: track, identity: identity, document: candidate.makeDocument(),
                                                   requestID: requestID, confirmedLockedVersionIDs: nil)
        if saved.disposition == .lockedConflict { return .init(versionID: nil, disposition: .skippedLocked) }
        return saved
    }

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
            try storeSourceTranslations(document, versionID: versionID, sourceHash: sourceContentHash)
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

    /// Read-only storage identity resolution shared by library actions,
    /// migration and acceptance checks, without exposing SQL handles.
    public func resolveStableKey(_ stableKey: String) throws -> String {
        try ensurePrepared()
        return try resolvedCanonicalStableKey(stableKey)
    }

    /// Returns a canonical offset scope only when the requested saved version
    /// belongs to the supplied track identity family. New Spotify keys may
    /// gain a redirect, but no track/version rows are created.
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

    public func statistics() async throws -> LyricsDatabaseStats {
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
        func bytes(at path: String) -> Int64 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return LyricsDatabaseStats(
            databaseURL: databaseURL,
            schemaVersion: try schemaVersion(),
            trackCount: trackCount,
            lyricsVersionCount: lyricsVersionCount,
            lyricLineCount: lyricLineCount,
            fileSize: bytes(at: databaseURL.path),
            lastUpdated: lastUpdatedSeconds.map(Date.init(timeIntervalSince1970:)),
            journalBytes: ["-wal", "-shm", "-journal"].reduce(0) { $0 + bytes(at: databaseURL.path + $1) },
            backups: try LyricsDatabaseBackup.files(beside: databaseURL)
        )
    }

    public func createBackup() async throws -> URL {
        try prepare()
        return try writeDatabaseSnapshot(label: "backup")
    }

    public func clearLyricsCache() async throws {
        // Saved versions, adopted selections, requests and alignment files belong to the library.
        librarySearchCache.removeAll()
        librarySearchDataVersion = -1
        librarySearchTotalChanges = -1
    }

    // MARK: - TranslationRepository

    public func loadTranslationRequest(key: String) async throws -> StoredTranslationRequest? {
        try readTranslationRequest(key: key)
    }

    private func readTranslationRequest(key: String) throws -> StoredTranslationRequest? {
        try ensurePrepared()
        let statement = try prepare("SELECT attempt_id, phase, result_json, updated_at, completion_version_id FROM translation_requests WHERE request_key = ?;")
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
        let completionID = columnText(statement, index: 4)
        guard completionID == nil || UUID(uuidString: completionID!) != nil else {
            throw TranslationRepositoryError.database("输出版本关联不可读；未重新发送")
        }
        return StoredTranslationRequest(key: key, attemptID: id, phase: phase, result: draft,
            updatedAt: Date(timeIntervalSince1970: time), completionVersionID: completionID.flatMap(UUID.init(uuidString:)))
    }

    public func beginTranslationRequest(key: String, explicitRetry: Bool) async throws -> StoredTranslationRequest {
        try ensurePrepared()
        return try withTransaction {
            if let prior = try readTranslationRequest(key: key), prior.phase != .prepared, !explicitRetry {
                throw TranslationRepositoryError.database("上次翻译已发起，结果尚未确认；请主动重试，不会自动重发")
            }
            let request = StoredTranslationRequest(key: key, completionVersionID: UUID())
            let statement = try prepare("INSERT OR REPLACE INTO translation_requests(request_key, attempt_id, phase, result_json, updated_at, completion_version_id) VALUES (?, ?, 'prepared', NULL, ?, ?);")
            defer { sqlite3_finalize(statement) }
            try bindText(key, at: 1, to: statement)
            try bindText(request.attemptID.uuidString, at: 2, to: statement)
            try bindDouble(request.updatedAt.timeIntervalSince1970, at: 3, to: statement)
            try bindText(request.completionVersionID?.uuidString, at: 4, to: statement)
            try stepDone(statement)
            return request
        }
    }

    public func updateTranslationRequest(_ request: StoredTranslationRequest) async throws {
        try ensurePrepared()
        try withTransaction {
            guard let previous = try readTranslationRequest(key: request.key), previous.attemptID == request.attemptID,
                  (previous.phase == .prepared && request.phase == .dispatching) ||
                  (previous.phase == .dispatching && request.phase == .received && request.result != nil) else {
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

    public func completeTranslationRequest(key: String, attemptID: UUID,
                                           context: TranslationCompletionContext) async throws -> StoredTranslationVersion {
        try ensurePrepared()
        let completed = try withTransaction {
            // Read the current attempt under the SQLite write lock, before any INSERT.
            guard let request = try readTranslationRequest(key: key), request.attemptID == attemptID,
                  request.phase == .received || request.phase == .saved else {
                throw TranslationRepositoryError.database("请求代次或阶段已改变；拒绝迟到完成")
            }
            guard let completionID = request.completionVersionID else {
                throw TranslationRepositoryError.database("旧请求无法安全关联输出版本；保留已有结果，可主动重试")
            }
            guard try context.requestKey() == key,
                  let source = try fetchSourceLyrics(versionID: context.lyricsVersionID),
                  source.hash == context.sourceContentHash,
                  source.lines.map(\.originalText) == context.originalLines else {
                throw TranslationRepositoryError.sourceContentMismatch
            }
            let identityStatement = try prepare("SELECT track_stable_key FROM lyrics_versions WHERE id = ?;")
            defer { sqlite3_finalize(identityStatement) }
            try bindText(context.lyricsVersionID.uuidString, at: 1, to: identityStatement)
            guard sqlite3_step(identityStatement) == SQLITE_ROW,
                  let sourceKey = columnText(identityStatement, index: 0) else {
                throw TranslationRepositoryError.sourceContentMismatch
            }
            let canonicalSource = try resolvedCanonicalStableKey(sourceKey)
            let canonicalContext = try resolvedCanonicalStableKey(context.identity.stableKey)
            if canonicalSource != canonicalContext {
                // The content checks above pin this result to the stored original version.
                // A localized display title need not create a recording redirect just to save it.
                guard let id = context.identity.spotifyTrackID, let recording = try fetchTrack(stableKey: canonicalSource),
                      id == (TrackIdentity.canonicalSpotifyTrackID(recording.spotifyID)
                             ?? TrackIdentity.canonicalSpotifyTrackID(recording.spotifyURI)) else {
                    throw TranslationRepositoryError.sourceContentMismatch
                }
            }
            if request.phase == .saved {
                guard request.result == nil,
                      let exact = try loadTranslationVersions(lyricsVersionID: context.lyricsVersionID,
                        targetLanguage: context.targetLanguage, sourceContentHash: context.sourceContentHash)
                        .first(where: { $0.record.id == completionID }),
                      context.accepts(engine: exact.record.engineID),
                      exact.record.providerExecutionMetadata.cacheIdentity == context.providerCacheIdentity else {
                    throw TranslationRepositoryError.database("已完成请求的精确版本缺失或不完整；不会重建或重发")
                }
                return exact
            }
            guard let draft = request.result, draft.targetLanguage == context.targetLanguage,
                  context.accepts(engine: draft.engineID) else {
                throw TranslationRepositoryError.database("请求缺少完整且同语言/引擎的结果")
            }
            // Always insert an independent candidate. Adoption remains a separate,
            // explicit Controller decision after commit and its current selection checks.
            let saved = try insertValidatedTranslation(versionID: completionID, lyricsVersionID: context.lyricsVersionID,
                sourceContentHash: context.sourceContentHash, originalLines: context.originalLines,
                draft: draft.with(isDraft: true, isArchived: false, providerCacheIdentity: context.providerCacheIdentity))
#if DEBUG
            translationCompletionCheckpoint?("beforeCommit")
#endif
            let statement = try prepare("""
                UPDATE translation_requests SET phase='saved', result_json=NULL, updated_at=?
                WHERE request_key=? AND attempt_id=? AND phase='received' AND completion_version_id=?;
                """)
            defer { sqlite3_finalize(statement) }
            try bindDouble(Date().timeIntervalSince1970, at: 1, to: statement)
            try bindText(key, at: 2, to: statement)
            try bindText(attemptID.uuidString, at: 3, to: statement)
            try bindText(completionID.uuidString, at: 4, to: statement)
            try stepDone(statement)
            guard sqlite3_changes(database) == 1 else {
                throw TranslationRepositoryError.database("完成 CAS 失败；版本和行已回滚")
            }
            return saved
        }
#if DEBUG
        translationCompletionCheckpoint?("afterCommit")
#endif
        return completed
    }

    /// Named TTML tracks share one original. A missing line in one language stays empty.
    private func storeSourceTranslations(_ document: LyricsDocument, versionID: UUID, sourceHash: String,
                                         preserveUntagged: Bool = false) throws {
        var languages = LyricSourceTranslation.languages(in: document.lines)
        guard !languages.isEmpty else {
            if preserveUntagged && document.lines.contains(where: { $0.translationText?.isEmpty == false }) {
                try insertEmbeddedTranslationIfAvailable(lyricsVersionID: versionID, sourceContentHash: sourceHash)
            }
            return
        }
        // A newly filed recording opens on the language the reader was using.
        if let preferred = languages.firstIndex(where: { tag in
            document.lines.allSatisfy { $0.translationText == $0.sourceTranslation(in: tag) }
        }) { languages.append(languages.remove(at: preferred)) }
        let existing = try loadTranslationVersions(lyricsVersionID: versionID, targetLanguage: "und", sourceContentHash: sourceHash)
        for tag in languages {
            let texts = document.lines.map { $0.sourceTranslation(in: tag) ?? "" }
            if existing.contains(where: { $0.isEmbeddedTranslation && $0.record.targetLanguage == tag &&
                $0.lines.map(\.translatedText) == texts }) { continue }
            let draft = AITranslationDraft(lines: texts.enumerated().map { .init(index: $0.offset, translation: $0.element) },
                targetLanguage: tag, model: "词源自带译文", baseURLHost: "", promptHash: "",
                sourceContentHash: sourceHash, sourceKind: .providerEmbedded,
                isMachineGenerated: false, isManuallyEdited: false, engineID: "provider-embedded")
            _ = try insertValidatedTranslation(versionID: UUID(), lyricsVersionID: versionID, sourceContentHash: sourceHash,
                                                originalLines: document.lines.map(\.originalText), draft: draft)
        }
    }

    /// Copy complete embedded text once into independent version history. The
    /// original lyric_lines stay untouched; BEGIN IMMEDIATE serializes two
    /// controllers opening the same source concurrently.
    public func preserveEmbeddedTranslation(lyricsVersionID: UUID, sourceContentHash: String) async throws {
        try ensurePrepared()
        try withTransaction {
            try insertEmbeddedTranslationIfAvailable(lyricsVersionID: lyricsVersionID, sourceContentHash: sourceContentHash)
        }
    }

    private func insertEmbeddedTranslationIfAvailable(lyricsVersionID: UUID, sourceContentHash: String) throws {
        guard let source = try fetchSourceLyrics(versionID: lyricsVersionID),
              let version = try fetchLyricsVersion(versionID: lyricsVersionID) else {
            throw TranslationRepositoryError.sourceLyricsNotFound
        }
        guard source.hash == sourceContentHash else { throw TranslationRepositoryError.sourceContentMismatch }
        let existing = try loadTranslationVersions(lyricsVersionID: lyricsVersionID,
            targetLanguage: "und", sourceContentHash: sourceContentHash)
        guard !existing.contains(where: { $0.isEmbeddedTranslation }) else { return }
        let lines = source.lines.map { AITranslationLine(index: $0.lineIndex, translation: $0.translationText ?? "") }
        let fromFile = version.providerSourceID.hasPrefix(LyricsPersistenceMapper.lyricFileSourcePrefix)
        let manual = !fromFile && (version.isManuallyEdited || [LyricsSource.manualEdit.rawValue,
            LyricsSource.manualImport.rawValue, LyricsSource.manualCreate.rawValue].contains(version.source))
        // Incomplete native text remains in lyric_lines; never manufacture
        // missing translations. Source-provided text may be sparse, while
        // manually authored source text still has to be complete.
        guard lines.contains(where: { !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              source.lines.allSatisfy({ line in
                  let originalBlank = line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  let text = line.translationText ?? ""
                  let translationBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  let validTranslation = manual
                      ? originalBlank == translationBlank
                      : (originalBlank == translationBlank || (!originalBlank && text.isEmpty))
                  return validTranslation && (!originalBlank || text.isEmpty) &&
                      !text.contains("\n") && !text.contains("\r")
              }) else { return }
        let draft = AITranslationDraft(lines: lines, targetLanguage: "und",
            model: manual ? "人工已有译文" : "词源自带译文", baseURLHost: "", promptHash: "",
            sourceContentHash: sourceContentHash, sourceKind: manual ? .manualImport : .providerEmbedded,
            isMachineGenerated: false, isManuallyEdited: manual, engineID: "provider-embedded")
        _ = try insertValidatedTranslation(versionID: UUID(), lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceContentHash, originalLines: source.lines.map(\.originalText), draft: draft)
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
            WHERE lyrics_version_id = ? AND (target_language = ? OR
              source_kind = 'providerEmbedded' OR (source_kind = 'legacyImported' AND target_language = 'und') OR engine_id = 'provider-embedded')
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
        return try withTransaction {
            try insertValidatedTranslation(versionID: UUID(), lyricsVersionID: lyricsVersionID,
                sourceContentHash: sourceContentHash, originalLines: originalLines, draft: draft)
        }
    }

    /// Caller owns the write transaction; never starts a nested transaction.
    private func insertValidatedTranslation(versionID: UUID, lyricsVersionID: UUID,
                                            sourceContentHash: String, originalLines: [String],
                                            draft: AITranslationDraft) throws -> StoredTranslationVersion {
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
        let allowsSparseRows = allowsSparseTranslationRows(
            sourceKind: draft.sourceKind,
            isMachineGenerated: draft.isMachineGenerated,
            isManuallyEdited: draft.isManuallyEdited
        )
        if allowsSparseRows,
           !draft.lines.contains(where: { !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw TranslationRepositoryError.invalidLines("词源译文不能为空")
        }
        for line in draft.lines {
            let sourceText = source.lines[line.index].originalText
            let sourceBlank = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let translationBlank = line.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sparseRow = allowsSparseRows && !sourceBlank && line.translation.isEmpty
            guard sourceBlank == translationBlank || sparseRow,
                  !sourceBlank || line.translation.isEmpty,
                  !line.translation.contains("\n"),
                  !line.translation.contains("\r") else {
                throw TranslationRepositoryError.invalidLines("空白行或换行规则不匹配")
            }
        }

        let now = Date()
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

        try insertTranslationVersion(record)
        for line in lines { try insertTranslationLine(line) }
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
            baseDoc = try applyingBestTiming(to: baseDoc, lyricsID: record.id, hash: sourceContentHash)
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
        baseDoc = try applyingBestTiming(to: baseDoc, lyricsID: record.id, hash: sourceContentHash)
        let document = applyingLockedReadings(
            to: baseDoc,
            readings: readings
        )
        _ = track
        return StoredEditableLyricsVersion(record: record, lines: lines, document: document, lockedReadingLayers: readings)
    }

    public func loadPersonalLibraryTimingVersion(id: UUID) throws -> DatabaseLyricsTimingVersionRecord? {
        try ensurePrepared()
        return try fetchTimingVersion(id: id)
    }

    private func timingSelectionKey(_ lyricsVersionID: UUID) -> String {
        "lyrics.timing.selection." + databaseURL.path + "." + lyricsVersionID.uuidString
    }

    /// Selection is a preference; immutable timeline assets and dates stay intact.
    public func adoptPersonalLibraryTimingVersion(id: UUID, trackStableKey: String) throws -> UUID {
        try ensurePrepared()
        guard let timing = try fetchTimingVersion(id: id),
              let lyrics = try fetchLyricsVersion(versionID: timing.lyricsVersionID),
              try resolvedCanonicalStableKey(lyrics.trackStableKey) == resolvedCanonicalStableKey(trackStableKey),
              timing.sourceContentHash == LyricsSourceContentHasher.hash(
                isSynchronized: lyrics.isSynced, lines: try fetchLines(versionID: lyrics.id)) else {
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        UserDefaults.lyricsQ.set(id.uuidString, forKey: timingSelectionKey(lyrics.id))
        return lyrics.id
    }

    /// Saves an immutable timing child on the same lyrics version. The exact
    /// lyric identity/hash is checked again before the new payload is stored.
    public func savePersonalLibraryTimingRevision(
        _ request: LibraryTimingRevisionSaveRequest
    ) throws -> DatabaseLyricsTimingVersionRecord {
        try ensurePrepared()
        guard TrackIdentity(track: request.track) == request.identity else {
            throw LyricsEditingRepositoryError.identityMismatch
        }
        guard let sourceTiming = try fetchTimingVersion(id: request.sourceTimingVersionID),
              let sourceVersion = try fetchLyricsVersion(versionID: sourceTiming.lyricsVersionID) else {
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        let canonicalKey = try resolvedCanonicalStableKey(request.identity.stableKey)
        guard try resolvedCanonicalStableKey(sourceVersion.trackStableKey) == canonicalKey else {
            throw LyricsEditingRepositoryError.identityMismatch
        }

        let sourceRows = try fetchLines(versionID: sourceVersion.id)
        let sourceHash = LyricsSourceContentHasher.hash(isSynchronized: sourceVersion.isSynced, lines: sourceRows)
        guard sourceTiming.sourceContentHash == sourceHash else {
            throw LyricsEditingRepositoryError.sourceContentMismatch
        }
        guard try fetchTrack(stableKey: sourceVersion.trackStableKey) != nil else {
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        let baseDocument = Self.documentForTimingValidation(
            identity: request.identity,
            track: request.track,
            version: sourceVersion,
            lines: sourceRows
        )

        guard let oldRows = DocumentTimingPayload.decodeRows(sourceTiming.spansPayload) else {
            throw LyricsEditingRepositoryError.sourceContentMismatch
        }
        let orderedPayload = request.lines.map { row in
            LineTimingPayload(lineIndex: row.lineIndex, performerID: row.performerID, spans: row.spans,
                              backgroundText: oldRows[row.lineIndex]?.backgroundText ?? row.backgroundText)
        }.sorted { $0.lineIndex < $1.lineIndex }
        guard !orderedPayload.isEmpty,
              Set(orderedPayload.map(\.lineIndex)).count == orderedPayload.count,
              orderedPayload.allSatisfy({
                  baseDocument.lines.indices.contains($0.lineIndex) && !$0.spans.isEmpty
              }) else {
            throw LyricsEditingRepositoryError.invalidTimeline("逐字时间行号重复、越界或没有时间片段")
        }
        let oldPayload = oldRows.values.sorted { $0.lineIndex < $1.lineIndex }
        guard orderedPayload != oldPayload else {
            throw LyricsEditingRepositoryError.noChanges
        }

        var updatedLines = baseDocument.lines.map { line -> LyricLine in
            var line = line
            line.timedSpans = nil
            line.performerID = nil
            return line
        }
        for payload in orderedPayload {
            updatedLines[payload.lineIndex].timedSpans = payload.spans
            updatedLines[payload.lineIndex].performerID = payload.performerID
            updatedLines[payload.lineIndex].backgroundText = payload.backgroundText
        }
        let updatedDocument = baseDocument.replacingLines(updatedLines, timingVersionID: sourceTiming.id)
        guard LyricsTimingCompatibility.hasOnlyCompatibleSpans(in: updatedDocument),
              let spansPayload = DocumentTimingPayload.encode(updatedLines) else {
            throw LyricsEditingRepositoryError.invalidTimeline("逐字时间与原文或行时间不兼容")
        }

        let record = DatabaseLyricsTimingVersionRecord(
            id: UUID(),
            lyricsVersionID: sourceVersion.id,
            source: DatabaseSourceIdentifier.identifier(for: .manualEdit),
            granularity: sourceTiming.granularity,
            sourceContentHash: sourceHash,
            spansPayload: spansPayload,
            createdAt: Date()
        )
        try withTransaction { try insertTimingVersion(record) }
        return record
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
        var sourceTimingMap: [Int: LineTimingPayload] = [:]
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
                sourceTimingMap = record?.rows ?? [:]
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
        guard translation.lines.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw LyricsEditingRepositoryError.invalidTranslation("至少保留一行译文")
        }
        for index in targetDocument.lines.indices {
            let originalBlank = targetDocument.lines[index].originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let translationText = translation.lines[index]
            let translationBlank = translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sparseManualRow = !originalBlank && translationText.isEmpty
            guard originalBlank == translationBlank || sparseManualRow,
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
            confidence: 1,
            isDraft: translation.isDraft
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
        let lines = document.lines.map { original in
            var line = original
            line.translationText = nil
            line.sourceTranslations = []
            return line
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
        sourceMap: [Int: LineTimingPayload],
        sourceRows: [DatabaseLyricLineRecord]
    ) -> [LyricsEditorLineDraft] {
        let rowsByText = Dictionary(grouping: sourceRows, by: \.originalText)
        let rowsByIndex = Dictionary(uniqueKeysWithValues: sourceRows.map { ($0.lineIndex, $0) })
        return proposedLines.enumerated().map { index, original in
            var line = original
            guard line.timedSpans != nil else { return line }
            let matchingSourceIndex = rowsByText[line.originalText]?.first { row in
                sourceMap[row.lineIndex]?.spans.contains { line.timedSpans?.contains($0) == true } == true
            }?.lineIndex
            let sourceIndex = matchingSourceIndex ?? index
            let priorEndTime = rowsByIndex[sourceIndex]?.endTime
            let endChanged = priorEndTime != line.endTime
            line.timedSpans = LyricsTimingCompatibility.compatibleSpans(
                in: line,
                enforceLineEndBoundary: endChanged && line.endTime != nil
            )
            if line.timedSpans?.isEmpty == false, line.backgroundText == nil, let matchingSourceIndex {
                line.backgroundText = sourceMap[matchingSourceIndex]?.backgroundText
            }
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
                kanaText: line.kanaText,
                performerID: line.performerID, backgroundText: line.backgroundText
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
        sourceMap: [Int: LineTimingPayload],
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

    private func allowsSparseTranslationRows(
        sourceKind: AITranslationSourceKind,
        isMachineGenerated: Bool,
        isManuallyEdited: Bool
    ) -> Bool {
        (sourceKind == .providerEmbedded && !isMachineGenerated && !isManuallyEdited)
            || (sourceKind == .manualEdit && !isMachineGenerated && isManuallyEdited)
    }

    private func validateStoredTranslation(
        record: DatabaseTranslationVersionRecord,
        lines: [DatabaseTranslationLineRecord],
        sourceLines: [DatabaseLyricLineRecord]
    ) -> Bool {
        let allowsSparseRows = allowsSparseTranslationRows(
            sourceKind: record.sourceKind,
            isMachineGenerated: record.isMachineGenerated,
            isManuallyEdited: record.isManuallyEdited
        )
        guard record.status == .complete,
              lines.count == sourceLines.count,
              lines.map(\.lineIndex) == Array(sourceLines.indices),
              !allowsSparseRows || lines.contains(where: {
                  !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return false }
        return lines.allSatisfy { translation in
            let original = sourceLines[translation.lineIndex].originalText
            let sourceBlank = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let translationBlank = translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sparseRow = allowsSparseRows && !sourceBlank && translation.translatedText.isEmpty
            return (sourceBlank == translationBlank || sparseRow) &&
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

    private func writePreUpgradeSnapshot() throws {
        // Read the committed data through a separate connection while the
        // migration holds the write lock.
        var reader: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &reader, SQLITE_OPEN_READONLY, nil)
        defer { if let reader { sqlite3_close(reader) } }
        guard result == SQLITE_OK, let reader else {
            throw LyricsRepositoryError.unavailable("数据库备份无法读取原库")
        }
        _ = try writeDatabaseSnapshot(label: "pre-v\(DatabaseMigrator.currentVersion)", source: reader)
    }

    private func writeDatabaseSnapshot(label: String, source: OpaquePointer? = nil) throws -> URL {
        guard let source = source ?? database else { throw LyricsRepositoryError.unavailable("SQLite handle 已关闭") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = databaseURL.deletingLastPathComponent()
        let base = databaseURL.deletingPathExtension().lastPathComponent
        let filename = "\(base).\(label)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlite3"
        let destination = directory.appendingPathComponent(filename)
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
                throw LyricsRepositoryError.unavailable("数据库备份无法创建")
            }
            defer { sqlite3_close(backupDatabase) }
            guard let backup = sqlite3_backup_init(backupDatabase, "main", source, "main") else {
                throw LyricsRepositoryError.unavailable("数据库备份初始化失败")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                // Preserve the source and abort; never migrate after a failed backup.
                throw LyricsRepositoryError.unavailable("数据库备份失败 (\(step)/\(finish))")
            }
            // Make the snapshot a standalone read-only recovery file, even
            // when the source database uses WAL journaling.
            guard sqlite3_exec(backupDatabase, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
                throw LyricsRepositoryError.unavailable("数据库备份日志整理失败")
            }
        }
        // Only a completed, closed snapshot receives the recovery filename.
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
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

        let keyStatement = try prepare("SELECT stable_key FROM tracks;")
        defer { sqlite3_finalize(keyStatement) }
        var knownKeys = Set<String>()
        while sqlite3_step(keyStatement) == SQLITE_ROW {
            guard let key = columnText(keyStatement, index: 0) else {
                throw LyricsRepositoryError.invalidData("Track stable_key 缺失")
            }
            knownKeys.insert(key)
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
        redirectResolver = resolver
    }

    private func hasTable(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(name, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// ラヴイットベイビー came back from Spotify as 141.29 s by one artist
    /// after it had been saved as 166.168 s by two. The stable key holds both,
    /// so the saved lyrics were not found and the song went to review. One
    /// Spotify track ID is one recording whatever length or credits the
    /// player reports this time, so its adopted version is used. Only under
    /// the same title: an ID read mid-skip can belong to the previous song
    /// (5o45jo… sat on two different titles, L-039). Read-only.
    private func adoptedSameSpotifyTrackStableKey(stableKey: String, title: String) throws -> String? {
        guard stableKey.hasPrefix("spotify-id:"),
              let prefix = stableKey.components(separatedBy: "|metadata:").first,
              prefix.count > "spotify-id:".count else { return nil }
        let wanted = TrackTextNormalizer.normalize(title)
        guard !wanted.isEmpty else { return nil }
        let query = try prepare("""
            SELECT t.stable_key, t.title FROM tracks t
            WHERE substr(t.stable_key, 1, length(?) + 1) = ? || '|' AND t.stable_key <> ?
            ORDER BY t.updated_at DESC, t.stable_key ASC;
            """)
        defer { sqlite3_finalize(query) }
        try bindText(prefix, at: 1, to: query)
        try bindText(prefix, at: 2, to: query)
        try bindText(stableKey, at: 3, to: query)
        var keys: [String] = []
        while true {
            let result = sqlite3_step(query)
            guard result == SQLITE_ROW else {
                guard result == SQLITE_DONE else { throw lastError() }
                break
            }
            guard let key = columnText(query, index: 0), let rowTitle = columnText(query, index: 1),
                  TrackTextNormalizer.normalize(rowTitle) == wanted else { continue }
            keys.append(key)
        }
        // The same rule as a direct read: adopted, locked or trusted, never
        // a revoked choice.
        for key in keys {
            let canonical = try resolvedCanonicalStableKey(key)
            if try fetchBestVersion(stableKey: canonical) != nil { return canonical }
        }
        return nil
    }

    private func adoptedAppleMusicStableKey(for track: Track) throws -> String? {
        guard let id = TrackIdentity.playbackID(for: track), id.hasPrefix("applemusic:") else { return nil }
        let query = try prepare("""
            SELECT t.stable_key FROM tracks t JOIN lyrics_versions v ON v.track_stable_key = t.stable_key
            WHERE lower(t.spotify_id) = ? AND v.is_preferred = 1
              AND NOT EXISTS (SELECT 1 FROM lyrics_selection_revocations r WHERE r.track_stable_key = t.stable_key)
            ORDER BY v.updated_at DESC, v.id DESC LIMIT 1;
            """)
        defer { sqlite3_finalize(query) }
        try bindText(id, at: 1, to: query)
        let result = sqlite3_step(query)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result == SQLITE_ROW ? columnText(query, index: 0) : nil
    }

    /// Preserve physical keys written before Music's persistent ID was part of the runtime key.
    /// An older metadata row can only be reused when no different player ID already owns it.
    private func appleMusicArchiveKey(for key: String) throws -> String {
        let prefix = "applemusic-id:"
        guard key.hasPrefix(prefix), let separator = key.range(of: "|metadata:"),
              separator.lowerBound >= key.index(key.startIndex, offsetBy: prefix.count) else { return key }
        let rawID = "applemusic:" + String(key[key.index(key.startIndex, offsetBy: prefix.count)..<separator.lowerBound])
        guard let id = TrackIdentity.appleMusicPersistentID(rawID) else { return key }
        if try fetchTrack(stableKey: key) != nil { return key }
        let recordingKey = prefix + id
        if try fetchTrack(stableKey: recordingKey) != nil { return recordingKey }
        let query = try prepare("""
            SELECT t.stable_key FROM tracks t
            WHERE t.spotify_id = ? COLLATE NOCASE
            ORDER BY EXISTS (SELECT 1 FROM lyrics_versions v WHERE v.track_stable_key = t.stable_key AND v.is_preferred = 1) DESC,
                     EXISTS (SELECT 1 FROM lyrics_versions v WHERE v.track_stable_key = t.stable_key AND v.is_locked = 1) DESC,
                     EXISTS (SELECT 1 FROM lyrics_versions v WHERE v.track_stable_key = t.stable_key) DESC,
                     t.created_at, t.stable_key
            LIMIT 1;
            """)
        defer { sqlite3_finalize(query) }
        try bindText("applemusic:" + id, at: 1, to: query)
        let result = sqlite3_step(query)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        if result == SQLITE_ROW, let existing = columnText(query, index: 0) { return existing }
        let fingerprint = String(key[separator.upperBound...])
        let legacy = "metadata:\(fingerprint)|metadata:\(fingerprint)"
        if let record = try fetchTrack(stableKey: legacy), record.spotifyID?.isEmpty != false, record.spotifyURI?.isEmpty != false {
            return legacy
        }
        return recordingKey
    }

    /// New Spotify metadata keys join the existing recording without creating
    /// another Track row. Existing physical splits are handled by the one-off pass.
    private func redirectNewSpotifyKey(_ stableKey: String) throws {
        let prefix = "spotify-id:"
        guard stableKey.hasPrefix(prefix),
              redirectResolver?.redirects[stableKey] == nil,
              let separator = stableKey.range(of: "|metadata:"),
              let id = TrackIdentity.canonicalSpotifyTrackID(String(stableKey[..<separator.lowerBound].dropFirst(prefix.count))),
              let title = stableKey[separator.upperBound...].split(separator: "|", omittingEmptySubsequences: false).first,
              !title.isEmpty,
              let database else { return }
        // Another repository object on the same database (the player and the
        // lyrics library each hold one) may already have written this
        // redirect. Its cached list here would not know, and a second insert
        // fails on the unique key, which used to stop the song's saved
        // lyrics from loading at all. Read the database, not only the cache.
        let existing = try prepare("SELECT 1 FROM track_identity_redirects WHERE source_stable_key = ? LIMIT 1;")
        defer { sqlite3_finalize(existing) }
        try bindText(stableKey, at: 1, to: existing)
        let existingResult = sqlite3_step(existing)
        guard existingResult == SQLITE_ROW || existingResult == SQLITE_DONE else { throw lastError() }
        if existingResult == SQLITE_ROW {
            try reloadRedirectResolver()
            return
        }
        let uri = "spotify:track:\(id)"
        guard let canonical = try sameTitleSpotifyRedirectTarget(sourceKey: stableKey, id: id, uri: uri, title: title) else { return }
        let now = Date().timeIntervalSince1970
        let insert = {
            // A different connection may have inserted a physical row since the lookup.
            guard try self.fetchTrack(stableKey: stableKey) == nil else { return }
            let redirect = try self.prepare("""
                INSERT INTO track_identity_redirects(source_stable_key, canonical_stable_key,
                    reason, evidence_kind, migration_id, created_at)
                VALUES (?, ?, 'same Spotify track ID', 'spotifyTrackIDExact', 'spotify-id-one-song-v1', ?)
                ON CONFLICT(source_stable_key) DO NOTHING;
                """)
            defer { sqlite3_finalize(redirect) }
            try self.bindText(stableKey, at: 1, to: redirect)
            try self.bindText(canonical, at: 2, to: redirect)
            try self.bindDouble(now, at: 3, to: redirect)
            try self.stepDone(redirect)
            guard sqlite3_changes(database) > 0 else { return }
            // A new source has no physical Track row; the full source key and
            // Spotify identifiers are the audit evidence for this read/save.
            let audit = try self.prepare("""
                INSERT INTO track_identity_merge_audit(migration_id, source_stable_key, canonical_stable_key,
                    source_spotify_id, source_spotify_uri, evidence, action, created_at)
                VALUES ('spotify-id-one-song-v1', ?, ?, ?, ?, 'spotifyTrackIDExact', 'redirect-only', ?);
                """)
            defer { sqlite3_finalize(audit) }
            try self.bindText(stableKey, at: 1, to: audit)
            try self.bindText(canonical, at: 2, to: audit)
            try self.bindText(id, at: 3, to: audit)
            try self.bindText(uri, at: 4, to: audit)
            try self.bindDouble(now, at: 5, to: audit)
            try self.stepDone(audit)
        }
        if sqlite3_get_autocommit(database) != 0 { try withTransaction(insert) }
        else { try insert() }
        try reloadRedirectResolver()
    }

    private func sameTitleSpotifyRedirectTarget(sourceKey: String, id: String, uri: String, title: Substring) throws -> String? {
        let query = try prepare("""
            SELECT t.stable_key, t.title FROM tracks t
            WHERE (lower(t.spotify_id) IN (?, ?) OR lower(t.spotify_uri) = ?)
              AND NOT EXISTS (SELECT 1 FROM tracks WHERE stable_key = ?)
            ORDER BY EXISTS (
                SELECT 1 FROM lyrics_versions v WHERE v.track_stable_key = t.stable_key
                  AND v.is_preferred = 1
                  AND NOT EXISTS (SELECT 1 FROM lyrics_selection_revocations r WHERE r.track_stable_key = t.stable_key)
            ) DESC, t.created_at ASC, t.stable_key ASC;
            """)
        defer { sqlite3_finalize(query) }
        try bindText(id, at: 1, to: query)
        try bindText(uri, at: 2, to: query)
        try bindText(uri, at: 3, to: query)
        try bindText(sourceKey, at: 4, to: query)
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw lastError() }
            // During a skip, a track ID can briefly belong to the preceding song.
            guard let key = columnText(query, index: 0), let rowTitle = columnText(query, index: 1),
                  TrackIdentity.normalizedComponent(rowTitle) == title else { continue }
            let canonical = try redirectResolver?.resolve(key) ?? key
            if canonical == key { return canonical }
            if let canonicalRow = try fetchTrack(stableKey: canonical),
               TrackIdentity.normalizedComponent(canonicalRow.title) == title { return canonical }
        }
    }

    private func resolvedCanonicalStableKey(_ stableKey: String) throws -> String {
        try redirectNewSpotifyKey(stableKey)
        let compatibleKey = try appleMusicArchiveKey(for: stableKey)
        let stableKey = adoptedMusicPlaybackKeys[compatibleKey] ?? compatibleKey
        guard let redirectResolver else { return stableKey }
        return try redirectResolver.resolve(stableKey)
    }

    private func resolvedIdentityFamily(stableKey: String) throws -> [String] {
        try redirectNewSpotifyKey(stableKey)
        let compatibleKey = try appleMusicArchiveKey(for: stableKey)
        let stableKey = adoptedMusicPlaybackKeys[compatibleKey] ?? compatibleKey
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

    private func canonicalVersionRecord(_ record: DatabaseLyricsVersionRecord, stableKey: String, parentVersionID: UUID? = nil) -> DatabaseLyricsVersionRecord {
        guard record.trackStableKey != stableKey || parentVersionID != nil else { return record }
        return DatabaseLyricsVersionRecord(
            id: record.id,
            trackStableKey: stableKey,
            parentVersionID: parentVersionID ?? record.parentVersionID,
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
                original_text, kana_text, romaji_text, translation_text, performer_id, background_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        try bindText(record.performerID, at: 9, to: statement)
        try bindText(record.backgroundText, at: 10, to: statement)
        try stepDone(statement)
    }

    /// A byte-identical file can restore voices lost by older imports. The
    /// original row, order and any already recorded voice still win.
    private func restoreFileVoices(_ lines: [LyricLine], versionID: UUID) throws {
        guard lines.contains(where: { $0.performerID != nil || $0.backgroundText != nil }) else { return }
        let statement = try prepare("""
            UPDATE lyric_lines SET performer_id = COALESCE(performer_id, ?1), background_text = COALESCE(background_text, ?2)
            WHERE lyrics_version_id = ?3 AND line_index = ?4 AND original_text = ?5
              AND ((performer_id IS NULL AND ?1 IS NOT NULL) OR (background_text IS NULL AND ?2 IS NOT NULL));
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(versionID.uuidString, at: 3, to: statement)
        for (index, line) in lines.enumerated() where line.performerID != nil || line.backgroundText != nil {
            sqlite3_reset(statement)
            try bindText(line.performerID, at: 1, to: statement)
            try bindText(line.backgroundText, at: 2, to: statement)
            try bindInt(index, at: 4, to: statement)
            try bindText(line.originalText, at: 5, to: statement)
            try stepDone(statement)
        }
    }

    private func manuscriptParent(_ manuscript: UUID, trackKey: String, preferred: UUID?) throws -> UUID? {
        let family = try resolvedIdentityFamily(stableKey: trackKey)
        let statement = try prepare("""
            SELECT id FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: family.count)))
              AND (id = ? OR (source = 'manualCreate' AND provider_source_id GLOB ?))
            ORDER BY (id = ?) DESC, created_at DESC, rowid DESC LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: statement) }
        try bindText(preferred?.uuidString, at: Int32(family.count + 1), to: statement)
        try bindText(LyricManuscript.sourcePrefix(manuscript) + "*", at: Int32(family.count + 2), to: statement)
        try bindText(preferred?.uuidString, at: Int32(family.count + 3), to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)) else {
                throw LyricsRepositoryError.invalidData("手稿原词版本 UUID 无效")
            }
            return id
        default: throw lastError()
        }
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

    private func findVersionID(
        stableKey: String,
        source: String,
        providerSourceID: String,
        contentHash: String,
        fileSourceHash: String? = nil
    ) throws -> UUID? {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let match = fileSourceHash == nil ? "AND content_hash = ? LIMIT 1" : "ORDER BY (content_hash = ?) DESC"
        let statement = try prepare("""
            SELECT id FROM lyrics_versions
            WHERE track_stable_key IN (\(placeholders(count: family.count))) AND source = ?
              AND provider_source_id = ? \(match);
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() {
            try bindText(key, at: Int32(index + 1), to: statement)
        }
        let offset = Int32(family.count)
        try bindText(source, at: offset + 1, to: statement)
        try bindText(providerSourceID, at: offset + 2, to: statement)
        try bindText(contentHash, at: offset + 3, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = columnText(statement, index: 0), let id = UUID(uuidString: value) else {
                throw LyricsRepositoryError.invalidData("歌词版本 UUID 无效")
            }
            if let fileSourceHash, try fetchSourceLyrics(versionID: id)?.hash != fileSourceHash { continue }
            return id
        }
        return nil
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
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw lastError(result) }
        return try trackRecord(from: statement)
    }

    /// Metadata only. Choosing where to file a lyric does not load every song's version history.
    func localRecordingChoices(preferredRecording: String? = nil) throws
        -> (records: [DatabaseTrackRecord], preferred: DatabaseTrackRecord?) {
        try prepare()
        let preferred = try preferredRecording.flatMap { try archiveTrack(stableKey: $0) }
        let statement = try prepare("""
            SELECT stable_key, spotify_id, spotify_uri, isrc, title, artist_display,
                   album, duration, artwork_url, created_at, updated_at
            FROM tracks AS t
            WHERE NOT EXISTS (SELECT 1 FROM track_identity_redirects AS r WHERE r.source_stable_key = t.stable_key)
            ORDER BY updated_at DESC, stable_key;
            """)
        defer { sqlite3_finalize(statement) }
        var recordings: [DatabaseTrackRecord] = []
        while try stepListeningHistoryRow(statement) {
            recordings.append(try trackRecord(from: statement))
        }
        if let preferred, !recordings.contains(where: { $0.stableKey == preferred.stableKey }) {
            recordings.insert(preferred, at: 0)
        }
        return (recordings, preferred)
    }

    private func trackRecord(from statement: OpaquePointer) throws -> DatabaseTrackRecord {
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
        return try fetchBestTimingVersion(lyricsVersionID: version.id, sourceContentHash: sourceContentHash,
                                          document: document) != nil
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
                   original_text, kana_text, romaji_text, translation_text, performer_id, background_text
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
                    translationText: columnText(statement, index: 7),
                    performerID: columnText(statement, index: 8), backgroundText: columnText(statement, index: 9)
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
           )?.record,
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
    private func applyingBestTiming(to document: LyricsDocument, lyricsID: UUID, hash: String) throws -> LyricsDocument {
        guard let selected = try fetchBestTimingVersion(lyricsVersionID: lyricsID, sourceContentHash: hash,
                                                        document: document) else { return document }
        var lines = document.lines
        for (index, row) in selected.rows {
            lines[index].performerID = row.performerID ?? lines[index].performerID
            lines[index].timedSpans = row.spans
            lines[index].backgroundText = row.backgroundText.flatMap { $0.isEmpty ? nil : $0 } ?? lines[index].backgroundText
        }
        return document.replacingLines(lines, timingVersionID: selected.record.id)
    }

    private func fetchBestTimingVersion(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        document: LyricsDocument
    ) throws -> (record: DatabaseLyricsTimingVersionRecord, rows: [Int: LineTimingPayload])? {
        let statement = try prepare("""
            SELECT id, lyrics_version_id, source, granularity,
                   source_content_hash, spans_payload, created_at
            FROM lyrics_timing_versions
            WHERE lyrics_version_id = ? AND source_content_hash = ?
            ORDER BY (id = ?) DESC, created_at DESC;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(lyricsVersionID.uuidString, at: 1, to: statement)
        try bindText(sourceContentHash, at: 2, to: statement)

        try bindText(UserDefaults.lyricsQ.string(forKey: timingSelectionKey(lyricsVersionID)) ?? "", at: 3, to: statement)

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
            guard let rows = DocumentTimingPayload.decodeRows(payload),
                  LyricsTimingCompatibility.validatedTimingMap(rows.mapValues { ($0.performerID, $0.spans) }, for: document) != nil else {
                continue
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let record = DatabaseLyricsTimingVersionRecord(
                id: id,
                lyricsVersionID: versionID,
                source: source,
                granularity: granularity,
                sourceContentHash: hash,
                spansPayload: payload,
                createdAt: createdAt
            )
            return (record, rows)
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

    /// Continue from the file's viewed language without changing any playback selection.
    func continueFiledLyricReading(_ target: LibraryPassageTarget, file: LocalLyricsFile,
                                   position: LibraryPassageTarget.ReadingPosition) throws -> LibraryPassageTarget {
        var continued = target
        continued.readingPosition = position
        let text = file.lines.map { $0.translationText ?? "" }
        guard case let .original(id) = target.source, text.contains(where: { !$0.isEmpty }) else { return continued }

        try ensurePrepared()
        guard let original = try fetchLyricsVersion(versionID: id),
              try resolvedCanonicalStableKey(original.trackStableKey) == resolvedCanonicalStableKey(target.trackKey) else {
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        let language = file.initialTranslationLanguage ?? "und"
        let sourceHash = LyricsPersistenceMapper.sourceContentHash(document: file.content)
        let versions = try loadTranslationVersions(lyricsVersionID: id, targetLanguage: language, sourceContentHash: sourceHash)
        if let match = versions.first(where: {
            $0.isComplete && $0.isEmbeddedTranslation && $0.record.targetLanguage == language && $0.lines.map(\.translatedText) == text
        }) {
            continued.source = .translation(match.record.id)
        }
        return continued
    }

    /// Returns tracks that have user local assets:
    /// - Manually edited or locally imported lyrics (`is_manually_edited = 1` or `source = 'local'` or `source = 'manual'`)
    /// - User locked lyrics version (`is_locked = 1`)
    /// - Adopted or locked translation versions (`is_locked = 1` or `is_manually_edited = 1` or active complete translation)
    /// - Saved reading versions (`reading_versions` attached to lyrics)
    /// - Saved fine timing versions (`lyrics_timing_versions` attached to lyrics)
    public func loadPersonalLibraryEntries(searchQuery: String? = nil, includeMissingLyrics: Bool = false) throws -> [PersonalLyricsLibraryEntry] {
        try prepare()
        let searchText = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !searchText.isEmpty {
            let saved = try searchCachedLibrary(searchText)
            guard includeMissingLyrics else { return saved }
            let needle = Self.normalizedLibrarySearchText(searchText)
            let all = try loadPersonalLibraryEntries(includeMissingLyrics: true)
            let missing = all.filter {
                $0.lyricsVersionCount == 0 && Self.normalizedLibrarySearchText("\($0.title) \($0.artist) \($0.album ?? "")").contains(needle)
            }
            return PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere(saved, among: all) + missing
        }
        // Newly saved keys must join their recording family without a restart.
        try reloadRedirectResolver()
        let statement = try prepare("""
            SELECT stable_key FROM tracks AS t
            WHERE \(includeMissingLyrics ? "1" : "EXISTS (SELECT 1 FROM lyrics_versions WHERE track_stable_key = t.stable_key)")
            ORDER BY stable_key;
            """)
        defer { sqlite3_finalize(statement) }
        var seen = Set<String>()
        var results: [PersonalLyricsLibraryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, index: 0) else { continue }
            let canonical = try resolvedCanonicalStableKey(key)
            guard seen.insert(canonical).inserted,
                  let track = try fetchTrack(stableKey: canonical) else { continue }
            results.append(try compileLibraryEntry(
                stableKey: canonical, spotifyID: track.spotifyID, spotifyURI: track.spotifyURI,
                isrc: track.isrc, title: track.title, artist: track.artistDisplay, album: track.album,
                duration: track.duration, artworkURL: track.artworkURL.flatMap(URL.init(string:)), fallbackDate: track.updatedAt
            ))
        }
        if includeMissingLyrics {
            results = PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere(results, among: results)
        }
        return results.sorted {
            if $0.lastModifiedAt != $1.lastModifiedAt { return $0.lastModifiedAt > $1.lastModifiedAt }
            return $0.trackStableKey < $1.trackStableKey
        }
    }

    private static func normalizedLibrarySearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    private func searchCachedLibrary(_ query: String) throws -> [PersonalLyricsLibraryEntry] {
        try refreshLibrarySearchCache()
        let needle = Data(Self.normalizedLibrarySearchText(query).utf8)
        return librarySearchCache.values.filter { song in
            song.versions.values.contains { $0.normalized.range(of: needle) != nil }
        }.map(\.entry).sorted {
            if $0.lastModifiedAt != $1.lastModifiedAt { return $0.lastModifiedAt > $1.lastModifiedAt }
            return $0.trackStableKey < $1.trackStableKey
        }
    }

    /// Reuse the version index so opening a text match can identify its exact source.
    func searchLibraryPassages(_ query: String, includeExcerpt: Bool = true) throws -> [LibraryPassageHit] {
        try prepare()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        try refreshLibrarySearchCache()
        let needle = Data(Self.normalizedLibrarySearchText(term).utf8)
        return librarySearchCache.values.compactMap { song in
            let metadata = song.versions["metadata"]?.normalized.range(of: needle) != nil
            guard let match = passageComponent(in: song, matching: needle) else {
                return metadata ? LibraryPassageHit(entry: song.entry, source: nil, excerpt: nil, matchesMetadata: true) : nil
            }
            let excerpt = includeExcerpt ? match.text.original.split { $0 == "\0" || $0.isNewline }.first {
                $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            } : nil
            return LibraryPassageHit(entry: song.entry, source: match.source, excerpt: excerpt.map(String.init), matchesMetadata: metadata)
        }.sorted {
            if $0.entry.lastModifiedAt != $1.entry.lastModifiedAt { return $0.entry.lastModifiedAt > $1.entry.lastModifiedAt }
            return $0.id < $1.id
        }
    }

    private func passageComponent(in song: SearchSong, matching needle: Data) -> (source: LibraryPassageSource, text: SearchVersionText)? {
        var best: (rank: Int, key: String, source: LibraryPassageSource, text: SearchVersionText)?
        for (key, text) in song.versions where text.normalized.range(of: needle) != nil {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { continue }
            let rank: Int
            let source: LibraryPassageSource
            switch parts[0] {
            case "lyrics":
                source = .original(id)
                rank = id == song.entry.activeLyricsVersionID ? 0 : 3
            case "attached":
                source = .attached(id)
                rank = id == song.entry.activeLyricsVersionID ? 6 : 7
            case "translation":
                source = .translation(id)
                rank = id == song.entry.activeTranslationVersionID ? 1 : 4
            case "reading":
                source = .reading(id)
                rank = song.entry.activeReadingVersionIDs.values.contains(id) ? 2 : 5
            default: continue
            }
            if let best, (best.rank, best.key) <= (rank, key) { continue }
            best = (rank, key, source, text)
        }
        return best.map { ($0.source, $0.text) }
    }

    /// Reading a historical version never changes the adopted lyrics or playback.
    func readLibraryPassage(_ target: LibraryPassageTarget, includeEditions: Bool = false) throws -> LibraryPassagePage? {
        guard let detail = try loadPersonalLibraryTrackDetail(stableKey: target.trackKey),
              var page = try readLibraryPassage(target, from: detail) else { return nil }
        if includeEditions { page.editions = detail.readingEditions }
        return page
    }

    func readPassagePair(trackKey: String, base: LibraryPassageSource, reference: LibraryPassageSource) throws -> (LibraryPassagePage, LibraryPassagePage)? {
        guard let detail = try loadPersonalLibraryTrackDetail(stableKey: trackKey),
              let first = try readLibraryPassage(.init(trackKey: trackKey, source: base), from: detail),
              let second = try readLibraryPassage(.init(trackKey: trackKey, source: reference), from: detail) else { return nil }
        return (first, second)
    }

    private func readLibraryPassage(_ target: LibraryPassageTarget, from detail: PersonalLyricsLibraryTrackDetail) throws -> LibraryPassagePage? {
        let entry = detail.entry
        var source = target.source
        // Old kept lines have only the recording and text. Locate the stored
        // version that contains the quote even if a newer version is adopted.
        if source == .selected, !target.find.isEmpty {
            try refreshLibrarySearchCache()
            let needle = Data(Self.normalizedLibrarySearchText(target.find).utf8)
            if let song = librarySearchCache[entry.trackStableKey], let match = passageComponent(in: song, matching: needle) {
                source = match.source
            }
        }
        var lyricsID: UUID?
        var translation: PersonalTranslationVersionItem?
        var reading: PersonalReadingVersionItem?
        switch source {
        case .selected:
            lyricsID = entry.activeLyricsVersionID ?? detail.lyricsVersions.max(by: { $0.updatedAt < $1.updatedAt })?.id
        case let .original(id), let .attached(id): lyricsID = id
        case let .translation(id):
            let savedOriginalID = target.savedQuote?.originalVersionID
            translation = detail.translationVersions.first {
                $0.id == id && (savedOriginalID == nil || $0.lyricsVersionID == savedOriginalID)
            }
            lyricsID = translation?.lyricsVersionID ?? savedOriginalID
        case let .reading(id):
            reading = detail.readingVersions.first { $0.id == id }
            lyricsID = reading?.lyricsVersionID
        }
        guard let lyricsID, let version = detail.lyricsVersions.first(where: { $0.id == lyricsID }) else { return nil }
        let originals = try fetchLines(versionID: lyricsID)
        guard !originals.isEmpty else { return nil }
        let hash = LyricsSourceContentHasher.hash(isSynchronized: version.isSynced, lines: originals)
        let attached = source == .attached(lyricsID)
        if !attached && translation == nil && target.savedQuote == nil {
            translation = detail.translationVersions.first { $0.lyricsVersionID == lyricsID && $0.id == entry.activeTranslationVersionID }
        }
        var translated: [Int: String] = [:]
        var hasStoredTranslation = false
        var pronunciation: [Int: String] = [:]
        var romanization: [Int: String] = [:]
        var edition = attached ? "原词自带的译文与读音" : (version.isCurrent ? "当前原词" : "已保存的原词")
        if let translation {
            let valid = try loadTranslationVersions(lyricsVersionID: lyricsID, targetLanguage: translation.targetLanguage,
                                                    sourceContentHash: hash).first { $0.record.id == translation.id }
            if let valid {
                hasStoredTranslation = true
                for line in valid.lines { translated[line.lineIndex] = line.translatedText }
                if case .translation = source { edition = "已保存的译文" }
            } else if case .translation = source, target.savedQuote == nil {
                let lines = try fetchTranslationLines(versionID: translation.id).map {
                    LibraryPassagePage.Line(id: $0.lineIndex, original: "", translation: $0.translatedText)
                }
                return LibraryPassagePage(entry: entry, originalVersionID: lyricsID, edition: "历史译文 · 单独阅读", lines: lines,
                                          matchesOriginalVersion: false, translationLanguage: translation.targetLanguage,
                                          translationSource: translation.sourceKind, translationLocked: translation.isLocked,
                                          translationVersionID: translation.id, resolvedSource: source)
            }
        }
        if let reading {
            let rows = try fetchReadingLines(versionID: reading.id)
            if try fetchReadingVersion(versionID: reading.id)?.sourceContentHash != hash {
                let lines = rows.map { LibraryPassagePage.Line(id: $0.lineIndex, original: $0.originalText, reading: $0.readingText) }
                return LibraryPassagePage(entry: entry, originalVersionID: lyricsID, edition: "历史读音 · 单独阅读", lines: lines,
                                          matchesOriginalVersion: false, resolvedSource: source)
            }
            for line in rows {
                pronunciation[line.lineIndex] = line.readingText
                if reading.representationID == ReadingRepresentationID.romaji.rawValue { romanization[line.lineIndex] = line.readingText }
            }
            edition = "已保存的读音"
        } else {
            for line in originals { romanization[line.lineIndex] = line.romajiText }
            var lockedLegacyLines: Set<Int> = []
            for layer in try fetchReadingLayers(versionID: lyricsID) {
                if let value = layer.romajiText { romanization[layer.lineIndex] = value }
                let text = [layer.kanaText, layer.romajiText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !text.isEmpty {
                    pronunciation[layer.lineIndex] = text
                    if layer.isLocked { lockedLegacyLines.insert(layer.lineIndex) }
                }
            }
            // Versioned readings are separate assets from the legacy kana/romaji columns.
            // Follow the same choices as the song archive, including locked versions.
            let selectedReadings = detail.readingVersions.filter {
                !attached && $0.lyricsVersionID == lyricsID && entry.activeReadingVersionIDs[$0.representationID] == $0.id
            }.sorted { $0.representationID < $1.representationID }
            var parts: [Int: [String]] = [:]
            for item in selectedReadings {
                guard try fetchReadingVersion(versionID: item.id)?.sourceContentHash == hash else { continue }
                for row in try fetchReadingLines(versionID: item.id) {
                    if item.representationID == ReadingRepresentationID.romaji.rawValue, !lockedLegacyLines.contains(row.lineIndex) {
                        romanization[row.lineIndex] = row.readingText
                    }
                    guard let value = row.readingText, !value.isEmpty,
                          parts[row.lineIndex]?.contains(value) != true else { continue }
                    parts[row.lineIndex, default: []].append(value)
                }
            }
            for (index, values) in parts where !lockedLegacyLines.contains(index) {
                pronunciation[index] = values.joined(separator: " · ")
            }
        }
        var timing: [Int: LineTimingPayload] = [:]
        if detail.timingVersions.contains(where: { $0.lyricsVersionID == lyricsID }),
           let stored = try fetchLyricsVersion(versionID: lyricsID) {
            let track = entry.libraryTrack
            let base = Self.documentForTimingValidation(identity: TrackIdentity(track: track), track: track, version: stored, lines: originals)
            timing = try fetchBestTimingVersion(lyricsVersionID: lyricsID, sourceContentHash: hash, document: base)?.rows ?? [:]
        }
        let quoteIndex: Int? = target.savedQuote.flatMap { quote in
            if quote.originalVersionID == lyricsID, let index = target.lineIndex,
               originals.contains(where: { $0.lineIndex == index }) { return index }
            return originals.first {
                $0.originalText.trimmingCharacters(in: .whitespacesAndNewlines) == target.find
            }?.lineIndex
        }
        if quoteIndex != nil, !hasStoredTranslation, target.savedQuote?.translation != nil {
            edition = "收藏时的译文"
        }
        let lines = originals.map { line in
            let embedded = [line.kanaText, line.romajiText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return LibraryPassagePage.Line(id: line.lineIndex, original: line.originalText,
                     translation: line.lineIndex == quoteIndex ? target.savedQuote?.translation
                        : (hasStoredTranslation ? translated[line.lineIndex] : line.translationText),
                     reading: pronunciation[line.lineIndex] ?? (embedded.isEmpty ? nil : embedded),
                     background: timing[line.lineIndex]?.backgroundText ?? line.backgroundText, startTime: line.startTime,
                     endTime: line.endTime, timedSpans: timing[line.lineIndex]?.spans,
                     performerID: timing[line.lineIndex]?.performerID ?? line.performerID,
                     romanization: romanization[line.lineIndex])
        }
        return LibraryPassagePage(entry: entry, originalVersionID: lyricsID, edition: edition, lines: lines,
                                  language: version.language, originalSource: version.source, originalLocked: version.isLocked,
                                  translationLanguage: hasStoredTranslation ? translation?.targetLanguage : nil,
                                  translationSource: hasStoredTranslation ? translation?.sourceKind ?? "" : "legacyEmbedded",
                                  translationLocked: hasStoredTranslation && translation?.isLocked == true,
                                  translationVersionID: hasStoredTranslation ? translation?.id : nil,
                                  resolvedSource: source == .selected ? .original(lyricsID) : source)
    }

    /// SQLite's change counters include other repository connections. Only a
    /// changed song reloads its text; unchanged versions keep their normalization.
    private func refreshLibrarySearchCache() throws {
        let version = try prepare("PRAGMA data_version;")
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW else { throw lastError() }
        let dataVersion = sqlite3_column_int(version, 0)
        let totalChanges = sqlite3_total_changes(database)
        guard dataVersion != librarySearchDataVersion || totalChanges != librarySearchTotalChanges else { return }
        try reloadRedirectResolver()
        let stamps = try prepare("""
            SELECT stable_key, 'metadata', title || char(31) || artist_display || char(31) || album || char(31) ||
                COALESCE(spotify_id, '') || COALESCE(spotify_uri, '') || COALESCE(isrc, '') || updated_at FROM tracks
            UNION ALL SELECT track_stable_key, 'alias:' || field || ':' || kind || ':' || value, value FROM track_aliases
            UNION ALL SELECT track_stable_key, 'lyrics:' || id,
                content_hash || ':' || updated_at || ':' || is_preferred || ':' || is_locked || ':' || is_manually_edited FROM lyrics_versions
            UNION ALL SELECT lv.track_stable_key, 'translation:' || tv.id,
                tv.updated_at || ':' || tv.is_archived || ':' || tv.is_draft || ':' || tv.is_locked
                FROM translation_versions tv JOIN lyrics_versions lv ON lv.id = tv.lyrics_version_id
            UNION ALL SELECT lv.track_stable_key, 'reading:' || rv.id,
                rv.updated_at || ':' || rv.is_current || ':' || rv.is_archived || ':' || rv.is_locked
                FROM reading_versions rv JOIN lyrics_versions lv ON lv.id = rv.lyrics_version_id
            UNION ALL SELECT lv.track_stable_key, 'legacy-reading:' || rl.lyrics_version_id || ':' || rl.line_index,
                COALESCE(rl.kana_text, '') || char(31) || COALESCE(rl.romaji_text, '')
                FROM lyric_reading_layers rl JOIN lyrics_versions lv ON lv.id = rl.lyrics_version_id
            UNION ALL SELECT lv.track_stable_key, 'timing:' || tm.id, tm.created_at
                FROM lyrics_timing_versions tm JOIN lyrics_versions lv ON lv.id = tm.lyrics_version_id
            UNION ALL SELECT track_stable_key, 'revoked', revoked_version_id FROM lyrics_selection_revocations;
            """)
        defer { sqlite3_finalize(stamps) }
        var signatures: [String: [String: String]] = [:]
        while sqlite3_step(stamps) == SQLITE_ROW {
            guard let key = columnText(stamps, index: 0), let component = columnText(stamps, index: 1) else { continue }
            let canonical = try resolvedCanonicalStableKey(key)
            signatures[canonical, default: [:]][component + ":" + key] = columnText(stamps, index: 2) ?? ""
        }
        for key in Array(librarySearchCache.keys) where signatures[key] == nil { librarySearchCache.removeValue(forKey: key) }
        for (key, signature) in signatures {
            guard librarySearchCache[key]?.signature != signature else { continue }
            guard signature.keys.contains(where: { $0.hasPrefix("lyrics:") }), let track = try fetchTrack(stableKey: key) else {
                librarySearchCache.removeValue(forKey: key)
                continue
            }
            let versions = try cachedSearchVersions(stableKey: key, previous: librarySearchCache[key]?.versions ?? [:])
            let entry = try compileLibraryEntry(stableKey: key, spotifyID: track.spotifyID, spotifyURI: track.spotifyURI,
                isrc: track.isrc, title: track.title, artist: track.artistDisplay, album: track.album,
                duration: track.duration, artworkURL: track.artworkURL.flatMap(URL.init(string:)), fallbackDate: track.updatedAt)
            librarySearchCache[key] = SearchSong(signature: signature, versions: versions, entry: entry)
        }
        librarySearchDataVersion = dataVersion
        librarySearchTotalChanges = totalChanges
    }

    private func cachedSearchVersions(stableKey: String, previous: [String: SearchVersionText]) throws -> [String: SearchVersionText] {
        let family = try resolvedIdentityFamily(stableKey: stableKey)
        let statement = try prepare("""
            WITH family AS (SELECT * FROM tracks WHERE stable_key IN (\(placeholders(count: family.count)))),
                 versions AS (SELECT * FROM lyrics_versions WHERE track_stable_key IN (SELECT stable_key FROM family))
            SELECT 'metadata', title || ' ' || artist_display || ' ' || album || ' ' || COALESCE(spotify_id, '') || ' ' || COALESCE(spotify_uri, '') || ' ' || COALESCE(isrc, '') AS text, 0 AS is_reading FROM family
            UNION ALL SELECT 'metadata', value, 0 FROM track_aliases WHERE track_stable_key IN (SELECT stable_key FROM family)
            UNION ALL SELECT 'lyrics:' || id, raw_text, 0 FROM versions
            UNION ALL SELECT 'lyrics:' || lyrics_version_id, original_text, 0 FROM lyric_lines WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT 'attached:' || lyrics_version_id, translation_text, 0 FROM lyric_lines WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT 'attached:' || lyrics_version_id, kana_text, 1 FROM lyric_lines WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT 'attached:' || lyrics_version_id, romaji_text, 1 FROM lyric_lines WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT 'attached:' || lyrics_version_id, COALESCE(kana_text, '') || ' ' || COALESCE(romaji_text, ''), 1
                FROM lyric_reading_layers WHERE lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT 'reading:' || rv.id, rl.reading_text, 1 FROM reading_lines rl JOIN reading_versions rv ON rv.id = rl.reading_version_id
                WHERE rv.lyrics_version_id IN (SELECT id FROM versions)
            UNION ALL SELECT 'translation:' || tv.id, tl.translated_text, 0 FROM translation_lines tl JOIN translation_versions tv ON tv.id = tl.translation_version_id
                WHERE tv.lyrics_version_id IN (SELECT id FROM versions);
            """)
        defer { sqlite3_finalize(statement) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: statement) }
        var originals: [String: [String]] = [:]
        var readings: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let component = columnText(statement, index: 0), let text = columnText(statement, index: 1), !text.isEmpty else { continue }
            originals[component, default: []].append(text)
            if sqlite3_column_int(statement, 2) == 1 { readings[component, default: []].append(text) }
        }
        var result: [String: SearchVersionText] = [:]
        for (component, parts) in originals {
            let original = parts.joined(separator: "\0")
            let reading = (readings[component] ?? []).joined(separator: "\0")
            if let old = previous[component], old.original == original, old.reading == reading {
                result[component] = old
            } else {
                let normalized = Self.normalizedLibrarySearchText(original + "\0" + JapaneseRomanizer.romanizeConfirmedKana(reading))
                result[component] = SearchVersionText(original: original, reading: reading, normalized: Data(normalized.utf8))
#if DEBUG
                librarySearchNormalizationCounts[stableKey, default: 0] += 1
#endif
            }
        }
        return result
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
            SELECT id, is_manually_edited, is_locked, confidence, updated_at, source, is_synced
            FROM lyrics_versions
            WHERE track_stable_key IN (\(placeholders(count: family.count)))
            ORDER BY is_preferred DESC, is_locked DESC, confidence DESC, updated_at DESC;
            """)
        defer { sqlite3_finalize(lyricsStmt) }
        for (index, key) in family.enumerated() { try bindText(key, at: Int32(index + 1), to: lyricsStmt) }

        var lyricsVersionCount = 0
        var hasSyncedLyrics = false
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
            if sqlite3_column_int(lyricsStmt, 6) == 1 { hasSyncedLyrics = true }

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
                SELECT id, is_locked, is_manually_edited, is_archived, status, updated_at, lyrics_version_id, is_draft
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
                let isDraft = sqlite3_column_int(transStmt, 7) == 1

                if isLocked { hasLockedTranslation = true }
                if isManual { hasManualTranslation = true }
                if activeTranslationVersionID == nil && !isArchived && !isDraft && (status == "complete" || isLocked) {
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
            activeTimingVersionID: activeTimingVersionID,
            hasSyncedLyrics: hasSyncedLyrics
        )
    }

    // MARK: - Track Detail Query

    public func loadPersonalLibraryTrackDetail(stableKey: String) throws -> PersonalLyricsLibraryTrackDetail? {
        try prepare()
        try reloadRedirectResolver()
        guard let track = try archiveTrack(stableKey: stableKey) else { return nil }
        let stableKey = track.stableKey
        let family = try resolvedIdentityFamily(stableKey: stableKey)

        let entry = try compileLibraryEntry(
            stableKey: stableKey,
            spotifyID: track.spotifyID,
            spotifyURI: track.spotifyURI,
            isrc: track.isrc,
            title: track.title,
            artist: track.artistDisplay,
            album: track.album,
            duration: track.duration,
            artworkURL: track.artworkURL.flatMap(URL.init(string:)),
            fallbackDate: track.updatedAt
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
                       (SELECT COUNT(*) FROM translation_lines WHERE translation_version_id = tv.id), tv.is_draft
                FROM translation_versions AS tv
                WHERE tv.lyrics_version_id IN (\(idPlaceholders))
                ORDER BY tv.is_locked DESC, tv.is_archived ASC, tv.updated_at DESC;
                """)
            defer { sqlite3_finalize(transStmt) }
            for (idx, id) in lyricsVersionIDs.enumerated() {
                try bindText(id.uuidString, at: Int32(idx + 1), to: transStmt)
            }

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

                let isDraft = sqlite3_column_int(transStmt, 15) == 1

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
                    isCurrent: id == entry.activeTranslationVersionID,
                    status: status,
                    confidence: confidence,
                    engineID: engineID,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    draft: isDraft ? true : nil
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

            var seenTimingLyrics = Set<UUID>()
            while sqlite3_step(timeStmt) == SQLITE_ROW {
                guard let idText = columnText(timeStmt, index: 0),
                      let id = UUID(uuidString: idText),
                      let lvidText = columnText(timeStmt, index: 1),
                      let lvid = UUID(uuidString: lvidText) else { continue }
                let source = columnText(timeStmt, index: 2) ?? ""
                let granularity = columnText(timeStmt, index: 3) ?? "timedUnit"
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(timeStmt, 4))

                let firstForLyrics = seenTimingLyrics.insert(lvid).inserted
                let selected = UserDefaults.lyricsQ.string(forKey: timingSelectionKey(lvid))
                let isCurrent = lyricsItems.first(where: { $0.id == lvid })?.isCurrent == true
                    && (selected.map { $0 == id.uuidString } ?? firstForLyrics)

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

            let lines = try fetchLines(versionID: id).map { line in
                PersonalLyricsLibraryPackage.PackageLyricLine(
                    lineIndex: line.lineIndex, startTime: line.startTime, endTime: line.endTime,
                    originalText: line.originalText, kanaText: line.kanaText, romajiText: line.romajiText,
                    translationText: line.translationText, performerID: line.performerID, backgroundText: line.backgroundText
                )
            }

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
        try reloadRedirectResolver()
        return try previewTrackImport(package, family: resolvedIdentityFamily(stableKey: package.track.stableKey))
    }

    private func previewTrackImport(_ package: PersonalLyricsLibraryPackage, family: [String]) throws -> PersonalLibraryImportPreview {
        let packagedLyrics = Set(package.lyricsVersions.map(\.id))
        func containsLyrics(_ id: UUID) throws -> Bool {
            if packagedLyrics.contains(id) { return true }
            guard let existing = try fetchLyricsVersion(versionID: id) else { return false }
            return family.contains(existing.trackStableKey)
        }
        var lyricsToAdd = 0
        var lyricsToSkip = 0
        var lyricsConflicts: [String] = []
        if let preferred = package.preferredLyricsVersionID, !packagedLyrics.contains(preferred) {
            lyricsConflicts.append("资产包采用的原词不存在")
        }

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
            guard family.contains(lv.trackStableKey) else {
                lyricsConflicts.append("原词 \(lv.id) 属于另一首歌")
                continue
            }
            let checkStmt = try prepare("SELECT content_hash, track_stable_key FROM lyrics_versions WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(checkStmt) }
            try bindText(lv.id.uuidString, at: 1, to: checkStmt)
            switch sqlite3_step(checkStmt) {
            case SQLITE_ROW:
                let existingHash = columnText(checkStmt, index: 0) ?? ""
                if columnText(checkStmt, index: 1).map(family.contains) != true {
                    lyricsConflicts.append("原词 \(lv.id) 已属于另一首歌")
                } else if existingHash == lv.contentHash {
                    lyricsToSkip += 1
                } else {
                    lyricsConflicts.append("Lyrics version \(lv.id) exists with differing content hash")
                }
            case SQLITE_DONE: lyricsToAdd += 1
            default: throw lastError()
            }
        }

        for tv in package.translationVersions {
            guard try containsLyrics(tv.lyricsVersionID) else {
                translationsConflicts.append("译文 \(tv.id) 的原词不在这首歌里")
                continue
            }
            let checkStmt = try prepare("SELECT source_content_hash, lyrics_version_id FROM translation_versions WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(checkStmt) }
            try bindText(tv.id.uuidString, at: 1, to: checkStmt)
            switch sqlite3_step(checkStmt) {
            case SQLITE_ROW:
                let existingHash = columnText(checkStmt, index: 0) ?? ""
                if columnText(checkStmt, index: 1) != tv.lyricsVersionID.uuidString {
                    translationsConflicts.append("译文 \(tv.id) 已属于另一份原词")
                } else if existingHash == tv.sourceContentHash {
                    translationsToSkip += 1
                } else {
                    translationsConflicts.append("Translation version \(tv.id) exists with differing content hash")
                }
            case SQLITE_DONE: translationsToAdd += 1
            default: throw lastError()
            }
        }

        for rv in package.readingVersions {
            guard try containsLyrics(rv.lyricsVersionID) else {
                readingsConflicts.append("读音 \(rv.id) 的原词不在这首歌里")
                continue
            }
            let checkStmt = try prepare("SELECT source_content_hash, lyrics_version_id FROM reading_versions WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(checkStmt) }
            try bindText(rv.id.uuidString, at: 1, to: checkStmt)
            switch sqlite3_step(checkStmt) {
            case SQLITE_ROW:
                let existingHash = columnText(checkStmt, index: 0) ?? ""
                if columnText(checkStmt, index: 1) != rv.lyricsVersionID.uuidString {
                    readingsConflicts.append("读音 \(rv.id) 已属于另一份原词")
                } else if existingHash == rv.sourceContentHash {
                    readingsToSkip += 1
                } else {
                    readingsConflicts.append("Reading version \(rv.id) (\(rv.representationID)) exists with differing content hash")
                }
            case SQLITE_DONE: readingsToAdd += 1
            default: throw lastError()
            }
        }

        for tv in package.timingVersions {
            guard try containsLyrics(tv.lyricsVersionID) else {
                timingsConflicts.append("时间轴 \(tv.id) 的原词不在这首歌里")
                continue
            }
            let checkStmt = try prepare("SELECT spans_payload, lyrics_version_id FROM lyrics_timing_versions WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(checkStmt) }
            try bindText(tv.id.uuidString, at: 1, to: checkStmt)
            switch sqlite3_step(checkStmt) {
            case SQLITE_ROW:
                let existingPayload = columnText(checkStmt, index: 0) ?? ""
                if columnText(checkStmt, index: 1) != tv.lyricsVersionID.uuidString {
                    timingsConflicts.append("时间轴 \(tv.id) 已属于另一份原词")
                } else if existingPayload == tv.spansPayload {
                    timingsToSkip += 1
                } else {
                    timingsConflicts.append("Timing version \(tv.id) exists with differing payload")
                }
            case SQLITE_DONE: timingsToAdd += 1
            default: throw lastError()
            }
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
        try prepare()
        try reloadRedirectResolver()
        let previews = try package.tracks.map { try previewTrackImport($0, family: resolvedIdentityFamily(stableKey: $0.track.stableKey)) }
        return PersonalDataImportPreview(trackPreviews: previews)
    }

    public func importPersonalDataPackage(_ package: PersonalDataPackage) throws {
        try package.validate()
        guard !package.tracks.isEmpty else { return }
        try prepare()
        try withTransaction {
            try reloadRedirectResolver()
            for trackPackage in package.tracks { try applyTrackImport(trackPackage) }
        }
    }

    // MARK: - Execute Import Package

    public func importPersonalLibraryPackage(_ package: PersonalLyricsLibraryPackage) throws {
        try prepare()
        try withTransaction {
            try reloadRedirectResolver()
            try applyTrackImport(package)
        }
    }

    private func applyTrackImport(_ package: PersonalLyricsLibraryPackage) throws {
        let preferenceFamily = try resolvedIdentityFamily(stableKey: package.track.stableKey)
        let preferenceQuery = try prepare("SELECT COUNT(*) FROM lyrics_versions WHERE track_stable_key IN (\(placeholders(count: preferenceFamily.count))) AND is_preferred = 1;")
        defer { sqlite3_finalize(preferenceQuery) }
        for (index, key) in preferenceFamily.enumerated() { try bindText(key, at: Int32(index + 1), to: preferenceQuery) }
        guard sqlite3_step(preferenceQuery) == SQLITE_ROW else { throw lastError() }
        let hasLocalPreference = sqlite3_column_int(preferenceQuery, 0) > 0
        guard sqlite3_step(preferenceQuery) == SQLITE_DONE else { throw lastError() }

        let preview = try previewTrackImport(package, family: preferenceFamily)
        guard !preview.hasConflicts else {
            throw LyricsRepositoryError.dataIntegrityViolation("「\(package.track.title)」存在冲突版本：\(preview.allConflicts.joined(separator: "、"))")
        }

        let targetStableKey = preferenceFamily[0]
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
            defer { sqlite3_finalize(lvInsert) }
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

            for line in lv.lines {
                let lineInsert = try prepare("""
                    INSERT OR IGNORE INTO lyric_lines(
                        lyrics_version_id, line_index, start_time, end_time,
                        original_text, kana_text, romaji_text, translation_text, performer_id, background_text
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(lyrics_version_id, line_index) DO UPDATE SET
                        performer_id = COALESCE(lyric_lines.performer_id, excluded.performer_id),
                        background_text = COALESCE(lyric_lines.background_text, excluded.background_text)
                    WHERE lyric_lines.original_text = excluded.original_text
                      AND ((lyric_lines.performer_id IS NULL AND excluded.performer_id IS NOT NULL)
                        OR (lyric_lines.background_text IS NULL AND excluded.background_text IS NOT NULL));
                    """)
                defer { sqlite3_finalize(lineInsert) }
                try bindText(lv.id.uuidString, at: 1, to: lineInsert)
                try bindInt(line.lineIndex, at: 2, to: lineInsert)
                if let st = line.startTime { try bindDouble(st, at: 3, to: lineInsert) } else { sqlite3_bind_null(lineInsert, 3) }
                if let et = line.endTime { try bindDouble(et, at: 4, to: lineInsert) } else { sqlite3_bind_null(lineInsert, 4) }
                try bindText(line.originalText, at: 5, to: lineInsert)
                try bindText(line.kanaText, at: 6, to: lineInsert)
                try bindText(line.romajiText, at: 7, to: lineInsert)
                try bindText(line.translationText, at: 8, to: lineInsert)
                try bindText(line.performerID, at: 9, to: lineInsert)
                try bindText(line.backgroundText, at: 10, to: lineInsert)
                try stepDone(lineInsert)
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
            defer { sqlite3_finalize(tvInsert) }
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

            for line in tv.lines {
                let tlInsert = try prepare("INSERT OR IGNORE INTO translation_lines(translation_version_id, line_index, translated_text) VALUES (?, ?, ?);")
                defer { sqlite3_finalize(tlInsert) }
                try bindText(tv.id.uuidString, at: 1, to: tlInsert)
                try bindInt(line.lineIndex, at: 2, to: tlInsert)
                try bindText(line.translatedText, at: 3, to: tlInsert)
                try stepDone(tlInsert)
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
            defer { sqlite3_finalize(rvInsert) }
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

            for line in rv.lines {
                let rlInsert = try prepare("""
                    INSERT OR IGNORE INTO reading_lines(
                        reading_version_id, line_index, original_text, reading_text,
                        tokens_json, language, source
                    ) VALUES (?, ?, ?, ?, ?, ?, ?);
                    """)
                defer { sqlite3_finalize(rlInsert) }
                try bindText(rv.id.uuidString, at: 1, to: rlInsert)
                try bindInt(line.lineIndex, at: 2, to: rlInsert)
                try bindText(line.originalText, at: 3, to: rlInsert)
                try bindText(line.readingText, at: 4, to: rlInsert)
                try bindText(line.tokensJSON, at: 5, to: rlInsert)
                try bindText(line.language, at: 6, to: rlInsert)
                try bindText(line.source, at: 7, to: rlInsert)
                try stepDone(rlInsert)
            }
        }

        for tv in package.timingVersions {
            let timeInsert = try prepare("""
                INSERT OR IGNORE INTO lyrics_timing_versions(
                    id, lyrics_version_id, source, granularity,
                    source_content_hash, spans_payload, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(timeInsert) }
            try bindText(tv.id.uuidString, at: 1, to: timeInsert)
            try bindText(tv.lyricsVersionID.uuidString, at: 2, to: timeInsert)
            try bindText(tv.source, at: 3, to: timeInsert)
            try bindText(tv.granularity, at: 4, to: timeInsert)
            try bindText(tv.sourceContentHash, at: 5, to: timeInsert)
            try bindText(tv.spansPayload, at: 6, to: timeInsert)
            try bindDouble(tv.createdAt.timeIntervalSince1970, at: 7, to: timeInsert)
            try stepDone(timeInsert)
        }

        if !hasLocalPreference, let preferred = package.preferredLyricsVersionID {
            try setPreferredLyricsVersion(trackStableKey: package.track.stableKey, lyricsVersionID: preferred)
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
        if let track = try fetchTrack(stableKey: version.trackStableKey), let id = track.spotifyID {
            let bareID = TrackIdentity.canonicalSpotifyTrackID(id) ?? id.lowercased()
            let uri = TrackIdentity.canonicalSpotifyURI(id) ?? id.lowercased()
            let clearRecording = try prepare("""
                UPDATE lyrics_versions SET is_preferred = 0 WHERE track_stable_key IN
                (SELECT stable_key FROM tracks WHERE lower(spotify_id) IN (?, ?) OR lower(spotify_uri) = ?);
                """)
            defer { sqlite3_finalize(clearRecording) }
            try bindText(bareID, at: 1, to: clearRecording)
            try bindText(uri, at: 2, to: clearRecording)
            try bindText(uri, at: 3, to: clearRecording)
            try stepDone(clearRecording)
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
