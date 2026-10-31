import SwiftUI

struct V3PlaylistPanel: View {
    @ObservedObject var browser: PlaylistBrowserModel
    @ObservedObject private var picker: PlaylistPickerModel
    let query: String
    let currentTrackID: String?
    @State private var hoveredSidebarID: String?
    @State private var hoveredTrackOffset: Int?
    init(browser: PlaylistBrowserModel, query: String, currentTrackID: String? = nil) {
        self.currentTrackID = currentTrackID
        self.browser = browser; self.query = query
        _picker = ObservedObject(wrappedValue: browser.picker)
#if DEBUG
        // Offscreen fixture state only; never moves the user's pointer.
        if ProcessInfo.processInfo.arguments.contains("--playlist-hover-fixture") {
            _hoveredSidebarID = State(initialValue: "morning")
            _hoveredTrackOffset = State(initialValue: 0)
        }
#endif
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
                        destination(picker.likedRowTitle, symbol: "heart.fill", id: PlaylistBrowserModel.likedID)
                        Divider().padding(.vertical, 6)
                        ForEach(playlists) { playlist in
                            destination(playlist.name, symbol: "music.note.list", id: playlist.id, playlist: playlist)
                                .onAppear { picker.ensureMembership(for: playlist) }
                                .onChange(of: currentTrackID) { _, _ in picker.ensureMembership(for: playlist) }
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
                                if browser.selectedID == PlaylistBrowserModel.queueID {
                                    trackRow(item)
                                } else {
                                    trackRow(item).onTapGesture(count: 2) { browser.play(item) }
                                }
                            }
                        }
                    }
                    if let notice = browser.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(12) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { browser.open() }
        .onChange(of: currentTrackID) { _, _ in browser.loadQueue() }
    }
    private var selectedTitle: String {
        if browser.selectedID == PlaylistBrowserModel.queueID { return "接下来播放" }
        if browser.selectedID == PlaylistBrowserModel.likedID { return picker.likedRowTitle }
        return picker.playlists.first { $0.id == browser.selectedID }?.name ?? "歌单"
    }
    private func destination(_ title: String, symbol: String, id: String, playlist: PlaylistSummary? = nil) -> some View {
        HStack(spacing: 4) {
            Button { browser.select(id) } label: {
                HStack(spacing: 8) {
                    Group {
                        if let playlist { PlaylistCover(url: playlist.imageURL) }
                        else { Image(systemName: symbol).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)) }
                    }.frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).lineLimit(1)
                        if let playlist { Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if id != PlaylistBrowserModel.queueID {
                let checked = playlist.map { picker.isMember($0) } ?? picker.isLiked
                let busy = playlist.map { picker.isPending($0) || picker.isChecking($0) }
                    ?? picker.pending.contains(PlaylistPickerModel.likedRowID)
                Button {
                    if let playlist { picker.toggle(playlist) } else { picker.toggleLikedSongs() }
                } label: { membershipCircle(checked: checked, busy: busy) }
                    .buttonStyle(.plain).disabled(busy)
                    .opacity(checked || busy || hoveredSidebarID == id ? 1 : 0)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 6)
        .background(browser.selectedID == id ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hoveredSidebarID = $0 ? id : nil }
        .padding(.horizontal, 6)
    }

    private func trackRow(_ item: SpotifyPlaylistTrack) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: item.track.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note") }
                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading) {
                Text(item.track.title).lineLimit(1)
                Text(item.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if browser.selectedID != PlaylistBrowserModel.queueID {
                Button { browser.play(item) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.plain).help("播放这首歌")
                    .opacity(hoveredTrackOffset == item.offset ? 1 : 0)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(hoveredTrackOffset == item.offset ? Color.primary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hoveredTrackOffset = $0 ? item.offset : nil }
    }
    private func membershipCircle(checked: Bool, busy: Bool) -> some View {
        Group {
            if checked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.primary) }
            else if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: "circle").foregroundStyle(Color.primary.opacity(0.4)) }
        }.frame(width: 24, height: 28)
    }
}

struct V3PlaylistQueuePreview: View {
    @ObservedObject var browser: PlaylistBrowserModel
    let currentTrackID: String?
    @State private var hoveredRow: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(browser.queue.prefix(5).enumerated()), id: \.offset) { index, track in
                HStack(spacing: 8) {
                    AsyncImage(url: track.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note") }
                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hoveredRow == index ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onHover { hoveredRow = $0 ? index : nil }
            }
            if browser.isQueueLoading && browser.queue.isEmpty { ProgressView().controlSize(.small) }
            else if browser.queue.isEmpty, browser.notice == nil {
                Text("接下来没有待播歌曲").foregroundStyle(.secondary)
            }
            if let notice = browser.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.task(id: currentTrackID) { browser.loadQueue() }
    }
}
