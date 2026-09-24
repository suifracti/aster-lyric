import Foundation

/// Per-line status for S3A partial candidates (Debug-only product surface).
public enum PartialLineStatus: String, Codable, Sendable, Equatable {
    case resolved
    case unresolved
    case lowConfidence
    case outsideCapturedRange
    case interpolated
}

public struct PartialAlignedLine: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { sourceLineIndex }
    public let sourceLineIndex: Int
    public let text: String
    public let status: PartialLineStatus
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let confidence: Double
    public let segmentID: UUID?
    public let evidenceKind: String
    public let speechRelativeStart: TimeInterval?
    public let speechRelativeEnd: TimeInterval?

    public init(
        sourceLineIndex: Int,
        text: String,
        status: PartialLineStatus,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        confidence: Double,
        segmentID: UUID?,
        evidenceKind: String,
        speechRelativeStart: TimeInterval? = nil,
        speechRelativeEnd: TimeInterval? = nil
    ) {
        self.sourceLineIndex = sourceLineIndex
        self.text = text
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.segmentID = segmentID
        self.evidenceKind = evidenceKind
        self.speechRelativeStart = speechRelativeStart
        self.speechRelativeEnd = speechRelativeEnd
    }
}

public struct CapturedTimeRange: Codable, Equatable, Sendable {
    public let segmentID: UUID
    public let start: TimeInterval
    public let end: TimeInterval

    public init(segmentID: UUID, start: TimeInterval, end: TimeInterval) {
        self.segmentID = segmentID
        self.start = start
        self.end = end
    }
}

/// Transient alignment candidate. Any formal save is owned by the consuming alignment job.
public struct PartialAlignmentCandidate: Codable, Equatable, Sendable {
    public let trackIdentityDigest: String
    public let captureSessionID: UUID
    public let locale: String
    public let localeFallbackReason: String?
    public let capturedRanges: [CapturedTimeRange]
    public let lines: [PartialAlignedLine]
    public let overallConfidence: Double
    public let resolvedCount: Int
    public let unresolvedCount: Int
    public let lowConfidenceCount: Int
    public let outsideCapturedRangeCount: Int
    public let coverageRatio: Double
    public let transcriptSegmentCount: Int
    public let capturedDuration: TimeInterval
    public let createdAt: Date

    public init(
        trackIdentityDigest: String,
        captureSessionID: UUID,
        locale: String,
        localeFallbackReason: String?,
        capturedRanges: [CapturedTimeRange],
        lines: [PartialAlignedLine],
        overallConfidence: Double,
        resolvedCount: Int,
        unresolvedCount: Int,
        lowConfidenceCount: Int,
        outsideCapturedRangeCount: Int,
        coverageRatio: Double,
        transcriptSegmentCount: Int,
        capturedDuration: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.trackIdentityDigest = trackIdentityDigest
        self.captureSessionID = captureSessionID
        self.locale = locale
        self.localeFallbackReason = localeFallbackReason
        self.capturedRanges = capturedRanges
        self.lines = lines
        self.overallConfidence = overallConfidence
        self.resolvedCount = resolvedCount
        self.unresolvedCount = unresolvedCount
        self.lowConfidenceCount = lowConfidenceCount
        self.outsideCapturedRangeCount = outsideCapturedRangeCount
        self.coverageRatio = coverageRatio
        self.transcriptSegmentCount = transcriptSegmentCount
        self.capturedDuration = capturedDuration
        self.createdAt = createdAt
    }
}

public struct HeldOutErrorStats: Codable, Equatable, Sendable {
    public let comparedLineCount: Int
    public let medianAbsoluteError: TimeInterval?
    public let p90AbsoluteError: TimeInterval?
    public let p95AbsoluteError: TimeInterval?
    public let meanAbsoluteError: TimeInterval?
    /// Absolute error ≤ 0.5 s
    public let withinHalfSecondCount: Int
    /// Absolute error ≤ 1.0 s
    public let withinOneSecondCount: Int
    /// Absolute error ≤ 2.0 s
    public let withinTwoSecondCount: Int
    /// Absolute error > 3.0 s (severe wrong timing / likely wrong line)
    public let obviousMismatchCount: Int
    public let note: String

    public static func unavailable(_ note: String) -> HeldOutErrorStats {
        HeldOutErrorStats(
            comparedLineCount: 0,
            medianAbsoluteError: nil,
            p90AbsoluteError: nil,
            p95AbsoluteError: nil,
            meanAbsoluteError: nil,
            withinHalfSecondCount: 0,
            withinOneSecondCount: 0,
            withinTwoSecondCount: 0,
            obviousMismatchCount: 0,
            note: note
        )
    }
}

public struct PartialAlignmentReport: Codable, Equatable, Sendable {
    /// Primary candidate (S3B when constrained alignment ran; else S3A).
    public let candidate: PartialAlignmentCandidate
    public let heldOut: HeldOutErrorStats
    public let judgment: String
    public let wavPaths: [String]
    /// S3A baseline for A/B comparison (always filled when speech succeeded).
    public let s3aCandidate: PartialAlignmentCandidate?
    public let s3aHeldOut: HeldOutErrorStats?
    public let acceptedAnchors: [AlignmentAnchor]
    public let rejectedAnchors: [AlignmentAnchor]
    public let usedConstrainedAlignment: Bool
    public let s3bFallbackReason: String?

    public init(
        candidate: PartialAlignmentCandidate,
        heldOut: HeldOutErrorStats,
        judgment: String,
        wavPaths: [String],
        s3aCandidate: PartialAlignmentCandidate? = nil,
        s3aHeldOut: HeldOutErrorStats? = nil,
        acceptedAnchors: [AlignmentAnchor] = [],
        rejectedAnchors: [AlignmentAnchor] = [],
        usedConstrainedAlignment: Bool = false,
        s3bFallbackReason: String? = nil
    ) {
        self.candidate = candidate
        self.heldOut = heldOut
        self.judgment = judgment
        self.wavPaths = wavPaths
        self.s3aCandidate = s3aCandidate
        self.s3aHeldOut = s3aHeldOut
        self.acceptedAnchors = acceptedAnchors
        self.rejectedAnchors = rejectedAnchors
        self.usedConstrainedAlignment = usedConstrainedAlignment
        self.s3bFallbackReason = s3bFallbackReason
    }
}
