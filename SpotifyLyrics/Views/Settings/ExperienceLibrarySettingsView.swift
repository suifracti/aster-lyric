import SwiftUI

/// The Release-facing catalog browser.  It is deliberately a thin shell over
/// PresentationCatalog and the immutable preview adapters: it does not own a
/// playback session, a window, a timer, or a persistence repository.
struct ExperienceLibrarySettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var selectionStore: PresentationSelectionStore

    @State private var selectedCategory: PresentationCategory
    @State private var selectedStableID: String
    @State private var compareStableID: String?
    @State private var compareEnabled = false
    @State private var capsuleState: PresentationPreviewCapsuleState = .expanded
    @State private var notice: String?

    private let catalog = PresentationCatalog.shared

    init(selectionStore: PresentationSelectionStore, initialCategory: PresentationCategory = .mainWindow) {
        self.selectionStore = selectionStore
        _selectedCategory = State(initialValue: initialCategory)
        _selectedStableID = State(initialValue: selectionStore.currentStableID(for: initialCategory))
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(width: 172)
            Divider()
            detailColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectInitialEntry()
        }
        .onChange(of: selectedCategory) { _, _ in
            selectInitialEntry()
        }
    }

    private var categoryList: some View {
        List(PresentationCategory.allCases, selection: $selectedCategory) { category in
            Label(category.displayName, systemImage: category.systemImageName)
                .tag(category)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("体验版本库分类")
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExperiencePageHeader(
                    title: "体验版本库",
                    detail: "预览并应用已经接入的主窗口、浮动表面和歌词呈现版本。预览不会改变播放位置或歌词数据库。"
                )

                Text("当前分类：\(selectedCategory.displayName)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                versionCards

                if let entry = selectedEntry {
                    versionDetail(entry)
                } else {
                    Text("此分类暂无可用版本")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
        }
    }

    private var versionCards: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(catalog.entries(for: selectedCategory)) { entry in
                Button {
                    selectedStableID = entry.stableID
                    compareEnabled = false
                    compareStableID = nil
                    notice = nil
                } label: {
                    ExperienceVersionRow(
                        entry: entry,
                        isSelected: entry.stableID == selectedStableID,
                        isCurrent: entry.stableID == selectionStore.currentStableID(for: selectedCategory),
                        isPreviewing: entry.stableID == selectionStore.transientPreviewStableID(for: selectedCategory)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func versionDetail(_ entry: PresentationMetadata) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.displayName)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(entry.stableID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.availability.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            LabeledContent("状态", value: entry.status.displayName)
            LabeledContent("版本", value: entry.version)
            LabeledContent("可用表面", value: entry.compatibleSurfaces.map(\.displayName).joined(separator: "、"))
            Text(entry.accessibilityNotes)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("预览") {
                    if selectionStore.beginPreview(category: selectedCategory, stableID: entry.stableID) {
                        notice = "预览中：尚未应用到正式设置"
                    } else {
                        notice = "此版本暂不支持预览"
                    }
                }
                .disabled(!entry.isPreviewable)

                Button("应用") {
                    apply(entry)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.canApplyPresentation(category: selectedCategory, stableID: entry.stableID))

                Button("取消预览") {
                    selectionStore.cancelPreview(for: selectedCategory)
                    notice = "已取消\(selectedCategory.displayName)预览"
                }
                .disabled(selectionStore.transientPreviewStableID(for: selectedCategory) == nil)

                Button("恢复推荐") {
                    let restored = settings.restoreRecommendedPresentation(for: selectedCategory)
                    selectedStableID = restored
                    compareEnabled = false
                    compareStableID = nil
                    notice = "已恢复推荐版本"
                }
            }

            if selectedCategory == .capsule,
               entry.isPreviewable {
                Picker("胶囊状态", selection: $capsuleState) {
                    ForEach(PresentationPreviewCapsuleState.allCases, id: \.self) { state in
                        Text(state.displayName).tag(state)
                    }
                }
                .pickerStyle(.segmented)
            }

            if entry.isPreviewable {
                previewControls(entry)
                previewSurface(entry)
                    .frame(minHeight: 250, maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("这是设计记录，当前没有可运行预览或应用入口。")
                }
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewControls(_ entry: PresentationMetadata) -> some View {
        HStack(spacing: 10) {
            Toggle("A/B 对照", isOn: $compareEnabled)
                .toggleStyle(.switch)
                .disabled(catalog.entries(for: selectedCategory).count < 2)

            if compareEnabled {
                Picker("对照版本", selection: Binding(
                    get: { compareStableID ?? comparisonCandidate(for: entry).stableID },
                    set: { compareStableID = $0 }
                )) {
                    ForEach(catalog.entries(for: selectedCategory).filter { $0.stableID != entry.stableID }) { candidate in
                        Text(candidate.displayName).tag(candidate.stableID)
                    }
                }
                .frame(maxWidth: 220)
            }
            Spacer()
        }
        .font(.system(size: 12, design: .rounded))
    }

    @ViewBuilder
    private func previewSurface(_ entry: PresentationMetadata) -> some View {
        let context = previewContext(for: entry)
        if compareEnabled,
           let comparisonEntry = catalog.metadata(for: compareStableID ?? comparisonCandidate(for: entry).stableID) {
            HStack(spacing: 1) {
                previewPane(entry, context: context)
                previewPane(comparisonEntry, context: context)
            }
        } else {
            previewPane(entry, context: context)
        }
    }

    private func previewPane(_ entry: PresentationMetadata, context: PresentationPreviewContext) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.displayName)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            PresentationPreviewAdapterView(entry: entry, context: context)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
    }

    private func previewContext(for entry: PresentationMetadata) -> PresentationPreviewContext {
        let surface = entry.compatibleSurfaces.first(where: { $0 != .preview }) ?? .preview
        return PresentationPreviewContext.mock(
            surface: surface,
            windowSize: PresentationPreviewSize(width: 720, height: 360),
            capsuleState: capsuleState
        )
    }

    private func comparisonCandidate(for entry: PresentationMetadata) -> PresentationMetadata {
        catalog.entries(for: selectedCategory).first(where: { $0.stableID != entry.stableID && $0.isPreviewable })
            ?? entry
    }

    private var selectedEntry: PresentationMetadata? {
        catalog.metadata(for: selectedStableID).flatMap { $0.category == selectedCategory ? $0 : nil }
    }

    private func selectInitialEntry() {
        let current = selectionStore.currentStableID(for: selectedCategory)
        if catalog.metadata(for: current)?.category == selectedCategory {
            selectedStableID = current
        } else {
            selectedStableID = catalog.recommended(for: selectedCategory)?.stableID
                ?? catalog.entries(for: selectedCategory).first?.stableID
                ?? ""
        }
        compareEnabled = false
        compareStableID = nil
        notice = nil
    }

    private func apply(_ entry: PresentationMetadata) {
        guard settings.applyPresentationSelection(category: selectedCategory, stableID: entry.stableID) else {
            notice = "此版本当前不能应用"
            return
        }
        notice = "已应用：\(entry.displayName)"
    }
}

private struct ExperienceVersionRow: View {
    let entry: PresentationMetadata
    let isSelected: Bool
    let isCurrent: Bool
    let isPreviewing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isPreviewable ? "rectangle.on.rectangle" : "doc.text")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                    if isCurrent {
                        ExperienceBadge(text: "当前", tint: .accentColor)
                    }
                    if isPreviewing {
                        ExperienceBadge(text: "预览", tint: .orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.status.displayName)
                    Text("·")
                    Text(entry.availability.displayName)
                    if !entry.isPreviewable {
                        Text("· 不可应用")
                    }
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

private struct ExperiencePageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }
}

private struct ExperienceBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private extension PresentationCategory {
    var systemImageName: String {
        switch self {
        case .mainWindow: return "macwindow"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .capsule: return "rectangle.topthird.inset.filled"
        case .floatingLyrics: return "text.bubble"
        case .backdrop: return "rectangle.inset.filled"
        case .lyricsTransition: return "arrow.triangle.2.circlepath"
        case .lyricsState: return "list.bullet.rectangle"
        case .progress: return "chart.bar"
        case .responsiveLayout: return "rectangle.split.3x1"
        }
    }
}
