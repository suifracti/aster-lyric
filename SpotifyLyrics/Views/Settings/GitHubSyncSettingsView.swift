import SwiftUI

/// Shared GitHub private-repository sync controls for Settings and the Personal Library sidebar.
struct GitHubSyncSettingsView: View {
    @ObservedObject var service: GitHubLyricsSyncService
    var compact = false
    @State private var tokenDraft = ""

    @MainActor
    init(service: GitHubLyricsSyncService? = nil, compact: Bool = false) {
        self.service = service ?? GitHubLyricsSyncService.shared
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if compact {
                LabeledContent("私有仓库") {
                    TextField("用户名/仓库名", text: $service.repositoryText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
                LabeledContent("分支") {
                    TextField("main", text: $service.branchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            } else {
                TextField("私有仓库（用户名/仓库名，或 GitHub 链接）", text: $service.repositoryText)
                    .textFieldStyle(.roundedBorder)
                TextField("分支（默认 main）", text: $service.branchText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                SecureField(
                    service.hasStoredToken ? "已保存 Token（输入新值以替换）" : "GitHub Fine-grained PAT（仅保存在 Keychain）",
                    text: $tokenDraft
                )
                .textFieldStyle(.roundedBorder)
                .font(compact ? .caption : .body)

                Button("保存") {
                    service.saveToken(tokenDraft)
                    tokenDraft = ""
                }
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isSyncing)

                if service.hasStoredToken {
                    Button("清除") {
                        tokenDraft = ""
                        service.clearToken()
                    }
                    .disabled(service.isSyncing)
                }
            }

            Toggle("查到或保存新歌词、译文、金句后自动同步", isOn: $service.autoSyncEnabled)
                .font(compact ? .caption : .callout)
                .disabled(!service.isConfigured)

            Toggle("同时写入完整数据包 JSON（backup/LyricIslandPersonalData.json）", isOn: $service.includeDataPackageBackup)
                .font(compact ? .caption : .callout)

            HStack(spacing: 8) {
                Button {
                    service.triggerManualSync()
                } label: {
                    Label(service.isSyncing ? "同步中…" : "立即全部同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(service.isSyncing || !service.isConfigured)

                Button("检查连接") {
                    service.testConnection()
                }
                .disabled(service.isSyncing || !service.isConfigured)
            }

            if let message = service.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(service.isErrorStatus ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = service.lastSyncSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("仅允许同步到你自己的 GitHub 私有仓库；每首歌曲导出为独立 Markdown（原词、译文对照与金句），便于跨端与 GPT 检索；Token 仅存 Keychain。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
