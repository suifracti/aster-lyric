import SwiftUI

/// Trial navigation overlays the artwork; it never participates in lyric layout.
struct V3SideDrawer: View {
    enum Tab: String, CaseIterable, Identifiable {
        case library = "歌词库", search = "搜索"
        var id: Self { self }
    }
    @Binding var isOpen: Bool
    @Binding var tab: Tab
    let fromTrailing: Bool
    let state: PlaybackState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nearHandle = false
    @State private var pointerInsideDrawer = false
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let width = min(360, geometry.size.width * 0.4)
            ZStack(alignment: fromTrailing ? .trailing : .leading) {
                if isOpen {
                    Color.clear.contentShape(Rectangle()).onTapGesture { isOpen = false }
                    VStack(spacing: 0) {
                        HStack {
                            Picker("抽屉页面", selection: $tab) {
                                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden()
                            Button { isOpen = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("关闭侧边抽屉")
                        }.padding(12)
                        Divider()
                        switch tab {
                        case .library: PersonalLyricsLibraryView(embeddedInSettings: true)
                        case .search:
                            SongSearchPopover(manager: state.songSearchManager, playbackState: state, embedded: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: width, height: max(1, geometry.size.height - 80))
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
                    .environment(\.colorScheme, .dark)
                    .onHover { inside in
                        pointerInsideDrawer = inside
                        if inside { cancelClose() } else { scheduleClose() }
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: fromTrailing ? .trailing : .leading).combined(with: .opacity))
                    .accessibilityIdentifier("v3.sideDrawer")
                } else {
                    // Leave the outer 14-pt progress rail free for seeking.
                    Button { isOpen = true } label: {
                        Capsule().fill(.white.opacity(0.65)).frame(width: 3, height: 48)
                            .opacity(nearHandle ? 1 : 0)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .frame(width: 14, height: 84).contentShape(Rectangle())
                    .padding(fromTrailing ? .trailing : .leading, 15)
                    .onHover { inside in
                        nearHandle = inside
                        if inside { isOpen = true }
                    }
                    .accessibilityLabel("打开歌词库与搜索抽屉")
                }
            }
            .frame(width: geometry.size.width, height: max(1, geometry.size.height - 80),
                   alignment: fromTrailing ? .trailing : .leading)
            .offset(y: 80)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.24), value: isOpen)
        }
        .onChange(of: isOpen) { _, open in
            if open { scheduleClose() } else { cancelClose() }
        }
        .onDisappear { cancelClose() }
    }

    private func cancelClose() { closeTask?.cancel(); closeTask = nil }
    private func scheduleClose() {
        cancelClose()
        guard isOpen else { return }
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            closeTask = nil
            if !pointerInsideDrawer { isOpen = false }
        }
    }
}
