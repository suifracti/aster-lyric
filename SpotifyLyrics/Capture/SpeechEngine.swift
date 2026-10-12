import Foundation

/// Stable identifiers for the speech engines available to alignment jobs.
public enum SpeechEngineID: String, Sendable, Equatable, CaseIterable {
    case apple = "speechEngine.apple.v1"
    case whisperCLI = "speechEngine.whisperCLI.experimental.v1"

    public var displayName: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisperCLI: return "Whisper CLI (experimental)"
        }
    }
}

/// Engine-agnostic timed speech piece for S3A/S3B consumption.
public struct SpeechEngineSegment: Equatable, Sendable {
    public let index: Int
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double?

    public init(
        index: Int,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.index = index
        self.text = text
        self.startTime = startTime
        self.endTime = max(startTime, endTime)
        self.confidence = confidence.map { min(1, max(0, $0)) }
    }
}

public struct SpeechEngineResult: Equatable, Sendable {
    public let engineID: SpeechEngineID
    public let language: String
    public let segments: [SpeechEngineSegment]
    public let audioDuration: TimeInterval
    public let diagnostics: [String]
    public let elapsedSeconds: TimeInterval

    public init(
        engineID: SpeechEngineID,
        language: String,
        segments: [SpeechEngineSegment],
        audioDuration: TimeInterval,
        diagnostics: [String] = [],
        elapsedSeconds: TimeInterval = 0
    ) {
        self.engineID = engineID
        self.language = language
        self.segments = segments
        self.audioDuration = audioDuration
        self.diagnostics = diagnostics
        self.elapsedSeconds = elapsedSeconds
    }

    public var nonEmptyTokenCount: Int {
        segments.reduce(0) { partial, seg in
            partial + seg.text.split { $0.isWhitespace || $0.isNewline }.count
        }
    }

    /// Bridge into the existing alignment pipeline without exposing engine details.
    /// Missing ASR confidence is encoded as `-1` (not fabricated as 1.0).
    public func asTimedTranscript() -> TimedTranscript {
        TimedTranscript(
            backendID: engineID.rawValue,
            segments: segments.enumerated().map { index, seg in
                TimedTranscriptSegment(
                    index: index,
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    confidence: seg.confidence ?? -1
                )
            },
            audioDuration: audioDuration
        )
    }

    /// True when this result has no real per-segment ASR confidence.
    public var hasAsrConfidence: Bool {
        segments.contains { $0.confidence != nil }
    }
}

public enum SpeechEngineError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(String)
    case invalidAudio(String)
    case cancelled
    case timeout
    case failed(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): return m
        case .invalidAudio(let m): return m
        case .cancelled: return "识别已取消"
        case .timeout: return "识别超时"
        case .failed(let m): return m
        case .permissionDenied: return "没有语音识别权限"
        }
    }

    public var asAlignmentError: AlignmentError {
        switch self {
        case .unavailable: return .recognizerUnavailable
        case .invalidAudio(let m): return .invalidAudio(m)
        case .cancelled: return .cancelled
        case .timeout: return .failed("语音识别超时")
        case .failed(let m): return .failed(m)
        case .permissionDenied: return .speechPermissionDenied
        }
    }
}

/// Pluggable speech front-end. S3A/S3B only see `SpeechEngineResult`.
public protocol LyricsSpeechEngine: Sendable {
    var engineID: SpeechEngineID { get }
    /// False when binary/model/locale cannot run (must not crash).
    var isAvailable: Bool { get }
    func transcribe(
        pcmURL: URL,
        languageHint: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> SpeechEngineResult
}

/// Internal engine selection shared by the Release automatic-alignment and assist paths.
public enum SpeechEngineRegistry {
    public static let environmentKey = "SPOTIFYLYRICS_SPEECH_ENGINE"
    /// Optional: `apple` | `whisper` | `whisper_cli` | full stable IDs.
    public static let userDefaultsKey = "debug.speechEngineID"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .lyricsQ
    ) -> any LyricsSpeechEngine {
        let raw = (environment[environmentKey] ?? defaults.string(forKey: userDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "whisper", "whisper_cli", "whispercli",
             SpeechEngineID.whisperCLI.rawValue.lowercased():
            return WhisperCLISpeechEngine()
        default:
            return AppleSpeechEngine()
        }
    }

    public static var activeEngineID: SpeechEngineID {
        resolve().engineID
    }
}
