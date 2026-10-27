import SwiftUI

struct V3PlaylistPanel: View {
    @ObservedObject var browser: PlaylistBrowserModel
    @ObservedObject private var picker: PlaylistPickerModel
    let query: String
    init(browser: PlaylistBrowserModel, query: String) {
        self.browser = browser; self.query = query
        _picker = ObservedObject(wrappedValue: browser.picker)
    }
    private var playlists: [PlaylistSummary] {
        picker.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var tracks: [SpotifyPlaylistTrack] {
        browser.tracks.filter { query.isEmpty || $0.track.title.localizedCaseInsensitiveContains(query) || $0.track.artist.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        destination("接下来播放", symbol: "list.bullet", id: PlaylistBrowserModel.queueID)
                        HStack {
                            destination(picker.likedRowTitle, symbol: "heart.fill", id: PlaylistBrowserModel.likedID)
                            Button { picker.toggleLikedSongs() } label: {
                                membershipCircle(checked: picker.isLiked, busy: picker.pending.contains(PlaylistPickerModel.likedRowID))
                            }.buttonStyle(.plain).disabled(picker.pending.contains(PlaylistPickerModel.likedRowID))
                        }.padding(.trailing, 10)
                        Divider().padding(.vertical, 6)
                        ForEach(playlists) { playlist in
                            HStack(spacing: 4) {
                                Button { browser.select(playlist.id) } label: {
                                    HStack(spacing: 8) {
                                        PlaylistCover(url: playlist.imageURL).frame(width: 32, height: 32)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name).lineLimit(1)
                                            Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { picker.toggle(playlist) } label: {
                                    membershipCircle(checked: picker.isMember(playlist), busy: picker.isPending(playlist) || picker.isChecking(playlist))
                                }.buttonStyle(.plain).disabled(picker.isPending(playlist) || picker.isChecking(playlist))
                            }
                            .padding(.horizontal, 10).frame(height: 44)
                            .background(browser.selectedID == playlist.id ? .white.opacity(0.09) : .clear)
                            .onAppear { picker.ensureMembership(for: playlist) }
                        }
                        if case .loading = picker.phase { ProgressView().controlSize(.small).padding() }
                        if case .failed(let error) = picker.phase { Text(error).font(.caption).padding() }
                        if let notice = picker.notice { Text(notice).font(.caption).padding() }
                    }
                }.frame(width: min(300, geometry.size.width * 0.43))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedTitle).font(.headline).padding(.horizontal, 12).padding(.top, 12)
                    if browser.selectedTracksAreLoading { ProgressView().controlSize(.small).padding() }
                    if let message = browser.emptyMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tracks) { item in
                                HStack(spacing: 8) {
                                    AsyncImage(url: item.track.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note") }
                                        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(item.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Button { browser.play(item) } label: { Image(systemName: "play.fill") }
                                        .buttonStyle(.plain).help("播放这首歌")
                                }
                                .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
                                .onTapGesture(count: 2) { browser.play(item) }
                            }
                        }
                    }
                    if let notice = browser.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(12) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { browser.open() }
    }
    private var selectedTitle: String {
        if browser.selectedID == PlaylistBrowserModel.queueID { return "接下来播放" }
        if browser.selectedID == PlaylistBrowserModel.likedID { return picker.likedRowTitle }
        return picker.playlists.first { $0.id == browser.selectedID }?.name ?? "歌单"
    }
    private func destination(_ title: String, symbol: String, id: String) -> some View {
        Button { browser.select(id) } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 10)
                .background(browser.selectedID == id ? .white.opacity(0.09) : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func membershipCircle(checked: Bool, busy: Bool) -> some View {
        Group {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(checked ? .white : .white.opacity(0.4)) }
        }.frame(width: 24, height: 28)
    }
}

struct V3PlaylistQueuePreview: View {
    @ObservedObject var browser: PlaylistBrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(browser.queue.prefix(5).enumerated()), id: \.offset) { _, track in
                HStack(spacing: 8) {
                    AsyncImage(url: track.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note") }
                        .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if browser.isQueueLoading { ProgressView().controlSize(.small) }
            if let notice = browser.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.task { browser.loadQueue() }
    }
}
