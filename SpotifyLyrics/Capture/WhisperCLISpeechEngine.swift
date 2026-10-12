import Foundation
import AVFoundation

/// Optional experimental speech front-end via whisper-cli (whisper.cpp).
/// Does not embed models or auto-download. Paths come from env / gitignored config.
public struct WhisperCLISpeechEngine: LyricsSpeechEngine {
    public let engineID: SpeechEngineID = .whisperCLI

    public static let binaryEnvironmentKey = "SPOTIFYLYRICS_WHISPER_CLI"
    public static let modelEnvironmentKey = "SPOTIFYLYRICS_WHISPER_MODEL"
    /// Optional language override; default `ja`.
    public static let languageEnvironmentKey = "SPOTIFYLYRICS_WHISPER_LANGUAGE"
    public static let timeoutEnvironmentKey = "SPOTIFYLYRICS_WHISPER_TIMEOUT_SECONDS"

    private let environment: [String: String]
    private let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    public var isAvailable: Bool {
        binaryURL != nil && modelURL != nil
    }

    public var binaryURL: URL? {
        resolveExistingPath(
            environment[Self.binaryEnvironmentKey]
                ?? defaultBinaryCandidates.first { fileManager.isExecutableFile(atPath: $0) }
        )
    }

    public var modelURL: URL? {
        resolveExistingPath(environment[Self.modelEnvironmentKey])
            ?? defaultModelCandidates.compactMap { resolveExistingPath($0) }.first
    }

    private var defaultBinaryCandidates: [String] {
        [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ]
    }

    private var defaultModelCandidates: [String] {
        // Prefer S0.5 experiment path without committing the model to git.
        let home = fileManager.homeDirectoryForCurrentUser.path
        return [
            "\(home)/backup/sptifylyrics/docs/phase-2-11c-zero-operation-alignment/s0-5-engine-viability/whisper-models/ggml-small.bin",
            "\(home)/.cache/whisper/ggml-small.bin",
            "/tmp/ggml-small.bin"
        ]
    }

    private func resolveExistingPath(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func transcribe(
        pcmURL: URL,
        languageHint: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> SpeechEngineResult {
        guard fileManager.isReadableFile(atPath: pcmURL.path) else {
            throw SpeechEngineError.invalidAudio("PCM 音频不可读")
        }
        guard let binary = binaryURL else {
            throw SpeechEngineError.unavailable(
                "Whisper CLI 不可用：请设置 \(Self.binaryEnvironmentKey) 指向 whisper-cli"
            )
        }
        guard let model = modelURL else {
            throw SpeechEngineError.unavailable(
                "Whisper 模型不可用：请设置 \(Self.modelEnvironmentKey) 指向 ggml 模型（不自动下载）"
            )
        }

        // whisper-cli expects ISO language (`ja`), not Apple locale (`ja-JP`).
        let language = Self.normalizeLanguage(
            environment[Self.languageEnvironmentKey] ?? languageHint ?? "ja"
        )
        let timeout = Double(environment[Self.timeoutEnvironmentKey] ?? "180") ?? 180
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("SpotifyLyricsWhisper", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let outBase = work.appendingPathComponent("out")
        let args = [
            "-m", model.path,
            "-f", pcmURL.path,
            "-l", language,
            "-oj",
            "-of", outBase.path,
            "--no-prints"
        ]

        try Task.checkCancellation()
        progress?(0.05)
        let started = Date()
        let result = try await runProcess(
            executable: binary,
            arguments: args,
            timeout: timeout
        )
        progress?(0.9)

        if result.exitCode != 0 {
            let err = String(data: result.stderr, encoding: .utf8) ?? ""
            throw SpeechEngineError.failed(
                "whisper-cli 退出码 \(result.exitCode): \(err.prefix(240))"
            )
        }

        let jsonURL = outBase.appendingPathExtension("json")
        guard fileManager.fileExists(atPath: jsonURL.path) else {
            throw SpeechEngineError.failed("whisper-cli 未写出 JSON 结果")
        }
        let data = try Data(contentsOf: jsonURL)
        let segments = try Self.parseWhisperJSON(data)
        guard !segments.isEmpty else {
            throw SpeechEngineError.failed("whisper-cli 未产生有效片段")
        }
        let audioDuration = max(
            segments.map(\.endTime).max() ?? 0,
            (try? AVURLAsset(url: pcmURL).duration.seconds) ?? 0
        )
        let elapsed = Date().timeIntervalSince(started)
        SCKSpikeLog.log(
            "SPEECH engine=whisper_cli pieces=\(segments.count) elapsed=\(String(format: "%.2f", elapsed))s lang=\(language) model=\(model.lastPathComponent)"
        )
        progress?(1)
        return SpeechEngineResult(
            engineID: .whisperCLI,
            language: language,
            segments: segments,
            audioDuration: audioDuration > 0 ? audioDuration : (segments.last?.endTime ?? 0),
            diagnostics: [
                "binary=\(binary.path)",
                "model=\(model.path)",
                "exit=\(result.exitCode)"
            ],
            elapsedSeconds: elapsed
        )
    }

    /// Maps `ja-JP` / `en_US` → `ja` / `en` for whisper-cli.
    static func normalizeLanguage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "ja" }
        let primary = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? trimmed
        return primary.lowercased()
    }

    private struct ProcessResult: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let box = ProcessBox()
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await Self.launch(executable: executable, arguments: arguments, box: box)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(5, timeout) * 1_000_000_000))
                box.terminate()
                throw SpeechEngineError.timeout
            }
            defer {
                group.cancelAll()
                box.terminate()
            }
            guard let first = try await group.next() else {
                throw SpeechEngineError.failed("whisper-cli 无结果")
            }
            return first
        }
    }

    private static func launch(
        executable: URL,
        arguments: [String],
        box: ProcessBox
    ) async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: SpeechEngineError.cancelled)
                    return
                }
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.terminationHandler = { proc in
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    let stderr = err.fileHandleForReading.readDataToEndOfFile()
                    box.resume(cont, .success(ProcessResult(
                        exitCode: proc.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    )))
                }
                do {
                    try process.run()
                    box.attach(process)
                } catch {
                    box.resume(cont, .failure(SpeechEngineError.failed(error.localizedDescription)))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Parses whisper.cpp JSON (`-oj`) transcription array.
    static func parseWhisperJSON(_ data: Data) throws -> [SpeechEngineSegment] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeechEngineError.failed("whisper JSON 根对象无效")
        }
        let rows = (root["transcription"] as? [[String: Any]]) ?? []
        var segments: [SpeechEngineSegment] = []
        for (index, row) in rows.enumerated() {
            let text = ((row["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var start: TimeInterval = 0
            var end: TimeInterval = 0
            if let offsets = row["offsets"] as? [String: Any] {
                if let from = offsets["from"] as? Double { start = from / 1000.0 }
                else if let from = offsets["from"] as? Int { start = Double(from) / 1000.0 }
                if let to = offsets["to"] as? Double { end = to / 1000.0 }
                else if let to = offsets["to"] as? Int { end = Double(to) / 1000.0 }
            }
            if end <= start, let timestamps = row["timestamps"] as? [String: Any] {
                start = parseClock(timestamps["from"] as? String) ?? start
                end = parseClock(timestamps["to"] as? String) ?? (start + 0.2)
            }
            if end <= start { end = start + 0.05 }
            segments.append(
                SpeechEngineSegment(
                    index: segments.count,
                    text: text,
                    startTime: max(0, start),
                    endTime: end,
                    confidence: nil
                )
            )
            _ = index
        }
        return segments
    }

    /// Parses `00:00:01,234` or `00:00:01.234`.
    private static func parseClock(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var process: Process?

        func attach(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }
            self.process = process
            if settled {
                process.terminate()
            }
        }

        func terminate() {
            lock.lock()
            let proc = process
            lock.unlock()
            proc?.terminate()
        }

        func resume(_ cont: CheckedContinuation<ProcessResult, Error>, _ result: Result<ProcessResult, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            settled = true
            cont.resume(with: result)
        }
    }
}

