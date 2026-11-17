import AppKit
import Combine
import Foundation

@MainActor
public final class SettingsDataController: ObservableObject {
    @Published public private(set) var statistics: LyricsDatabaseStats?
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var isBusy = false

    @Published private(set) var artworkBytes: Int64 = 0
    @Published private(set) var canvasBytes: Int64 = 0

    private let repository: any LyricsRepository
    private let localIndex: LocalLyricsIndex

    public init(
        repository: any LyricsRepository = SQLiteLyricsRepository(),
        localIndex: LocalLyricsIndex = .shared
    ) {
        self.repository = repository
        self.localIndex = localIndex
    }

    public func refreshStatistics() {
        run("正在读取本机空间…") { "" }
    }

    public func createBackup() {
        run("正在备份歌词数据库…") { [repository] in
            let url = try await repository.createBackup()
            return "已创建备份 " + url.lastPathComponent
        }
    }

    public func clearLyricsCache() {
        run("正在清理封面与背景视频…") { [repository] in
            try await repository.clearLyricsCache()
            try await V3CanvasStore.shared.clearCache()
            ArtworkImageLoader.shared.clearCache()
            return "已清理封面与背景视频缓存。"
        }
    }

    func trashBackup(_ backup: LyricsDatabaseBackup) {
        guard let stats = statistics, stats.backups.contains(backup) else { return }
        run("正在整理备份…") {
            guard try LyricsDatabaseBackup.files(beside: stats.databaseURL).contains(backup) else {
                return "这份备份已移动，列表已更新。"
            }
            try FileManager.default.trashItem(at: backup.url, resultingItemURL: nil)
            return backup.url.lastPathComponent + " 已移到废纸篓。"
        }
    }

    func dismissNotice() { statusMessage = "" }

    public func rebuildLocalIndex() {
        let count = localIndex.rebuild()
        statusMessage = "本地歌词索引已重建（\(count) 个文件）"
    }

    public func revealDatabase() {
        let url = statistics?.databaseURL ?? SQLiteLyricsRepository.defaultDatabaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "数据库文件尚未创建"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func exportDiagnostics() {
        let stats = statistics
        let lines = [
            "SpotifyLyrics 脱敏诊断摘要",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "数据库文件：\(stats?.databaseURL.lastPathComponent ?? SQLiteLyricsRepository.defaultDatabaseURL.lastPathComponent)",
            "Schema：v\(stats?.schemaVersion ?? DatabaseMigrator.currentVersion)",
            "Track 数量：\(stats?.trackCount ?? 0)",
            "LyricsVersion 数量：\(stats?.lyricsVersionCount ?? 0)",
            "LyricLine 数量：\(stats?.lyricLineCount ?? 0)",
            "数据库大小：\(stats.map { Self.formatBytes($0.fileSize) } ?? "未知")",
            "最近更新时间：\(stats.flatMap(\.lastUpdated).map { ISO8601DateFormatter().string(from: $0) } ?? "未知")",
            "注意：此摘要不包含 Client Secret、Access Token、Refresh Token 或完整授权响应。"
        ]
        let directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = directory.appendingPathComponent("SpotifyLyrics-Diagnostics-\(Self.fileTimestamp()).txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "诊断摘要已导出：\(url.lastPathComponent)"
        } catch {
            statusMessage = "诊断摘要导出失败：\(error.localizedDescription)"
        }
    }

    private func run(_ message: String, operation: @escaping @MainActor () async throws -> String) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = message
        Task {
            defer { isBusy = false }
            var result = ""
            do {
                result = try await operation()
                statistics = try await repository.statistics()
                artworkBytes = ArtworkImageLoader.shared.diskBytes
                canvasBytes = try await V3CanvasStore.shared.diskBytes()
                statusMessage = result
            } catch {
                statusMessage = [result, error.localizedDescription].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
