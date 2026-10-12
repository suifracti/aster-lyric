import Foundation

/// S3A: run Speech + LineForcedAligner per continuous CapturedAudioSegment,
/// map relative Speech times to absolute Spotify positions, and emit a
/// PartialAlignmentReport for the consuming alignment job's quality gate.
public enum SegmentPartialAlignmentPipeline {
    public static let reportDirectoryName = "s3a-reports"

    /// Align plain lyric lines against one or more continuous segments that
    /// already have temporary 16 kHz mono WAV paths.
    public static func align(
        session: CapturedAudioSession,
        segments: [CapturedAudioSegment],
        plainLines: [LyricLine],
        languageHint: String?,
        localeOverride: String?,
        groundTruthSyncedLines: [LyricLine]?,
        identity: TrackIdentity,
        generation: UInt64,
        isGenerationCurrent: @escaping @Sendable () -> Bool
    ) async throws -> PartialAlignmentReport {
        guard isGenerationCurrent() else {
            throw AlignmentError.cancelled
        }
        let text = plainLines.map(\.originalText).joined(separator: "\n")
        let localeRec = AlignmentLocaleRecommender.recommend(
            languageHint: languageHint,
            lyricText: text,
            override: localeOverride
        )
        SCKSpikeLog.log(
            "S3A locale=\(localeRec.localeIdentifier) reason=\(localeRec.reason) fallback=\(localeRec.usedFallback)"
        )

        let usable = segments.filter { seg in
            guard let path = seg.temporaryPCMReference, path.hasSuffix(".wav") else { return false }
            return FileManager.default.isReadableFile(atPath: path) && seg.sampleCount > 0
        }
        guard !usable.isEmpty else {
            throw AlignmentError.invalidAudio("没有可用于识别的 segment WAV")
        }

        var ranges: [CapturedTimeRange] = []
        var totalTranscriptSegments = 0
        var totalCapturedDuration: TimeInterval = 0
        var bundles: [SegmentSpeechBundle] = []

        // Pluggable speech front-end via registry (default Apple; experimental engines optional).
        // S3A/S3B never import engine-specific types or subprocess details.
        let speechEngine = SpeechEngineRegistry.resolve()
        SCKSpikeLog.log(
            "S3A speech_engine=\(speechEngine.engineID.rawValue) available=\(speechEngine.isAvailable)"
        )
        if !speechEngine.isAvailable {
            throw AlignmentError.recognizerUnavailable
        }

        for segment in usable {
            guard isGenerationCurrent() else { throw AlignmentError.cancelled }
            guard let wavPath = segment.temporaryPCMReference else { continue }
            let wavURL = URL(fileURLWithPath: wavPath)
            let posStart = segment.spotifyPositionStart
            let posEnd = segment.spotifyPositionEnd ?? (posStart + max(segment.duration, 0.1))
            ranges.append(CapturedTimeRange(segmentID: segment.segmentID, start: posStart, end: posEnd))
            totalCapturedDuration += max(0, posEnd - posStart)

            SCKSpikeLog.log(
                "S3A speech begin segmentID=\(segment.segmentID.uuidString.prefix(8)) wav=\(wavURL.lastPathComponent) pos=\(fmt(posStart))->\(fmt(posEnd)) engine=\(speechEngine.engineID.rawValue)"
            )
            let transcript: TimedTranscript
            do {
                let engineResult = try await speechEngine.transcribe(
                    pcmURL: wavURL,
                    languageHint: localeRec.localeIdentifier,
                    progress: nil
                )
                let prepared = prepareTranscript(
                    engineResult: engineResult,
                    plainLines: plainLines,
                    languageHint: localeRec.localeIdentifier
                )
                transcript = prepared.transcript
                SCKSpikeLog.log(
                    "S3A speech diag engine=\(engineResult.engineID.rawValue) raw_pieces=\(engineResult.segments.count) prepared_pieces=\(transcript.segments.count) tokens=\(engineResult.nonEmptyTokenCount) elapsed=\(String(format: "%.2f", engineResult.elapsedSeconds))s asr_conf=\(engineResult.hasAsrConfidence)"
                )
                for line in prepared.diagnostics.prefix(12) {
                    SCKSpikeLog.log("S3A transcript_prep \(line)")
                }
            } catch let engineError as SpeechEngineError {
                SCKSpikeLog.log(
                    "S3A speech failed segmentID=\(segment.segmentID.uuidString.prefix(8)) engine=\(speechEngine.engineID.rawValue) error=\(engineError.localizedDescription)"
                )
                // Surface hard unavailability instead of silently skipping all segments.
                if case .unavailable = engineError {
                    throw engineError.asAlignmentError
                }
                if case .permissionDenied = engineError {
                    throw engineError.asAlignmentError
                }
                continue
            } catch {
                SCKSpikeLog.log("S3A speech failed segmentID=\(segment.segmentID.uuidString.prefix(8)) error=\(error.localizedDescription)")
                continue
            }
            guard isGenerationCurrent() else { throw AlignmentError.cancelled }
            totalTranscriptSegments += transcript.segments.count
            SCKSpikeLog.log(
                "S3A speech ok segmentID=\(segment.segmentID.uuidString.prefix(8)) transcriptSegments=\(transcript.segments.count) audioDuration=\(fmt(transcript.audioDuration))"
            )
            bundles.append(
                SegmentSpeechBundle(
                    segment: segment,
                    transcript: transcript,
                    positionStart: posStart,
                    positionEnd: posEnd
                )
            )
        }

        if bundles.isEmpty {
            throw AlignmentError.noSpeech
        }

        return try finalizeFromBundles(
            session: session,
            bundles: bundles,
            plainLines: plainLines,
            localeRec: localeRec,
            groundTruthSyncedLines: groundTruthSyncedLines,
            identity: identity,
            wavPaths: usable.compactMap(\.temporaryPCMReference),
            writeSidecar: true
        )
    }

    /// Offline / evaluation entry: identical S3A→S3B→report path after speech.
    /// Does not open SQLite or adopt results. Used by S2/S3 full-pipeline harness.
    public static func alignFromTimedTranscript(
        session: CapturedAudioSession,
        segment: CapturedAudioSegment,
        plainLines: [LyricLine],
        transcript: TimedTranscript,
        languageHint: String?,
        localeOverride: String?,
        groundTruthSyncedLines: [LyricLine]?,
        identity: TrackIdentity,
        writeSidecar: Bool = false
    ) throws -> PartialAlignmentReport {
        let text = plainLines.map(\.originalText).joined(separator: "\n")
        let localeRec = AlignmentLocaleRecommender.recommend(
            languageHint: languageHint,
            lyricText: text,
            override: localeOverride
        )
        let prepared = prepareTranscript(
            timed: transcript,
            plainLines: plainLines,
            languageHint: localeOverride ?? languageHint ?? localeRec.localeIdentifier
        )
        for line in prepared.diagnostics.prefix(12) {
            SCKSpikeLog.log("S3A transcript_prep \(line)")
        }
        SCKSpikeLog.log(
            "S3A prepared raw_pieces=\(transcript.segments.count) prepared_pieces=\(prepared.transcript.segments.count)"
        )
        let posStart = segment.spotifyPositionStart
        let posEnd = segment.spotifyPositionEnd ?? (posStart + max(segment.duration, 0.1))
        let bundle = SegmentSpeechBundle(
            segment: segment,
            transcript: prepared.transcript,
            positionStart: posStart,
            positionEnd: posEnd
        )
        return try finalizeFromBundles(
            session: session,
            bundles: [bundle],
            plainLines: plainLines,
            localeRec: localeRec,
            groundTruthSyncedLines: groundTruthSyncedLines,
            identity: identity,
            wavPaths: [segment.temporaryPCMReference].compactMap { $0 },
            writeSidecar: writeSidecar
        )
    }

    /// Normalize + split long ASR segments before S3A/S3B (engine-agnostic).
    public static func prepareTranscript(
        engineResult: SpeechEngineResult,
        plainLines: [LyricLine],
        languageHint: String?
    ) -> (transcript: TimedTranscript, diagnostics: [String], split: TranscriptSegmentSplitter.Result) {
        let norm = TranscriptNormalizer.normalize(
            engineResult: engineResult,
            languageHint: languageHint
        )
        let split = TranscriptSegmentSplitter.split(
            normalized: norm,
            plainLines: plainLines,
            language: norm.language
        )
        let transcript = TranscriptSegmentSplitter.asTimedTranscript(
            split: split,
            engineID: engineResult.engineID.rawValue,
            audioDuration: engineResult.audioDuration
        )
        var diag = split.diagnostics
        diag.append("norm_ops=\(norm.operations.count)")
        diag.append("raw=\(engineResult.segments.count)->split=\(split.subsegments.count)")
        return (transcript, diag, split)
    }

    public static func prepareTranscript(
        timed: TimedTranscript,
        plainLines: [LyricLine],
        languageHint: String?
    ) -> (transcript: TimedTranscript, diagnostics: [String], split: TranscriptSegmentSplitter.Result) {
        let engineID = SpeechEngineID(rawValue: timed.backendID) ?? .apple
        let segs = timed.segments.map { seg in
            SpeechEngineSegment(
                index: seg.index,
                text: seg.text,
                startTime: seg.startTime,
                endTime: seg.endTime,
                confidence: LineForcedAligner.isObservedAsrConfidence(seg.confidence) ? seg.confidence : nil
            )
        }
        let engineResult = SpeechEngineResult(
            engineID: engineID,
            language: languageHint ?? "ja",
            segments: segs,
            audioDuration: timed.audioDuration,
            diagnostics: ["from=timed_transcript"],
            elapsedSeconds: 0
        )
        return prepareTranscript(
            engineResult: engineResult,
            plainLines: plainLines,
            languageHint: languageHint
        )
    }

    /// Shared post-speech alignment chain (S3A baseline + S3B + report).
    private static func finalizeFromBundles(
        session: CapturedAudioSession,
        bundles: [SegmentSpeechBundle],
        plainLines: [LyricLine],
        localeRec: LocaleRecommendation,
        groundTruthSyncedLines: [LyricLine]?,
        identity: TrackIdentity,
        wavPaths: [String],
        writeSidecar: Bool
    ) throws -> PartialAlignmentReport {
        let ranges: [CapturedTimeRange] = bundles.map {
            CapturedTimeRange(segmentID: $0.segment.segmentID, start: $0.positionStart, end: $0.positionEnd)
        }
        let totalTranscriptSegments = bundles.reduce(0) { $0 + $1.transcript.segments.count }
        let totalCapturedDuration = ranges.reduce(0.0) { $0 + max(0, $1.end - $1.start) }

        // --- S3A baseline (global Partial DP per segment) ---
        let s3aLines = buildS3ALines(
            bundles: bundles,
            plainLines: plainLines,
            ranges: ranges,
            locale: localeRec.localeIdentifier,
            groundTruthSyncedLines: groundTruthSyncedLines
        )
        let s3aCandidate = makeCandidate(
            identity: identity,
            sessionID: session.sessionID,
            localeRec: localeRec,
            ranges: ranges,
            lines: s3aLines,
            transcriptSegmentCount: totalTranscriptSegments,
            capturedDuration: totalCapturedDuration
        )
        let s3aHeldOut = evaluateHeldOut(candidateLines: s3aLines, groundTruth: groundTruthSyncedLines)

        // --- S3B anchors + constrained regions ---
        let (accepted, rejected) = AnchorConstrainedAligner.selectAnchors(
            bundles: bundles,
            plainLines: plainLines
        )
        SCKSpikeLog.log(
            "S3B anchors accepted=\(accepted.count) rejected=\(rejected.count)"
        )
        for a in accepted.prefix(20) {
            SCKSpikeLog.log(
                "S3B ANCHOR_OK line=\(a.lyricLineIndex) conf=\(fmt(a.overallConfidence)) t=\(fmt(a.absoluteStartTime)) lyric=\(a.lyricText.prefix(24)) speech=\(a.transcriptText.prefix(24))"
            )
        }
        for r in rejected.prefix(15) {
            SCKSpikeLog.log(
                "S3B ANCHOR_REJ line=\(r.lyricLineIndex) reason=\(r.rejectionReason ?? "?") conf=\(fmt(r.overallConfidence))"
            )
        }

        var usedConstrained = false
        var fallbackReason: String? = nil
        var s3bLines: [PartialAlignedLine]
        if let constrained = AnchorConstrainedAligner.alignConstrained(
            bundles: bundles,
            plainLines: plainLines,
            acceptedAnchors: accepted,
            capturedRanges: ranges,
            locale: localeRec.localeIdentifier
        ) {
            s3bLines = applyOutsideCaptured(
                lines: constrained,
                plainLines: plainLines,
                ranges: ranges,
                groundTruthSyncedLines: groundTruthSyncedLines
            )
            usedConstrained = true
        } else {
            s3bLines = s3aLines
            fallbackReason = accepted.isEmpty
                ? "insufficientAnchors_zero"
                : "insufficientAnchors_need_\(AnchorAlignmentPolicy.minimumAnchorsForConstrained)"
            SCKSpikeLog.log("S3B fallback to S3A reason=\(fallbackReason ?? "")")
        }

        // --- S4: local window refine between anchors (does not replace global DP) ---
        if accepted.count >= 2 {
            let local = LocalAlignmentWindow.refineBetweenAnchors(
                plainLines: plainLines,
                bundles: bundles,
                anchors: accepted,
                existing: s3bLines,
                locale: localeRec.localeIdentifier
            )
            s3bLines = local.lines
            for d in local.diagnostics.prefix(12) {
                SCKSpikeLog.log("S4 \(d)")
            }
        }

        // --- S4: capture-window + repeated-section occurrence constraints ---
        let capStart = ranges.map(\.start).min() ?? 0
        let capEnd = ranges.map(\.end).max() ?? (capStart + totalCapturedDuration)
        let capture = RepeatedLyricsSectionResolver.CaptureWindow(
            absoluteStart: capStart,
            absoluteEnd: capEnd,
            trackDuration: max(session.trackDuration, capEnd)
        )
        var timedMap: [Int: TimeInterval] = [:]
        for line in s3bLines {
            if let t = line.startTime {
                timedMap[line.sourceLineIndex] = t
            }
        }
        let languageHint = localeRec.localeIdentifier.lowercased().hasPrefix("zh")
            ? "zh"
            : (localeRec.localeIdentifier.lowercased().hasPrefix("en") ? "en" : "ja")
        let resolution = RepeatedLyricsSectionResolver.resolve(
            plainLines: plainLines,
            timedLines: timedMap,
            capture: capture,
            anchors: accepted,
            language: languageHint
        )
        for d in resolution.diagnostics {
            SCKSpikeLog.log("S4 \(d)")
        }
        let keptTimes = RepeatedLyricsSectionResolver.applyRejections(
            times: timedMap,
            resolution: resolution
        )
        s3bLines = s3bLines.map { line in
            guard let t = line.startTime else { return line }
            if keptTimes[line.sourceLineIndex] == nil {
                // Drop rejected / ambiguous repeated-section wrong occurrence.
                let reason = resolution.results.first { $0.lyricLineIndex == line.sourceLineIndex }?.reason
                    ?? "repeated_section_drop"
                return PartialAlignedLine(
                    sourceLineIndex: line.sourceLineIndex,
                    text: line.text,
                    status: .unresolved,
                    startTime: nil,
                    endTime: nil,
                    confidence: 0,
                    segmentID: line.segmentID,
                    evidenceKind: "s4:\(reason)",
                    speechRelativeStart: line.speechRelativeStart,
                    speechRelativeEnd: line.speechRelativeEnd
                )
            }
            // Annotate capture constraint OK
            if !line.evidenceKind.contains("s4:") {
                return PartialAlignedLine(
                    sourceLineIndex: line.sourceLineIndex,
                    text: line.text,
                    status: line.status,
                    startTime: t,
                    endTime: line.endTime,
                    confidence: line.confidence,
                    segmentID: line.segmentID,
                    evidenceKind: line.evidenceKind + ";s4:capture_ok",
                    speechRelativeStart: line.speechRelativeStart,
                    speechRelativeEnd: line.speechRelativeEnd
                )
            }
            return line
        }
        // Also drop times outside capture on S3A primary for consistency
        _ = keptTimes

        let s3bCandidate = makeCandidate(
            identity: identity,
            sessionID: session.sessionID,
            localeRec: localeRec,
            ranges: ranges,
            lines: s3bLines,
            transcriptSegmentCount: totalTranscriptSegments,
            capturedDuration: totalCapturedDuration
        )
        let s3bHeldOut = evaluateHeldOut(candidateLines: s3bLines, groundTruth: groundTruthSyncedLines)
        let judgment = makeS3BJudgment(
            s3a: s3aCandidate,
            s3b: s3bCandidate,
            s3aHeldOut: s3aHeldOut,
            s3bHeldOut: s3bHeldOut,
            acceptedCount: accepted.count,
            usedConstrained: usedConstrained
        )

        let report = PartialAlignmentReport(
            candidate: s3bCandidate,
            heldOut: s3bHeldOut,
            judgment: judgment,
            wavPaths: wavPaths,
            s3aCandidate: s3aCandidate,
            s3aHeldOut: s3aHeldOut,
            acceptedAnchors: accepted,
            rejectedAnchors: rejected,
            usedConstrainedAlignment: usedConstrained,
            s3bFallbackReason: fallbackReason
        )
        if writeSidecar {
            try writeReport(report, sessionID: session.sessionID)
        }
        SCKSpikeLog.log(
            "S3A coverage=\(fmt(s3aCandidate.coverageRatio)) resolved=\(s3aCandidate.resolvedCount) low=\(s3aCandidate.lowConfidenceCount) unresolved=\(s3aCandidate.unresolvedCount)"
        )
        SCKSpikeLog.log(
            "S3B coverage=\(fmt(s3bCandidate.coverageRatio)) resolved=\(s3bCandidate.resolvedCount) low=\(s3bCandidate.lowConfidenceCount) unresolved=\(s3bCandidate.unresolvedCount) anchors=\(accepted.count) constrained=\(usedConstrained) judgment=\(judgment)"
        )
        return report
    }

    private static func buildS3ALines(
        bundles: [SegmentSpeechBundle],
        plainLines: [LyricLine],
        ranges: [CapturedTimeRange],
        locale: String,
        groundTruthSyncedLines: [LyricLine]?
    ) -> [PartialAlignedLine] {
        var bestByLine: [Int: PartialAlignedLine] = [:]
        for bundle in bundles {
            let posStart = bundle.positionStart
            let result = LineForcedAligner.align(
                lines: plainLines,
                transcript: bundle.transcript,
                audioDuration: max(bundle.transcript.audioDuration, bundle.segment.duration),
                parameters: AlignmentParameters(
                    recognizerID: bundle.transcript.backendID,
                    localeIdentifier: locale,
                    sampleRate: 16_000,
                    channels: 1
                )
            )
            for (index, aligned) in result.lines.enumerated() {
                let textLine = plainLines[index].originalText
                if aligned.startTime < 0 {
                    if bestByLine[index] == nil {
                        bestByLine[index] = PartialAlignedLine(
                            sourceLineIndex: index,
                            text: textLine,
                            status: .unresolved,
                            startTime: nil,
                            endTime: nil,
                            confidence: aligned.confidence,
                            segmentID: bundle.segment.segmentID,
                            evidenceKind: aligned.evidence.kind.rawValue
                        )
                    }
                    continue
                }
                let absStart = posStart + aligned.startTime
                let absEnd = aligned.endTime.map { posStart + $0 }
                let status: PartialLineStatus
                switch aligned.status {
                case .aligned: status = .resolved
                case .lowConfidence: status = .lowConfidence
                case .interpolated: status = .interpolated
                case .unmatched: status = .unresolved
                }
                let candidate = PartialAlignedLine(
                    sourceLineIndex: index,
                    text: textLine,
                    status: status,
                    startTime: absStart,
                    endTime: absEnd,
                    confidence: aligned.confidence,
                    segmentID: bundle.segment.segmentID,
                    evidenceKind: aligned.evidence.kind.rawValue,
                    speechRelativeStart: aligned.startTime,
                    speechRelativeEnd: aligned.endTime
                )
                if let existing = bestByLine[index] {
                    if shouldReplace(existing, with: candidate) {
                        bestByLine[index] = candidate
                    }
                } else {
                    bestByLine[index] = candidate
                }
            }
        }
        return applyOutsideCaptured(
            lines: plainLines.indices.map { index in
                bestByLine[index] ?? PartialAlignedLine(
                    sourceLineIndex: index,
                    text: plainLines[index].originalText,
                    status: .unresolved,
                    startTime: nil,
                    endTime: nil,
                    confidence: 0,
                    segmentID: nil,
                    evidenceKind: "noEvidence"
                )
            },
            plainLines: plainLines,
            ranges: ranges,
            groundTruthSyncedLines: groundTruthSyncedLines
        )
    }

    private static func applyOutsideCaptured(
        lines: [PartialAlignedLine],
        plainLines: [LyricLine],
        ranges: [CapturedTimeRange],
        groundTruthSyncedLines: [LyricLine]?
    ) -> [PartialAlignedLine] {
        var byIndex = Dictionary(uniqueKeysWithValues: lines.map { ($0.sourceLineIndex, $0) })
        var result: [PartialAlignedLine] = []
        for index in plainLines.indices {
            if let row = byIndex[index], row.startTime != nil {
                result.append(row)
                continue
            }
            if let gt = groundTruthSyncedLines, index < gt.count {
                let gtTime = gt[index].timestamp
                let covered = ranges.contains { gtTime >= $0.start - 0.25 && gtTime <= $0.end + 0.25 }
                if !covered {
                    result.append(
                        PartialAlignedLine(
                            sourceLineIndex: index,
                            text: plainLines[index].originalText,
                            status: .outsideCapturedRange,
                            startTime: nil,
                            endTime: nil,
                            confidence: 0,
                            segmentID: nil,
                            evidenceKind: "outsideCapturedRange"
                        )
                    )
                    continue
                }
            }
            if let row = byIndex[index] {
                result.append(row)
            } else {
                result.append(
                    PartialAlignedLine(
                        sourceLineIndex: index,
                        text: plainLines[index].originalText,
                        status: .unresolved,
                        startTime: nil,
                        endTime: nil,
                        confidence: 0,
                        segmentID: nil,
                        evidenceKind: "noEvidence"
                    )
                )
            }
        }
        return result.sorted { $0.sourceLineIndex < $1.sourceLineIndex }
    }

    private static func makeCandidate(
        identity: TrackIdentity,
        sessionID: UUID,
        localeRec: LocaleRecommendation,
        ranges: [CapturedTimeRange],
        lines: [PartialAlignedLine],
        transcriptSegmentCount: Int,
        capturedDuration: TimeInterval
    ) -> PartialAlignmentCandidate {
        let resolved = lines.filter { $0.status == .resolved || $0.status == .interpolated }.count
        let low = lines.filter { $0.status == .lowConfidence }.count
        let unresolved = lines.filter { $0.status == .unresolved }.count
        let outside = lines.filter { $0.status == .outsideCapturedRange }.count
        let timed = lines.filter { $0.startTime != nil }
        let overall: Double = {
            guard !timed.isEmpty else { return 0 }
            return timed.map(\.confidence).reduce(0, +) / Double(timed.count)
        }()
        let coverage = lines.isEmpty ? 0 : Double(resolved + low) / Double(lines.count)
        return PartialAlignmentCandidate(
            trackIdentityDigest: String(identity.stableKey.prefix(48)),
            captureSessionID: sessionID,
            locale: localeRec.localeIdentifier,
            localeFallbackReason: localeRec.usedFallback ? localeRec.reason : nil,
            capturedRanges: ranges,
            lines: lines,
            overallConfidence: overall,
            resolvedCount: resolved,
            unresolvedCount: unresolved,
            lowConfidenceCount: low,
            outsideCapturedRangeCount: outside,
            coverageRatio: coverage,
            transcriptSegmentCount: transcriptSegmentCount,
            capturedDuration: capturedDuration
        )
    }

    /// Strip timestamps for algorithm input while preserving text order.
    public static func plainLines(from document: LyricsDocument) -> [LyricLine] {
        document.lines.map { line in
            LyricLine(
                id: line.id,
                timestamp: 0,
                originalText: line.originalText,
                endTime: nil,
                translationText: line.translationText,
                romajiText: line.romajiText,
                kanaText: line.kanaText,
                rubyTokens: line.rubyTokens
            )
        }
    }

    private static func shouldReplace(_ existing: PartialAlignedLine, with candidate: PartialAlignedLine) -> Bool {
        let rank: (PartialLineStatus) -> Int = { status in
            switch status {
            case .resolved: return 4
            case .interpolated: return 3
            case .lowConfidence: return 2
            case .unresolved: return 1
            case .outsideCapturedRange: return 0
            }
        }
        if rank(candidate.status) != rank(existing.status) {
            return rank(candidate.status) > rank(existing.status)
        }
        return candidate.confidence > existing.confidence
    }

    public static func evaluateHeldOut(
        candidateLines: [PartialAlignedLine],
        groundTruth: [LyricLine]?
    ) -> HeldOutErrorStats {
        guard let groundTruth, !groundTruth.isEmpty else {
            return .unavailable("no_held_out_synced_lyrics")
        }
        var errors: [TimeInterval] = []
        var obvious = 0
        var le05 = 0
        var le1 = 0
        var le2 = 0
        for line in candidateLines {
            guard let start = line.startTime,
                  line.status == .resolved || line.status == .lowConfidence || line.status == .interpolated,
                  line.sourceLineIndex < groundTruth.count else { continue }
            let gt = groundTruth[line.sourceLineIndex].timestamp
            guard gt.isFinite, gt >= 0 else { continue }
            let err = abs(start - gt)
            errors.append(err)
            if err <= 0.5 { le05 += 1 }
            if err <= 1.0 { le1 += 1 }
            if err <= 2.0 { le2 += 1 }
            if err > 3.0 { obvious += 1 }
        }
        guard !errors.isEmpty else {
            return .unavailable("no_overlapping_timed_lines_for_comparison")
        }
        let sorted = errors.sorted()
        func percentile(_ p: Double) -> TimeInterval {
            let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[idx]
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        return HeldOutErrorStats(
            comparedLineCount: errors.count,
            medianAbsoluteError: percentile(0.5),
            p90AbsoluteError: percentile(0.9),
            p95AbsoluteError: percentile(0.95),
            meanAbsoluteError: mean,
            withinHalfSecondCount: le05,
            withinOneSecondCount: le1,
            withinTwoSecondCount: le2,
            obviousMismatchCount: obvious,
            note: "held_out_start_time_abs_error_seconds"
        )
    }

    /// Product-value judgment for S3B vs S3A (conservative; not forced PASS).
    private static func makeS3BJudgment(
        s3a: PartialAlignmentCandidate,
        s3b: PartialAlignmentCandidate,
        s3aHeldOut: HeldOutErrorStats,
        s3bHeldOut: HeldOutErrorStats,
        acceptedCount: Int,
        usedConstrained: Bool
    ) -> String {
        if !usedConstrained || acceptedCount < AnchorAlignmentPolicy.minimumAnchorsForConstrained {
            return "C_insufficient_reliable_anchors"
        }
        let covGain = s3b.coverageRatio - s3a.coverageRatio
        let s3aSevere = s3aHeldOut.obviousMismatchCount
        let s3bSevere = s3bHeldOut.obviousMismatchCount
        let heldOutComparable = s3aHeldOut.comparedLineCount > 0 && s3bHeldOut.comparedLineCount > 0
        let errorWorse: Bool = {
            guard heldOutComparable,
                  let aMed = s3aHeldOut.medianAbsoluteError,
                  let bMed = s3bHeldOut.medianAbsoluteError else { return false }
            // "明显恶化": median up by >0.75s or severe mismatches increase by ≥2
            return (bMed - aMed) > 0.75 || s3bSevere >= s3aSevere + 2
        }()
        // Coverage regression or held-out deterioration with anchors present:
        // still experimental value, not "insufficient anchors".
        if errorWorse || covGain < -0.02 {
            return "B_coverage_up_but_errors_remain"
        }
        if covGain >= 0.08, s3bSevere <= s3aSevere + 1 {
            return "A_anchors_improve_coverage_safely"
        }
        if covGain > 0.02 || (s3b.resolvedCount > s3a.resolvedCount) {
            return "B_coverage_up_but_errors_remain"
        }
        if acceptedCount >= 2 {
            return "B_coverage_up_but_errors_remain"
        }
        return "C_insufficient_reliable_anchors"
    }

    private static func writeReport(_ report: PartialAlignmentReport, sessionID: UUID) throws {
        // Keep reports outside the capture tree so stop() scavengers don't
        // delete evidence before acceptance copies it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotifylyrics-s3a-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jsonURL = root.appendingPathComponent("partial-\(sessionID.uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: jsonURL, options: .atomic)

        let mdURL = root.appendingPathComponent("partial-\(sessionID.uuidString.prefix(8)).md")
        let c = report.candidate
        let h = report.heldOut
        let a = report.s3aCandidate
        let ah = report.s3aHeldOut
        var md = """
        # S3B Anchor-Constrained Partial Alignment Report

        - session: `\(c.captureSessionID.uuidString)`
        - identity: `\(c.trackIdentityDigest)`
        - locale: `\(c.locale)` fallback: \(c.localeFallbackReason ?? "none")
        - capturedDuration: \(fmt(c.capturedDuration)) s
        - transcriptSegments: \(c.transcriptSegmentCount)
        - judgment: **\(report.judgment)**
        - usedConstrainedAlignment: \(report.usedConstrainedAlignment)
        - s3bFallbackReason: \(report.s3bFallbackReason ?? "none")
        - acceptedAnchors: \(report.acceptedAnchors.count)
        - rejectedAnchors: \(report.rejectedAnchors.count)

        ## A/B comparison (same capture + plain lyrics)

        | metric | S3A | S3B |
        |---|---:|---:|
        | resolved | \(a?.resolvedCount ?? -1) | \(c.resolvedCount) |
        | lowConfidence | \(a?.lowConfidenceCount ?? -1) | \(c.lowConfidenceCount) |
        | unresolved | \(a?.unresolvedCount ?? -1) | \(c.unresolvedCount) |
        | outsideCapturedRange | \(a?.outsideCapturedRangeCount ?? -1) | \(c.outsideCapturedRangeCount) |
        | coverageRatio | \(a.map { fmt($0.coverageRatio) } ?? "n/a") | \(fmt(c.coverageRatio)) |
        | overallConfidence | \(a.map { fmt($0.overallConfidence) } ?? "n/a") | \(fmt(c.overallConfidence)) |
        | acceptedAnchors | 0 (n/a) | \(report.acceptedAnchors.count) |
        | rejectedAnchors | 0 (n/a) | \(report.rejectedAnchors.count) |

        ## Held-out errors (S3B primary)

        - compared: \(h.comparedLineCount)
        - medianAbsErr: \(h.medianAbsoluteError.map(fmt) ?? "n/a")
        - p90: \(h.p90AbsoluteError.map(fmt) ?? "n/a")
        - p95: \(h.p95AbsoluteError.map(fmt) ?? "n/a")
        - mean: \(h.meanAbsoluteError.map(fmt) ?? "n/a")
        - ≤0.5s: \(h.withinHalfSecondCount)
        - ≤1s: \(h.withinOneSecondCount)
        - ≤2s: \(h.withinTwoSecondCount)
        - obviousMismatch(>3s): \(h.obviousMismatchCount)
        - note: \(h.note)
        """
        if let ah {
            md += """


        ## Held-out errors (S3A baseline)

        - compared: \(ah.comparedLineCount)
        - medianAbsErr: \(ah.medianAbsoluteError.map(fmt) ?? "n/a")
        - p90: \(ah.p90AbsoluteError.map(fmt) ?? "n/a")
        - p95: \(ah.p95AbsoluteError.map(fmt) ?? "n/a")
        - mean: \(ah.meanAbsoluteError.map(fmt) ?? "n/a")
        - ≤0.5s: \(ah.withinHalfSecondCount)
        - ≤1s: \(ah.withinOneSecondCount)
        - ≤2s: \(ah.withinTwoSecondCount)
        - obviousMismatch(>3s): \(ah.obviousMismatchCount)
        - note: \(ah.note)
        """
        }
        md += """


        ## Accepted anchors
        """
        if report.acceptedAnchors.isEmpty {
            md += "\n- (none)"
        } else {
            for anc in report.acceptedAnchors {
                md += "\n- line=\(anc.lyricLineIndex) t=\(fmt(anc.absoluteStartTime))-\(fmt(anc.absoluteEndTime)) conf=\(fmt(anc.overallConfidence)) textSim=\(fmt(anc.textConfidence)) lyric=\(anc.lyricText.prefix(28)) speech=\(anc.transcriptText.prefix(28)) evidence=\(anc.evidence)"
            }
        }
        md += """


        ## Rejected anchors (first 30)
        """
        let rej = report.rejectedAnchors.prefix(30)
        if rej.isEmpty {
            md += "\n- (none)"
        } else {
            for anc in rej {
                md += "\n- line=\(anc.lyricLineIndex) reason=\(anc.rejectionReason ?? "?") conf=\(fmt(anc.overallConfidence)) textSim=\(fmt(anc.textConfidence)) lyric=\(anc.lyricText.prefix(24)) speech=\(anc.transcriptText.prefix(24))"
            }
        }
        md += """


        ## S3B lines (first 40)
        """
        for line in c.lines.prefix(40) {
            let t = line.startTime.map(fmt) ?? "-"
            md += "\n- [\(line.sourceLineIndex)] \(line.status.rawValue) t=\(t) conf=\(fmt(line.confidence)) kind=\(line.evidenceKind) \(line.text.prefix(36))"
        }
        if let a {
            md += """


        ## S3A lines (first 40)
        """
            for line in a.lines.prefix(40) {
                let t = line.startTime.map(fmt) ?? "-"
                md += "\n- [\(line.sourceLineIndex)] \(line.status.rawValue) t=\(t) conf=\(fmt(line.confidence)) kind=\(line.evidenceKind) \(line.text.prefix(36))"
            }
        }
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        SCKSpikeLog.log("S3B report json=\(jsonURL.path)")
        SCKSpikeLog.log("S3B report md=\(mdURL.path)")
    }

    private static func fmt(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}
