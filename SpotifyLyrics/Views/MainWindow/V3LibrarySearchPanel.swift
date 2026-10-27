import SwiftUI

struct V3LibrarySearchPresentation: Equatable {
    enum Tab: String, CaseIterable, Identifiable {
        case library, search
        var id: Self { self }
        var title: String { self == .library ? "歌词库" : "搜索" }
    }
    var tab: Tab?
    var isPresented: Bool { tab != nil }
    mutating func open(_ tab: Tab) { self.tab = tab }
    mutating func toggle(_ tab: Tab) { self.tab = self.tab == tab ? nil : tab }
    mutating func dismiss() { tab = nil }

    static func size(in canvas: CGSize) -> CGSize {
        CGSize(width: max(1, min(760, canvas.width - 80)), height: max(1, min(600, canvas.height - 80)))
    }
}

/// Reuses the drawer's existing library and full search views without changing the canvas layout.
struct V3LibrarySearchPanel: View {
    @Binding var presentation: V3LibrarySearchPresentation
    let state: PlaybackState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22)
                    .contentShape(Rectangle())
                    .onTapGesture { presentation.dismiss() }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Picker("歌词库与搜索", selection: Binding(
                            get: { presentation.tab ?? .library },
                            set: { presentation.open($0) }
                        )) {
                            ForEach(V3LibrarySearchPresentation.Tab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                        Spacer(minLength: 0)
                        Button("在新窗口打开") {
                            let tab = presentation.tab
                            presentation.dismiss()
                            openWindow(id: tab == .search ? "song-search" : "personal-library-activity")
                        }
                        .font(.caption).buttonStyle(.borderless)
                        Button { presentation.dismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭歌词库与搜索")
                    }
                    .padding(14)
                    Divider()
                    Group {
                        if presentation.tab == .search {
                            SongSearchPopover(manager: state.songSearchManager, playbackState: state, embedded: true)
                        } else {
                            PersonalLyricsLibraryView(embeddedInSettings: true)
                        }
                    }
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: V3LibrarySearchPresentation.size(in: geometry.size).width,
                       height: V3LibrarySearchPresentation.size(in: geometry.size).height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .environment(\.colorScheme, .dark)
                .accessibilityIdentifier("v3.librarySearchPanel")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onExitCommand { presentation.dismiss() }
        }
    }
}
