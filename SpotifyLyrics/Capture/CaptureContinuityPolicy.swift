import Foundation

/// Central thresholds for LiveCapture S2 continuity. Do not scatter magic
/// numbers in the coordinator.
public enum CaptureContinuityPolicy: Sendable {
    /// Absolute Spotify position jump (seconds) treated as seek when it exceeds
    /// expected progress by this much.
    public static let seekJumpThreshold: TimeInterval = 1.50

    /// Small position jitter from Desktop polling is ignored below this.
    public static let positionJitterTolerance: TimeInterval = 0.40

    static func isSeek(previousPosition: TimeInterval, position: TimeInterval,
                       elapsed: TimeInterval, wasPlaying: Bool) -> Bool {
        let expected = wasPlaying ? previousPosition + max(0, elapsed) : previousPosition
        let jump = abs(position - previousPosition)
        return abs(position - expected) > seekJumpThreshold && jump > positionJitterTolerance
    }

    /// Host-time gap without any audio buffer before we end the open segment
    /// for `audioGap` (while still capturing overall).
    public static let audioGapTimeout: TimeInterval = 1.75

    /// Minimum open-segment duration before a gap can close it (avoids
    /// thrashing on the first buffers).
    public static let minimumSegmentDurationBeforeGapClose: TimeInterval = 0.35

    /// How often to emit an ANCHOR line while a segment is open and playing.
    public static let anchorLogInterval: TimeInterval = 2.0

    /// When paused, silence buffers still arrive; do not open a new segment
    /// solely because peak is low. Pause/resume is driven by `isPlaying`.
    public static let ignoreAudioActivityWhilePaused: Bool = true

    /// Require this many consecutive position observations with a large jump
    /// before declaring seek (reduces false splits when a single poll is late).
    public static let seekConfirmationPolls: Int = 1

    /// Temp root name under NSTemporaryDirectory (scavenged on launch).
    public static let temporaryRootName = "SpotifyLyricsCapture"

    /// Subfolder for S2 session artifacts (segment sidecars; optional PCM).
    public static let s2SessionsFolderName = "s2-sessions"

    /// Capture source identifier for provenance later (not written to SQLite in S2).
    public static let captureSourceID = "screenCaptureKit.spotifyAudio.v1"
}
