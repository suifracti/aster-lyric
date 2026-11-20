# Aster · Lyric｜项目记忆

规则见 [AGENTS](../AGENTS.md)；规格维护在 [TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md)。Aster · Lyric / 星弦 / lyricsQ / Spotify Lyrics 同属本项目。**2026-11-20 精简热页：** L-001～L-053 完整逐字历史已无损归档至 [project-memory-archive-2026-11-20.md](archive/project-memory-archive-2026-11-20.md)。

## 按用户说法找经验

| 用户说法或本次触及范围 | 到哪里找 |
|---|---|
| 改名、换界面、旧数据/人工歌词不丢；清理缓存、备份、数据包导入、GitHub 私有库同步 | L-001、L-047、L-055 · `SettingsDataController`、`AppleMusicArtworkCache`、`writeDatabaseSnapshot`、`GitHubLyricsSyncService` |
| 从其他应用选字、⌘K 找回一句、读命中句、续读位置、歌本摘段 | L-043、L-046、L-051 · `WorkspaceQuickFind`、`LibraryPassageReader`、`LyricBookExcerptPicker` |
| 两份稿逐句对读、选这句、编辑定位、打开 TXT/LRC/TTML、写手稿 | L-048、L-049、L-050 · `LibraryVersionComparison`、`LyricFileDocument`、`LyricManuscript` |
| 新包、截图、构建/签名、性能采样；极简折叠；找回旧环境光与参数 | L-002、L-003、L-004 · [DEVELOPMENT_WORKFLOW](DEVELOPMENT_WORKFLOW.md)、`authenticAmbientArtworkLayers` |
| 已采用歌词被挡、重复入库、歌单不打勾、Desktop 时长跳变、幽灵记录 | L-005、L-006、L-039、L-040 · `TrackIdentity`、`redirectNewSpotifyKey`、`adoptedSameSpotifyTrackStableKey` |
| 本地搜索缓存、预加载重复搜词、找歌重开变回当前曲、队列与插播、停播校准 | L-007、L-008、L-054 · `searchCachedLibrary`、`LyricsSessionController.preloadedRecordingIDs`、`PlaylistBrowserModel`、`PlaybackState` |
| 版本弹窗错挂/黑屏、悬停转圈、歌词源译文补存/重对齐 | L-009、L-010、L-011 · `PersonalLyricsLibraryService`、`TranslationSessionController.synchronize` |
| 边缘进度与缩放冲突、胶囊、统一控件、工具栏/歌词/播放栏样式、亮背景/译文放大 | L-012、L-015、L-016、L-019、L-020、L-052 · `V3WindowEdgePlaybackOverlay`、`V3ControlBarSurface`、`V3BackdropBrightness` |
| 译文风格「我的风格」、提示词长度、模型刷新与档位 | L-017、L-042 · `AITranslationConfiguration`、`AITranslationPromptBuilder` |
| 模糊曲线、羽化圆形、主窗口订阅歌词库卡顿、独立窗口状态串扰 | L-018、L-052、L-054 · `V3BlurCurve`、`V3LibraryOwner`、`V3ListeningPresentation`、`V3Keepsakes` |
| 歌词源（プチリリ/QQ 500/健康休息）、歌手别名/外来语/同母带/纯文本升级/逐字优先与准时 | L-013、L-014、L-026、L-034～L-041 · `LyricsSafeMatcher`、`LyricsSourceHealth`、`LyricsWordTimingUpgrade`、`TimedLineBounds` |
| 视频 Canvas 瞬时峰值、歌手照片、封面占位闪屏、逐字动画、QRC/KRC/YRC、繁简与片假名注音 | L-021～L-024、L-053 · `Snappy`、`V3ArtistImageStore`、`ArtworkView`、`JapaneseRubyPresentation` |
| 天气粒子、VU 表、声纹、频谱、Metal 情境、窗口可见/暂停高帧耗电、流动 Butterchurn、律动静音 | L-025、L-027～L-029、L-032、L-054 · `V3WindowVisibilityProbe`、`V3AnimationIsland`、`V3CoverBreath`、`V3MusicPulse`、`V3SceneShaders` |
| 全屏选屏与 Esc、状态栏双行与滚动、顶部灵动岛与刘海、金句与外观多位置独立 | L-030、L-031、L-043～L-045 · `FullScreenLyricsWindowController`、`MenuBarTextFormatter`、`CapsuleNotchGeometry`、`AppearanceControl` |
| 多版本对比工作台、对唱声部真实歌手名、和声 TTML、AI 翻译进度弧 | L-032、L-052、L-053 · `LibraryVersionsWorkspace`、`LyricsTimeline.VoicePresentation`、`AITranslationLiveStage` |

## 默认自动执行与已有资产入口

规则继承 Vault 根 `AGENTS.md` 与 [仓库 AGENTS](../AGENTS.md)。

- 工程与检查：`SpotifyLyrics/`、`SpotifyLyrics.xcodeproj/`、`Tests/`、`Scripts/`、`Tools/`。
- 规格与构建：[TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md)、[DEVELOPMENT_WORKFLOW](DEVELOPMENT_WORKFLOW.md)、[STATUS](STATUS.md)；离屏图用 `Scripts/ui-snapshots.sh`（不替代真窗）。

## 核心长期约束与关键经验（L-001 ～ L-055）

### 数据身份、规则边界与构建取证（L-001 ～ L-004, L-033）

- **L-001 数据资产不随 UI/改名变化**：保留 Bundle ID (`com.spotifylyrics.app`)、正式 SQLite 路径、UserDefaults/Keychain 身份、旧 rawID、人工/锁定版本、live/preview 隔离与请求去重。
- **L-002 分别取证**：区分 unsigned 构建、稳定签名的 Keychain ACL/TCC、离屏图与真窗实机；性能对比写明歌曲、窗口、播放/暂停与构建；禁止运行 `pkill -x SpotifyLyrics`（会杀掉同名测试宿主 `L-041`）。
- **L-003 极简原则**：`folding, not cutting`，详见 [设计原则](TOOLBAR_BEHAVIOR.md#design-principle-user-2026-10-21)。
- **L-004 旧环境光参数**：`.authenticAmbient` (`v3ArtworkPresentation.authenticAmbient.v1`) 保留用户现存缩放/模糊参数；历史参考为 scale 1.12 / opacity 0.56 / blur*48。
- **L-033 增量类型布局崩溃**：改 `some View` 实际返回类型后若离屏宿主崩在 `initializeWithCopy`，先 `touch` 调用方 Swift 文件重编。

### 身份解析、搜索缓存、队列与播放同步（L-005 ～ L-008, L-021, L-039 ～ L-040）

- **L-005 存储键与请求 ID 分离**：`canonicalSpotifyTrackID`（小写）用于旧身份键，`spotifyRequestTrackID`（保大小写）用于 Spotify API；Apple Music 用合格 16 位持久 ID 区分同名录音；`resolveStableKey` / `TrackIdentity.playbackID` 用于当前曲判定与跨时长读取。
- **L-006 精确 ID 信任曲库元数据**：`SpotifyTrackArtistResolver` 以曲库标题、全歌手与时长作歌词匹配，Desktop duration 仅用于进度条，不改身份键。
- **L-007 搜索缓存与预加载**：`SQLiteLyricsRepository.searchCachedLibrary` 用 `data_version`/`total_changes` 按歌曲签名增量复用；`JapaneseMeCabEngine` 运行期缓存结果并将轮询降至 1 ms；`attemptedPreloadRecordingIDs` / `preloadedRecordingIDs` 按录音去重预加载（复用可见队列下两首，不触发 AI 翻译）。
- **L-008 队列与多来源播放状态**：`PlaylistBrowserModel` 按原始 offset 与一次性 skip 标记推进；Apple Music / Spotify 共用当前播放源；非当前播放器停播通知只更新自身状态，轻量校准发现停播或明确退出后统一回空闲；搜索窗/歌单窗与悬停面板共享查询但独立保留筛选。
- **L-021 重定向跨连接同步**：两个仓库对象写重定向前先查数据库 `track_identity_redirects` 并重载缓存，避免唯一键冲突阻塞已存歌词加载。
- **L-039 幽灵记录与批量补词**：`PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere` 折叠同 ID 或错用切歌 ID 的重复空行但不删库；`PlaybackState.lyricsBatch` 跨窗口延续并支持继续未查与仅重试失败。
- **L-040 兜底与同名读取**：`bestAvailableFallback` 在歌名（非仅包含）、歌手与无版本冲突下自动选用最佳时间轴候选；`adoptedSameSpotifyTrackStableKey` 同 ID+规范化歌名跨时长读取；已发送译文回写校对版本 UUID 与原词哈希。

### 歌词来源、匹配与逐字时间轴（L-013 ～ L-014, L-023, L-026, L-034 ～ L-038, L-041）

- **L-013 / L-026 来源接入与健康**：国内已接网易云、QQ（首选 `shc.y.qq.com` 失败回 `c.y.qq.com`）、酷狗、酷我；日文独立纯文本走补充源 `PetitLyricsProvider`（3–6s 补充源含 `lyrics.ovh`、`LinkCore`）。**L-035 `LyricsSourceHealth`** 对连续 2 次网络超时/5xx 故障源休眠 15 分钟并放至补充位，任意正常响应即唤醒。
- **L-014 / L-036 / L-037 / L-038 匹配规则**：支持繁简转换、标点/横线折叠、括号别名展开、部分歌手+毫秒同长（`durationExact` ≤0.05s / `sameMasterTolerance` 0.1s 且要求非整秒）或双源同词（`partialArtistLyricsAgreement`）、外来语辅音 `loanwordKey`、多合作署名与 `(Explicit)` 容忍（`promoteSameMaster`，**L-037**）、`titleBilingualPair`（**L-038**）。纯文本重查传 `plainAlreadyHeld` 等待时间轴来源（`waitsForTiming`）。伴奏/カラオケ 标为不可同长放行。
- **L-023 / L-041 逐字与行切换**：QQ QRC（自定义 3DES + S-box）、KRC、YRC 均用 `TimedLineBounds.covering` 确保行尾包住末字以参与逐字优先级；`probeNetworkProviders` 仅逐行时等待 3s 逐字宽限；`LyricsWordTimingUpgrade` 在 `attachWordTiming` 同事务挂接时间轴子版本而不丢原行 ID、锁定位与译文；行切换使用 `.milliseconds(2)` 公差的 `Task.sleep(until:)` 与 `PlaybackState.lineSwitchLead = 0.15`；L-034 规定先用当前代码重查统计样本再放宽规则，且新规则需歌名一致 + 时长 ≤2s。

### UI 面板、呈现、情境与动画性能（L-009 ～ L-012, L-015 ～ L-020, L-022, L-024 ～ L-025, L-027 ～ L-031, L-052）

- **L-009 / L-011 / L-018 窗口与订阅隔离**：版本弹窗挂主窗口 `V3LibraryOwner` 根视图（非短命悬停窗，也不触发主窗口整树重绘）；悬停详情用 `prefetchCurrentTrack` 提前备好。
- **L-012 / L-015 / L-016 / L-019 ～ L-020 统一视觉与边缘**：`V3PanelRow`、`V3ControlBarSurface`、`V3PlaybackButtons`、`V3SegmentedPicker` 统一控件；边缘进度条缩至窗内 8–24 pt，前景 ≥120 pt 时自动切换绕封面弧线并拖动（松手才通过 `PlaybackSeekDraft` 校验 `seekRecording` 提交）；模糊用指数曲线 `V3BlurCurve`（base 24）；新光效与呈现分别存 `v3.ambient.treatment.v1`、`v3.playbackStyle.v1`，不改旧 rawID。
- **L-022 / L-024 媒体、动画与高亮**：`Snappy` + `LevelDBFileReader` 预分配按需解 Canvas，`V3ArtistImageStore` 只长期缓存成功图，封面与背景严格按当前 URL 匹配、`ArtworkView` 无正方形底板；`V3BackdropBrightness` 采样视频最亮 1/4 + 封面亮度，过亮自动压暗并提亮封面色字体（`v3ActiveTranslationLarger` / `floatingDesktopSoftBacking`）；CA 动画用过去 `beginTime` 不用 `timeOffset`；暂停 1.5s 才插灰色层；桌面歌词用 `CGDisplayBounds` 边对齐判定全屏隐藏；行内逐词对无障碍合并为单节点。
- **L-025 / L-027 / L-028 / L-029 / L-032 粒子、情境与律动**：`CAEmitterCell` 下落需重力 `yAcceleration`；全尺寸三层情境 `V3Room` + Metal 着色 `V3SceneShaders.metal`（仅 `colorEffect` + 封面 `.image`，禁对含 NSView 子树用 `layerEffect`）与 `V3SceneLayer` / `V3ListeningPresentation` / `v3.roomOverrides.v1` 隔离多窗口试看与用户设置；`V3BackdropAmbience` 与跨行 `.opacity` 层叠避开指针/无动画吞没（**L-028**）；流动用 `WKWebView` Butterchurn（`hitTest` 透传）；`V3MusicPulse` 读取 `silentSeconds`（Spotify 音量 0 时全零提示）并在调音量前先读实时状态。
- **L-030 / L-031 / L-043 / L-044 / L-045 / L-052 多窗口与小窗**：金句存 `favorite-lines.json`；全屏 Esc/退出共用 `handleExitCommand`；**L-044** 状态栏模板图按行宽度独立计算滚动/省略，`ListeningLyricsReader` 与顶部灵动岛 `CapsuleNotchGeometry` 共用快照定句与单句循环（`lyricLineLoopControl`）；`LyricTextLayers` 保证「只看译文」不漏拼音；`LyricsPresentationOffsetTarget` 将偏移校准隔离出搜索预览；`VoicePresentation.nameLabel` 只展示真实歌手署名。

### 译文、离线工作台、文档、对读、手稿与歌本（L-010, L-017, L-032, L-042, L-046 ～ L-051, L-053）

- **L-010 / L-017 / L-042 / L-053 翻译**：`TranslationSessionController.synchronize` 按「手动/不显示 > 锁定/人工 > AI > 词源译文（含时间重对齐）」投影并触发 AI；「我的风格」v3（raw `translationPrompt.personalV2.v2`）先还原场景与语体、允许邻行重组、短化至 ~3,100 字符、保留字谜/收尾线索；批量预译与进度弧复用请求去重，仅进度阶段递增（`AITranslationLiveStage.advanced`）。
- **L-046 ～ L-051 工作台、阅读与档案资产**：`SettingsWorkspace` 空闲为主入口，播放时手动进入不被新歌切走；⌘K 与系统服务查本机歌名/原词/译文/读音/金句，`RecentLyricsReadings` 保存最近 5 份稿与视口行；TXT/LRC/TTML 文档窗（含 `x-bg` 和声、多语切换 `continueFiledLyricReading`）支持原样存入/导出；`LibraryVersionsWorkspace` 与 `LibraryVersionComparison` 按分组对齐同源或不同原词并选句生成 `is_draft` 人工子稿；`LyricManuscript` 保留手稿头与父稿；`LyricBook`（A5 PDF Core Text 目录跳转）与 `LyricBookExcerptPicker` 按行号/版本摘段。**L-047** SQLite 在线快照备份、单事务个人包导入、文件协调目录同步与 64 MiB LRU `AppleMusicArtworkCache`，严禁清缓存误删原词/锁定资产。

### 2026-11-20 状态收敛、动画时钟隔离与测试收口（L-054）

- **动画时钟隔离**：`V3CoverBreath`、前景灯效（`V3EdgeLights`/`V3CoverRimLight`）、`V3VUMeter`、`V3SpectrumOverlay`、`V3Soundprint` 将高频 `TimelineView(.animation(minimumInterval: 1/30))` 隔离进 `V3AnimationIsland` 并以 `v3WindowVisible && v3IsPlaying`（及对应特效开关）门控，暂停或窗口最小化/遮挡时完全撤下动画时钟；`V3WindowEdgePlaybackOverlay` 静态配色模式改用 `0.25s` 节流；`V3MusicPulseLightView.configure` 仅在位置变化时置 `needsLayout`。
- **多窗与预览状态收敛**：`MainLyricsWindowView` 监听 `state.isShowingSearchPreview` 切回 `.followsPlayback`，防止工作台吞掉预览；`AppleMusicImmersiveV3WindowView` 对专注/搜索预览关闭 `developsKeepsakes` 与情境层，且 `V3Keepsakes.develop` 对 15 秒内同 `(kind, trackKey)` 去重，防止主窗与全屏重复洗出拍立得/星座留念（见 `testKeepsakeDevelopDeduplicatesRepeatedWindowFinish`）。
- **预加载不再触发重复在线逐字搜索**：`LyricsSessionController` 区分 `wordTimingOnlineSearchedVersions` 与 `wordTimingUpgradeAttempts`（入队列同步插入），预加载或首次保存后若无本地逐字稿不再二次请求在线 provider，保留 `localTimingReference` 零网络升级，修复 `testPreloadedQueueTrackPlaysFromStorageWithoutAnotherSearch`。
- **源码合同脚本与文档收口**：修复 `Tests/capsule_*.sh`、`Tests/apple_music_immersive_v3_contract.sh` 与 `Tests/v3_toolbar_popover_event_contract.*` 对拆分文件的路径/依赖引用；按 Vault `AGENTS.md` §2.2 规范将本页与 [TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md) 历史详录无损归档至 `docs/archive/`。

### 2026-11-20 GitHub 私有库全量/增量 Markdown 同步（L-055）

- **L-055 私有仓库隔离、Keychain 保护与无损增量树提交**：`GitHubLyricsSyncService` / `GitHubSyncClient` 强制校验远端 `private == true` 并硬拒绝 `suifracti/aster-lyric` 等开源/公开仓库；PAT 存 Keychain `com.spotifylyrics.github-sync`（遵守 `SPOTIFYLYRICS_DISABLE_KEYCHAIN=1` 与 `DebugAcceptanceDataIsolation`）；`GitHubSyncSnapshotBuilder` 按确定性排序输出 `README.md`、`INDEX.md`、`favorites.md`、`tracks/<slug> [<hash>].md` 与固定导出时间的 `backup/LyricIslandPersonalData.json`，客户端本地计算 Git blob SHA-1 对远端 tree 增量上传（无变更跳过提交），删曲仅清理 `tracks/` 与托管路径而不碰仓库内其他用户笔记；`SQLiteLyricsRepository.withTransaction` 仅在非内部重定向的持久化写提交后广播 `.personalLibraryAssetsDidMutate` 驱动 6 秒防抖自动同步。
