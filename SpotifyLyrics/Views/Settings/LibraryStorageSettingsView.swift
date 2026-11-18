import AppKit
import SwiftUI

struct LibraryStorageSettingsView: View {
    @ObservedObject var data: SettingsDataController
    @State private var showsBackups = false
    @State private var showsLocation = false

    var body: some View {
        Section("本机空间") {
            if let stats = data.statistics {
                let databaseBytes = stats.fileSize + stats.journalBytes
                let backupBytes = stats.backups.reduce(0) { $0 + $1.bytes }
                let mediaBytes = data.artworkBytes + data.canvasBytes
                let total = databaseBytes + backupBytes + mediaBytes
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(size(total)).font(.system(size: 28, weight: .medium, design: .serif))
                        Spacer()
                        Button { data.refreshStatistics() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).disabled(data.isBusy).help("刷新用量").accessibilityLabel("刷新用量")
                    }
                    if total > 0 {
                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                WorkspacePalette.ink.frame(width: geometry.size.width * CGFloat(databaseBytes) / CGFloat(total))
                                Color.orange.frame(width: geometry.size.width * CGFloat(backupBytes) / CGFloat(total))
                                Color.secondary.opacity(0.45)
                            }
                        }
                        .frame(height: 7).clipShape(Capsule()).accessibilityHidden(true)
                    }
                    Text("\(stats.trackCount) 首歌 · \(stats.lyricsVersionCount) 份原词 · \(stats.lyricLineCount) 行")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                HStack {
                    marker(WorkspacePalette.ink)
                    Text("歌词数据库")
                    Spacer()
                    Text(size(databaseBytes)).monospacedDigit().foregroundStyle(.secondary)
                    Button("创建备份") { data.createBackup() }.disabled(data.isBusy)
                }
                DisclosureGroup(isExpanded: $showsBackups) {
                    if stats.backups.isEmpty {
                        Text("创建的数据库备份会出现在这里。").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 7) {
                                ForEach(stats.backups) { backup in backupRow(backup) }
                            }
                        }
                        .frame(height: min(145, CGFloat(stats.backups.count) * 34))
                    }
                } label: {
                    HStack {
                        marker(.orange)
                        Text("数据库备份").fixedSize()
                        Text("\(stats.backups.count) 份").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(size(backupBytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    marker(.secondary.opacity(0.55))
                    Text("封面与背景视频")
                    Spacer()
                    Text(size(mediaBytes)).monospacedDigit().foregroundStyle(.secondary)
                    Button("清理缓存") { data.clearLyricsCache() }
                        .disabled(data.isBusy || mediaBytes == 0)
                }
                DisclosureGroup("文件位置与内容", isExpanded: $showsLocation) {
                    Text(stats.databaseURL.path).font(.callout).textSelection(.enabled)
                    Text("数据库备份包含歌曲、歌词版本、译文、读音与播放记录。金句保存在旁边的 favorite-lines.json 中。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("数据格式", value: "v\(stats.schemaVersion)")
                    LabeledContent("网络封面与歌手照片", value: size(data.networkArtworkBytes))
                    LabeledContent("Apple Music 本机封面", value: size(data.localArtworkBytes))
                    LabeledContent("背景视频", value: size(data.canvasBytes))
                    HStack {
                        Button("在 Finder 中显示数据库") { data.revealDatabase() }
                        Button("重建本地歌词索引") { data.rebuildLocalIndex() }
                    }
                }
            } else if data.isBusy {
                ProgressView("读取用量…").controlSize(.small)
            } else {
                Button("读取本机空间") { data.refreshStatistics() }
            }
        }
    }

    private func marker(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }

    private func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func backupRow(_ backup: LyricsDatabaseBackup) -> some View {
        HStack(spacing: 7) {
            Text(backup.beforeUpgrade ? "升级前" : "手动备份").font(.caption.weight(.medium))
            Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(size(backup.bytes)).font(.caption.monospacedDigit())
            Menu {
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup.url])
                }
                Button("移到废纸篓", systemImage: "trash", role: .destructive) { data.trashBackup(backup) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(data.isBusy)
            .accessibilityLabel("管理备份").help(backup.url.lastPathComponent)
        }
        .frame(minHeight: 27)
    }
}
