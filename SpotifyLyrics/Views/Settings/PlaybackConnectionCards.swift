import AppKit
import SwiftUI

struct PlaybackConnectionCards: View {
    @V3ContentPlaybackState var state: PlaybackState
    @ObservedObject var settings: AppSettingsStore
    @State private var available: [Client: Presence] = [:]
    @State private var notice: String?

    private enum Client: CaseIterable {
        case spotify, music
        var title: String { self == .spotify ? "Spotify" : "Apple Music" }
        var symbol: String { self == .spotify ? "waveform.circle" : "music.note" }
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var mode: PlaybackSourceMode { self == .spotify ? .spotify : .appleMusic }
        var source: PlaybackSourceIdentity { self == .spotify ? .spotifyDesktop : .appleMusic }
    }

    private struct Presence {
        let url: URL?
        let running: Bool
    }

    private var needsAutomation: Bool {
        return Client.allCases.contains { client in
            state.desktopConnectionStatus[client.source] == .permissionDenied && available[client]?.running == true &&
                (settings.playbackSourceMode == .auto || settings.playbackSourceMode == client.mode)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Button {
                    select(.auto)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: settings.playbackSourceMode == .auto ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(WorkspacePalette.ink)
                        Text("自动跟随").font(.callout.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .help("跟随正在播放的 Spotify 或 Apple Music")
                .accessibilityAddTraits(settings.playbackSourceMode == .auto ? .isSelected : [])
                Spacer()
                Button(state.providerStatus == .connecting ? "检测中…" : "重新检测", systemImage: "arrow.clockwise") {
                    notice = nil
                    state.checkPlaybackConnection()
                    refreshPresence()
                }
                    .disabled(state.providerStatus == .connecting || state.isUsingMockPreview)
                    .buttonStyle(.borderless)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 11) {
                    card(.spotify).frame(minWidth: 176)
                    card(.music).frame(minWidth: 176)
                }
                VStack(spacing: 8) { card(.spotify); card(.music) }
            }
            if settings.playbackSourceMode == .spotify {
                Toggle("启动时自动检测 Spotify", isOn: $settings.connectSpotifyOnLaunch)
                    .toggleStyle(V3RowToggleStyle())
            }
            if needsAutomation {
                Label("请在「隐私与安全性 › 自动化」允许星弦控制播放器。", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开系统设置") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.borderless)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { refreshPresence() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification), perform: applicationChanged)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification), perform: applicationChanged)
    }

    private func card(_ client: Client) -> some View {
        let selected = settings.playbackSourceMode == client.mode
        let active = state.hasLiveTrack && state.playbackSourceIdentity == client.source && !state.isUsingMockPreview
        let local = available[client]
        return VStack(alignment: .leading, spacing: 9) {
            Button {
                select(client.mode)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: client.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(WorkspacePalette.ink)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(client.title).font(.callout.weight(.semibold))
                        Text(status(for: client, local: local, active: active))
                            .font(.caption).foregroundStyle(active ? WorkspacePalette.ink : .secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(WorkspacePalette.ink) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("使用 \(client.title)，\(status(for: client, local: local, active: active))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button("打开 \(client.title)", systemImage: "arrow.up.right") { open(client) }
                .buttonStyle(.borderless).font(.caption).disabled(local?.url == nil)
        }
        .padding(11)
        .background(selected ? WorkspacePalette.selection : .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(selected ? 0 : 0.065)))
    }

    private func status(for client: Client, local: Presence?, active: Bool) -> String {
        if active { return (state.isPlaying ? "正在播放 · " : "已暂停 · ") + state.currentTrack.title }
        guard let local else { return "正在检查本机…" }
        guard local.url != nil else { return "未安装" }
        guard local.running else { return "App 未打开" }
        if settings.playbackSourceMode == client.mode, state.providerStatus == .connecting { return "正在检测…" }
        if let status = state.desktopConnectionStatus[client.source] {
            switch status {
            case .noTrack: return "已连接 · 未选曲"
            case .permissionDenied: return "需要系统自动化授权"
            case .unavailable: return "App 在运行 · 暂未读到播放状态"
            default: break
            }
        }
        return "App 在运行"
    }

    private func refreshPresence() {
        let workspace = NSWorkspace.shared
        available = Dictionary(uniqueKeysWithValues: Client.allCases.map { client in
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: client.bundleID).first
            return (client, Presence(url: app?.bundleURL ?? workspace.urlForApplication(withBundleIdentifier: client.bundleID), running: app != nil))
        })
    }

    private func select(_ mode: PlaybackSourceMode) {
        guard settings.playbackSourceMode != mode else { return }
        settings.playbackSourceMode = mode
        notice = nil
    }

    private func applicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Client.allCases.contains(where: { $0.bundleID == application.bundleIdentifier }) else { return }
        refreshPresence()
    }

    private func open(_ client: Client) {
        guard let url = available[client]?.url else { return }
        notice = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in notice = "无法打开 \(client.title)。\(error.localizedDescription)" } }
        }
    }
}
