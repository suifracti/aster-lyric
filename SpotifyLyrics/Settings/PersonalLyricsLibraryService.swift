import Foundation
import AppKit
import Combine

@MainActor
public final class PersonalLyricsLibraryService: ObservableObject {
    @Published public private(set) var entries: [PersonalLyricsLibraryEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var statusMessage: String = ""
    @Published public var searchQuery: String = ""

    @Published public var selectedTrackDetail: PersonalLyricsLibraryTrackDetail?
    private var detailRequestID = UUID()
    private var requestedTrackStableKey: String?
    @Published public var importPreview: PersonalLibraryImportPreview?
    @Published public var pendingImportPackage: PersonalLyricsLibraryPackage?
    @Published public var showImportPreviewSheet = false

    @Published public var dataImportPreview: PersonalDataImportPreview?
    @Published public var pendingDataPackage: PersonalDataPackage?
    @Published public var showDataImportPreviewSheet = false

    @Published public private(set) var syncFolderURL: URL?
    @Published public private(set) var isSyncing = false

    @Published public var revisionDraft: LibraryLyricsRevisionDraft?
    @Published public var translationRevisionDraft: LibraryTranslationRevisionDraft?
    @Published public var readingRevisionDraft: LibraryReadingRevisionDraft?
    @Published public var timingRevisionDraft: LibraryTimingRevisionDraft?
    @Published public private(set) var revisionError: String?
    @Published public private(set) var revisionBusy = false

    public func beginRevision(versionID: UUID, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = Track(title: entry.title, artist: entry.artist, album: entry.album ?? "", duration: entry.duration, isrc: entry.isrc, spotifyId: entry.spotifyTrackID, artworkURL: entry.artworkURL, spotifyURL: entry.spotifyURI.flatMap(URL.init(string:)))
                try await repository.prepare()
                guard let source = try await repository.loadEditableVersion(versionID: versionID, track: track, identity: TrackIdentity(track: track)) else {
                    throw LyricsEditingRepositoryError.sourceNotFound
                }
                revisionDraft = LibraryLyricsRevisionDraft(track: track, source: source)
            } catch {
                statusMessage = "打开编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveRevision(_ draft: LibraryLyricsRevisionDraft, confirmingTimingLoss: Bool = false) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let result = try await repository.saveManualEdit(
                    draft.saveRequest(confirmingTimingLoss: confirmingTimingLoss)
                )
                guard result.lyricsVersion != nil else { throw LyricsEditingRepositoryError.sourceNotFound }
                revisionDraft = nil
                refreshTrackDetail(stableKey: draft.source.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    public func beginTranslationRevision(version: PersonalTranslationVersionItem, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = libraryTrack(for: entry)
                let identity = TrackIdentity(track: track)
                try await repository.prepare()
                guard let lyricsSource = try await repository.loadEditableVersion(
                    versionID: version.lyricsVersionID, track: track, identity: identity
                ) else { throw LyricsEditingRepositoryError.sourceNotFound }
                let versions = try await repository.loadTranslationVersions(
                    lyricsVersionID: version.lyricsVersionID,
                    targetLanguage: version.targetLanguage,
                    sourceContentHash: lyricsSource.sourceContentHash
                )
                guard let source = versions.first(where: { $0.record.id == version.id }) else {
                    throw TranslationRepositoryError.versionNotFound
                }
                translationRevisionDraft = LibraryTranslationRevisionDraft(
                    track: track, lyricsSource: lyricsSource, source: source
                )
            } catch {
                statusMessage = "打开译文编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveTranslationRevision(_ draft: LibraryTranslationRevisionDraft) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let result = try await repository.saveManualEdit(draft.saveRequest())
                guard result.translationVersion != nil else { throw LyricsEditingRepositoryError.sourceNotFound }
                translationRevisionDraft = nil
                refreshTrackDetail(stableKey: draft.lyricsSource.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    public func beginReadingRevision(version: PersonalReadingVersionItem, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = libraryTrack(for: entry)
                let identity = TrackIdentity(track: track)
                try await repository.prepare()
                guard let lyricsSource = try await repository.loadEditableVersion(
                    versionID: version.lyricsVersionID, track: track, identity: identity
                ) else { throw LyricsEditingRepositoryError.sourceNotFound }
                let versions = try await repository.loadReadingVersions(
                    lyricsVersionID: version.lyricsVersionID,
                    representationID: version.representationID,
                    sourceContentHash: lyricsSource.sourceContentHash
                )
                guard let source = versions.first(where: { $0.record.id == version.id }) else {
                    throw ReadingRepositoryError.versionNotFound
                }
                readingRevisionDraft = LibraryReadingRevisionDraft(
                    track: track, lyricsSource: lyricsSource, source: source
                )
            } catch {
                statusMessage = "打开读音编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveReadingRevision(_ draft: LibraryReadingRevisionDraft) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                _ = try await repository.saveReadingVersion(draft.saveRequest())
                readingRevisionDraft = nil
                refreshTrackDetail(stableKey: draft.lyricsSource.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    public func beginTimingRevision(version: PersonalTimingVersionItem, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = libraryTrack(for: entry)
                let identity = TrackIdentity(track: track)
                try await repository.prepare()
                guard let lyricsSource = try await repository.loadEditableVersion(
                    versionID: version.lyricsVersionID, track: track, identity: identity
                ), let source = try await repository.loadPersonalLibraryTimingVersion(id: version.id),
                   source.lyricsVersionID == lyricsSource.record.id,
                   source.sourceContentHash == lyricsSource.sourceContentHash,
                   let draft = LibraryTimingRevisionDraft(track: track, lyricsSource: lyricsSource, source: source) else {
                    throw LyricsEditingRepositoryError.sourceNotFound
                }
                timingRevisionDraft = draft
            } catch {
                statusMessage = "打开逐字时间编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveTimingRevision(_ draft: LibraryTimingRevisionDraft) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                _ = try await repository.savePersonalLibraryTimingRevision(draft.saveRequest())
                timingRevisionDraft = nil
                refreshTrackDetail(stableKey: draft.lyricsSource.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    private let repository: SQLiteLyricsRepository
    private let defaults: UserDefaults
    private var pendingSyncFolderURL: URL?

    private func libraryTrack(for entry: PersonalLyricsLibraryEntry) -> Track {
        Track(
            title: entry.title,
            artist: entry.artist,
            album: entry.album ?? "",
            duration: entry.duration,
            isrc: entry.isrc,
            spotifyId: entry.spotifyTrackID,
            artworkURL: entry.artworkURL,
            spotifyURL: entry.spotifyURI.flatMap(URL.init(string:))
        )
    }

    public init(
        repository: SQLiteLyricsRepository = SQLiteLyricsRepository(),
        defaults: UserDefaults = .lyricsQ
    ) {
        self.repository = repository
        self.defaults = defaults
        self.syncFolderURL = PersonalDataSyncStore.restoreFolderReference(defaults: defaults)
    }

    public func refresh() {
        isLoading = true
        statusMessage = "正在加载歌词库..."
        let query = searchQuery
        Task {
            do {
                let list = try await repository.loadPersonalLibraryEntries(searchQuery: query.isEmpty ? nil : query)
                self.entries = list
                self.isLoading = false
                self.statusMessage = list.isEmpty ? "个人歌词库为空" : "共 \(list.count) 首本地资产歌曲"
            } catch {
                self.isLoading = false
                self.statusMessage = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    public func selectTrack(stableKey: String) {
        let requestID = UUID()
        detailRequestID = requestID
        requestedTrackStableKey = stableKey
        Task {
            do {
                let detail = try await repository.loadPersonalLibraryTrackDetail(stableKey: stableKey)
                guard detailRequestID == requestID else { return }
                selectedTrackDetail = detail
            } catch {
                guard detailRequestID == requestID else { return }
                statusMessage = "获取歌曲详情失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshTrackDetail(stableKey: String) {
        guard requestedTrackStableKey == stableKey else { return }
        selectTrack(stableKey: stableKey)
    }

    // MARK: - Version Actions

    public func adoptLyricsVersion(versionID: UUID, trackStableKey: String, applyToPlayback: ((UUID) async throws -> Bool)? = nil) {
        Task {
            do {
                try await repository.setPersonalLibraryActiveLyrics(trackStableKey: trackStableKey, lyricsVersionID: versionID)
                _ = try await applyToPlayback?(versionID)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "切换歌词版本失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleLyricsLock(versionID: UUID, currentLocked: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.toggleLyricsLocked(versionID: versionID, locked: !currentLocked)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "锁定歌词失败：\(error.localizedDescription)"
            }
        }
    }

    public func adoptTranslation(versionID: UUID, trackStableKey: String) {
        Task {
            do {
                try await repository.adoptTranslation(versionID: versionID)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "采用翻译失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleTranslationLock(versionID: UUID, currentLocked: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.markTranslationLocked(versionID: versionID, locked: !currentLocked)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "锁定翻译失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleTranslationArchive(versionID: UUID, currentArchived: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.archiveTranslation(versionID: versionID, archived: !currentArchived)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "归档翻译失败：\(error.localizedDescription)"
            }
        }
    }

    public func adoptReading(versionID: UUID, trackStableKey: String) {
        Task {
            do {
                try await repository.adoptReadingVersion(versionID: versionID)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "采用读音失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleReadingLock(versionID: UUID, currentLocked: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.markReadingLocked(versionID: versionID, locked: !currentLocked)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "锁定读音失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleReadingArchive(versionID: UUID, currentArchived: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.archiveReadingVersion(versionID: versionID, archived: !currentArchived)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "归档读音失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export / Import

    public func exportPackage(for stableKey: String) {
        Task {
            do {
                let package = try await repository.exportPersonalLibraryPackage(stableKey: stableKey)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(package)

                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.json]
                savePanel.nameFieldStringValue = "\(package.track.artist) - \(package.track.title).lyricisland.json"
                savePanel.title = "导出歌词资产包"
                savePanel.message = "导出包含歌词、翻译、读音与逐字时间轴的标准数据包"

                if savePanel.runModal() == .OK, let url = savePanel.url {
                    try data.write(to: url, options: .atomic)
                    self.statusMessage = "导出成功：\(url.lastPathComponent)"
                }
            } catch {
                self.statusMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    public func exportPersonalData() {
        Task {
            do {
                let package = try await repository.exportPersonalDataPackage()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(package)

                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.json]
                savePanel.nameFieldStringValue = "LyricIsland-Personal-Data-v1.lyricisland.json"
                savePanel.title = "导出个人数据"
                savePanel.message = "导出所有个人歌词、翻译、读音与逐字时间轴资产"

                if savePanel.runModal() == .OK, let url = savePanel.url {
                    try data.write(to: url, options: .atomic)
                    self.statusMessage = "个人数据导出成功：" + url.lastPathComponent
                }
            } catch {
                self.statusMessage = "个人数据导出失败：" + error.localizedDescription
            }
        }
    }

    public func presentImportDialog() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "选择要导入的歌词资产包"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let package = try decoder.decode(PersonalLyricsLibraryPackage.self, from: data)
                    let preview = try await repository.previewImportPersonalLibraryPackage(package)

                    self.pendingImportPackage = package
                    self.importPreview = preview
                    self.showImportPreviewSheet = true
                } catch {
                    self.statusMessage = "读取歌词包失败：\(error.localizedDescription)"
                }
            }
        }
    }

    public func presentPersonalDataImportDialog() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "选择个人数据包"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let package = try decoder.decode(PersonalDataPackage.self, from: data)
                    try package.validate()
                    let preview = try await repository.previewImportPersonalDataPackage(package)

                    self.pendingSyncFolderURL = nil
                    self.pendingDataPackage = package
                    self.dataImportPreview = preview
                    self.showDataImportPreviewSheet = true
                } catch {
                    self.statusMessage = "读取个人数据包失败：" + error.localizedDescription
                }
            }
        }
    }

    // MARK: - Private Folder Sync

    public func selectSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "选择私人同步文件夹"
        panel.message = "Lyric Island 将在此文件夹中保存一个个人数据包文件"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PersonalDataSyncStore.saveFolderReference(url, defaults: defaults)
                syncFolderURL = url.standardizedFileURL
                statusMessage = "已选择同步文件夹：" + url.path
            } catch {
                statusMessage = "选择同步文件夹失败：" + error.localizedDescription
            }
        }
    }

    public func cancelSyncFolder() {
        PersonalDataSyncStore.clearFolderReference(defaults: defaults)
        syncFolderURL = nil
        pendingSyncFolderURL = nil
        statusMessage = "已取消私人同步文件夹"
    }

    public func syncNow() {
        guard !isSyncing else { return }
        guard let folder = syncFolderURL ?? PersonalDataSyncStore.restoreFolderReference(defaults: defaults) else {
            statusMessage = "请先选择同步文件夹"
            return
        }

        syncFolderURL = folder
        isSyncing = true
        statusMessage = "正在检查同步文件夹..."

        Task {
            defer { self.isSyncing = false }
            do {
                let localPackage = try await repository.exportPersonalDataPackage()
                let remotePackage = try PersonalDataSyncStore.withFolderAccess(folder) {
                    try PersonalDataSyncStore.read(from: folder)
                }

                if let remotePackage {
                    let preview = try await repository.previewImportPersonalDataPackage(remotePackage)
                    if preview.hasConflicts || preview.totalNewAssets > 0 {
                        self.pendingSyncFolderURL = folder
                        self.pendingDataPackage = remotePackage
                        self.dataImportPreview = preview
                        self.showDataImportPreviewSheet = true
                        self.statusMessage = "发现同步目录数据，请先查看导入预览"
                    } else {
                        self.statusMessage = "同步检查完成：没有可导入的新个人资产，未自动覆盖"
                    }
                } else {
                    try PersonalDataSyncStore.withFolderAccess(folder) {
                        try PersonalDataSyncStore.write(localPackage, to: folder)
                    }
                    self.statusMessage = "已将 " + String(localPackage.tracks.count) + " 首歌曲写入同步文件夹"
                }
            } catch {
                self.statusMessage = "同步检查失败：" + error.localizedDescription
            }
        }
    }

    public func confirmImport() {
        guard let package = pendingImportPackage else { return }
        Task {
            do {
                try await repository.importPersonalLibraryPackage(package)
                self.statusMessage = "成功导入「\(package.track.title)」的歌词资产"
                self.pendingImportPackage = nil
                self.importPreview = nil
                self.showImportPreviewSheet = false
                refresh()
            } catch {
                self.statusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    public func confirmPersonalDataImport() {
        guard let package = pendingDataPackage else { return }
        let syncFolder = pendingSyncFolderURL
        Task {
            do {
                try await repository.importPersonalDataPackage(package)
                if let syncFolder {
                    let mergedPackage = try await repository.exportPersonalDataPackage()
                    try PersonalDataSyncStore.withFolderAccess(syncFolder) {
                        try PersonalDataSyncStore.write(mergedPackage, to: syncFolder)
                    }
                    self.statusMessage = "同步完成：已导入并安全更新同步文件"
                } else {
                    self.statusMessage = "成功导入 " + String(package.tracks.count) + " 首歌曲的个人资产"
                }
                self.pendingSyncFolderURL = nil
                self.pendingDataPackage = nil
                self.dataImportPreview = nil
                self.showDataImportPreviewSheet = false
                refresh()
            } catch {
                self.statusMessage = "个人数据包导入失败：" + error.localizedDescription
            }
        }
    }

    public func cancelImport() {
        self.pendingImportPackage = nil
        self.importPreview = nil
        self.showImportPreviewSheet = false
    }

    public func cancelPersonalDataImport() {
        pendingSyncFolderURL = nil
        self.pendingDataPackage = nil
        self.dataImportPreview = nil
        self.showDataImportPreviewSheet = false
    }
}
