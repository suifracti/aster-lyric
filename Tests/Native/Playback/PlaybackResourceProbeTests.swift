import Darwin
import Foundation
import XCTest
@testable import SpotifyLyrics

private struct PlaybackProbeSample: Codable {
    let elapsedSeconds: Double
    let intervalWallSeconds: Double?
    let intervalCPUSeconds: Double?
    let cpuPercent: Double?
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let residentBytes: UInt64
}

private struct PlaybackProbeReport: Codable {
    let schema: String
    let trackTitle: String
    let trackIdentity: String
    let warmupSeconds: Double
    let measurementSeconds: Double
    let samplingIntervalSeconds: Double
    let refreshCount: Int
    let refreshCountDuringMeasurement: Int
    let playerCommandCount: Int
    let lyricsProviderCalls: Int
    let cacheHit: Bool
    let cachedLyricsLineCount: Int
    let averageCPUPercent: Double
    let startResidentBytes: UInt64
    let endResidentBytes: UInt64
    let peakResidentBytes: UInt64
    let samples: [PlaybackProbeSample]
}

private struct PlaybackProbeResourceReading {
    let uptime: TimeInterval
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let residentBytes: UInt64

    var totalCPUSeconds: Double { userCPUSeconds + systemCPUSeconds }

    static func current() throws -> PlaybackProbeResourceReading {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw PlaybackProbeError.getrusage(errno)
        }
        let userCPU = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let systemCPU = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { pointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), pointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw PlaybackProbeError.machTaskInfo(result)
        }

        return PlaybackProbeResourceReading(
            uptime: ProcessInfo.processInfo.systemUptime,
            userCPUSeconds: userCPU,
            systemCPUSeconds: systemCPU,
            residentBytes: info.resident_size
        )
    }
}

private enum PlaybackProbeError: Error {
    case getrusage(Int32)
    case machTaskInfo(kern_return_t)
    case cacheDidNotLoad
    case invalidOutputPath
}

@MainActor
private final class PlaybackResourceProbeProvider: PlaybackProvider {
    let displayName = "Isolated fixed playback probe"
    private let track: ProviderTrack
    private let initialPosition: TimeInterval
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private(set) var refreshCount = 0
    private(set) var playerCommandCount = 0

    init(track: ProviderTrack, initialPosition: TimeInterval) {
        self.track = track
        self.initialPosition = initialPosition
    }

    func refresh() async -> PlaybackSnapshot {
        refreshCount += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        return PlaybackSnapshot(
            status: .ready,
            track: track,
            position: min(track.duration, initialPosition + elapsed),
            isPlaying: true,
            sourceIdentity: .spotifyDesktop
        )
    }

    func play() async throws { playerCommandCount += 1 }
    func pause() async throws { playerCommandCount += 1 }
    func previous() async throws { playerCommandCount += 1 }
    func next() async throws { playerCommandCount += 1 }
    func seek(to position: TimeInterval) async throws {
        _ = position
        playerCommandCount += 1
    }
}

private actor PlaybackProbeLyricsCallCounter {
    private var calls = 0

    func increment() { calls += 1 }
    func callCount() -> Int { calls }
}

private struct PlaybackProbeNoNetworkLyricsProvider: LyricsProvider {
    let counter: PlaybackProbeLyricsCallCounter
    let name = "Probe-only offline miss counter"
    let executionLane = LyricsProviderExecutionLane.local

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        _ = track
        _ = identity
        await counter.increment()
        return .noMatch
    }
}

@MainActor
final class PlaybackResourceProbeTests: XCTestCase {
    func testCachedPlaybackResourceProbe() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["LYRICSQ_PROBE_OUTPUT"],
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set LYRICSQ_PROBE_OUTPUT to opt in to the 32-second resource probe.")
        }
        guard ProcessInfo.processInfo.environment["LYRICSQ_NATIVE_TESTS"] == "1",
              ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1",
              ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] == nil else {
            throw XCTSkip("The resource probe only runs in the isolated native test host with Keychain disabled and no Spotify client ID.")
        }
        guard outputPath.hasPrefix("/") else { throw PlaybackProbeError.invalidOutputPath }

        let nativeDefaults = UserDefaults.lyricsQ
        nativeDefaults.removeObject(forKey: "spotify.clientID")
        nativeDefaults.set(false, forKey: AppSettingsStore.Key.automaticAlignmentEnabled)
        nativeDefaults.set(false, forKey: AppSettingsStore.Key.aiAutoTranslateNewLyrics)
        nativeDefaults.set(false, forKey: AppSettingsStore.Key.autoSearchLyricsOnTrackChange)

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyricsq-playback-resource-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let suiteName = "com.spotifylyrics.playback-resource-probe.\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settingsDefaults.set(false, forKey: AppSettingsStore.Key.connectSpotifyOnLaunch)
        settingsDefaults.set(PlaybackSourceMode.spotify.rawValue, forKey: AppSettingsStore.Key.playbackSourceMode)
        settingsDefaults.set(false, forKey: AppSettingsStore.Key.autoSearchLyricsOnTrackChange)
        settingsDefaults.set(false, forKey: AppSettingsStore.Key.automaticAlignmentEnabled)
        settingsDefaults.set(false, forKey: AppSettingsStore.Key.aiAutoTranslateNewLyrics)
        settingsDefaults.set(false, forKey: AppSettingsStore.Key.restoreWindowState)
        defer {
            settingsDefaults.removePersistentDomain(forName: suiteName)
        }

        let trackID = "spotify:track:lyricsq-resource-probe"
        let track = Track(
            id: trackID,
            title: "Playback Resource Probe",
            artist: "Isolated Fixture",
            album: "Native Probe",
            duration: 240,
            spotifyId: trackID
        )
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: (0..<64).map { index in
                LyricLine(timestamp: Double(index) * 3.5, originalText: "Probe lyric line \(index + 1)")
            },
            isSynchronized: true,
            source: .local,
            confidence: 1
        )
        let repository = SQLiteLyricsRepository(
            databaseURL: temporaryRoot.appendingPathComponent("lyrics.sqlite3"),
            alignmentProvenanceDirectory: temporaryRoot.appendingPathComponent("provenance", isDirectory: true)
        )
        try await repository.prepare()
        let saved = try await repository.save(track: track, identity: identity, document: document)
        let versionID = try XCTUnwrap(saved.versionID)
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey: identity.stableKey, lyricsVersionID: versionID)

        let provider = PlaybackResourceProbeProvider(
            track: ProviderTrack(
                id: trackID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration
            ),
            initialPosition: 24
        )
        let lyricsProviderCounter = PlaybackProbeLyricsCallCounter()
        let lyricsProvider = PlaybackProbeNoNetworkLyricsProvider(counter: lyricsProviderCounter)
        let settings = AppSettingsStore(defaults: settingsDefaults)
        settings.connectSpotifyOnLaunch = false
        settings.playbackSourceMode = .spotify
        settings.autoSearchLyricsOnTrackChange = false
        settings.automaticAlignmentEnabled = false
        var translationConfiguration = settings.aiTranslationConfiguration
        translationConfiguration.autoTranslateNewLyrics = false
        settings.aiTranslationConfiguration = translationConfiguration

        let playback = PlaybackState(
            provider: provider,
            lyricsProvider: lyricsProvider,
            lyricsRepository: repository,
            settings: settings
        )
        playback.startProvider(connectSpotify: true)

        let cacheDeadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < cacheDeadline {
            if playback.hasLiveTrack,
               playback.currentTrackIdentity == identity,
               playback.liveLyricsVersionID == versionID,
               playback.liveLyrics.count == document.lines.count {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let cacheHit = playback.hasLiveTrack
            && playback.currentTrackIdentity == identity
            && playback.liveLyricsVersionID == versionID
            && playback.liveLyrics.count == document.lines.count
        guard cacheHit else { throw PlaybackProbeError.cacheDidNotLoad }

        let warmupSeconds = 2.0
        let measurementSeconds = 30.0
        let samplingIntervalSeconds = 1.0
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let refreshCountAtMeasurementStart = provider.refreshCount
        var previous = try PlaybackProbeResourceReading.current()
        let measurementStart = previous.uptime
        var samples = [PlaybackProbeSample(
            elapsedSeconds: 0,
            intervalWallSeconds: nil,
            intervalCPUSeconds: nil,
            cpuPercent: nil,
            userCPUSeconds: previous.userCPUSeconds,
            systemCPUSeconds: previous.systemCPUSeconds,
            residentBytes: previous.residentBytes
        )]

        for sampleIndex in 1...30 {
            let deadline = measurementStart + Double(sampleIndex) * samplingIntervalSeconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                let sleepNanoseconds = UInt64(max(1_000_000, min(remaining, 0.05) * 1_000_000_000))
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            }

            let current = try PlaybackProbeResourceReading.current()
            let wallDelta = current.uptime - previous.uptime
            let cpuDelta = max(0, current.totalCPUSeconds - previous.totalCPUSeconds)
            samples.append(PlaybackProbeSample(
                elapsedSeconds: current.uptime - measurementStart,
                intervalWallSeconds: wallDelta,
                intervalCPUSeconds: cpuDelta,
                cpuPercent: wallDelta > 0 ? (cpuDelta / wallDelta) * 100 : nil,
                userCPUSeconds: current.userCPUSeconds,
                systemCPUSeconds: current.systemCPUSeconds,
                residentBytes: current.residentBytes
            ))
            previous = current
        }

        let measured = Array(samples.dropFirst())
        let actualMeasurementSeconds = samples.last?.elapsedSeconds ?? 0
        let cpuValues = measured.compactMap(\.cpuPercent)
        let rssValues = samples.map(\.residentBytes)
        let averageCPU = cpuValues.isEmpty ? 0 : cpuValues.reduce(0, +) / Double(cpuValues.count)
        let finalLyricsProviderCalls = await lyricsProviderCounter.callCount()
        let finalCacheHit = playback.liveLyricsVersionID == versionID
            && playback.liveLyrics.count == document.lines.count
        let report = PlaybackProbeReport(
            schema: "lyricsq-playback-resource-probe-v1",
            trackTitle: track.title,
            trackIdentity: identity.stableKey,
            warmupSeconds: warmupSeconds,
            measurementSeconds: actualMeasurementSeconds,
            samplingIntervalSeconds: samplingIntervalSeconds,
            refreshCount: provider.refreshCount,
            refreshCountDuringMeasurement: provider.refreshCount - refreshCountAtMeasurementStart,
            playerCommandCount: provider.playerCommandCount,
            lyricsProviderCalls: finalLyricsProviderCalls,
            cacheHit: finalCacheHit,
            cachedLyricsLineCount: finalCacheHit ? playback.liveLyrics.count : 0,
            averageCPUPercent: averageCPU,
            startResidentBytes: rssValues.first ?? 0,
            endResidentBytes: rssValues.last ?? 0,
            peakResidentBytes: rssValues.max() ?? 0,
            samples: samples
        )
        let reportData = try JSONEncoder.playbackProbeEncoder.encode(report)
        try reportData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

        XCTAssertEqual(samples.count, 31)
        XCTAssertEqual(provider.playerCommandCount, 0, "The fixed provider must never receive a control command.")
        XCTAssertEqual(finalLyricsProviderCalls, 0, "The preloaded cache must avoid every lyrics-provider lookup.")
        XCTAssertTrue(finalCacheHit, "The preloaded lyrics must remain the active cached version during measurement.")
        XCTAssertGreaterThan(provider.refreshCount - refreshCountAtMeasurementStart, 0)
        XCTAssertGreaterThanOrEqual(actualMeasurementSeconds, 29.5)
    }
}

private extension JSONEncoder {
    static var playbackProbeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
