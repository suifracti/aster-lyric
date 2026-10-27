import AppKit
import SwiftUI

/// Popover behind the player's add-to-playlist button. It keeps Spotify's own ordering and
/// writes changes the moment a row is clicked, so there is nothing to confirm.
struct PlaylistPickerPopover: View {
    @ObservedObject var model: PlaylistPickerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Color.white.opacity(0.08))
            listContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 380, height: 480)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear { model.open() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("寻找播放列表", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var listContent: some View {
        switch model.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取歌单…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Button("重试") { model.load() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .ready:
            ScrollView {
                LazyVStack(spacing: 1) {
                    createRow
                    likedRow
                    ForEach(model.filteredPlaylists) { playlist in
                        playlistRow(playlist)
                    }
                    if model.filteredPlaylists.isEmpty, !model.trimmedQuery.isEmpty {
                        Text("没有匹配的歌单")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var createRow: some View {
        Button { model.createPlaylist() } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12))
                    if model.isCreatingPlaylist {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("新建列表").font(.system(size: 13, weight: .medium))
                    Text("「\(model.newPlaylistName)」").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isCreatingPlaylist)
        .help("新建播放列表，并加入当前歌曲")
    }

    private var likedRow: some View {
        Button { model.toggleLikedSongs() } label: {
            row(
                title: model.likedRowTitle,
                subtitle: model.likedCount.map { "\($0) 首" },
                artwork: AnyView(
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.32, blue: 0.85),
                                                          Color(red: 0.85, green: 0.35, blue: 0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(.white)
                    }
                ),
                checked: model.isLiked,
                busy: model.pending.contains(PlaylistPickerModel.likedRowID),
                checking: false
            )
        }
        .buttonStyle(.plain)
        .disabled(model.pending.contains(PlaylistPickerModel.likedRowID))
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        Button { model.toggle(playlist) } label: {
            row(
                title: playlist.name,
                subtitle: "\(playlist.trackCount) 首",
                artwork: AnyView(PlaylistCover(url: playlist.imageURL)),
                checked: model.isMember(playlist),
                busy: model.isPending(playlist),
                checking: model.isChecking(playlist)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isPending(playlist) || model.isChecking(playlist))
        .onAppear { model.ensureMembership(for: playlist) }
    }

    private func row(title: String, subtitle: String?, artwork: AnyView,
                     checked: Bool, busy: Bool, checking: Bool) -> some View {
        HStack(spacing: 10) {
            artwork.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            Group {
                if busy || checking {
                    ProgressView().controlSize(.small)
                } else if checked {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                } else {
                    Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(.white.opacity(0.22))
                }
            }
            .frame(width: 20)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Button("完成") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }
}

private struct PlaylistCover: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Right-click must open the picker instead of a menu. The catcher only claims
/// right-button events so the button underneath keeps its normal click.
struct V3RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return self
            default: return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}
