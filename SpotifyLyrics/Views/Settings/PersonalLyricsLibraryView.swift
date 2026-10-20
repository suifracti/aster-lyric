import SwiftUI

public struct PersonalLyricsLibraryView: View {
    @EnvironmentObject private var playback: PlaybackState
    @StateObject private var service = PersonalLyricsLibraryService()
    @State private var selectedStableKey: String?
    @State private var libraryFilter: LibraryFilter = .all
    @State private var showSyncFolder = false
    private let embeddedInSettings: Bool

    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "全部", translations = "有译文", manual = "人工歌词 / 译文", locked = "锁定歌词 / 译文"
        var id: Self { self }

        func includes(_ entry: PersonalLyricsLibraryEntry) -> Bool {
            switch self {
            case .all: return true
            case .translations: return entry.translationVersionCount > 0
            case .manual: return entry.hasManualLyrics || entry.hasManualTranslation
            case .locked: return entry.hasLockedLyrics || entry.hasLockedTranslation
            }
        }
    }

    private var visibleEntries: [PersonalLyricsLibraryEntry] {
        service.entries.filter(libraryFilter.includes)
    }

    private var currentSongEntry: PersonalLyricsLibraryEntry? {
        guard let identity = playback.currentTrackIdentity else { return nil }
        return service.entries.first { entry in
            entry.trackStableKey == identity.stableKey
                || (playback.liveLyricsVersionID != nil && entry.activeLyricsVersionID == playback.liveLyricsVersionID)
        }
    }

    public init() {
        embeddedInSettings = false
    }

    init(embeddedInSettings: Bool) {
        self.embeddedInSettings = embeddedInSettings
    }

    public var body: some View {
        Group {
            if embeddedInSettings {
                embeddedSettingsBody
            } else {
                NavigationSplitView {
                    sidebarContent
                        .frame(minWidth: 280)
                        .navigationTitle("我的歌词库")
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                Button {
                                    service.exportPersonalData()
                                } label: {
                                    Label("导出个人数据", systemImage: "archivebox")
                                }
                                .help("导出全部个人歌词资产")

                                Button {
                                    service.presentPersonalDataImportDialog()
                                } label: {
                                    Label("导入个人数据", systemImage: "shippingbox")
                                }
                                .help("导入标准个人数据包并先查看冲突")

                                Button {
                                    service.presentImportDialog()
                                } label: {
                                    Label("导入资产包", systemImage: "square.and.arrow.down")
                                }
                                .help("导入 .lyricisland.json 歌词资产包")

                                Button {
                                    service.refresh()
                                } label: {
                                    Label("刷新", systemImage: "arrow.clockwise")
                                }
                                .help("刷新歌词库")
                            }
                        }
                } detail: {
                    detailContent
                }
            }
        }
        .sheet(item: $service.revisionDraft) { draft in
            LibraryLyricsRevisionSheet(service: service, initialDraft: draft)
        }
        .sheet(item: $service.translationRevisionDraft) { draft in
            LibraryTranslationRevisionSheet(service: service, initialDraft: draft)
        }
        .sheet(item: $service.readingRevisionDraft) { draft in
            LibraryReadingRevisionSheet(service: service, initialDraft: draft)
        }
        .sheet(item: $service.timingRevisionDraft) { draft in
            LibraryTimingRevisionSheet(service: service, initialDraft: draft)
        }
        .sheet(isPresented: $service.showImportPreviewSheet) {
            if let preview = service.importPreview {
                PersonalLibraryImportPreviewSheet(preview: preview, onConfirm: {
                    service.confirmImport()
                }, onCancel: {
                    service.cancelImport()
                })
            }
        }
        .sheet(isPresented: $service.showDataImportPreviewSheet) {
            if let preview = service.dataImportPreview {
                PersonalDataImportPreviewSheet(preview: preview, onConfirm: {
                    service.confirmPersonalDataImport()
                }, onCancel: {
                    service.cancelPersonalDataImport()
                })
            }
        }
        .onAppear {
            service.refresh()
        }
    }

    private var embeddedSettingsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("我的歌词库")
                    .font(.system(size: 24, weight: .bold))
                Text("已保存的歌词与译文，可搜索、筛选、切换和编辑版本。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    service.exportPersonalData()
                } label: {
                    Label("导出", systemImage: "archivebox")
                }
                .help("导出全部个人歌词资产")

                Button {
                    service.presentPersonalDataImportDialog()
                } label: {
                    Label("导入数据", systemImage: "shippingbox")
                }
                .help("导入标准个人数据包并先查看冲突")

                Button {
                    service.presentImportDialog()
                } label: {
                    Label("导入资产", systemImage: "square.and.arrow.down")
                }
                .help("导入 .lyricisland.json 歌词资产包")

                Button {
                    service.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新歌词库")
            }

            Divider()

            GeometryReader { geometry in
                // Settings already owns the navigation column. Use only the
                // width it offers instead of enlarging the whole split view.
                let isWide = geometry.size.width >= 760
                let showsList = isWide || selectedStableKey == nil
                let listWidth = isWide ? 270 : (showsList ? geometry.size.width : 0)
                let detailWidth = max(0, geometry.size.width - listWidth - (isWide ? 1 : 0))
                // Keep the native List in one place across width changes.
                // Replacing it between conditional branches can leave stale
                // SwiftUI list attributes while the Settings sidebar animates.
                HStack(spacing: 0) {
                    sidebarContent
                        .frame(width: listWidth)
                        .clipped()
                        .accessibilityHidden(!showsList)
                    Divider()
                        .frame(width: isWide ? 1 : 0)
                        .opacity(isWide ? 1 : 0)
                    VStack(alignment: .leading, spacing: 8) {
                        if !isWide {
                            Button {
                                selectedStableKey = nil
                            } label: {
                                Label("返回歌曲列表", systemImage: "chevron.left")
                            }
                            .buttonStyle(.borderless)
                        }
                        detailContent
                    }
                    .frame(width: detailWidth)
                    .clipped()
                    .accessibilityHidden(detailWidth == 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let stableKey = selectedStableKey {
            PersonalLibraryTrackDetailView(service: service, stableKey: stableKey)
        } else {
            VStack(spacing: 12) {
                RecordShelfMark()
                    .frame(width: 48, height: 30)
                    .foregroundStyle(.tertiary)
                Text("选择一张唱片")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("从左侧记录架打开歌曲档案，查看、切换或编辑保存的版本。")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索歌曲或内容，按回车查找", text: $service.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        service.refresh()
                    }
                if !service.searchQuery.isEmpty {
                    Button {
                        service.searchQuery = ""
                        service.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !service.statusMessage.isEmpty {
                HStack {
                    Text(service.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            HStack {
                Menu {
                    Picker("筛选歌曲", selection: $libraryFilter) {
                        ForEach(LibraryFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                } label: {
                    Label(libraryFilter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                Spacer()
                Text("\(visibleEntries.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if let entry = currentSongEntry {
                Button {
                    libraryFilter = .all
                    selectedStableKey = entry.trackStableKey
                } label: {
                    Label("查看当前歌曲的已存版本", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            DisclosureGroup("私人文件夹同步", isExpanded: $showSyncFolder) {
                syncFolderSection
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if visibleEntries.isEmpty && !service.isLoading {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(service.searchQuery.isEmpty && libraryFilter == .all ? "还没有保存的歌词" : "没有符合条件的歌曲")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(service.searchQuery.isEmpty && libraryFilter == .all
                         ? "采用的歌词、保存的译文和人工编辑版本会收录在这里。"
                         : "试试其他搜索词，或切回全部歌曲。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
            } else {
                List(visibleEntries, selection: $selectedStableKey) { entry in
                    PersonalLibraryEntryRow(entry: entry)
                        .tag(entry.trackStableKey)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var syncFolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("同步文件夹", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("选择") {
                    service.selectSyncFolder()
                }
            }

            if let folder = service.syncFolderURL {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Button {
                        service.syncNow()
                    } label: {
                        Label(
                            service.isSyncing ? "检查中..." : "同步现在",
                            systemImage: service.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(service.isSyncing)

                    Button("取消同步") {
                        service.cancelSyncFolder()
                    }
                }
            } else {
                Text("尚未设置私人同步文件夹")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct PersonalLibraryEntryRow: View {
    let entry: PersonalLyricsLibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: entry.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(entry.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let album = entry.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 6) {
                if entry.lyricsVersionCount > 0 {
                    AssetBadge(
                        title: "歌词 \(entry.lyricsVersionCount)",
                        icon: entry.hasLockedLyrics ? "lock.fill" : (entry.hasManualLyrics ? "pencil" : nil)
                    )
                }
                if entry.translationVersionCount > 0 {
                    AssetBadge(
                        title: "译文 \(entry.translationVersionCount)",
                        icon: entry.hasLockedTranslation ? "lock.fill" : (entry.hasManualTranslation ? "pencil" : nil)
                    )
                }
                if entry.hasReading {
                    AssetBadge(
                        title: "读音",
                        icon: nil
                    )
                }
                if entry.hasFineTiming {
                    AssetBadge(
                        title: "逐字",
                        icon: nil
                    )
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AssetBadge: View {
    let title: String
    let icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(title)
                .font(.system(size: 10, weight: .regular))
        }
        .foregroundStyle(.secondary)
    }
}

private struct RecordShelfMark: View {
    var body: some View {
        VStack(spacing: 5) {
            Capsule().frame(width: 38, height: 3)
            Capsule().frame(width: 28, height: 3).frame(width: 38, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Track Detail View

public struct PersonalLibraryTrackDetailView: View {
    @EnvironmentObject private var playback: PlaybackState
    @ObservedObject var service: PersonalLyricsLibraryService
    let stableKey: String
    @State private var selectedSection: VersionSection = .all
    @State private var translationDeletionCandidate: PersonalTranslationVersionItem?
    @State private var showTranslationDeletionConfirmation = false

    private enum VersionSection: String, CaseIterable, Identifiable {
        case all = "全部", lyrics = "原词", translations = "译文", readings = "读音", timing = "时间轴"
        var id: Self { self }
    }

    public var body: some View {
        Group {
            if let detail = service.selectedTrackDetail, detail.entry.trackStableKey == stableKey {
                let lyricsVersions = detail.lyricsVersions.sorted { lhs, rhs in
                    if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                    return lhs.updatedAt > rhs.updatedAt
                }
                let translationVersions = detail.translationVersions.sorted { lhs, rhs in
                    if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                    return lhs.updatedAt > rhs.updatedAt
                }
                let readingVersions = detail.readingVersions.sorted { lhs, rhs in
                    if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                    return lhs.updatedAt > rhs.updatedAt
                }
                let timingVersions = detail.timingVersions.sorted { lhs, rhs in
                    if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                    return lhs.createdAt > rhs.createdAt
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        trackHeader(detail.entry)

                        Picker("版本类型", selection: $selectedSection) {
                            ForEach(VersionSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("切换当前版本会保留旧稿；锁定的版本不会被自动替换。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Section 1: Lyrics Versions
                        if selectedSection == .all || selectedSection == .lyrics {
                            versionSection(title: "原词", count: lyricsVersions.count, icon: "text.quote") {
                                if lyricsVersions.isEmpty {
                                    emptyPlaceholder("暂无保存的歌词版本")
                                } else {
                                    ForEach(lyricsVersions) { lv in
                                        lyricsVersionCard(lv, entry: detail.entry, versions: lyricsVersions)
                                    }
                                }
                            }
                        }

                        // Section 2: Translation Versions
                        if selectedSection == .all || selectedSection == .translations {
                            versionSection(title: "译文", count: translationVersions.count, icon: "character.bubble") {
                                if translationVersions.isEmpty {
                                    emptyPlaceholder("暂无保存的翻译版本")
                                } else {
                                    ForEach(translationVersions) { tv in
                                        translationVersionCard(tv, entry: detail.entry)
                                    }
                                }
                            }
                        }

                        // Section 3: Reading Versions
                        if selectedSection == .all || selectedSection == .readings {
                            versionSection(title: "读音", count: readingVersions.count, icon: "character.book.closed") {
                                if readingVersions.isEmpty {
                                    emptyPlaceholder("暂无保存的读音版本")
                                } else {
                                    ForEach(readingVersions) { rv in
                                        readingVersionCard(rv, entry: detail.entry)
                                    }
                                }
                            }
                        }

                        // Section 4: Timing Versions
                        if selectedSection == .all || selectedSection == .timing {
                            versionSection(title: "时间轴", count: timingVersions.count, icon: "waveform") {
                                if timingVersions.isEmpty {
                                    emptyPlaceholder("暂无保存的逐字时间轴")
                                } else {
                                    ForEach(timingVersions) { tm in
                                        timingVersionCard(tm, entry: detail.entry)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .id(stableKey)
            } else {
                VStack {
                    ProgressView()
                    Text("正在加载歌曲资产...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: stableKey) {
            service.selectTrack(stableKey: stableKey)
        }
        .alert("删除译文版本？", isPresented: $showTranslationDeletionConfirmation) {
            Button("删除", role: .destructive) {
                confirmTranslationDeletion()
            }
            Button("取消", role: .cancel) {
                translationDeletionCandidate = nil
            }
        } message: {
            if let version = translationDeletionCandidate, version.isCurrent {
                Text("将永久删除这条译文及其逐行内容。它正在使用，删除后会重新选择可用译文；原词和其他版本不受影响。")
            } else {
                Text("将永久删除这条译文及其逐行内容；原词和其他版本不受影响。")
            }
        }
    }

    private func confirmTranslationDeletion() {
        guard let version = translationDeletionCandidate else { return }
        translationDeletionCandidate = nil
        Task { @MainActor in
            guard await service.deleteTranslationVersion(versionID: version.id, trackStableKey: stableKey) else { return }
            playback.reconcileExternalTranslationDeletion(versionID: version.id, trackStableKey: stableKey)
        }
    }

    private func trackHeader(_ entry: PersonalLyricsLibraryEntry) -> some View {
        HStack(alignment: .center, spacing: 18) {
            AsyncImage(url: entry.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay(Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.artist)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                if let album = entry.album, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Button {
                service.exportPackage(for: entry.trackStableKey)
            } label: {
                Label("导出资产包", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func versionSection<Content: View>(
        title: String,
        count: Int,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(count) 个版本")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            Divider()
            content()
        }
    }

    private func emptyPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 8)
    }

    // MARK: - Version Rows

    private func lyricsVersionCard(_ lv: PersonalLyricsVersionItem, entry: PersonalLyricsLibraryEntry, versions: [PersonalLyricsVersionItem]) -> some View {
        let provenance = DatabaseSourceIdentifier.provenanceDescription(source: lv.source, parentVersionID: lv.parentVersionID) { id in
            guard let parent = versions.first(where: { $0.id == id }) else { return nil }
            return (parent.source, parent.parentVersionID)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    LibraryVersionLabel(kind: "lyrics", id: lv.id, originalTitle: DatabaseSourceIdentifier.displayName(for: lv.source))
                    if lv.parentVersionID != nil { statusTag("修订版", color: .orange) }
                    if lv.isCurrent { IslandStatusPill(title: "使用中", tone: .active) }
                    if lv.isLocked { IslandStatusPill(title: "已锁定") }
                    if lv.isManuallyEdited { statusTag("人工编辑", color: .secondary) }
                    if lv.isSynced { statusTag("时间轴", color: .secondary) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("编辑为新版本") { service.beginRevision(versionID: lv.id, entry: entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(service.revisionBusy)
                    if !lv.isCurrent {
                        Button("设为当前") {
                            service.adoptLyricsVersion(versionID: lv.id, trackStableKey: entry.trackStableKey, applyToPlayback: { try await playback.adoptCurrentLyricsVersion(versionID: $0) })
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    versionMenu {
                        Button(lv.isLocked ? "解锁" : "锁定") {
                            service.toggleLyricsLock(versionID: lv.id, currentLocked: lv.isLocked, trackStableKey: entry.trackStableKey)
                        }
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    metadataLabel("来源")
                    Text(provenance).foregroundStyle(.secondary).gridCellColumns(3)
                }
                GridRow {
                    metadataLabel("内容")
                    Text("\(lv.lineCount) 行 · \(lv.language)").foregroundStyle(.secondary)
                    metadataLabel("更新")
                    Text(formattedDate(lv.updatedAt)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.caption)
        }
        .versionRowSurface(isCurrent: lv.isCurrent)
    }

    private func translationVersionCard(_ tv: PersonalTranslationVersionItem, entry: PersonalLyricsLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    LibraryVersionLabel(kind: "translation", id: tv.id, originalTitle: tv.sourceKind.uppercased())
                    if tv.isCurrent { IslandStatusPill(title: "使用中", tone: .active) }
                    if tv.isLocked { IslandStatusPill(title: "已锁定") }
                    if tv.isArchived { statusTag("已归档", color: .secondary.opacity(0.7)) }
                    if tv.isManuallyEdited { statusTag("人工编辑", color: .secondary) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("编辑为新版本") {
                        service.beginTranslationRevision(version: tv, entry: entry)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.revisionBusy)
                    if !tv.isCurrent && !tv.isArchived {
                        Button("设为当前") { service.adoptTranslation(versionID: tv.id, trackStableKey: entry.trackStableKey) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    versionMenu {
                        Button(tv.isLocked ? "解锁" : "锁定") {
                            service.toggleTranslationLock(versionID: tv.id, currentLocked: tv.isLocked, trackStableKey: entry.trackStableKey)
                        }
                        Button(tv.isArchived ? "恢复" : "归档") {
                            service.toggleTranslationArchive(versionID: tv.id, currentArchived: tv.isArchived, trackStableKey: entry.trackStableKey)
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            translationDeletionCandidate = tv
                            showTranslationDeletionConfirmation = true
                        }
                        .disabled(tv.isLocked)
                        .help(tv.isLocked ? "请先解锁版本后再删除" : "永久删除此译文版本")
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    metadataLabel("目标语言")
                    Text(tv.targetLanguage).foregroundStyle(.secondary)
                    metadataLabel("内容")
                    Text("\(tv.lineCount) 行").foregroundStyle(.secondary)
                }
                GridRow {
                    metadataLabel("更新")
                    Text(formattedDate(tv.updatedAt)).foregroundStyle(.secondary).monospacedDigit().gridCellColumns(3)
                }
            }
            .font(.caption)
        }
        .versionRowSurface(isCurrent: tv.isCurrent)
    }

    private func readingVersionCard(_ rv: PersonalReadingVersionItem, entry: PersonalLyricsLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    LibraryVersionLabel(kind: "reading", id: rv.id, originalTitle: rv.representationID.contains("kana") ? "假名 (KANA)" : "罗马音 (ROMAJI)")
                    if rv.isCurrent { IslandStatusPill(title: "使用中", tone: .active) }
                    if rv.isLocked { IslandStatusPill(title: "已锁定") }
                    if rv.isArchived { statusTag("已归档", color: .secondary.opacity(0.7)) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("编辑为新版本") { service.beginReadingRevision(version: rv, entry: entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(service.revisionBusy)
                    if !rv.isCurrent && !rv.isArchived {
                        Button("设为当前") { service.adoptReading(versionID: rv.id, trackStableKey: entry.trackStableKey) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    versionMenu {
                        Button(rv.isLocked ? "解锁" : "锁定") {
                            service.toggleReadingLock(versionID: rv.id, currentLocked: rv.isLocked, trackStableKey: entry.trackStableKey)
                        }
                        Button(rv.isArchived ? "恢复" : "归档") {
                            service.toggleReadingArchive(versionID: rv.id, currentArchived: rv.isArchived, trackStableKey: entry.trackStableKey)
                        }
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    metadataLabel("来源")
                    Text(rv.sourceKind).foregroundStyle(.secondary)
                    metadataLabel("行数")
                    Text("\(rv.lineCount)").foregroundStyle(.secondary)
                }
                GridRow {
                    metadataLabel("更新")
                    Text(formattedDate(rv.updatedAt)).foregroundStyle(.secondary).monospacedDigit().gridCellColumns(3)
                }
            }
            .font(.caption)
        }
        .versionRowSurface(isCurrent: rv.isCurrent)
    }

    private func timingVersionCard(_ tm: PersonalTimingVersionItem, entry: PersonalLyricsLibraryEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    LibraryVersionLabel(kind: "timing", id: tm.id, originalTitle: tm.source.uppercased())
                    if tm.isCurrent { IslandStatusPill(title: "使用中", tone: .active) }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        metadataLabel("粒度")
                        Text(tm.granularity).foregroundStyle(.secondary)
                        metadataLabel("创建")
                        Text(formattedDate(tm.createdAt)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            Button("编辑为新版本") { service.beginTimingRevision(version: tm, entry: entry) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.revisionBusy)
        }
        .versionRowSurface(isCurrent: tm.isCurrent)
    }

    /// Less frequent, reversible actions (lock, archive) share one menu so
    /// each row shows at most two buttons.
    private func versionMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("锁定、归档等")
        .accessibilityLabel("更多版本操作")
    }

    private func metadataLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.tertiary)
            .frame(minWidth: 52, alignment: .leading)
    }

    private func statusTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private extension View {
    func versionRowSurface(isCurrent: Bool) -> some View {
        self
            .padding(.horizontal, isCurrent ? 12 : 0)
            .padding(.vertical, 12)
            .background(isCurrent ? Color.accentColor.opacity(0.06) : Color.clear)
            .overlay(alignment: .bottom) { Divider() }
            .overlay(alignment: .leading) {
                if isCurrent {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: 2)
                        .padding(.vertical, 8)
                }
            }
    }
}

// MARK: - Import Preview Sheet

private struct LibraryEditorHeading: View {
    let context: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 21, weight: .semibold, design: .serif))
        }
    }
}

public struct PersonalLibraryImportPreviewSheet: View {
    let preview: PersonalLibraryImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入歌词资产包预览")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("歌曲：\(preview.trackTitle) - \(preview.trackArtist)")
                    .font(.subheadline.bold())
                Text("资产新增统计：")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    summaryItem(title: "歌词版本", add: preview.lyricsToAdd, skip: preview.lyricsToSkip)
                    summaryItem(title: "翻译版本", add: preview.translationsToAdd, skip: preview.translationsToSkip)
                    summaryItem(title: "读音版本", add: preview.readingsToAdd, skip: preview.readingsToSkip)
                    summaryItem(title: "逐字时间轴", add: preview.timingsToAdd, skip: preview.timingsToSkip)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            if preview.hasConflicts {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("发现版本冲突")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                    Text("存在相同版本 ID 但内容不一致的资产，已阻止静默覆盖：")
                        .font(.caption)
                    ForEach(preview.allConflicts, id: \.self) { c in
                        Text("• \(c)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("确认导入") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.hasConflicts || preview.totalNewAssets == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func summaryItem(title: String, add: Int, skip: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.bold())
            Text("新增: \(add) · 跳过: \(skip)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Standard Personal Data Preview Sheet

public struct PersonalDataImportPreviewSheet: View {
    let preview: PersonalDataImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入个人数据预览")
                .font(.headline)

            Text("包含 " + String(preview.trackCount) + " 首歌曲，新增 " + String(preview.totalNewAssets) + " 项个人资产")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if preview.trackPreviews.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("此数据包不包含个人歌词资产")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(preview.trackPreviews, id: \.trackStableKey) { trackPreview in
                            trackSummary(trackPreview)
                        }
                    }
                }
                .frame(minHeight: 180)
            }

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("确认导入") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.hasConflicts || preview.totalNewAssets == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func trackSummary(_ trackPreview: PersonalLibraryImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trackPreview.trackTitle + " — " + trackPreview.trackArtist)
                .font(.subheadline.bold())

            HStack(spacing: 12) {
                summaryItem(title: "歌词", add: trackPreview.lyricsToAdd, skip: trackPreview.lyricsToSkip)
                summaryItem(title: "翻译", add: trackPreview.translationsToAdd, skip: trackPreview.translationsToSkip)
                summaryItem(title: "读音", add: trackPreview.readingsToAdd, skip: trackPreview.readingsToSkip)
                summaryItem(title: "逐字时间轴", add: trackPreview.timingsToAdd, skip: trackPreview.timingsToSkip)
            }

            if trackPreview.hasConflicts {
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现冲突，已阻止静默覆盖")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    ForEach(trackPreview.allConflicts, id: \.self) { conflict in
                        Text("• " + conflict)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func summaryItem(title: String, add: Int, skip: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.bold())
            Text("新增: " + String(add) + " · 跳过: " + String(skip))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(5)
    }
}

// MARK: - Unified Library & Listening History Window

public struct UnifiedLibraryHistoryWindowView: View {
    @EnvironmentObject private var playback: PlaybackState
    @EnvironmentObject private var appSettings: AppSettingsStore

    public init() {}

    public var body: some View {
        contentArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                }
            }
        .frame(minWidth: 880, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Text("歌词库与收听记录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Picker("视图", selection: $playback.selectedLibraryToolTab) {
                ForEach(LibraryToolTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .accessibilityIdentifier("segmented_library_tool_tabs")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var contentArea: some View {
        switch playback.selectedLibraryToolTab {
        case .library:
            PersonalLyricsLibraryView()
        case .history:
            ListeningHistoryView()
        case .statistics:
            ListeningStatisticsView()
        }
    }
}


/// Local presentation metadata only; asset identity and source content stay immutable.
struct LibraryVersionLabel: View {
    let originalTitle: String
    @AppStorage private var customTitle: String
    @AppStorage private var note: String
    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var draftNote = ""

    init(kind: String, id: UUID, originalTitle: String) {
        self.originalTitle = originalTitle
        let key = "personalLibrary.versionLabel.\(kind).\(id.uuidString)"
        _customTitle = AppStorage(wrappedValue: "", key + ".title", store: UserDefaults.lyricsQ)
        _note = AppStorage(wrappedValue: "", key + ".note", store: UserDefaults.lyricsQ)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(customTitle.isEmpty ? originalTitle : customTitle)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .help(customTitle.isEmpty ? originalTitle : customTitle)
                Button {
                    draftTitle = customTitle
                    draftNote = note
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("名称与备注")
                .accessibilityLabel("编辑名称与备注：\(customTitle.isEmpty ? originalTitle : customTitle)")
            }
            if !customTitle.isEmpty {
                Text("原始名称：\(originalTitle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(note)
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("版本名称与备注")
                    .font(.headline)
                Text("原始名称：\(originalTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义名称").font(.subheadline)
                    TextField("留空使用原始名称", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("自定义版本名称")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("备注").font(.subheadline)
                    TextEditor(text: $draftNote)
                        .font(.body)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
                        .accessibilityLabel("版本备注")
                }
                Text("仅保存在本机，不随资产包导出。歌词原文、来源和采用状态保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("恢复默认") {
                        customTitle = ""
                        note = ""
                        isEditing = false
                    }
                    .disabled(customTitle.isEmpty && note.isEmpty && draftTitle.isEmpty && draftNote.isEmpty)
                    .help("清除自定义名称和备注，恢复原始显示")
                    Spacer()
                    Button("取消") { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") {
                        customTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        isEditing = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
    }
}


private struct LibraryLyricsRevisionSheet: View {
    @ObservedObject var service: PersonalLyricsLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryLyricsRevisionDraft
    @State private var timingLossPendingDraft: LibraryLyricsRevisionDraft?
    @State private var showTimingLossConfirmation = false
    private static let secondsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    init(service: PersonalLyricsLibraryService, initialDraft: LibraryLyricsRevisionDraft) {
        self.service = service
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryEditorHeading(context: "LYRICS REVISION", title: "编辑歌词为新版本")
            Text("\(draft.track.title) · \(draft.track.artist)").font(.headline)
            Text("保存后生成独立修订版，原版保留，当前采用不变。回到歌词库可选择任一版本“设为当前”。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("开始时间（秒）").frame(width: 110, alignment: .leading)
                Text("歌词原文")
            }.font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($draft.lines) { $line in
                        HStack(alignment: .top, spacing: 12) {
                            TextField("未排时间", value: $line.startTime, formatter: Self.secondsFormatter)
                                .frame(width: 110)
                                .accessibilityLabel("歌词开始时间")
                            TextField("歌词", text: $line.originalText, axis: .vertical)
                                .lineLimit(1...6)
                                .accessibilityLabel("歌词原文")
                            Button {
                                draft.lines.removeAll { $0.id == line.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .help("移除此草稿行")
                                .disabled(draft.lines.count <= 1)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(service.revisionBusy)
            if let error = service.revisionError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("添加歌词行") { draft.lines.append(LyricsEditorLineDraft(originalText: "")) }
                Spacer()
                if service.revisionBusy { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存为新版本") { requestSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasChanges)
            }
            .disabled(service.revisionBusy)
        }
        .padding(24)
        .frame(width: 760, height: 580)
        .interactiveDismissDisabled(service.revisionBusy)
        .alert("保存将丢失部分逐字时间", isPresented: $showTimingLossConfirmation) {
            Button("确认并保存兼容部分", role: .destructive) {
                if let pending = timingLossPendingDraft {
                    service.saveRevision(pending, confirmingTimingLoss: true)
                }
                timingLossPendingDraft = nil
            }
            Button("取消", role: .cancel) { timingLossPendingDraft = nil }
        } message: {
            Text(timingLossPendingDraft?.timingLossSummary.confirmationMessage ?? "取消不会写入数据库。")
        }
    }

    private func requestSave() {
        let summary = draft.timingLossSummary
        guard summary.requiresConfirmation else {
            service.saveRevision(draft)
            return
        }
        timingLossPendingDraft = draft
        showTimingLossConfirmation = true
    }
}

private struct LibraryTranslationRevisionSheet: View {
    @ObservedObject var service: PersonalLyricsLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryTranslationRevisionDraft

    init(service: PersonalLyricsLibraryService, initialDraft: LibraryTranslationRevisionDraft) {
        self.service = service
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryEditorHeading(context: "TRANSLATION REVISION", title: "编辑译文为新版本")
            Text("\(draft.track.title) · \(draft.track.artist) · \(draft.source.record.targetLanguage)")
                .font(.headline)
            Text("原译文会保留；保存后可在歌词库中选择要采用的版本。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(draft.lines.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(sourceLine(at: index))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            TextField("译文", text: $draft.lines[index], axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("第 \(index + 1) 行译文")
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(service.revisionBusy)
            revisionError
            HStack {
                Spacer()
                if service.revisionBusy { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存为新版本") { service.saveTranslationRevision(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasChanges || service.revisionBusy)
            }
        }
        .padding(24)
        .frame(width: 700, height: 600)
        .interactiveDismissDisabled(service.revisionBusy)
    }

    private func sourceLine(at index: Int) -> String {
        guard draft.lyricsSource.document.lines.indices.contains(index) else { return "第 \(index + 1) 行" }
        return draft.lyricsSource.document.lines[index].originalText
    }

    @ViewBuilder private var revisionError: some View {
        if let error = service.revisionError {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

private struct LibraryReadingRevisionSheet: View {
    @ObservedObject var service: PersonalLyricsLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryReadingRevisionDraft

    init(service: PersonalLyricsLibraryService, initialDraft: LibraryReadingRevisionDraft) {
        self.service = service
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryEditorHeading(context: "READING REVISION", title: "编辑读音为新版本")
            Text("\(draft.track.title) · \(draft.track.artist) · \(draft.source.record.representationID)")
                .font(.headline)
            Text("原读音会保留；保存后可在歌词库中选择要采用的版本。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(draft.lines.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(sourceLine(at: index))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            TextField("读音", text: $draft.lines[index], axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("第 \(index + 1) 行读音")
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(service.revisionBusy)
            if let error = service.revisionError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if service.revisionBusy { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存为新版本") { service.saveReadingRevision(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasChanges || service.revisionBusy)
            }
        }
        .padding(24)
        .frame(width: 700, height: 600)
        .interactiveDismissDisabled(service.revisionBusy)
    }

    private func sourceLine(at index: Int) -> String {
        guard draft.lyricsSource.document.lines.indices.contains(index) else { return "第 \(index + 1) 行" }
        return draft.lyricsSource.document.lines[index].originalText
    }
}

private struct LibraryTimingRevisionSheet: View {
    @ObservedObject var service: PersonalLyricsLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryTimingRevisionDraft
    private static let secondsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    init(service: PersonalLyricsLibraryService, initialDraft: LibraryTimingRevisionDraft) {
        self.service = service
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryEditorHeading(context: "TIMING REVISION", title: "编辑逐字时间轴为新版本")
            Text("\(draft.track.title) · \(draft.track.artist)").font(.headline)
            Text("修改时间会保留原时间轴。保存后歌词仍关联原歌词版本。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("原文与字词")
                Spacer()
                Text("开始（秒）").frame(width: 105)
                Text("结束（秒）").frame(width: 105)
            }
            .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($draft.lines) { $line in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(line.originalText)
                                .font(.callout.weight(.medium))
                                .textSelection(.enabled)
                            ForEach($line.spans) { $span in
                                HStack(spacing: 8) {
                                    Text(span.source.text + span.source.trailingWhitespace)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    TextField("开始", value: $span.startTime, formatter: Self.secondsFormatter)
                                        .frame(width: 105)
                                        .accessibilityLabel("\(span.source.text) 开始时间")
                                    TextField("结束", value: $span.endTime, formatter: Self.secondsFormatter)
                                        .frame(width: 105)
                                        .accessibilityLabel("\(span.source.text) 结束时间")
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(service.revisionBusy)
            if let error = service.revisionError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if service.revisionBusy { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存为新版本") { service.saveTimingRevision(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasChanges || service.revisionBusy)
            }
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(service.revisionBusy)
    }
}
