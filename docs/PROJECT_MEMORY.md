# Aster · Lyric｜项目记忆

规则见 [AGENTS](../AGENTS.md)；规格继续维护在 [TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md)，不另建并列任务表。项目旧名 Spotify Lyrics / lyricsQ / Lyric Island 用于历史检索，不当成四个项目。

## 按用户说法找经验

先读此索引，再读命中的条目正文与实际实现；索引只帮助定位，不替代原因和证据。无匹配时再查项目任务源、相关差异和历史，不能因此断言以前没做过。

| 用户说法或本次触及范围 | 到哪里找 |
|---|---|
| 改名、换界面、旧数据或人工歌词不能丢；改持久化/身份逻辑 | L-001 |
| 清理缓存、Apple Music 封面未计入空间、另一个窗口打开时也要备份最新歌词 | L-047 · SettingsDataController、AppleMusicArtworkCache、writeDatabaseSnapshot |
| 数据包导入一半报错、版本串到别首歌、确认旧的同步文件 | L-047 · previewTrackImport、importPersonalDataPackage、PersonalDataSyncStore |
| 从其他应用选字查歌词、⌘K 找回一句、搜到副歌却只打开歌曲档案 | L-043、L-046 · WorkspaceQuickFind、searchLibraryPassages |
| 两份稿逐句对读、改译时借用另一版的句子、读到第二次副歌后对读或编辑却跳回开头 | L-049 · LibraryCompareRequest、LibraryVersionComparison、LibraryTranslationRevisionDraft |
| 编辑器打开停在开头、重开丢草稿、试听跳到别首歌 | L-049 · prepareLyricsEditor、focusLine、auditionLyricsEditorLine |
| 从 Finder 打开歌词文件、给本机录音补稿、导出手里的版本、入库后合声消失 | L-032、L-048 · LyricFileDocument、LocalLyricsFile、PortableLyricsEdition |
| 没放歌时写手稿、从歌词库版本开稿、调整段落或接着修上一稿 | L-050 · LyricManuscript、LyricWritingDesk、ManuscriptStanzas |
| 从原词、译文或金句编歌本、摘连续几句、保存原出处、导出带目录的 PDF | L-051 · LyricBook、LyricBookExcerptPicker、LyricBookPrint |
| 新包、截图、构建/签名、实际运行是哪份 | L-002；DEVELOPMENT_WORKFLOW.md |
| 极简、减少按钮、保留旧功能 | L-003；TOOLBAR_BEHAVIOR.md |
| 找回旧环境光、模糊/缩放参数、样式合并；改 renderer/偏好 | L-004；AppSettingsStore.swift 与 authenticAmbientArtworkLayers |
| 已采用歌词突然被挡住、同一首重复入库、歌单已存却不打勾；改 Spotify ID | L-005；TrackIdentity、SQLiteLyricsRepository、PlaylistPickerTests |
| Desktop 时长跳变、合作歌手待确认、错误的时长差提示 | L-006；SpotifyTrackArtistResolver、LyricsSearchManager |
| 搜索慢、本地结果等网络、搜索 Apple Music 或旧译文、预加载同一首重复搜索 | L-007；searchLibraryPassages、refreshLibrarySearchCache、TrackSearchManager、LyricsSessionController |
| 找歌重开后变回当前曲、弹出歌单后筛选丢失 | L-007、L-008；SongSearchManager.prepareQuery、PlaylistBrowserModel.filteredTracks |
| 队列不更新、循环列表被裁掉、隐藏后点第三首多跳、Apple Music 歌单串到 Spotify | L-008；PlaylistBrowserModel、AppleMusicPlaylistCatalog、V3PlaylistQueuePreview |
| 播放 App 的运行、连接与在线曲库授权容易混淆 | L-008；PlaybackConnectionCards、PlaybackState、SettingsLocation |
| 别的播放器停止让当前歌词消失、切换来源误暂停或串掉播放模式 | L-008；PlaybackState.receiveDesktopUpdate、runProviderCommand、playbackSourceRevision |
| 停播或退出后旧歌词还挂着，位置校准拿不到歌曲 | L-008；PlaybackSnapshot.desktopStopped、PlaybackState.acceptDesktopPlaybackEnd |
| 版本弹窗挂在悬浮窗、关后黑着、大歌词库关闭或丢选择 | L-009；PersonalLyricsLibraryService、PersonalLibrarySheets |
| 有歌词源译文却不显示、部分行没有译文、重复补存 | L-010；TranslationSessionController.synchronize 与 chooseVersion |
| TTML 自带翻译或罗马音却没显示、无时间轴的文件被当成同步歌词 | L-032、L-048 · TTMLParser、AMLLLyricsProvider |
| 悬停歌词库转圈、版本列表开得慢 | L-011；prefetchCurrentTrack、currentDetail |
| 边缘线内移/加粗、胶囊热区、封面卡片不同宽、分段选中块乱动 | L-012；V3EdgeRailView、V3ResponsiveGeometry、V3SegmentedPicker |
| 面板控件不统一、选项太多太杂、画面风格太多、播放栏按钮不一致、歌词库页签变黑 | L-016；V3PanelRow、V3RowToggleStyle、V3DisclosureRow、foldedEntryIndices、V3PlaybackButtons |
| 译文风格不对、编辑后发送的风格不同、旧翻译可能重发 | L-017；AITranslationConfiguration.personalStyleGuidance、TranslationSessionController |
| 模糊变化不均匀、找旧环境光的圆形、歌词库面板切换卡顿 | L-018；V3BlurCurve、featheredAmbientArtworkLayers、V3LibraryOwner |
| 加光效、加播放呈现、新呈现不显示或挡住歌词 | L-019；V3AmbientTreatment、v3ScenePlayerHidden、V3PlaybackStyles.swift |
| 工具栏/歌词/播放栏样式、核对只在指针附近显示的界面 | L-020；V3ToolbarStyle、V3LyricStyle、v3PlayerBarOptions |
| 已采用的歌突然“歌词暂不可用”、合作歌手写法不同（假名/罗马字）进了核对 | L-021；redirectNewSpotifyKey、retryingStore、nameReadingKey |
| 视频背景（Canvas）、歌手照片背景、按封面配色、随音乐律动、拖进度吸附、跳转回弹、脏词显示 | L-022；SpotifyLocalCache、V3BackdropMedia、CoverColorRoute、V3MusicPulse、LyricCensorRestorer |
| 切歌瞬间 CPU 抬升，过几秒才回落 | L-022 性能第二轮；SpotifyLocalCache、Snappy、V3CanvasStore.remoteClip |
| 不同画面背景大小不一样、取景切了没效果、繁体歌名对不上简体来源、别人有逐字/对唱我们没有 | L-023；V3BackdropArtworkGeometry、v3SharedBackdropComplete、TrackTextNormalizer.normalize、KRCParser、QRCParser |
| 逐字上浮/长音发光动画跳回开头、状态栏弹窗改版、封面闪占位图或露出方形底板、暂停褪色、桌面歌词情境隐藏 | L-024；LyricLineView animateLift、MenuBarLyricsPopoverView、ArtworkView、v3PauseFadesColor、FloatingLyricsWindowController.observeContext |
| 主窗口有封面，歌词库、找歌、歌单或情境仍显示占位图；切歌后暂时还挂着旧封面或背景 | L-024；ArtworkView、CachedArtwork、ArtworkImageLoader、V3RainLens |
| 情境一开旧画面切不过去、光色不走封面色、同一首对唱在不同窗口不一样 | L-052；V3ListeningPresentation、V3RoomOverrides、LyricsTimeline.presentedLyrics |
| 选过新画面后找不到柔和光晕或独立色场、体验版本库打开错分类 | L-052；V3SceneFamily.olderPictures、SettingsLocation.versionsFor |
| 合唱被标成某个人独唱、桌面歌词或灵动岛看不出谁在唱 | L-052；LyricsTimeline.VoicePresentation |
| 别的播放器有声部或逐字、想找同一首的其他版本、提前翻译歌单或查缓存 | L-053；LyrimuseLyricsCache、LibraryVersionSearchSheet、TranslationSessionController |
| 查找其他版本等很久、预览和对读叠窗、歌名和署名错配；片假名缺注音 | L-053 版本窗口接续；LibraryVersionComparison、JapaneseRubyPresentation |
| 听歌有对唱，但阅读、文件或印本漏掉声部，合唱在档案里重复 | L-051；PassageVoicePresentation、LyricBook.Chapter.readingRows |
| 单句循环只在主窗口有、切窗口找不到取消、拖进度被拉回 | L-052；PlaybackState.lyricLineLoopControl |
| 预览别首歌词时调偏移却改到正在播放的歌词 | L-052；LyricsPresentationOffsetTarget、V3LyricActions.calibrateLyrics |
| 状态栏弹窗、展开灵动岛或旧版桌面卡片只亮整句；透明桌面歌词暂停后进度消失 | L-052；WordTimedLyricText、TimedLyricHighlight、synchronizedLivePresentationClock |
| 「只看译文」仍出现罗马音 / 拼音、隐藏原文后拼音消失 | L-052；LyricTextLayers、DisplayPreferences.usesInlinePinyin |
| 粒子（雨雪雾、歌词意象）不显示、VU 表指针手感、新呈现一行放不下、分享卡排版跑偏、封面墙离屏图空白、声纹圈、频谱 | L-025；V3GlassWeather、V3ParticleHostView、V3VUMeter、V3LyricShareCard、ListeningCoverWall、V3Soundprint、V3SpectrumOverlay |
| 最小化后画面还在刷新、一个窗口关闭却让另一个不再获取天气、书页翻完还占用 | L-025；V3WindowVisibilityProbe、V3FlowLayer、V3SceneTransition、V3WeatherWatcher |
| QQ 来源突然全部 http(500)、别人有词我们“暂无歌词正文” | L-026；QQExperimentalLyricsProvider.searchBases |
| 某个来源一段时间连着超时/503、每首新歌都卡几秒、来源顺序要不要按统计调 | L-035；LyricsSourceHealth、LyricsSearchManager supplements |
| 在窗口边缘拖进度会变成缩放窗口、进度线靠近时下移不好看、胶囊和工具栏像两套控件、画面面板底部被截断 | L-015；V3EdgePillScrubber、V3ControlBarSurface、V3ThemeSelectorView |
| 来源里有词却被拒、歌手写法不同（括号别名、只对上一部分）、同名歌手误进核对 | L-014；artistGroups、parentheticalArtistNames、artistNameParts、primaryArtistPartialName |
| 英文歌名对片假名歌名（Timeless/タイムレス）、汉字人名读不出、别人有时间轴我们只有纯文本 | L-036；LyricsSafeMatcher.loanwordKey、titleLoanwordReading、durationExact、featuredArtistExactLength |
| 停在「核对歌词版本」：多出合作署名、双名客串、(Explicit)、翻译歌名但同母带、伴奏同长 | L-037；promoteSameMaster、sameMasterTolerance、TrackTextNormalizer 伴奏标记 |
| 日文歌名有译文而英文歌名搜不到、百分数歌名在来源里换了写法 | L-022 2026-11-19 接续；localized-title-companion、titlePercentageExact |
| 已存纯文本永远升级不到时间轴、只按歌名搜到的全对结果仍要核对、「原名 - 英文名」 | L-038；plainAlreadyHeld/waitsForTiming、looseQueryConfirmed、titleBilingualPair、publisherPageExact |
| 别人有逐字我们只有逐行、已存逐行不会升级成逐字、行切换比别人慢一点 | L-041；probeNetworkProviders lineTimingHeld、LyricsWordTimingUpgrade、TimedLineBounds（QRC/KRC/YRC 行尾）、scheduleWordTimingUpgrade、PlaybackState.lineSwitchLead、scheduleLineBoundaryWake |
| AI 译文读起来像照日文断行切开、主语缺失、太书面、和我自己的译法不像 | L-042；`personalV2Instructions` full-audit-v3-r1、Codex 合同里的跨行条款 |
| AI 整首翻译提示词太长、换了提示词后继续使用已发请求 | L-042 末尾短版接续；AITranslationPromptBuilder、TranslationSessionController |
| AI 模型刷新看起来没反应、Codex 档位名字和星弦不同 | L-042 末尾模型目录接续；TranslationModelSettingsStore、TranslationReasoningPolicy |
| 缺歌词里同一首歌的重复记录（时长错、借用别首的 ID）、批量补全拿错时长去搜 | L-039；PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere、needsLyrics |
| 批量补词切换窗口时停掉、只看到次数、需要核对却看不到候选 | L-039；PlaybackState.lyricsBatch、LyricsBatchControls、LyricsSessionController.completeBatchLyrics |
| 加歌词源、日文独立歌曲找不到词、酷狗酷我是否已接、哪个源慢 | L-013；PetitLyricsProvider、LyricsProviderConfiguration、supplementProviderNames |
| 翻阅收藏、从副歌第二次出现的位置接下一句、搜到旧译文、继续阅读丢位置或被档案覆盖 | L-046 · LibraryPassageReader、RecentLyricsReadings、V3FavoriteLines |
| 灵动岛挡刘海、只剩歌名、想停在一句读、换歌拖错进度 | L-045；CapsuleNotchGeometry、CapsuleLyricsView、vocalCountdownWindow |
| 从灵动岛、桌面歌词或状态栏读全文，保持定住的那一处 | L-045；ListeningLyricsSnapshot、ListeningLyricsReader |
| 状态栏双行词、日英混排少半句、收藏当前句、完整歌词与版本档案、没放歌时的菜单 | L-044；MenuBarTextFormatter.statusImages、MenuBarFullLyricsSnapshot、WorkspaceShelfCard、KeepLyricButton |
| 全屏歌词按 Esc 没反应，退出后留下大窗 | L-031；FullScreenLyricsWindowController、handleExitCommand |
| 桌面歌词、灵动岛、菜单栏分散难找，调整一个外观时另一个预览被采用 | L-043；AppearanceSettingsView、AppearanceSurface、PresentationSelectionStore.apply |
| 搜设置后还得找开关、状态栏字号搜不到 | L-043；AppearanceControl、WorkspaceLookupRow、SettingsHistory |
| 设置里找歌或歌词、从金句或封面墙回到歌、没放音乐时继续整理、历史录音一直转圈 | L-043；SettingsWorkspace、SettingsHistory、selectedDetail(for:) |
| 不同窗口的听歌统计互相覆盖、歌曲排行无法回到档案 | L-043；listeningStatisticsLoad(for:)、ListeningStatisticsView |
| 歌词库弹到独立窗口后筛选丢了、搜索时批量补词用了上一组结果 | L-043；PersonalLibraryScope、entries(for:) |
| 歌词库用一句歌词找到歌，却不知道是哪份稿或点不开那句 | L-043、L-046；PersonalLyricsLibraryService.matchingPassage、LibraryPassageReader |

## 默认自动执行：不等用户提醒

日常记录与联动继承 Vault 根 `AGENTS.md` 的“2 项目记录”，全周期复盘见“5.1 全周期复盘与覆盖”。通过[仓库 AGENTS](../AGENTS.md)定位总规则和本项目主源；本页只维护场景索引、具体经验与已有覆盖点。

## 已有资产入口

- 工程：`SpotifyLyrics/`、`SpotifyLyrics.xcodeproj/`；既有检查 `Tests/`；脚本 `Scripts/`、`Tools/`。
- 工具栏行为：规格中的 `SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift`、`V3ToolbarPresentationTests` 与 `Tests/v3_toolbar_model_contract.sh` 是定位线索；核改动时仍需读当前实现。
- UI 离屏展示：`Scripts/ui-snapshots.sh`，不是用户 Mac 的真实操作证据。
- 当前操作/签名：[DEVELOPMENT_WORKFLOW](DEVELOPMENT_WORKFLOW.md)。历史版本核对：[STATUS](STATUS.md) 及其来源，旧通过只对原截点有效。
- 私人体验及历史决定在用户授权的 Vault 项目记录，公开仓库仅保存必要脱敏约束。

## L-001 外观和名称变化不能改掉数据身份

适用：项目更名、场景/工具栏重构、歌词库/翻译/预览调整。

依据：仓库既有 AGENTS 的正式资产保护，以及项目更名后的长期约束。保留 Bundle ID、数据库位置、UserDefaults/Keychain 身份、旧 rawID、人工/锁定版本、录音身份、live/preview 隔离和请求去重。更换 UI 实现不等于允许重置旧数据。

下次检查：先找已有持久化/会话与身份用例，按实际影响验证；本次只整理规则，未读全实现或使用正式数据库，因此不是新的功能 PASS。历史原因不足时保留未知，不编造迁移故事。

## L-002 图、构建、签名权限和真实体验分别取证

适用：截图失败、Debug 候选、性能对比、OAuth/Keychain 与“最新版”判断。

依据：既有开发参考区分 unsigned 编译与稳定 Apple Development 身份；截图脚本属于离屏展示。unsigned 构建成功不能验证 Keychain ACL/TCC；不同 cdhash、旧 Bundle 版本号或图片日期不能单独证明当前运行版本。

下次检查：记录实际源码/dirty、构建签名、App 路径及数据环境；性能记录歌曲、窗口和播放状态。复用适用证据，不为了文档打包或调用模型；没有实机条件写 NOT_RUN，不把视觉 fixture 当播放/缓存全链路通过。

历史失败案例（`ff823a2`，2026-11-03）：Round 12 返修的 Debug 构建和 23 项定向原生检查有当轮执行记录，但基线隔离 App 在 30 秒采样中途丢失歌曲并报告暂停，候选没有取得有效播放样本；重采又因歌曲状态未就绪及 Spotify Apple Events 超时终止。现存本机 `.local/round12-repair/perf-baseline-context.log`、`perf-retry.log` 与提交说明相符。`perf-baseline-invalid.json` 是作废数据，不能作为性能通过或回归的依据，也不能拼成与候选的对照。本轮仅复读这些证据，未重新采样。下一次只复用在同曲、同构建、同窗及连续播放条件下有效的样本；不从静态截图推断播放态资源表现。原始日志和图不进入仓库。

2026-11-11 核回云端证据时，`ff823a2` 的 [CI 运行](https://github.com/suifracti/aster-lyric/actions/runs/41479559608) 总结果为 failure，但原生 job 被取消，没有测试步骤日志，不能将其当成某项断言失败。`bca27ed` 的 [完整 CI](https://github.com/suifracti/aster-lyric/actions/runs/42876477987) 已成功，附件 SOURCE_SHA 与该提交一致，五组生产逻辑合同全过，Xcode 16.4 的 Debug `-O` 原生目标执行 129 项，128 项通过、1 项跳过、0 失败。跳过的是 `testAtmospherePresetRespondsInItsPaddedArea`，因为云端宿主没有暴露 SwiftUI 辅助功能子节点，整块按钮点击仍需实机证据。附件明确将真实 Mac GUI 和成对 CPU/RSS 标记为 NOT_RUN。下次区分 job 取消、构建/测试失败和实机未测，复用这份有效结果，不因旧红灯重跑全部检查或改弱断言。

搜索接续修复 `bfc2913` 的 [完整 CI](https://github.com/suifracti/aster-lyric/actions/runs/42892375192) 随后通过，附件源码身份一致，原生仍为 128 通过、1 跳过、0 失败，五组合同通过。另一次本机隔离启动检查使用 `880315e` 与 `bfc2913`、Xcode 26.6 Debug `-Onone` 和同源缓存副本。窗口、场景及指针条件一致，但两版均在 Spotify Apple Events 超时后处于无歌曲状态，因此未采 CPU/RSS。终端中相同生产脚本在普通和私有 home 环境都能约 0.2 秒返回 9 字段。随后系统 TCC 日志确认，隔离身份的 Apple Events 授权提示等待 120 秒后返回 timeout=true/result=false。日用身份已获准，其排在后面的请求在该等待结束后返回 result=true，但 App 的 3 秒读取早已结束。系统队列清空后后台重启日用 Debug，重新读到缓存歌词。独立测试身份须先完成 macOS 的自动化确认，再接续自然播放下的资源对照。

现场还发现一份旧 Downloads 预览包与 Debug 版同时运行，共写全局日志。旧实例退出前未单独取证其数据库路径。结束旧实例、后台重启当前 Debug 后，当前版本正确加载缓存的 51 行歌词。隔离 App 随后的单次复核仍超时。以后按实际可执行路径核歌词 App 进程，包名可能带 preview 后缀，不能只匹配 `SpotifyLyrics.app`，也不能将共用日志里的所有错误归给一个 PID。终端只读观察进程后来以超时错误退出，旧 PID 文件不代表仍在等待。

2026-11-19：同一台 Mac 顺序运行 `774ad81` 与本轮的隔离 Debug 宿主，合成曲《夜を越えて · After the rain》处于播放、水面情境、1024×640 主窗，两个版本均用临时库和同一封面样例。用 `top -stats pid,cpu,rsize` 每 5 秒采一次，弃首帧，随后 30 秒平均 CPU 为 28.9% 与 23.6%，RSS 中位数为 249.5 与 245.5 MiB。这个短样本用于可见状态的回归筛查。屏外窗口的可见信号另由原生窗口测试核对，隐藏态 CPU、全屏资源和真实 Spotify 播放没有采样。

## L-003 极简是保留能力、折叠入口

适用：减少控件、面板重排、快捷键/设置合并。

依据：[规格的设计原则](TOOLBAR_BEHAVIOR.md#design-principle-user-2026-10-21) 明确 folding, not cutting。先定位原有行为和入口，列出这次未冲突的保留项；新布局应能走原工作流，不能以更干净为由删除功能。以实际受影响行为验证，不用源码字符串数量或截图替代用户目标。

状态：以上三条是从现行规则/规格提取的要求和证据边界，不是本轮新运行结果，尚无新的用户体验确认。

## L-004 恢复旧 UI 先找准版本，保留参数身份与当前演变

适用：恢复环境光/背景、改模糊或缩放、简化样式菜单、迁移设置。历史体验已明确区分所需 v0.1.2 原版与另一候选；不能看名字相似就当同一效果。仓库仅保留脱敏结论，个人反馈原文仍在授权的 Vault。

- 历史锚点：`6528be3103f75fd4f63757855b9d61cd30f757d8` 的 `SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift`（blob `5f6d828636ca7fb36381219b96ced4c2bd01739a`）。当时 `ambientArtworkLayers` 是封面 scale 1.12、opacity 0.56、blur=`normalizedBlur*48`，Screen 光层 opacity 0.34、radius=`680+normalizedBlur*220`；这些是历史参数，不是今天应一律重设的默认值。
- 稳定身份：旧 `.ambient` 与后来同名效果不能混写。现有独立 `.authenticAmbient` 的 rawID 为 `v3ArtworkPresentation.authenticAmbient.v1`。权威在 `SpotifyLyrics/Settings/AppSettingsStore.swift`，相关键含 `v3.backdropBlur.authenticAmbient.v1`、`v3.authenticAmbientBackdropScale.v1`、`v3.artworkPosition.authenticAmbient.v1`、`v3.artworkSizeScale.authenticAmbient.v1`；场景参数还有 `v3.scene.renderers.v1`，不能只改一个旧键。
- 当前实现：在 `main@fd66ec3a2ebdba6eccb99d45a0022ddcfd1010bd` 静态核对，同一 Backdrop 文件的 `authenticAmbientArtworkLayers` 已使用 `perceptualBlur=pow(normalizedBlur,1.35)`、可调 `backdropImageScale` 和亮度；opacity 为 `min(0.74,0.56*brightness)`，blur 为 `perceptualBlur*48`，光层半径为 `680+perceptualBlur*220`。Settings 的场景初值是 blur 25（范围 0–100）、前景/背景 scale 1（范围 0.8–1.4）、brightness 1（范围 0.6–1.4）；不能把历史固定 scale 1.12 强盖到当前存储值。
- 菜单与效果分开：[TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md) 当前允许将入口合并为分类/样式；renderer、rawID、独立偏好和迁移后的等效画面仍须保留。旧菜单数量不是永久产品要求。

下次先定位用户指的版本/效果、实际参数键和已有设置迁移，再改本次部分；检查受影响的旧选择/旧参数能否保留。没找到值先查来源，不另猜默认让用户重调。本次核对源码和历史反馈定位，未运行 Mac App、未验证新画面或正式偏好数据。

## L-005 Spotify 的存储身份与请求 ID 分开，已采用歌词沿持久重定向读取

歌单明明已保存却不打勾、暂停/元数据刷新后已采用歌词被“身份待确认”挡住，或同一 Spotify 歌曲因时长变化出现多条键时，先分清数据库身份和网络请求 ID。`canonicalSpotifyTrackID` 小写是旧身份键兼容约定；调用 Spotify 和比较返回曲目时用 `spotifyRequestTrackID` 保留 base62 大小写，不能全局改小写规则。

`8175366` 的歌单误判已定位为请求/成员比较错误使用小写 ID。权威入口是 `SpotifyLyrics/Lyrics/TrackIdentity.swift`、`PlaybackState.playlistRequestTrackID` 与 `PlaylistPickerModel`。同播放 ID 的通知保持 activeIdentity；`LyricsSessionController.hasAdoptedLyrics` 与 `SQLiteLyricsRepository.redirectNewSpotifyKey` 让新键重定向到该 ID 已有记录，优先有用户采用歌词的键，否则最早的键，写入既有 redirects 和 merge audit，不删版本资产。

现有 `PlaylistPickerTests`、`testLightSourceAdoptionSurvivesColdStartPauseAndMetadataRefresh`、`testYouAndIdolNewDurationKeyRedirectsToSelectedLyrics` 分别定位大小写、已采用歌词与不同 duration key。`606ecc6`、`08e918b` 已删除 Spotify 专用的 adoptedStableKey/sameRecording 前缀补丁；Apple Music 的持久 ID 路径保留，因删除后既有测试失败。历史冷启动相关实现见 `5e82030`。本轮核源码与既有用例，未读正式库或重做真实账号检查；下次保留旧键格式、人工选择、审计和 Apple Music 独立行为。

2026-11-11 在 `bf9ca8d` 基线上复现了后台校准的两个相关问题。失败快照原先也进入完整歌曲同步，立即把来源设为 unknown，持续失败后会清掉当前歌曲。另一个问题是校准拿完整元数据键与已采用歌词键比较，同 ID 的显示标题/专辑更新后，正常进度也会被拒绝。`PlaybackState.refreshProvider(calibrationOnly:)` 现在只接收 ready、同来源且 desktopRecordingKey 一致的校准，保持歌词的持久身份独立。停止与退出仍由现有桌面事件处理，没有增加重试或定时器。新增超时回归、扩展 Light source 原用例，均先复现失败，随后 Debug 的 18 项桌面播放测试通过。历史 Round 12 采样没有逐次校准状态日志，仍不能据此认定那次失败的唯一原因或把旧样本恢复为有效数据。

同日继续核版本操作时，在 `2103d88` 基线上发现译文与读音的“采用”入口仍直接比较 stableKey。YOU & IDOL 的旧 `201` 键与播放时的 `229` 键已重定向到同一记录，界面却因此只写入选择，没有即时更新正在播放的版本。`PersonalLyricsLibraryService.isCurrentTrack` 现在复用 `SQLiteLyricsRepository.resolveStableKey` 比较两边的规范键，两个采用入口共用该判断。它不新增身份规则、不修改键格式或歌词资产，原有非当前歌曲的保存路径继续适用。扩展现有 YOU & IDOL 用例先复现判断错误，随后 Debug 的 3 项 LibraryRevisionsContractTests 通过，真实窗口点击尚未验证。原词“编辑为新版本”自动采用已有保存实现和回归断言，本次沿用。

继续在 `82981d9` 基线上核对搜索入口，`PlaybackState.loadSearchResult` 也只用完整元数据身份判断当前歌曲。《Light source》播放元数据与已存旧标题不同时，点击其本地结果会错误进入独立搜索预览。这里复用现有 `TrackIdentity.playbackID` 判断是否选中正在播放的录音，沿原 SQLite-first 实时会话加载。歌词匹配与存储仍使用原完整身份。扩展同一首歌的既有用例先复现错误，随后 Debug 的桌面播放及搜索两组检查共 24 项通过，确认不进入预览、保留已采用歌词且没有 seek。真实界面点击尚未验证。

2026-11-18：Apple Music 的两个本机曲目可以同名、同歌手、同专辑、同长度。合格的持久 ID 现在用于区分它们，资料刷新继续指向同一个已存在档案。旧库中已有同一 ID 的物理键会沿用，录音尚未绑定播放器时仍可沿同元数据的旧档案接入。新建的物理键以 Apple Music 持久 ID 存储。Spotify 的旧键与请求 ID 规则照其既有路径。隔离旧库与新录音用例验证了老原稿、第二首的独立原稿和改名后的读取。

## L-006 匹配信任精确 Spotify ID 的曲库元数据，进度仍用播放时长

Desktop 对同首歌报出不同 duration、合作歌手被误判或时长差提示异常时，用精确 track ID 取得的曲库标题、全部歌手和时长做歌词匹配；播放时长只服务进度，不改现有身份键。

`c9f9252` 修正了曲库条目因与 Desktop duration 相差超过 2 秒而被拒绝的判断。`SpotifyLyrics/Lyrics/TrackMetadata.swift` 的 `SpotifyTrackArtistResolver.matchingTrack` / `TrackArtists.matches` 对精确 ID 命中信任曲库信息，`LyricsSearchManager` 用该元数据匹配且保留原 identity；`V3SearchPanel.catalogDuration` 用同一曲库时长计算提示。

现有 `testCatalogDurationOverridesDesktopDurationWithoutChangingIdentity` 覆盖播放报 150.8 秒、曲库为 168 秒时，168 秒来源结果可采用且不显示错误时长差。本轮静态复核，不把它写成今天全部歌词源的网络通过。下次不能为修匹配改 duration 身份键，或反过来用曲库 duration 改播放器进度。

## L-007 本地搜索复用版本内存文本，预加载尝试按运行期去重

本地已存结果应先显示，在线结果到达后补上。规范化文字和罗马音按版本缓存，后续查询做子串匹配；库有变化只重建受影响歌曲/版本，不能每次查询重新生成全库罗马音。

架构来历在 `7905f04`。此前搜歌结果直接携带歌词正文，歌曲目录与歌词来源职责混在一起。该提交拆出 metadata-only `TrackSearchManager`、独立 `LyricsSearchManager` 与共用只读 `LocalLyricsIndex`。当前接线仍是 `PlaybackState` 持有同一个 repository，搜歌只返回元数据，选择后由实时或隔离预览会话加载歌词。旧研究文档列出的待接来源及阶段限制是历史方案，不能自动恢复为今天的任务。

`188ce6f`、`f693196` 对应搜索缓存与变更接线。`SQLiteLyricsRepository.searchCachedLibrary` / `refreshLibrarySearchCache` / `cachedSearchVersions` 用 data_version、total_changes 感知变化，再比较逐歌曲签名，复用未变版本。`SpotifyLyrics/Search/TrackSearchManager.swift` 先发布本地 isLocal 结果再加在线结果。这里是内存缓存，不是数据库迁移或全文索引。

预加载的另一处重复请求由 `c7bdf04` 收敛。现用 `LyricsSessionController.attemptedPreloadRecordingIDs` 在 isPreload 路径按录音去重，包括需要核对和无歌词结果；`preloadedRecordingIDs` 记录成功项，真正播放仍走正常加载。`PlaybackState.preloadUpcomingLyrics` 只预取歌词，不进 AI 翻译。

2026-11-19：Spotify 预加载复用 `PlaylistBrowserModel` 已确认的队列，不另外读一次 API。候选从可见队列取接下来的两首不同录音，跳过已标记跳过的歌曲及当前录音。Apple Music 读取同一份已核对当前位置的歌单后续；已开启随机、单曲循环或顺序不可确认时保留浏览但不预取。按持久 ID 去重，播放时可以沿用预取的版本，即使队列与播放快照的专辑或长度不同。两播放器切换时取消预加载，单播放器换歌时交给实时会话加载新曲，余下预取等新队列确认后再调整。

现有 `LibraryIdentitySearchContractTests`、`testReviewedQueueSongIsPreloadedOnceButStillSearchedWhenPlayed`、`testPreloadedQueueTrackPlaysFromStorageWithoutAnotherSearch` 是回归入口。下次保留本地先出、单曲失效、正常播放不受尝试集合阻挡和绝不提前 AI 翻译。

2026-11-11 用 `0c9a4be` 的生产查询函数，在本机缓存的私有 SQLite 副本上测量。Xcode 26.6、Debug `-Onone`，556 首已存歌曲、754 个歌词版本，首次构建搜索缓存耗时 2.171 秒。随后 10 个中日英/罗马音查询平均 4.12 ms，范围 2.09–5.35 ms，规范化计数不再变化。暖缓存的仓库查询达到原“390 首 0.1 秒”目标，首次查询仍有缓存建立成本。实际搜索入口的闭包持续捕获同一个 `resolvedRepository`，没有逐次新建缓存。测量借用隔离归档中的原生测试宿主，临时测量方法和原始 JSON 仅留本机，未加入 CI。未测真实面板绘制、在线等待或并发写入期间的延迟。

2026-11-11 核对本机 `source-stats.jsonl`（10-24 至 11-10，235 条）：10-31 之后正在播放的新歌首次找词 16 次，中位 19 秒，8 次无结果。各来源自身多在 1–2 秒内返回，差额来自读音引擎。`JapaneseMeCabEngine.run` 每次调用都新起一个 MeCab 进程，并以 10 ms 间隔轮询退出；同一句歌词会在预览候选、正式候选、每个查询变体和最终文档里各补全一次，匹配器比较标题和歌手读音时也走同一入口。`2026-10-30` 报告已定位这段重复工作但当轮未修。

现在 `JapaneseMeCabEngine` 在本次运行内按“可执行文件、参数、文本”记住成功输出，失败不记；轮询间隔改为 1 ms。没有改匹配规则、候选流程、来源或数据库，读音结果与原来逐字相同。新增 `testRepeatedLyricLineStartsTheReadingProcessOnce` 先复现同一句启动 3 次进程，修复后为 1 次。同机 Debug 测得 46 行日文补全首次 0.62 秒降到 0.17 秒，重复 0.007 秒；20 次匹配判定首次 0.066 秒，重复 0.016 秒（10-30 报告用另一组数据测得 0.574 秒，条件不同，只作参照）。完整原生 130 项中 129 通过、1 跳过、0 失败。真实新歌的端到端找词耗时要等统计文件积累新样本后再比，本轮没有实测。

同一批无结果歌曲逐首向 LRCLIB 复查：8 首中 7 首确实没有条目，拒绝的是同名的其他歌曲，属于正确拒绝。只有《KILL MY LOVE》存在歌手写作 `Miliyah`、204 秒的带时间轴条目，播放侧是 `加藤MILIYAH`、198 秒，因 `primaryArtistConflict` 被硬拒。这是歌手别名规则的已知边界，本轮未改，其他来源未逐一复查。

2026-11-18：找歌用已接收的当前曲快照；输入关键词不会再重新轮询或改变桌面播放器。Apple Music 选中时向系统「音乐」搜索本机资料库，同名现场版和录音室版以各自的持久 ID 保留。明确输入 Spotify 曲目链接仍可读取该曲的目录资料。搜索已存原词、旧译文和读音时只把出处与查询带给阅读页，目录结果不传整篇歌词。匹配到旧版时「读这句」打开对应版本，没放歌时也可阅读已存歌曲。隔离真窗从文件入库，再从「搜索」输入旧译独有词，点击「读这句」已读回那一行；不会把阅读当作播放。

2026-11-19：悬停搜索、主窗搜索和独立窗口都从 `SongSearchManager` 读同一份输入。首次打开有在播曲时可用它填充，明确清空后继续留空。有查询结果或正在查时，打开另一入口不重新请求。切换资料库会取消旧查询，仍打开的入口用原输入重新查询一次。

## L-008 队列刷新保留稍后重复项，点击按原始 offset 前进

启动时空队列、开始播放后打开仍为空，或循环歌单/隐藏行使跳转错位时，复用旧列表并刷新；刷新成功只去掉开头连续的当前歌曲，不能删掉稍后再次出现的同一首。`firstIndex` 的前缀裁剪只留在切歌通知路径。

`075d578` 恢复 `V3PlaylistQueuePreview` 打开时的 `loadQueue()`，`24cfa3a` 分开网络刷新与 `currentTrackChanged` 的裁剪，`e91ffca` 删除 queueJump intent 和 X 的当前歌特例。权威是 `SpotifyLyrics/Spotify/PlaylistBrowserModel.swift` 的 rawQueue、queueItems、jumpToQueuedTrack 和 `V3PlaylistPanel.swift`。隐藏行仍保留原始 offset；跳转先用掉跨过的 skip 标记，再发 offset + 1 次 next，X 一律标记。

现有 `testQueueThirdPositionUsesThreeNextCallsIncludingHiddenSong` 覆盖首次空载再刷新、稍后重复曲目和隐藏第二首后点原第三首恰好三次 next。`e91ffca` 当轮报告 Debug 构建和 31 项相关检查通过，本轮只核既有证据，未对真实 Spotify 发写请求。下次保留原始队列位置、旧列表和一次性标记语义，不恢复已删的时序/跳转来源补丁。

2026-11-18：原先爱心弹层会跟当前播放器，但右侧歌单、队列、搜索行插播仍固定请求 Spotify，Music 行还会因两个空 Spotify ID 而一起高亮。现在大面板、悬停和封面播放栏共用同一个来源。Music 本地歌单与喜爱按持久 ID 读取；当前歌单先核对当前曲所在的原始位置，只展示往后 25 首。手动待播与随机顺序属于系统「音乐」，所以用「歌单顺序」和「歌单后续」。点重复曲在原位置核对 ID 后播放；若歌单改变则提示刷新。切换来源会清掉旧队列、跳过标记和异步动作。长歌单在 osascript 退出前就排空输出管道。原生桩验证了 AppleScript 可编译、无 Spotify 凭据、重复位置、迟到令牌、长输出。真实账户操作须单独观察。

播放来源页按播放器显示本机安装、运行及已观测的连接情况，App 运行不等于已经连接，自动跟随的选择也不冒充某个正在播放的来源。「重新检测」复用播放器读取路径，不先清空实时歌曲；单播放器授权信息由实际快照记录。Spotify 在线授权折叠在独立入口，首页不请求账号资料。搜索中的「在线搜索设置」打开在线授权页。靠真实工作台、设置和搜索窗口走过两条入口；没有打开音乐 App、改业务凭据或发送播放写操作。

同日《Complain》唱完后，Spotify 已播《哀、愛さ》，星弦停在旧曲终点；现场日志在此期间仍有播放模式响应，到再下一首才收到有效切歌。Spotify 与 Apple Music 的轻量位置校准原先发现新 ID 就弃掉并一直等通知。现在已验证的新录音 ID 触发普通元数据读取，用同来源的新快照进入既有切歌流程。通知在途先到时仍丢弃迟到读数，超时或格式错误继续保留当前记录。原生脚本桩分别核了两种 ID 和无通知的切歌回退。

同一曲出现两次时，完整队列和悬停预览的「跳过这首」都把所点行的原始 offset 和歌曲 ID 交给 `PlaylistBrowserModel`。正常换歌会移掉经过的前缀并平移标记。队列刷新重排且无法辨认重复项时，撤销该标记，避免跳错。原生桩验证了 A–B–A 队列、末尾新增、两次 A 分别播放与跳过。连续相同 ID 的播放边界仍无法仅从现有换歌事件判断。

2026-11-19：自动跟随时，非当前播放器的停止通知只更新它自己的连接状态。播放、暂停、前后切、进度与播放模式按最后接受的来源派发；切换来源后，旧命令迟到的错误或模式结果不再改写当前显示，旧队列跳转也不会续跑。「本曲结束后」仍能在同一播放器换歌时暂停，换到另一播放器时取消。原生定向测试 37 项通过，覆盖后台停止、迟到的暂停错误、新来源在旧写入期间切换模式、同源和跨源的定时；真实账户播放未参与验证。

2026-11-19 补停播校准。Spotify 和 Apple Music 的脚本先读当前播放状态，明确停播时不需要再取进度或歌曲 ID。通知、校准与退出走同一处清理当前录音的逻辑。校准检查已观测来源的进程，退出后不再发 Apple Event。空结果、未知来源和迟到响应仍按原有来源与代次判断。播放器桩确认漏通知时状态栏回到空闲，新播放通知正常接续；没有用真实账户切歌或停播。

2026-11-19：歌单面板和独立歌单窗口共用所选位置、搜索框和筛选。独立窗可刷新；关键词匹配歌单名、歌名、艺人和专辑。筛选只隐藏不匹配的行，没有重新编号。歌单页顶的「播放首个结果」从可见第一首的原始位置开始。队列点击继续验证原始项和位置。

隔离真窗核过原词/译文搜索结果带到独立窗、清空后主窗重开仍留空，以及歌单筛选与所选列表随窗口打开。24 项定向原生检查通过，队列样例隐藏第二首并筛取第三首后，仍向播放器桩前进三次。真实账户播放未参与验证。

## L-009 版本弹窗归主窗口，居中歌词库保留在后面

悬停面板弹预览、编辑、名称备注或删除确认后，只剩遮罩、错挂窗口或大歌词库丢选择时，检查 sheet 的 owner。主窗口的 `PersonalLyricsLibraryService` 持有状态，根视图挂一次 `PersonalLibrarySheets`；悬停入口先关面板再弹出，居中大歌词库保留同一歌曲和选择。

`f0c6eb0` 将短生命周期悬停面板的 sheet 接到主窗，`8e85fe6` 补齐名称/备注与删除译文，并去掉 `V3LibrarySearchPanel` 的 beforePresentSheet。权威在 `SpotifyLyrics/Settings/PersonalLyricsLibraryService.swift`、`PersonalLyricsLibraryView.swift` 的 presentSheet/PersonalLibrarySheets 与主窗根的 modifier。设置窗口保留自己的 service 和 sheets；主窗 equatable 边界不能挡住 service 状态更新。

`8e85fe6` 当轮报告会话合同、24 项原生检查及三张离屏合成图；本轮核实际结构，不把离屏图当真实系统材质或全部点击验收。下次保留大库后景、选中歌曲和独立设置窗口，不能为统一弹窗把所有入口都变成关闭大库。

## L-010 歌词源译文在 synchronize 中补存，默认选择不改变自动 AI 资格

已缓存原词带 translation_text，但没有独立译文版本或用户未主动选择时，沿 `TranslationSessionController.synchronize` 现有加载路径保存并选择歌词源译文。优先级为手动选择（含“不显示”）、锁定/人工、AI，最后歌词源译文；部分行没有译文仍保留原行对应与空白。

`5fd3e0e` 增加 chooseVersion 最后的 embedded 选择，`7e4e676` 曾在 loadBestStored 再补一次；`8e85fe6` 以 34 行/32 行的 synchronize 用例证明原 session 已承担保存，删除这条重复补存。权威在 `SpotifyLyrics/Services/TranslationSessionController.swift` 的 loadExistingOrAutoTranslate、chooseVersion、project，以及 `SQLiteLyricsRepository.preserveEmbeddedTranslation`。显示源译文时仍按原自动 AI 开关、资格和请求去重决定是否发起请求，不能因已有源译文短路原来的自动翻译行为。

`Tests/translation_session_contract.swift` 现有 NetEase/无 AI 默认源译文与 34/32 稀疏译文检查走“缓存加载 → synchronize → 选中源译文”，使用离线 fake。历史曾发现 65 个缺独立译文版本的记录，本轮未读正式库，不能宣称它们已经全部补齐。下次保留人工/锁定版本和手动“不显示”，不恢复 loadBestStored 的重复写入，不为文档验证调用收费模型。

## L-011 悬停版本列表提前准备当前详情，整库选择另走一路

打开歌词库悬停面板长时间转圈时，先查详情是否排在整库列表查询之后。当前歌曲详情在切歌和相关版本变化时独立预取，打开时直接取已准备的详情；大歌词库的选择详情仍独立维护。

`23a378e` 的隔离库记录是详情排在列表后耗时 660 ms，预取后查缓存低于 1 ms；该数值不含 UI 绘制。权威在 `SpotifyLyrics/Settings/PersonalLyricsLibraryService.swift` 的 prefetchCurrentTrack、currentDetail、selectTrack，以及主窗与 `AppleMusicImmersiveV3QuickControls.swift` 的调用。当前曲目详情和大库选中项不是同一个发布状态。

本轮复读提交记录与调用，不把缓存查找耗时写成用户实际“打开面板 → 版本显示”已低于 100 ms。下次检查切歌、采用/修改版本后的预取接线，保留大库选择和当前歌曲详情的独立性，不通过每次打开重新查全库解决。

## L-012 Round 12 轨道、卡片与分段控件沿现有局部实现调整

**2026-11-11 起，本条里的轨道内移、加粗、6–26pt 热区和胶囊 26pt 留白已被 L-015 取代**；封面卡片同宽和共用分段控件仍然有效。

边缘进度线、胶囊热区、封面列宽或分段选中块异常时，先查 Round 12 返修后的局部实现，不按旧截图恢复四边 mask 或胶囊短进度条。

`5d8dab7`、`be24b9a`、最终 `ff823a2` 的权威是 `V3WindowEdgePlaybackOverlay.swift`。胶囊四边留 26pt，热区 6–26pt；指针距边 48pt 内，只有接近的边移到 14pt，整条线宽 4pt。`V3EdgeRailView` 只有 trackLayer/progressLayer，以 CALayer 在 160ms 内过渡，Reduce Motion 用淡入；胶囊短进度已删除。`7144775` 的 `V3ResponsiveGeometry.foregroundCardWidth` 让卡片随封面宽度，最低 300pt，封面更小时居中其上，位置移动整列。`0c4ae15` 的共用 `V3SegmentedPicker` 仅选择变化时移动选中块，等宽、不跟随指针，Reduce Motion 直接切换。

`ff823a2` 同时让“当前译文”只在翻译页出现，并把译文 UI 合同定位到拆分后的 `AppleMusicImmersiveV3Lyrics.swift`。现有 `testApproachingTopMovesOnlyThatProgressRailInward`、`testForegroundPlayerCardTracksCoverWidthWithMinimum` 和 `V3ToolbarPresentationTests` 是检查入口。当轮报告 Debug 构建、23 项定向原生检查和离屏图；本轮没有运行或拍图，播放态性能未完成，见 L-002。下次保留局部图层动画、正常偏好/位置值和共享控件，不为旧字符串断言退回交互。

## L-013 加歌词源先测真实缺词歌曲，中国平台已接四家，日文独立歌曲走プチリリ

想加来源、怀疑某家没接、或日文独立发行歌曲找不到词时，先看现有来源的实际贡献，再用真实缺词歌曲去测候选站，不按“别的项目用了什么”直接接。

2026-11-11 的现状：网易云、QQ、酷我、酷狗四家中国平台都已接入并默认查询。正式库的歌词版本数为 LRCLIB 507、网易云 177、QQ 42、AMLL 11、LinkCore 8、酷狗 2、酷我 0。酷我 304 次查询里 145 次有候选，酷狗 265 次里 104 次有候选，但都排在网易云和 QQ 之后，很少成为最终采用的版本。再接咪咕等同类平台，对缺词歌曲帮助不大，因为缺的主要是日文独立发行。

用 11 月无结果的 8 首歌实测候选站：歌ネット返回 Cloudflare 验证页（403），UtaTen 返回空正文，J-Lyric 的搜索域名 TLS 握手失败，Genius 返回 403。这四家拒绝程序访问，没有接，也不绕过。プチリリ（petitlyrics.com）正常响应，8 首里 5 首有歌手相符的条目。Musixmatch 浏览器 token 与 Spotify 私有歌词接口沿用[既有审计](REFERENCE_PROJECTS_LYRICS_AUDIT.md)的结论，不接。

`PetitLyricsProvider` 的取词流程是搜索页（歌名加主歌手）、歌词页、`/lib/pl-lib.js` 里的页面令牌、`/com/get_lyrics.ajax`。令牌与打开歌词页的会话绑定，缺 `X-Requested-With` 或没先开歌词页都会得到 400，所以每次查询用独立的临时会话，不保存 Cookie。页面 `<canvas id="lyrics">` 里的回退文本只有约一半行数，不能当正文用。网站自己的 App 接口能给逐行和逐字时间轴，但需要它的应用密钥，没有采用，因此本来源只有纯文本。最多取前两条记录。

它和 lyrics.ovh、LinkCore 同属 `LyricsSearchManager.supplementProviderNames`，只在其他在线来源没有可采用结果时才查询。匹配规则没有为它改动：歌名、歌手、专辑都相符的会自动采用；专辑不同、站内没列合作歌手、歌手写法不同的进入“核对歌词版本”或被拒。真实网站实测 6 首：3 首取到正文并进入核对（41、57、58 行），1 首因播放侧歌手写作 `GAN (岩田剛典)` 被 `primaryArtistConflict` 拒绝，2 首搜索无结果（其中《KILL MY LOVE》站内歌手是 `加藤 ミリヤ`，按 `加藤MILIYAH` 搜不到）。每次查询 1.4–3.5 秒。旧设置读入时会自动获得这个来源，之后手动关闭会保留。

同轮把 lyrics.ovh 的超时从 8 秒改为 3 秒，LinkCore 的总超时从 16 秒改为 6 秒。依据是本机统计：lyrics.ovh 267 次查询 11 次有候选、无一采用，未命中常要 5–6 秒；LinkCore 226 次里 60 次失败。LinkCore 的歌手实体验证走目录缓存，不受这个总超时影响。真实听歌下“无结果”的总等待时间变化没有实测。

新增 `testPetitLyricsReturnsPlainTextWithTheSitesOwnTitleAndArtist`，并把 プチリリ 加进 `testLowYieldSourcesWaitAndAreSkippedAfterAutomaticAdoption`；测试只用编造的文本和本地网络桩。完整原生 131 项中 130 通过、1 跳过、0 失败，来源配置合同通过。下次网站改版时先看搜索表格的 `lyrics-list-title`、`lyrics-list-artist` 和令牌脚本，改版会报解析失败而不是返回空歌词。

## L-014 歌手写法不同：括号别名算同一人，只对上一部分的进核对

来源里明明有这首歌，却因歌手名不完全一致被 `primaryArtistConflict` 直接拒绝或搜不到时，先分清是哪一种写法差异。2026-11-11 有三个真实例子：Spotify 侧 `GAN (岩田剛典)` 对来源的 `岩田剛典`；Spotify 侧 `加藤MILIYAH` 对 LRCLIB 的 `Miliyah` 和プチリリ的 `加藤 ミリヤ`。

括号别名按同一位歌手处理。`TrackTextNormalizer.parentheticalArtistNames` 把 `外名 (内名)` 拆成两个完整名字，`LyricsSafeMatcher.artistGroups` 把它们各自加成一组主歌手，于是来源只写其中一个名字也得到 `primaryArtistExact`，沿原有打分自动采用。括号里是 feat、with、CV、vo 开头的署名不算别名；只对上括号内名字的一半不算。只展开播放侧（Spotify 及其别名），不展开来源侧。

只对上一部分的，单独一个来源不够，需要旁证才自动采用（见下一段的两条）。`artistNameParts` 把歌手名按汉字、假名、拉丁字母分段，汉字至少 2 个字、假名至少 3 个、拉丁字母至少 5 个才算一段，少数泛用词不算。歌名完全一致且有一段相同时，记 `primaryArtistPartialName`（+0.18）；歌名不一致仍然拒绝。它不带 `primaryArtistExact`，所以不会触发原有的多来源一致采用。

用户同日明确要求听歌时不能还要自己选，所以这类候选有两条自动采用的路。第一条在匹配器里：时长与播放侧相差 2 秒以内（`durationClose`）且没有版本冲突时，升到 `autoMedium`。第二条在 `LyricsSearchManager.partialArtistLyricsAgreement`：两个不同来源各有一个这样的候选，且歌词文字相同，就采用其中更好的一个（有时间轴的优先），记 `partialArtistLyricsAgreement`。文字是否相同用去掉空白和标点后的 8 字片段比较，较短一方至少 40 个片段、六成以上出现在另一方，所以换行不同不影响，短文本不会误判。两条都不满足时仍进“核对歌词版本”，例如只有一个来源且没有时长。另有 Spotify ID 或 ISRC 这类独立身份证据时不受这些限制。代价是同姓歌手的同名歌可能出现在核对列表里，这是有意接受的。

プチリリ按“歌名加歌手”搜不到时，再按歌名搜一次，只打开歌手名有一段相同的记录，最多两条。

新增 `testArtistWrittenDifferentlyIsRecognisedOrLeftForReview`、`testPetitLyricsSearchesByTitleWhenTheArtistSpellingFindsNothing` 与 `testPartlyMatchingArtistIsAdoptedWhenTwoSourcesGiveTheSameWords`。完整原生 134 项中 133 通过、1 跳过、0 失败，原有匹配用例没有因此改变结论。真实来源实测：《Phone Number》由プチリリ自动采用（43 行纯文本）；《KILL MY LOVE》由 LRCLIB 与プチリリ歌词一致而自动采用 LRCLIB 的带时间轴版本（79 行，来源标注时长 204 秒，播放侧 198 秒），整次找词 10.9 秒。时间轴与实际播放是否对齐没有听过。这两首是用库里记录的歌名、歌手、专辑和时长在测试宿主里跑的，没有经过真实播放和 Spotify 目录别名。

下次有人想把“部分相同”放宽成自动采用时，先看这里的理由；想收紧时，调 `artistNameParts` 的最短长度或泛用词表，不要回到整名必须相等。

## L-015 拖动进度在胶囊上，边缘线只显示；浮在画面上的条共用一种外观

用户反馈在窗口边缘拖进度容易变成缩放窗口，Round 12 让进度线靠近时内移又不好看。根源是进度线贴着系统的缩放热区，在那里做点击怎么调都别扭。2026-11-11 改为把拖动搬到胶囊上：`V3EdgeRailView` 只画进度，不移动、不加粗、不接收指针事件；`V3EdgePillScrubber` 是胶囊内侧的一条细线，顶边时在按钮下方，底边时在上方，竖排时在朝画面的一侧，热区 10pt。悬停或拖动时胶囊里的已播时间显示指针处的时间，不再有浮动时间标签（旧标签曾被胶囊遮住一半）。胶囊为 304×50，竖排 54×248。`V3WindowEdgeHitBand`、`nearEdge` 和 `--edge-rail-inset` 已删除。拖动中切歌不会跳到新歌，沿用原来的 `dragTrackKey`。

工具栏与胶囊共用 `V3ControlBarSurface`（材质、细边、阴影相同，随系统浅深色）。胶囊里的图标和时间用 `Color.primary`，播放圆钮保留封面强调色；亮封面不再把胶囊压成黑色。胶囊距窗口边 18pt，与工具栏的内缩一致。胶囊在 `V3AnimationIsland` 里会被裁切，所以给阴影留了 `shadowRoom`。

画面面板原来两行大卡加四行风格，背景模糊的数值框被截在面板底部。现在四个分类是一行小卡，缩略图按设计尺寸 150×72 绘制后整体缩小；所选分类的风格是一行等宽按钮，说明进提示；封面的静止/流动开关在“风格”标题右侧。入口、渲染器、rawID、已存参数和悬停预览没有变，辅助功能标识 `v3.family.*`、`v3.style.*`、`v3.scene.*`、`v3.cover.motion` 保留。

规格在 TOOLBAR_BEHAVIOR 的 Round 13。`Tests/v3_edge_pointer_state_contract.py` 改为断言边缘不再有热区并检查胶囊尺寸，原生用例换成 `testEdgeRailStaysAtTheWindowEdgeAndTakesNoPointerEvents` 与 `testPillScrubberMapsThePointerAndKeepsClearOfTheResizeBorder`。完整原生 134 项中 133 通过、1 跳过、0 失败。离屏图只用来查布局有没有错位；真实窗口里的手感、亮暗封面上的可读性和播放时的资源占用没有验证，以用户实机反馈为准。桌面控制工具按策略不能访问本 App，真实画面只能靠用户截图。

同日用户看过真实效果后反馈胶囊“消失得太快或太突然”，并要求保留跟随、优化跟随与出现消失的逻辑。原因有两处：保持区只有 46pt，而胶囊本身伸进窗口 68pt，从侧面斜着靠近胶囊时会先走出保持区；隐藏没有任何延迟。现在 `keepDistance` 为 84pt；视图层的 `playerShown` 在指针离开后停留 0.6 秒再用 0.24 秒淡出（离开窗口为 0.3 秒），停留期间回到胶囊或它与窗口边之间的区域会原地保留（`updating(..., lingering:)`）。跟随改为指针沿边越过胶囊末端 20pt 之后才移动，指针与胶囊平齐时不动；以前是离锚点 96pt 就跳，而胶囊半长有 152pt，所以指针还在胶囊旁边它就会跳。延迟只在视图层，纯逻辑核心仍然没有定时器，10,000 次指针移动不写状态的检查照旧通过。这些数值是按代码推的，手感仍待用户确认。

随后用户截图显示胶囊压在工具栏上。纯逻辑核心按真实窗口尺寸计算出的位置与工具栏保持 12pt，不重叠，所以问题在绘制：我把外观和阴影用内边距塞进了 `V3AnimationIsland`，并调换了工具栏位置探针与背景的顺序，绘制出的胶囊不再等于布局算出的那个矩形。现在外观画在隔离容器外面，容器尺寸恢复为胶囊自身尺寸，探针回到原来的位置。我没能在真实窗口里复现并确认是这两处中的哪一处，所以每次胶囊出现时会写一行 `EDGE pill show frame=… toolbar=…` 到 e2e 日志，下次再重叠先看这行。呼出距离从 30pt 放宽到 44pt，用户的原话是太窄容易滑到窗口边缘、但也不要太宽。

用户提的“进度围绕封面发光”已做成可选项：`v3.edgeProgress.placement.v1` 取 `windowEdge`（默认）或 `coverHalo`，入口在画面 → 更多画面选项的“进度位置”。前景封面用 `v3ReportsForegroundCover` 上报自己在画布里的位置和圆角（四处大封面都接了），`V3EdgeRailView` 在有光环目标时把同一条进度线画在封面外 6pt，已播部分 3pt 并带同色光晕。没有前景封面或只有 120pt 以下的缩略图时回到窗口边缘。用户问过无封面时是否围绕歌词，我没有做：歌词区是画面里最大的一块，绕一圈会最抢眼。光环只显示进度，拖动仍在胶囊上。真实窗口里的观感待用户确认。

2026-11-19：V3 主进度条与封面进度原先直接用松手时的当前歌曲，边缘取同一个歌曲键也挡不住 A→B→A。改由 `PlaybackState.seekRecording` 区分播放录音的切换，主窗、全屏、经典、Direction D、边缘、封面、状态栏和灵动岛共用 `PlaybackSeekDraft`。同曲暂停、更新位置或收到封面保留这次拖动。Mac 原生滑条仍支持先写值再开始、键盘/辅助功能只提交一次，边缘胶囊也有独立的辅助功能调整入口。指令排队后若录音已换，播放器侧调用会跳过。桌面事件桩送出 A→B→A，原拖动无法提交。隔离真窗主进度从 18 调到 73 秒，界面读到 1:13，提供方只收到一次调用。

同轮重新执行上次参与比较的 15 个 Python 入口。7 个失败中，拆分后的行、进度和预览检查重新指向当前实现；经典几何运行实际代码；背景迁移、试听选词与听歌统计/历史读失败恢复改用真模块 XCTest。已逐一执行 13 个独立命令和 2 个迁移包装命令，均通过。关联原生检查 130 项通过，1 项按原条件跳过。

2026-11-19 后续复查 13 个独立 Python 入口。只剩 `v3_redesign_contract.py` 仍引用双行菜单栏改造前的 `animationDistance`。断言改为检查两行按各自图宽计算、沿用既有的滚动速度规则并调用动画，复跑通过。其余 12 个独立入口已直接通过。调用 Xcode 的入口和需要数据库参数的矩阵另由各自检查覆盖。

## L-016 一套界面贴合功能：行式面板、折叠、统一播放栏（Round 14）

2026-11-11 用户看过真实截图后要求整体合并优化，原话是要做“适配我们功能的 ui，而不是套模板让功能去适配 ui”，并表示不监督、让我一直做下去。规格写在 TOOLBAR_BEHAVIOR 的 Round 14，按批次各自提交：

- A `f689fc2`：进度线自动定位，前景封面不小于 120pt 时绕封面（`V3ProgressTrack`），否则沿窗口边缘；两处都能拖，窗口边缘的热区在 8–24pt，外侧 8pt 留给缩放。指针进入热区变手形、线原地加粗、时间标签跟随。“进度位置”选项删除。顺带修了工具栏位置从未传到边缘播放器的问题：`V3ToolbarFramePreferenceKey.reduce` 被不上报的兄弟视图用空矩形覆盖，胶囊因此会压在工具栏上（之前 L-015 的诊断日志里 toolbar 一直是 0）。
- B `ff427c4`：界面上的 Lyric Island 改为 Aster · Lyric；主窗口仍兼容旧标题匹配，标识和存储键不变。
- C `67d03a5`：工具面板统一为 30pt 行。`V3PanelRow`、`V3RowToggleStyle`（面板根部统一套用）、`V3InlineSwitch`、`V3PanelSection`、`V3DisclosureRow`；`V3NumericSlider` 改单行并去掉范围说明、刻度和预设按钮（预设仍由 / , . 键提供）；`V3SegmentedPicker` 标签宽 64pt。文字面板的读音类选项折进“读音与更多”（`v3.text.advancedExpanded.v1`）。“恢复歌词时间”与偏移行的归零是同一操作，收进偏移行。
- D `abeca69`：环境光风格行只露原版环境光和柔光羽化，柔和光晕、独立色场在“更多”菜单里，被选中时回到行内（`foldedEntryIndices`）。
- E `78f9669`：卡片、紧凑栏、边缘胶囊共用 `V3PlaybackButtons` 的按钮与顺序；紧凑栏以前没有上一首/下一首。时间统一为 0:22。
- F `11b5776`：居中面板与歌词库窗口改用中性的 `V3SegmentedPicker`，不再是系统黑色或蓝色页签；收听记录页去掉大标题和说明段；日期统一 `v3ShortDateText`。
- G `72b2d02`：设置页首收小；模型与思考强度有行式版本供译文面板使用。离屏图里设置侧栏选中项是黑底看不见字，但加强调色后离屏图不变，判断为离屏渲染器的问题，没有改。

验证范围：每批完整原生测试和 CI 五组合同通过，离屏图只用来查错位和截断。真实窗口的观感、手感都没有经过用户确认；桌面控制工具按策略拒绝访问本 App。

## L-017 「我的风格」译风曾只存在于未合并的快照分支

用户设置里保存的是 `translationPrompt.personalV2.v2`（full-audit-v2-r1，2026-10-09 按用户全部确认译稿审计出的规则），正式库里 22 份 AI 译文都用它生成。但这个预设只在 Codex 快照提交 `5a96753`（不在 main）里存在，main 的枚举里没有它，`TranslationPromptPresetID(rawValue:) ?? .naturalSong` 静默退回较短的“自然歌曲 v2”。2026-11-12 按同一 raw value 恢复为第一项和新安装默认值，指令原文取自 `5a96753`，并附上 10-15 复核得出的多语种说明（`personalV2Guidance`）。自然歌曲等其他预设保留可选；已保存的译文不重写，只有新的请求使用。

当时正式库里没有人工改过的译文（`is_manually_edited` 为 0），所以没有新的用户修订可以对照；22 份 AI 译文按现有规则抽查，没有发现擅加“永远/一定”、无据补性别代词或拆并行。用户的确认译稿在 Vault 的翻译目录，不在本项目文件夹内，这次没有读取。下次改译风前先查 `defaults read com.spotifylyrics.app ai.promptPresetID` 看用户实际选的是哪个，并确认枚举里有它。

2026-11-18 的设置只有一个「我的风格」编辑框，正文与多语种说明都可以改。用户可以清空再输入，点完成、离开编辑框或离开页面时保存。旧设置原来只存正文，读取时补齐当年实际发送的尾注。两个提示词生成入口都使用请求创建时的设置快照。已发送的旧请求曾把所有个人风格写在同一个键下，恢复结果要沿原键和原歌词版本，重译由用户发起。检查入口是 `SearchSourceContractTests` 和 `AITranslationContractTests.testProtectedRecovery`，均走隔离库或模拟传输。

## L-018 模糊曲线、羽化圆形与主窗口订阅歌词库

**模糊曲线。** 用户反复说模糊“指数增长”。在真实窗口里把同一首歌的背景模糊依次设为 0 到 100 截图，量背景细节：旧曲线 `pow(n, 1.35)` 在 25% 已去掉大半细节，50% 以后几乎不再变化。2026-11-12 改为按比例增长的 `V3BlurCurve.response`（底数 24），各画面 100% 的最大半径不变，每四分之一滑块把半径乘以同一倍数。已保存的数值经 `V3BlurCurve.fromV1` 换算一次（标记 `v3.blur.curve.v2`），画面不变、显示的数字变了；色场类画面（内页、专注、独立色场）的滑块含义不同，数值不动。
下次调模糊，先在真实窗口逐档截图对比，不要只看公式。

**羽化的圆形。** 用户记得的“四周特别模糊、中间一个清晰圆形”的环境光，就是 `2c7c083`（2026-10-16）之前的柔光羽化。四周铺满一层恒定重模糊（36pt 加滑块），中间是与窗口等高的圆形封面。那次提交把四周的模糊也绑到滑块上，于是低模糊时圆和四周分不出来。该提交在 README、发布说明和旧截图里都没有出现，是从项目笔记“移除羽化模式固定 36pt 背景模糊”一句找到的。

**主窗口订阅歌词库。** `AppleMusicImmersiveV3WindowView` 用 `@StateObject` 持有 `PersonalLyricsLibraryService`，但 body 不读它的任何属性。它的每次 `@Published` 变化（加载提示、列表、选中详情）都会让整个主窗口连同歌词重算，用户感到歌词库面板里切换卡顿。现在由不发布变化的 `V3LibraryOwner` 持有；显示歌词库数据的面板仍各自 `@ObservedObject`。改善是按代码路径判断的，没有在真实窗口计时。

## L-019 新光效与新播放呈现的接入方式

- **新光效不加渲染器。** 双色、窗光是“原版环境光 + 光效”（`v3.ambient.treatment.v1`），由 `V3SceneFamily.inUse` 统一判断当前画面，旧的场景、渲染器 rawID 和数值都不动。
- **新播放呈现不改旧开关。** 六种新呈现存在 `v3.playbackStyle.v1`，标准 / 悬停 / 边缘背后的两个开关不变。
- **隐藏播放卡和封面的判断。** 布局里原来用“边缘模式开”来隐藏播放卡，现统一改为 `settings.v3ScenePlayerHidden`。侧脊、唱片架、角落、幕间还通过 `compositionShowsCover` 关掉场景自己的封面；各布局本来就按这个属性给出无封面版式。
- **封面相关的呈现。** 封面进度和黑胶直接用已上报的前景封面位置（`V3ForegroundCoverFrame`）。黑胶的唱片画在布局下层，封面才能挡在它前面。
- **验证方法。** 在真实窗口截图，对比同一区域的亮度：窗光前两版在浅色封面上完全看不出来，测量后才确认是光带汇聚在窗外，加上亮度不够。

## L-020 工具栏、歌词、播放栏样式做成选项；只在指针附近显示的界面怎么核对

- **默认不变。** 用户要求把方案都做成可选项预览。工具栏、歌词呈现、进度条各存一个键（`v3.toolbarStyle.v1`、`v3.lyricStyle.v1`、`v3.playerBar.progress.v1`），另有三个播放栏开关，默认值都是原样。
- **接入位置。**
  - 歌词样式在 `AppleMusicImmersiveV3LyricRow` 里按 `settings.v3LyricStyle` 调整透明度、模糊、放大和光晕。
  - 逐字歌词的 `AppleMusicImmersiveV3TimedRowView` 看不到设置，用环境值 `v3LyricStyle` 传入。
  - 播放栏选项用 `v3PlayerBarOptions` 环境值传入。
- **只在指针附近显示的界面。** 工具栏只在指针靠近时显示，`screencapture` 拍不到。用离屏主机的 `--toolbar full --toolbar-style …` 核对，仅用于排版。
- **译文同行的坑。** 用 ViewThatFits 判断“放不放得下”时，候选视图不能带固定宽度，否则永远判为放得下。
- **截图前先看用户的现选值。** 截图脚本只改要看的那一项，结束后恢复用户自己的选择（这次用户正在用封面进度和环形工具栏）。

## L-021 已存歌词读不出来：两个数据库对象各自缓存重定向；合作歌手写成假名

**症状**：已采用过歌词的歌，突然显示“歌词暂不可用”。2026-11-12 用户连续截到三次：《Romeo and Cinderella - Remix》、一首 nyamura 的歌、《君とコーヒー (feat. Sando Aoi)》。

**原因**：
- Spotify Desktop 时而报全部歌手、时而只报主歌手，同一首歌因此得到新的身份键，读取时要写一条重定向（新键 → 旧键）。
- 播放器和歌词库各有一个 `SQLiteLyricsRepository`，各自在内存里缓存重定向表。
- 一个对象写过的重定向，另一个的缓存不知道。它再写一次时撞上 `track_identity_redirects.source_stable_key` 唯一约束。
- `isLyricsSelectionRevoked` 抛错后，会话为了保护已采用的版本而停止，显示失败。

**修复与验证**：
- `redirectNewSpotifyKey` 写之前先查数据库；已有就刷新缓存并跳过。
- 测试 `testSecondRepositoryReadsARedirectTheFirstAlreadyWrote` 在旧代码上复现了同一个错误。

**顺带的改动**：
- 读库失败会自动重试三次。
- 提示改为“暂时读不到本机歌词库，已保存的歌词还在”。
- 启动时把上一次日志留在 `/tmp/spotifylyrics-e2e.log.1`。这次就是因为反复重启把现场日志清掉了，第一次没查到原因。

**合作歌手写成假名**：《Imagination (feat. Raguma)》的网易云记录写作「らぐま」。主歌手、专辑、时长（151.29 秒）都一致，却因合作歌手名不同进了核对，前后搜了 25 秒。
- `TrackTextNormalizer.nameReadingKey` 只把纯假名的名字转写成罗马字再比较；含汉字或谚文的名字保留原样，以免中文读音被当成日文名。
- 测试 `testGuestWrittenInKanaIsTheSameGuest`。

以后再遇到“别人有歌词、我们没有”，先看日志里是否有 `PERSISTENCE` / `SESSION failed`，再看 `MATCH` 的扣分项。

## L-022 第一批调研方案：本机 Canvas、歌手照片、封面路线、律动

- **Canvas 只读本机。** Spotify 的 Canvas 只在私有接口里给，条款不许第三方用。客户端把加载过的 Canvas 地址存在 `PersistentCache/Users/<账号>-user/primary.ldb`：键是 `!xmeta#cache#` + `01 30` + `#` + 长度 + uri + `#`，值是 protobuf `Any` 包着的 `EntityCanvazResponse.Canvaz`（2 地址、4 类型、5 uri）。`SpotifyLocalCache.swift` 按 LevelDB/Snappy 公开格式自己实现只读查找（不开库、不抢锁、单文件读失败就跳过）。Lyrimuse 是 GPL、本仓库保留所有权利，所以没抄它的代码，只参考做法。实测 2,818 首有 Canvas，每次 20–30 ms。
- **粗扫会严重低估。** 直接 grep `.ldb` 只看到几百条，因为数据块大多是 Snappy 压缩的。
- **歌手照片不需要登录。** 公开嵌入页 `open.spotify.com/embed/track/<id>` 里有歌手 uri（`SpotifyTrackArtistResolver` 本来就请求这一页，现在顺带留下 ID）；官方 oEmbed 给 320 px 头像，图片 ID 的尺寸码 `00005174` 换成 `0000e5eb` 即 640 px。
- **已定外观不动。** `BackdropPalette` 的主色、副色、光色保持原算法；新增 `route / identity / partner / edge` 只用于自动选择、双色、窗光和强调色（`CoverColorRoute`，参照 Tauon）。
- **律动单独采集。** `V3MusicPulse` 不复用排轴的采集（那边有身份守卫和排轴状态），自己开一路只含 Spotify 的 ScreenCaptureKit 音频流；画面每帧用锁读数值，SwiftUI 不随帧重绘。默认关闭：持续采集会让菜单栏一直显示录制标志。
- **律动第一版完全没有数据。** Spotify 的声音是两个分开的声道，`CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` 需要先问大小再分配；只给一个 `AudioBufferList` 的空间会直接失败，分析器一帧都没收到（用户反馈“看不出区别”）。改成先问大小后，日志 `PULSE levels` 每 5 秒报低音峰值和 BPM（实测峰值 3–16 倍、120 BPM）。光也从封面正后方（被封面挡住）改成封面外的一圈光环加整体轻微提亮，连拍真窗口能看出节拍起伏。
- **Spotify 缓存里还有速度、调性、节拍、人声和段落。** 键 `!xmeta#cache#` + 3 字节类型 + `#` + 长度 + uri + `#`：`02 E0 DE` 是 AudioAttributes（1 速度 double；2 {1 调名, 2 大小调, 3 {1 Camelot, 2 颜色}}），`02 E0 D9` 是 Beats（2 重复 {1 秒 float, 3 小节第几拍, 4 置信度, 5 强拍}），`02 E0 DA` 是 VocalActivity（22050 Hz、每 315 采样一格），`01 3C` 是 automix Cuepoints（段落点，毫秒）。这些只给在列表里显示过 BPM 列的歌（本机约 1 万首有速度，几百首有节拍）；新歌通常没有，播放中也不一定补上。
- **自己估速度的坑**：150 BPM 一拍是 37.5 帧，不是整数，37、38 两个间隔各只对上一半的拍，两拍（75 帧）反而最齐，于是估成一半；先把起音曲线平滑两次即可。80–160 BPM 之外的“差一倍”是固有歧义，不再硬调。
- **背景素材合并成一个选择。** 第一版“背景素材”和“有视频时用视频”分开，选了歌手照片还得关视频才看得到；现为 视频 / 封面 / 歌手照片 一个选择（`v3.backdrop.source.v2`，从两个旧键迁移）。
- **Spotify 有时给不出封面地址**（`ARTWORK desktop … found=false`），前景封面变成占位图；现在改从公开 oEmbed 取同一首歌的 640 px 封面。
- **封面先显示随后又没了（2026-11-18）。** 《Uta o Oshietekureta Anata e》的日志有封面成功、图片地址进背景、同一录音又收到空地址三个连续事件；Spotify CDN 返回 200。播放事件已保留封面，定时校准走另一入口把它覆盖了。`PlaybackState.synchronize` 统一用 `retainingArtwork`，只在同来源同录音缺地址时沿用已经解析的封面。原生用例复现空地址校准前后保留封面，同时继续更新时间、歌词身份和版本。
- **封面从启动起可补读（2026-11-19）。** 初始读取、桌面通知、校准发现换歌都从已接受的同一快照补封面。Spotify 的保留大小写 ID 在播放器封面缺失时查询公开封面。首次补读落空后，后续桌面通知允许再试一次；位置校准不会重复请求。收到新封面会取消旧读取，晚回的结果不能覆盖它。播放器桩先复现了启动缺封面和迟到结果覆盖，修复后两组原生检查共 30 项通过，包含旧档案已确认的跨语言歌名仍沿用同一已采用版本。
- **跳转保持与单句循环冲突。** 循环靠 Spotify 报告的位置判断句尾，保持会把它挡住（`testLyricLineRepeatsUntilCancelledAndStopsOnTrackChange` 抓到）；来源 `lyric-line-loop` 不保持。
- **脏词还原只做等长替换。** 走 `ReadingProjection` 的显示投影（和繁简转换同一处），逐字片段按原 UTF-16 范围重取文字；投影缓存键加上这个开关。
- **顺带修正**：`testPinnedPlacement` 还在要求“永远不放左侧”，与 Round 14 的“右侧放不下就放左侧”冲突，已按现行为更新。
- **界面跟随封面色（2026-11-18）。** 用户截图里当前句是封面色，读音、播放键、红心仍是白色，看着不统一。现在由 `v3FollowCoverColor`（`v3.followCoverColor.v1`，默认开）统一控制：当前句连同读音、罗马音、译文、和声，已播放的波形，播放圆键，已开启的红心、随机、循环和「添加到歌单」（选歌单时，或已知在某个歌单里），以及工具栏选中项的底色，都取主窗口的 `v3CoverAccent`。关掉后它们全部变白。背景、轮廓光、四边灯带不受这个开关影响。开关在画面面板「背景细节」上方。
- **「添加到歌单」自己知道已收（2026-11-18）。** 原先只有打开选歌单面板、逐个查过后才知道这首歌在不在歌单里，播放卡上的按钮因此一直是白色。现在按钮出现时，`PlaylistPickerModel.refreshSavedIndexIfNeeded` 在后台按快照号读一次每份歌单的曲目（`trackIDs(inPlaylist:)`，Apple Music 返回 nil，不参与）。换歌时直接查这份索引，不发请求。歌单列表最多每 10 分钟重读一次；本机加入或移出后同步更新索引。测试见 `PlaylistSavedIndexTests`。
- **搜索慢、别人有时间轴我们只有纯文本、翻译看不到在哪、亮背景只想改字色（2026-11-19）。**
  - **实测方法**：临时写一个由 flag 文件控制的在线测试，用 App 实际的来源链对两首歌搜索，打印总耗时、首次显示时间、每个来源的耗时和结果、原始候选（标题、歌手、时长、首尾行时间），测完删除。
  - **GIJIKOI（Haruki Hamano）**：LRCLIB 约 1 秒就返回了带时间轴的「ギジコイ - GIJIKOI」，但时长是 217 秒，Spotify 是 200 秒，判为 durationFar，于是没有提前显示。搜索一直等到 LinkCore 超时返回 HTTP 500（5.5 秒）、再跑完第二轮宽松查询，约 10 秒才采用这份歌词。现在 `automaticProvisionalDocument` 对「带时间轴、标题（含并列写法）和主歌手完全一致、只差时长之类证据」的候选也先显示，最终仍可能被替换。实测 1.6 秒出词。网易云按「GIJIKOI Haruki Hamano」查不到这首（对方 App 的译文多半来自网易云），没有处理。
  - **Less Kiss（TakaseToya）**：LinkCore 给出精确匹配的纯文本；网易云其实有「レスなキス / 高瀬統也」，带时间轴、有译文、最后一行在 178.5 秒（曲长 180 秒），但标题和歌手写法不同，匹配器配不上。新增 `timedSameWords`：已经采用的是纯文本时，如果另一个来源的歌词正文相同（`lyricShingles`/`sameWords`），带时间轴，不是 live/remix/cover，最后一行没超出曲长 2 秒以上，时长差不超过 20 秒，就改用它的时间轴和译文，诊断记为 `@timing-same-words`。测试见 `LyricsTimingAndEarlyDisplayTests`。
  - **翻译失败**：截图里的「上次请求已发起但没有可恢复的完整结果」，是本轮做性能测试时反复重启 App、打断了正在进行的翻译。翻译慢主要因为用户选了 GPT-6.2-Sol + 超高思考强度。看不到在哪个对话：以前每次翻译都用一个新的临时目录作为工作目录、用完就删，而 Codex 按工作目录归类对话，所以找不到。现在固定为 Application Support 下的「Aster Lyric 翻译对话」（`CodexTranslationWorkspace`，空目录，只读运行）。译文面板在选 GPT/ChatGPT 时写明对话名和文件夹，可以在 Finder 中显示；思考强度为高或超高时提示会很慢。
  - **封面亮度改为直接测图**：调色板给出的亮度远低于实际图片（一张米色封面实际均值 0.65），所以亮背景判断不准。`V3BackdropBrightness.cover(url)` 改为取封面原图缩到 16×16 后的平均亮度；有视频时仍用视频亮区的值。用户把亮背景保护整体关了（`v3.brightCoverShadow.enabled.v1`=0），核对时临时打开、截图后已恢复。
  - **亮背景「只调文字」**：`v3BrightProtectionTextOnly`。画面不压暗，背景亮度超过 0.5 时歌词改用深色字（`V3LyricInk.dark`）加白色细描边；当前句的封面色用 `V3ReadableAccent.darkColor` 加深，只作用于歌词，播放卡和工具栏仍用浅色的封面色。文字面板改为三档「关 / 只调文字 / 文字和背景」。歌词行里原来写死的白色都改成从环境读取 `v3LyricInk`。
- **2026-11-19 接续，日文标题补译文和百分数标题识别。**《GIJIKOI》采用 LRCLIB 的原词后，从可信日文并列标题「ギジコイ」补查一次网易云。先显示原词，再按时间邻域与原文对应补译文，源分行不同可合并同一句的译文片段。搜索自动采用与回退路径共用补查。隔离的真实来源测试中，1.63 秒首次显示原词，补查用 0.86 秒，52 行里补到 46 行。自动存档的同一版可用「重新搜索歌词」补存词源译文，沿用原版本与时间轴。存档会从下一行补出缺省行尾，比较原文和行首即可；读音补全应直接复制行再更新读音，避免丢掉词源译文字段。
- **《Less Kiss》首屏接续。** 真机旧版网易云查询约 0.82 秒返回《レスなキス》录音，英文歌名与拉丁歌手名同时不同使它被拒，等待发行方页面对词后才采用，总搜索 11.63 秒。按 TuneCore 同一首曲目的两种语言页补充发行名称，限于 Spotify 原录音 ID、发行专辑及原名。现有匹配器可在首轮验证歌手、原录音时长和版本，并先显示时间轴。LRCLIB、网易云、QQ、LinkCore 的隔离在线组合实测 2.06 秒出首屏，采用网易云 30 行，其中 28 行有译文，未请求 LinkCore。现场版仍以自己的网络和来源设置为准。
- **《百分之零》/ 橙汁。** QQ 音乐已回传《0%》的 QRC，原先被 `titleMismatch` 拒绝。整首标题是同一个百分数、主歌手一致、时长差 ≤1 秒且同步歌词与曲长吻合时可自动采用；来源少列合作歌手也可匹配。隔离实测用单歌手和完整署名均命中 QQ `000uSIBD3tnEOS` 的 55 行逐字稿，截图对应句的行首为 43.74 秒。
- **播放时主线程过忙（2026-11-19，用户选择「先做性能」）。** 真实 App 播放中（原版环境光、视频背景、波形进度条、无情境）整进程 CPU 64–98%，`ps -M` 显示几乎全在主线程。用 `-O` 构建结果相同，所以不是没开优化的问题。
  - **查法**（本机关闭了开发者模式，Instruments 无法附加，下面这套可以直接复用）：临时探针构建：① 在大视图 body 里调用 `Self._printChanges()`，统计每 10 秒的重算次数；② 交换 `-[NSView setNeedsLayout:]`，按类和所在窗口统计、并抽样调用栈；③ 用环境变量开关逐块拿掉画面（歌词列、背景、播放卡、工具栏、整窗）后实测 CPU。探针代码不提交。
  - **发现**：主窗口根视图每秒被标记需要布局约 250–800 次，几乎每帧都在做一次完整的 SwiftUI 布局和渲染，而 body 重算每秒只有 2–3 次。①触发源之一：`TimelineView(.animation(minimumInterval: 0.25))` 并不会按间隔限流，它所在的宿主仍每帧请求更新；播放卡的时间标签每秒约 200 次，波形进度条也是同样写法。②开销主要来自歌词列：拿掉歌词列后 CPU 降到约 13%，整窗清空约 1%。拿掉背景、播放卡、工具栏，或关闭换行动画，都没有明显差别。
  - **改法**：新增 `V3TickSchedule`（`.v3Every(秒, paused:)`），时间标签、波形、菜单栏进度、声纹圈和情境里 12 fps 的效果都改用它，真正的动画仍用 `.animation`。歌词视口放进 `V3AnimationIsland` 这道布局边界，窗口每帧的布局只放置它，不再重排每一行和每个逐字高亮视图。
  - **结果**：同一场景交替实测，改前 64–67%，改后 31–44%（真实 Spotify、视频背景、各自重启后等 25 秒，再测 20 秒）。逐字高亮、滚动和译文在真实窗口截图里正常。暂停和窗口不可见时的数值、菜单栏和灵动岛同时开着的情况没有单独测。
  - **试过但无效、已撤回**：时间标签岛的宿主不用自动布局；岛的 `layout()` 只在 frame 变了时才赋值；逐字高亮的 `layout()` 加缓存。主窗口每帧的触发源没有全部找到：拿掉歌词、背景、播放卡、工具栏之后仍有约 280 次/秒，开销不大，没有继续追。
- **性能第二轮，切歌瞬时峰值（2026-11-19）。** 对运行中的签名 Debug `1983053` 被动取样，Spotify 连播《Less Kiss》转到《シュガーラッシュ》，其中一次约一秒窗口的整进程峰值为 168%，一核计作 100%。Canvas 开启时，采样中最重的后台栈是 `SpotifyCanvasLocator → LevelDBFileReader → Snappy`。未命中时也会检查多张表，Spotify 尚未缓存新曲视频时还会按既有间隔重试。
  - **改动与证据**：`Snappy` 按解压长度分配缓冲区，使用成块复制并处理重叠引用，LevelDB 按字节批量比较键。切歌取消旧视图任务时会取消后台查找并在读表间退出。沿用原账户选择、缓存视频验证、重试和封面回退。用同一 Mac 上真实 Spotify 缓存，Debug `-Onone` 独立进程每个 ID 五次取 CPU 中位数，三种查无视频样本从 837–1128 ms 降至 176–182 ms，一个命中样本从 504 ms 降至 96 ms，并返回相同视频。此为查找路径的配对数据，整 App 候选的切歌峰值尚无同曲同窗对照。
- **歌词在亮背景、同色封面上看不清；译文太小（2026-11-19）。** 用户截图里的背景是亮橙色的 Canvas 视频，当前句用的封面色和背景接近，白字也看不清，桌面歌词同样有这个问题。用户还说「翻译有点小，但不想要默认一样大的方案」。
  - 原因：亮度只按封面图算（视频盖在上面时完全测不到）；「亮封面自动加阴影」只在封面写真场景生效；封面色没有按对比度处理。
  - 做法：`V3BackdropBrightness` 在 Canvas 视频显示时，取 0.5、2、4 秒三帧，计算最亮四分之一像素的平均亮度（用平均值会低估文字后面那块亮区），日志写 `BACKDROP clip luminance`。窗口把它乘以视频自带的 0.74 遮罩系数，作为 `backgroundLuminance`；没有视频时用封面亮度。
  - 亮度高于 0.35 时，在背景上叠一层压暗（`brightBackgroundScrim`，最多 0.45），前景封面不压。自动文字阴影改成所有版式都生效：封面写真类阈值 0.45，其他 0.42。`V3ReadableAccent` 把封面色往白色混，直到亮度至少比背景高 0.42（下限 0.62，上限 0.92）。这三项都归「亮背景自动保护」开关（沿用原来的 `v3BrightCoverShadowEnabled`）。
  - 实测：kikangentei 的仓库视频测得 0.62，画面压暗之后白字清楚了。
  - 译文：`v3ActiveTranslationLarger`（默认开）只让当前句的译文放大到原文的约 0.56、加粗，其余行仍是小字，保留层次。排版测量（大字模式的 auxiliary）用同一个函数。
  - 桌面歌词：`floatingDesktopSoftBacking`（默认开）在两行文字后面垫一层模糊成没有边的暗影，颜色跟随文字描边。原文有注音和普通两条绘制路径，所以加在外层的 SwiftUI 上，不放进 AppKit 的绘制。
  - 测试见 `V3LyricReadabilityTests`。
- **歌手照片有时找不到（2026-11-18）。** `V3ArtistImageStore` 曾把一次失败的 oEmbed 当成「这位歌手没有照片」，整个会话都不再查，于是同一歌手的后续歌曲也一直显示封面。照片下载失败时背景也会变空。现在成功的结果才长期缓存；失败当场重试一次，之后 90 秒内不再查。照片下不来就退回封面。实测 back number「ヒロイン」的嵌入页、oEmbed 和 640 px 图都返回 200，说明是偶发失败。
- **未在真窗口核对**：本轮 Spotify 不响应 Apple Events，视频背景、歌手照片、律动没能在播放中的歌上看到效果。另有三个源码约定脚本（`apple_music_immersive_v3_contract`、`capsule_lyrics_contract`、`capsule_v4_top_attached_contract`）在改动前就失败，与本轮无关。

## L-023 背景大小统一、繁简匹配、QQ/酷狗逐字与对唱

**背景大小。** 用户要求过不同画面背景一样大。

当时的原因：
- 每个场景各存一份取景和缩放，默认值也不同。
- 铺满在 100% 时还额外放大 1.12 倍。
- “尽量完整”仍按 1.15 倍裁掉方形封面的上下，看起来和铺满一样。
- 垫底的模糊副本跟着模糊滑块走，低模糊时几乎是清楚的，像第二张被裁切的封面。
- 羽化有自己的一套：按封面位置偏移，还为主体放大 1.3 倍。

现在的做法：
- 取景和缩放所有画面共用一份（羽化也用）。
- 完整就是整张放下，铺满就是刚好铺满。
- 垫底层固定重度模糊。
- 羽化背景居中、不额外放大。这沿用 2026-10 定下的“背景严格居中、左右对称”。

2026-11-19 补迁移：旧「经典·柔和光晕」没有情境键时，第一次读共用背景缩放被固定成 1，切换画面后重开也可能从新画面默认值起步。现在从首次启动时使用的旧尺寸与取景读出并持久保存这对共用设置，已存在的共用值优先。临时偏好以旧经典 130%、前景 90% 复现，修复后换到羽化并重开仍为 130% 且保留完整取景。经典几何检查改为运行实际投影与偏移函数，覆盖最小缩放对称和大尺寸留边限制。

**繁简。** 《曾經你說（說唱版）》的候选因“歌名不同 + 主唱冲突”被全部拒绝，其实只是 Spotify 用繁体、来源用简体。
- `TrackTextNormalizer.normalize` 先做繁体转简体。
- 身份键用的是 `TrackIdentity.normalizedComponent`，不受影响。
- 搜索词去重时不折算，所以两种写法都会去查。

**逐字。** 之前只有网易云 yrc 带逐字，QQ 和酷狗都只取了逐行，所以“别人有逐字我们没有”。
- **KRC**：`fmt=krc`，内容是 base64，以 `krc1` 开头，用 16 字节固定密钥异或，再 zlib 压缩；字的时间相对于行。
- **QRC**：`musicu.fcg` 的 `GetPlayLyricInfo` 接口，参数 `qrc=1, crypt=1`，返回十六进制。
  - 解密用 QQ 版三重 DES（解-加-解）。它沿用 Brad Conte 公共领域 DES 的位布局，即每 4 字节倒序读取。
  - QQ 改了两处 S 盒（S2[23]=15，S4[53]=10），密钥编排后半段取位也错开一位。
  - 只按标准 DES 打 S 盒补丁是解不开的，必须照这个布局实现。
  - 解密后是 zlib 压缩的 XML，`LyricContent` 里每个字写成“字(绝对开始,时长)”。
  - 字本身可能是括号，正则用懒惰匹配 `(.*?)\((\d+),(\d+)\)`。
- 网易云 `YRCParser` 按左括号切字，直接套 KRC 会切错，所以 KRC 单独写了解析器。

**对唱。**
- 两种格式里只有“歌手名：”的一行，表示下面几句由谁唱。
- 11 月 18 日《Complain》的 AMLL 原稿保存两条同句，`v2` 和 `v1` 起点只差 46 ms，时间大部分重合。原来两行都画，第二声部又统一缩进 12%，看起来像重复和行首错位。V3 播放列现在把相邻的不同声部、完全同文、起点近且大部分重合的句子显示在同一行，滚动也对回这一行。不同唱词、后来再唱的同一句、可读的演唱者姓名和档案中的各声部原始记录均保留。主窗口各对唱声部沿当前文字对齐方式排版。

- **同一晚续：两类“别人有我们没有”。**
  - 《如果真爱 - ２０２４ 说唱版》：来源都写作“如果真爱（2024说唱版）”，原来的排版判断只去掉单独的横线，括号和空格还在，于是所有来源都被拒，五轮查询全跑完用了 41 秒。现在去掉空格、横线、括号、间隔号后字符相同，就算同一歌名。
  - 《听悲伤的情歌 - 女版》：酷狗是同一歌手、198 秒分毫不差的《听悲伤的情歌》，原来只进了核对列表。现在同一歌手、时长差 1 秒内、标题只多出版本名（不含“伴奏”“Live”“DJ”“加速”等会改变内容的词），就自动采用。
- **Spotify 官方歌词做不了。** 网页令牌接口 `open.spotify.com/api/token` 回 400，说明里写着按开发者条款不许使用，还要求轮换的一次性口令；用我们自己授权的 OAuth 令牌请求 `spclient…/color-lyrics` 回 403 “RBAC: access denied”。剩下的路只有绕过访问控制，不做。
- **Apple Music 歌词（2026-11-13 已撤掉：用户不要需要自己填令牌的功能；以下做法只作记录）。**
  - 开发者令牌从网页播放器脚本里取（`/assets/index~*.js` 中的 JWT，选未过期里最晚过期的一个）。
  - 曲库查询只用开发者令牌就行；歌词还需要用户自己粘贴的 `media-user-token`，存在钥匙串 `com.spotifylyrics.applemusic-lyrics.v1`。
  - 来源配置里，已有用户的配置把它追加到末尾，新装放在 AMLL 后面，这样约定里“已有顺序原样保留”这一条照样成立。

## 实际覆盖与接续

方法继承总规则“2 项目记录”“5.1 全周期复盘与覆盖”。以下区分枚举、定向源码阅读和运行证据，**仍未建立全历史处理截止点**。

- 此前2026-11-10 在 `main@78d600a14270837dd3fffa3359dee47179a2150b` 全文读原 AGENTS、DEVELOPMENT_WORKFLOW、SUBMISSION_BASELINE、STATUS，读 TOOLBAR_BEHAVIOR 前 85 行及 Vault 入口/相关交接；后来在 `fd66ec3a2ebdba6eccb99d45a0022ddcfd1010bd` 核 Settings、Backdrop、L-004 历史原件并补自然场景索引。这些是规则/局部资料覆盖，不是全产品审计。
- 本轮在2026-11-11 固定 `main@3f069781b6c9f2b5bdf2c5e26ccbfc9f1581cb82`。完整枚举本机 refs 与可达提交数：main 794 个，全部 refs 795 个；项目可见根提交 `50045ecccfab88bf88a824ff67acab6295d6bb81`，2026-07-26 21:10:12 +08:00，首次 Spotify Lyrics App 实施。现有 main、origin/main/HEAD、4 个 tag、4 个 Codex snapshot commit ref 和 1 个 checkpoint tree ref；main 之外仅历史 snapshot `5a96753184e763908abb87c71949a4acd47fb904`。这些数字是枚举结果，不代表正文已读。
- 本轮全文读现行 AGENTS、PROJECT_MEMORY、Vault 项目 README/项目总览；定向读 TOOLBAR_BEHAVIOR 的 Round 11/12、Handoff 开头的 Round 6 历史及有关决定片段。核 L-005～L-012 列出的身份、匹配、缓存/预加载、队列、sheet、译文、详情预取和轨道的当前实现、关键差异与现有用例；查看 `075d578`、`24cfa3a`、`e91ffca`、`8e85fe6`、`23a378e`、`7144775`、`ff823a2` 等提交的相关 diff/说明，以及 L-002 所列本机作废性能日志。源码静态核对、提交中的当轮报告和本轮运行验证分别表述。
- 本轮没有重跑 Xcode/测试、启动 App、读正式库/Keychain、操作 Spotify 或调用模型；正式安装版和用户实际运行版未核。尚未逐一读从根到截点的全部提交正文/源码，也未完整枚举与阅读 GitHub PR、Issue、Release、远端其他历史 refs/附件及全部用户会话；4 个 tag 和本机 snapshot 仅枚举，不能称全分支审计。
- 全周期正文从根提交 `50045ecccfab88bf88a824ff67acab6295d6bb81` 开始，先核该阶段来源与后续真实差异；本次已经定向核过的主题/版本可复用去重，不用重新验证一遍。新提交和文档补记不前移产品历史处理点。产品开发仍按用户当轮任务，不由未完成复盘自动恢复。
- 后续自主推进又定向读取了根提交的 Mock 模型/播放状态、`5f20b8d` 的 Desktop provider 与状态实现、`4a0997c` 的明确 Mock Preview/请求代际与歌曲会话分离、`c8283ab` 的恢复/seek 差异，以及 `7905f04` 的搜歌/歌词模型和管理器。最早 14 个提交只枚举了身份与变更目录，早期审计/研究正文仅选读相关部分，UI 图片未复查，因此全历史完成游标仍未前移。当前修复所需的分工原因归入 L-005/L-007，未把旧 Mock 回退或旧来源规划恢复成现行行为。

## L-024 第二批：逐字手感、副歌、状态栏弹窗、视觉细节（2026-11-13）

- **Core Animation 不要用 `timeOffset` 表示“已经开始了多久”。** 动画走到结尾后会从头再播一遍，逐字上浮会在句中重新弹一次。改成把 `beginTime` 设在过去：`layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed`，配合 `fillMode = .both`、`isRemovedOnCompletion = false`。上浮和长音发光都按这个写。
- **离屏截图宿主里 SwiftUI `.blur` 不生效。** 状态栏弹窗顶部第一版用模糊封面，离屏图里封面上的字清清楚楚。改成把封面缩到 12 像素再放大当色场：不依赖渲染器，也没有模糊开销。离屏宿主的深色弹窗本来就是白底（改动前也一样），深色效果要看真实 App。
- **本 App 的电脑操作被策略禁止**（`request_access` 返回 policyDenied），状态栏弹窗打不开做真窗口核对；只能用 `Scripts/ui-snapshots.sh <dir> menubar-light menubar-dark`。主窗口仍可用 `screencapture -l` 拍。
- **换歌时封面闪一下占位图**：`ArtworkView` 原来先把图置空再加载。现在保留旧图，新图载入后从轻微模糊中显出，再移除旧图；新歌没有封面时照旧不保留旧图。任务键只用封面地址，同一张专辑换歌不再重播。
- **非正方形前景封面露出方形底板（2026-11-18）。** Spotify 的 Superfly 这张封面原图为 568×640。`ArtworkView` 在方形槽里用 fit 放图，却把占位渐变、整体裁切、边框和效果几何留在方形槽上。现在保持原图取景和固定布局槽，圆角、边框、题句、进度与情境效果都跟随实际封面矩形；切歌显影期间仍保留原有交接，缺封面时用同一层圆角裁切绘制占位图。
- **已有封面在别的入口仍显示占位（2026-11-19）。** 档案、找歌和队列的缩略图原来另用 `AsyncImage`，读不到听歌窗已解码的封面。现在这些入口、歌单选择器、最近播放、封面墙和拍立得共用 `CachedArtwork`，沿用 `ArtworkImageLoader` 的本机文件与网络缓存。缩略图保留各自裁切，封面和雨滴玻璃按当前 URL 显示并拒绝已取消的加载结果。定向原生测试先复现临时源文件消失后歌单的封面变空，再验证复用播放已加载的长方形封面，以及地址清空以后不串图。
- **下一首的封面慢到时仍显示上一张（2026-11-19）。** 短暂显影曾留下旧图直至新请求结束，慢请求时错图能保留数秒。前景现在按当前 URL 取图，缓存图立即可用，等待时显示当前歌曲的占位；新图到达仍可显影。V3 及经典背景只显示当前素材的图与取色，V3 封面和视频共享静态封面请求，先显示当前封面再等可选的歌手照片。人物位置与 Canvas 就绪状态也限定在当前素材或录音。隔离原生窗口把第二张封面延迟六秒，旧版显示旧前景；候选先显示新歌占位和中性背景，随后收到新图与配色，回上一首先显示缓存图。36 项定向原生检查通过、1 项环境跳过，两个背景脚本通过。歌手照片与 Canvas 的真实媒体未参与该样例。
- **暂停褪色**用一层灰色 `.blendMode(.saturation)`，只在暂停 1.5 秒后才插入。播放时不存在这层，不多一次全窗合成。跳转造成的短暂停顿不会触发。
- **桌面歌词情境隐藏**：CGWindowList 的第 0 层窗口要在桌面歌词所在屏幕上覆盖全屏。只看宽高，会把另一块同分辨率的屏幕也判成全屏。用显卡的屏幕矩形与窗口矩形比较四条边，两者都以主屏左上角为原点。隐藏期间保留鼠标穿透设置。见 Apple 的 [CGDisplayBounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:)) 与 [kCGWindowBounds](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds)。
- **侧拉工具栏**：右缘 76 pt 内触发，竖列居中，从窗外滑入；悬停面板改为 `preferredEdge: .minX`，即向左打开（`V3ToolPopoverAnchor` 里按样式判断）。`v3_toolbar_model_contract` 断言了样式清单，加样式要一并更新。
- **面板里多个独立开关排成一行时用 `V3ChipToggles`**，与分段控件同一底槽；不要再用三个 `V3InlineSwitch` 挤一行，会把标签折成两行。
- **胶囊开合（G5）暂缓**：用户计划把胶囊做成灵动岛，单独设计。
- **写偏好前先读 Bundle ID**：本 App 是 `com.spotifylyrics.app`，不是仓库名。猜错域会在 ~/Library/Preferences 留下空文件。
- **逐词的底层与高亮层共用一个朗读出口。** 主窗行内逐词按原文提供一个文本节点，外层保留「跳转到歌词时间」动作。原生隔离窗里曾把同一行拆成 28 个文本节点，合并后剩一个完整正文节点。注音底字的高亮复制层也从辅助功能树隐藏，原有读音编辑可用默认动作触发。

## L-025 窗上天气、歌词意象、VU 表（2026-11-13）

- **`CAEmitterCell` 没有加速度时在屏幕上一个都不出现。** 雨丝第一版速度设得再高再低都看不到，按参数逐项对照雪（能显示）才定位到这一点，原因未查明。凡是下落的粒子都给重力（`yAcceleration`），雨用 −1700 加 200 初速。
- **核对粒子不必等播放。** 用临时可执行文件开一个自己的窗口，放 `V3ParticleHostView`，再用 `screencapture -l` 拍。只需把 `V3WindowVisibilityProbe` 补个桩。`CGWindowListCreateImage` 在新 SDK 里已不可用。
- **歌词意象只认关键词。** 英文按整词匹配，避免 train / brain 被当成 rain；中日韩按子串匹配。原文和译文都看。默认关，防止效果过多。
- **VU 指针**用阻尼弹簧，ζ 0.8、ω 16.7，每帧两次半隐式欧拉，约 0.3 秒到位、过冲约 1.5%，有单测。读数 = 0.6 + 0.24·log2(电平比)，歌曲平均电平落在 0 VU 以下。没有真实左右声道，只标“低 / 高”。
- **`V3ControlBarSurface` 是胶囊形**，套在高卡片上会变成大圆团。卡片用 `V3PlaybackSurface(cornerRadius:)`。
- **新呈现超过 6 个就分两行**（同歌词呈现）。`v3_toolbar_model_contract` 断言了呈现清单，加呈现要一并更新。离屏宿主新增 `--playback-presentation`。
- **分享卡（`ImageRenderer`）里，用 `scaledToFill` 的方图当竖卡底图要给它单独的 frame 并 clipped**，否则整张卡被撑宽，文字被推出画面。分享卡的渲染在单测里出图（临时目录 `aster-share-card-test.png`），可直接看。
- **`ImageRenderer` 不画 ScrollView 里的 Lazy 网格**（出空白图），单测宿主里 `screencapture -l` 也拍不到（没有录屏权限，静默失败）。核对封面墙这类视图，用临时可执行文件单独编译该视图，给 `ArtworkImageLoader` 补桩，开窗后用 `screencapture -l` 拍。
- `SearchSourceContractTests.testRepeatedLyricLineStartsTheReadingProcessOnce` 偶尔超时，重跑即过，与本轮改动无关。
- **声纹圈画在封面外的矩形环上**，起点和方向沿用窗口边缘进度：顶部正中、顺时针。按对角线画圆环会超出窗口，还会压到下方播放卡。录音存在 Caches/Soundprints，每首一个 JSON，180 格，每格用滑动混合（0.7/0.3）记录。
- **频谱 24 段**：从 50 Hz 到 12 kHz 按音高均分，每段至少一个 FFT 格，相邻段首尾相接；每段对自己的长期均值归一。环绕封面和声纹圈共用 `V3SpectrumOverlay.loopPoint` 的矩形环，起点顶部正中、顺时针。
- `FloatingLyricsPresentationTests.testFloatingPresentationBehavior`（A-B-A 宽度键复用）偶尔失败，连续重跑两次都过，判断为偶发，与频谱无关。注意：命令链里不要把提交排在测试之后又不看测试结果，这次就因此带着失败提交了一次（重跑全过）。
- **临时改画面不要借用悬停预览的 `presentationOverride`**。副歌时换素材给背景视图单独加了参数 `chorusSwapsMaterial`，只翻转短片层：显示条件为“已保存的素材是视频”与“正在副歌”二者不同时为真。短片提前找好，切换时不用再等。
- **雨夜房间用 `V3RainRoomModifier`**，挂在主窗口指针追踪（`onContinuousHover`）之后，所以画面里的坐标仍是缩放前的。关闭时缩放为 1、房间透明，视图结构不变，开关不会重建内容。
- **情境（2026-11-18 改版）。** 用户反馈雨夜房间打开后画面特别小（原来缩到 62%），视觉也一般，同时希望不止做房间。现在 `V3RoomModifier` 让画面保留窗口约 85–92%，四周只留 22–54 pt 的边距，作为窗框和墙。房间的效果画在玻璃上，并且不接收指针。可选：雨夜窗边、夜行列车（窗外的光只在玻璃上下边缘掠过，中间不挡歌词，每 9 秒有一盏路灯扫过）、雪夜小屋（四角结霜，炉火闪动），以及一个不是房间的「老电影」（胶片齿孔、颗粒、偶尔的划痕、闪烁）。设置键为 `v3.room.v1`，第一次会读旧的 `v3.rainRoom.v1`。入口在「更多 › 窗口 › 情境」。离屏宿主可以用 `--room rain|train|snow|film` 出图。
- **情境第二批（2026-11-18，用户说「全做吧」）。** 「窗」类：雨夜窗边、夜行列车、雪夜小屋、跟随天气。「材质」类：书页、拍立得、星座、老电影。
  - 窗类墙面按本地时刻染色（清晨偏冷、白天、黄昏琥珀色、夜里深蓝），每分钟读一次。
  - 「副歌时开窗」（`v3.roomOpensOnChorus.v1`，默认开）：副歌时窗框淡去，画面回到全尺寸。
  - 夜行列车的灯速取 `SpotifyTrackAnalysis.load` 里的 BPM，以 110 为一倍，限制在 60–180。不需要打开随音乐律动。
  - 跟随天气用 CoreLocation 的降精度位置，四舍五入到 0.1°，请求 Open-Meteo 的 `weather_code`，30 分钟刷新一次。没有权限或没有回应时显示雨夜窗。Info-Additions.plist 加了 `NSLocationUsageDescription`。
  - 书页：遇到空行或间隔 ≥7 秒算新一段，每段开头翻一页。拍立得：当前句手写在下方白边，字体按 Klee、手札体、楷体顺序回退。星座：每句一颗星，按歌曲 stableKey 生成固定星图。
  - 雾窗歌词样式：唱完的句子先保持清晰，再用 3.2 秒被雾慢慢盖回。
  - 冲洗台（`V3Keepsakes`）：在拍立得或星座下，一首歌唱过六成以上再离开，会生成一张 PNG（拍立得卡或完整星图），和 index.json 一起放在 favorite-lines.json 旁边的 Keepsakes 目录，不写歌词库。卡片保留这首歌重复最多的一句，没有重复时取三分之一处那句。情境边距里的托盘可以把它收进歌本（摘句）、存为图片、在 Finder 中显示或删除。测试见 `V3RoomSceneTests` 和 `V3KeepsakeTests`。
- **情境重做为全尺寸三层（2026-11-18）。** 用户的意见是：不要把现在的界面缩小装进新地方，情境应该贴合现有画面，做成一组独立的功能。旧的 `V3RoomModifier` 缩小加外框已删掉。现在的结构：
  - 背景层 `V3SceneBackLayer`：在背景和歌词之间，放光、星空、掠过的灯、炉火、台灯、窗棂的影子，用柔和的渐变，不画硬边。
  - 封面层 `V3SceneCoverLayer`：贴着 `foregroundCover`，包括拍立得白边（含手写句子和胶带）、胶片框、书中插图框，以及冲洗台托盘。
  - 玻璃层 `V3SceneGlassLayer`：在最上层，不接收点击，放雨、雪、霜、颗粒和翻页。
  - 每个情境有自己的「副歌时刻」（`v3.roomOpensOnChorus.v1`）：雨夜下大雨加闪电，夜车开上桥（灯加倍、下方城市光），雪夜雪更密，星座划过流星，拍立得按一下快门，老电影放映灯闪一下，书页标出副歌那一段。
  - 情境的调色只在情境里叠加，不改用户自己的画面设置。
  - 入口：工具栏新增面板 `.scene`「情境」，在画面和更多之间，用卡片选择，悬停时在真实画面上试看（`scenePreview`）。「更多 › 窗口」里的旧入口已去掉。`v3.room.v1` 照常读取。
  - 坑：拍立得下沿不能按 `playbackRegion` 算，它和封面帧不在同一个坐标空间，算出来会压住播放卡。现在下沿宽度固定为侧边的 2.4 倍，正好放进封面和播放卡之间的空隙。主题 `coverPhoto` 不显示前景封面，核对封面层要用默认场景出图。
- **情境第三批：要有「惊艳感」、要互相适配（2026-11-18）。** 用户说看不出窗边情境的效果，整套也不够新颖，并要求所有部分互相适配、不能突兀。
  - **不用 Metal**：本机没装 Metal Toolchain，需要单独下载；CI 也会因此依赖它。`layerEffect` 等着色器还会让 NSView 子视图（逐字高亮 `TimedLyricHighlightView`、粒子）在栅格化时消失。所以全部改用 Canvas、材质和预渲染贴图。
  - 雨滴玻璃 `V3RainBeads`：420 颗水珠，大的每颗是一个小透镜，倒映缩小、上下颠倒的封面，有暗边和高光，其中 22 颗会滑落并留下水痕。
  - 起雾的窗 `V3FogGlass`：`.ultraThinMaterial` 在真窗口里会真正模糊后面的画面，但离屏图里是一片实心。用鼠标划过可以擦开，20 秒内慢慢重新起雾，部分擦痕会往下流。歌词区域默认半透，不然什么都读不到。
  - 极光 `V3Aurora`：三层连续的光幕，颜色取自封面；封面没什么颜色时用经典的绿、青、紫。不能用一根根细光条拼，会出现条纹。
  - 水面 `V3WaterLight`：用 CPU 生成一张能无缝平铺的光纹贴图，两层反向漂移。颜色要在 Canvas 图层里用 multiply 染色，`colorMultiply` 在 plusLighter 下不生效，出来是灰的。每唱一句，以及鼠标划过时，都会荡开水波（`V3SceneInput` 不发布变化，避免整窗重绘）。
  - 适配：所有情境的光都按封面亮度调整（`v3SceneLight`），颜色取封面色；切换情境时 0.8 秒淡入淡出；开着情境时不再叠加「窗上天气」和歌词意象粒子；拍立得没有前景封面时，改在左下角贴一张小拍立得；跟随天气遇到雾天（WMO 45、48）会选起雾的窗。
  - 动效不再跟着播放暂停而停，只看「减少动态效果」。副歌时刻仍然只在播放时出现。
  - 真窗口核对的方法：临时写入 `v3.room.v1`，重启 App，用 `screencapture -l` 截图，完成后恢复原值。离屏图里的模糊和混合方式不可信。
- **情境整套换装、行宽、封面交融（2026-11-18）。** 用户要求：换情境时，歌词位置、歌词效果、封面样式、播放栏和菜单都一起适配；歌词不必固定在那么窄的宽度；情境不能整片盖住封面，要和封面交融。
  - `V3Room.look(accent:)` 给每个情境定一整套：版式（`V3ListeningScene`）、歌词位置、歌词呈现、播放呈现、进度条、控件材质（`V3SceneChrome`）、行宽。
  - 版式和歌词位置走窗口已有的预览通道（`compositionScene`、`compositionStyle`、`compositionLyricsPosition`、背景的 `presentationOverride`），不写设置。
  - 歌词呈现、播放呈现、进度条走 `AppSettingsStore.applySceneLayer`：第一次套用时先在内存里记下用户自己的值；情境自己设的值不落盘；用户在情境里手动改的值照常保存，并更新记下的原值；关掉情境时恢复原值。测试见 `V3SceneLayerTests`。真窗口里核过，切了六个情境后 `v3.lyricStyle.v1` 没有变。
  - 「整套换装」（`v3.roomRestyles.v1`，默认开）可以只要情境、不换版式。
  - 控件：`V3ControlBarSurface` 和 `V3PlaybackSurface` 读取环境里的 `v3SceneChrome`，按情境调色和圆角。
  - 行宽：新增 `v3.lyricWidth.v1`，可选标准 1、宽 1.35、满幅 1.9，在文字面板设置；情境可以带自己的行宽。它同时放大 680 pt 的行宽上限和各版式 760/840/940 的上限。行在排版时读取静态的 `V3LyricWidth.scale`，所以在 lyricsColumn 里先赋值，并用 `.id(lyricWidthScale)` 让行宽变化时重建。
  - 封面交融：玻璃层在前景封面处开一个柔边的洞，只留 25% 的效果；背景层的色调都混入封面色（`v3Mixed`）；封面本身带一点情境的痕迹（雪夜四角结霜、雨夜水光、水面光纹、夜车掠过的反光、极光的彩边、星座压暗），见 `V3CoverBlend`。
  - 起雾的窗：清晰区改成覆盖整个窗口的渐变，雾的白度减半，不再出现一个椭圆形的洞。
- **情境改用 GPU 着色器（2026-11-18，用户授权按需装工具）。** 实测播放中稳定后的 CPU：不开情境约 61%，Canvas 雨滴 64%，水面 57%；GPU 版雨滴 61%，水面 58%。所以换着色器不是为了性能，而是为了效果：真实的水珠物理（Heartfelt 式滑落和水痕，每颗按表面法线折射封面），以及每帧实时计算、会被水波推动的光纹。
  - 文件：`SpotifyLyrics/Views/MainWindow/V3SceneShaders.metal`。只用生成型的 `colorEffect`，把封面作为 `.image` 参数传入。不对画面用 `layerEffect`：主窗口的歌词行（`TimedLyricHighlightView`）、视频背景（`V3CanvasVideoView`）、`V3AtmosphereFieldView` 和窗口可见性探针都是 AppKit 视图，栅格化后会消失或失效。
  - 工具链：Xcode 26 需要另外执行 `xcodebuild -downloadComponent MetalToolchain`（本机已装 17F109）。CI 在原生构建前加了一步：缺编译器才下载。离屏宿主走同一个工程，会一起编出 `default.metallib`。
  - Canvas 版的 `V3RainBeads` 和光纹贴图已删，`V3WaterLight` 只保留取色。
- **换包前不要紧接在测试后复制 App。** `test-native.sh` 会把 SpotifyLyricsTests.xctest 放进 App 的 PlugIns 目录，签名校验因此失败。应先删掉产物，单独重新构建，校验通过后再复制。

2026-11-19：V3 听歌区安装一个 `V3WindowVisibilityProbe`，主窗和全屏各自读 AppKit 可见区域。旧实现各自跟踪 Canvas、天气粒子和频谱，WebKit 流动分支和情境玻璃绕过这层。现在情境、封面和播放样式都使用各自窗口的同一个可见状态。可见的雨雪仍可以在暂停时移动。书页的翻页与胶片亮光结束后撤下动画时钟。跟随天气只在至少一个可见窗口需要时查位置，关闭最后一个窗口时取消正在进行的请求。原生测试移出并恢复 AppKit 窗口，读到可见、不可见、再可见，相关测试 33 通过、1 项跳过；隔离真窗核对水面仍正常呈现。资源对照见 L-002。

## L-026 QQ 搜索主机失效（2026-11-13）

- **现象**：《サヨナラ》（stb）别的 App 有词，我们显示“已找到歌曲，暂无歌词正文”。日志里 QQ 每次都是 `outcome=http(500)`，网易云只有空目录命中。
- **原因**：`c.y.qq.com` 的 `client_search_cp` 对所有搜索都回 HTTP 500；`shc.y.qq.com` 同一路径正常，响应结构一样（Lyrimuse 也是先试 shc）。QQ 来源因此对所有歌都失效，不只这一首。
- **做法**：`searchBases` 按顺序试 shc、c，失败记一行 `QQ search host failed`。旧格式响应把多位歌手用 `;` 连成一个名字（`stb;NEA`），解析时拆开。
- **同一首歌的不同条目歌词不一样**：专辑版条目（ブルーリグレット）没有歌词（-1901 / 24001），单曲条目有。所以要逐个候选取词，不能只看第一条。
- **排查顺序**：先看日志里各来源的 `PROBE finish … outcome=`，再用 curl 复现那个接口，最后对照调研目录里别家的实现。

## L-027 播放中核对的结果与“听不到声音”（2026-11-13）

- **Spotify 自己的音量为 0 时，ScreenCaptureKit 采到的是全零**，日志是 `PULSE levels bassPeak=0.00 bpm=-`。VU 表、频谱、声纹圈都不动，这不是采集坏了。现在静音 3 秒后界面会提示（`V3MusicPulse.hearsSilence`）。排查律动“没反应”先看这行日志，再看 `osascript -e 'tell application "Spotify" to sound volume'`。
- **用户正在播放时可以直接核对播放中的效果**，不用改播放状态：用 defaults 临时打开效果，重启 App，`screencapture -l` 拍，再还原。选窗口要按面积最大选，用户钉着面板时第一个窗口是面板。
- **粒子层在 App 里坐标没有翻转**（日志 `WEATHER … flipped=false geometryFlipped=false`），雨、雪都从上往下。浅色背景上雨丝很淡，是对比度问题。
- **雾窗样式**复用 `V3TypewriterReveal`（`fingertip: true`）：更宽的软边，加一条四周渐隐的水痕；其他行用比景深更重的模糊。

## L-028 方案池第四批的做法（2026-11-13）

- **推荐的三批做完后，方案池里还有几十条没排进批次的小项**（A、C、E、F、G、H、I、J 各组都有）。用户说“继续”时，从这些里挑量小、风险低的做，不必再等下载或调音量的授权。
- **背景的附加效果包在 `V3BackdropAmbience` 修饰器里**，指针位置的状态留在修饰器内部，鼠标移动时不会重算背景视图。两个开关都关时结构不变（始终有一层 GeometryReader），切换不会重建背景、重载视频。
- **行级的显隐放在 `.animation(nil, value: isActive)` 之外**再叠一层 `.opacity` 和自己的动画，否则会被里面的“无动画”吞掉。
- **按句跳转用 `presentationTimeNow`**（歌词时间），跳转目标减去 `presentationOffset`，和单句循环一致；连按时靠“跳转保持”让时钟停在目标上，不会跳回。

## L-029 第五批的做法与坑（2026-11-13）

- **`@MainActor` 写在类声明上一行**，往它和类之间插入别的类型会让类失去主线程隔离，报一串 “main actor-isolated … from a nonisolated context”。新类型插在 `@MainActor` 之前。
- **设置页的停靠**由持有歌词窗口的 `WindowManager.dockFloatingLyrics` 处理。2026-11-18 替换了只对已开窗口生效的通知入口，现在关闭时点停靠也会显示并移到所选位置。
- **跟着低音的效果共用 `V3BassFollower`**：瞬时升、0.22 秒回落，数据过期（0.5 秒没更新）当作 0。视图用 `TimelineView` 每秒 30 次读一次，状态放在一个不发布变化的盒子里。
- **封面呼吸挂在 `v3ReportsForegroundCover` 里**，所有前景封面都有；上报的封面位置仍是静止时的。
- **显示层不能改歌词行的长度**：逐字时间、注音、译文对齐都按字符位置。星号还原因为长度不变才安全；隐藏括号内容（I10）因此没做。
- **“只有署名”的假歌词**在来源里拦（网易云、QQ），不进匹配打分。

## L-030 金句与整句亮（2026-11-13）

- **新的用户数据不进正式数据库**：金句存在 `Application Support/SpotifyLyrics/favorite-lines.json`，不需要迁移。`V3FavoriteLines(fileURL:)` 可以指到临时目录做测试，测试不碰正式目录。
- **整句亮只在显示层去掉逐字时间**（`LyricLine.withoutWordTiming`，在行视图的入口处），不改保存的歌词，也不改行的文字和长度。
- **设置搜索是按页匹配关键词**（`SettingsCategory.searchTerms`）。加了新设置要把名字补进对应页的关键词，否则搜不到。

## L-031 换气、人声包络、全屏选屏（2026-11-13）

- **换气复用间奏三点的窗口**（`LyricsTimeline.vocalCountdownWindow`，空隙 4 秒以上）。只有窗口指向的那一行包一层 `TimelineView`，其他行不受影响。
- **律动光的三个来源按顺序用**：Spotify 的节拍表、听到的低音、当前句逐字的起点。第三个由窗口在换行时写进 `V3VocalOnsets.current`，光层自己读，不经过背景视图的参数。
- **判断“没听到声音”用 `silentSeconds`**，不是数据是否新鲜：Spotify 音量为 0 时采集仍在送全零的数据。
- **全屏歌词选屏**是纯函数 `targetIndex(home:count:prefersOther:)`；11 月 13 日现场只有一块屏。

- 2026-11-18 系统列出两块屏幕。用未显示的 AppKit 窗口跨两个实际显示区域，验证了灵动岛跟随主窗口、固定屏幕优先、指定屏缺席时回退并保留选择。另外复现并修好关闭窗口恢复后桌面歌词仍被旧屏幕编号挪走。桌面歌词外观可把窗口移到指定屏幕，按可用区域保留相对位置；灵动岛的固定选择单用显示器 UUID，旧屏幕编号继续用于恢复布局。这些检查没有拔插显示器或制造真实全屏切换。

- 全屏歌词复用听歌区时，听歌快捷键会先接收 Esc。全屏和普通听歌区共用 `handleExitCommand`，先收起已打开的临时控件，全屏无临时控件时退出。全屏切换期间收到退出请求先记下，委托回调结束后再继续原生切换或收窗。隔离宿主用真实全屏窗口检查键盘和退出路径，确认窗口已从屏幕移除，避免只查 `showFullScreen`。

- 全屏的工具面板使用同一套控件，固定后直接显示在全屏窗口内。「窗外」工具栏在全屏用窗口内的标准布局，离开全屏恢复普通窗口自身的布局。全屏「更多」里的「退出」和 Esc 最终都走 `hideFullScreen()`。

## L-032 和声、流动、动音量前先看状态（2026-11-15）

- **加一个可选数据先看有没有 JSON 列**：和声存在逐字时间的 JSON（`spans_payload`）里，`LineTimingPayload.backgroundText` 可选，没有时不写进 JSON，所以旧数据的去重比较和旧版本读取都不变，不用升数据库版本。
  - 2026-11-18 修订。加载和编辑统一用 `DocumentTimingPayload.decodeRows` 一次读出整条时间轴，可沿用同一份已校验的行和和声。先前加载每一行都会重读整首 JSON，手工调整一个词头或打开编辑器还会丢失和声。旧 `decode` 的元组接口仍然可用。
  - 不要为了存和声写出“有行但 spans 为空”的条目：`decode` 遇到空 spans 会让整份逐字时间作废。
  - 无逐字的对唱、和声也属于原稿。v14 在原词行增加可空的演唱者和和声字段，旧哈希和选中稿继续有效。有逐字时先取所选时间轴标的声部，缺项从原词行补。此前版本丢失的无逐字声部可以通过重新存入字节相同的源文件补回。
  - **AMLL 把和声的译文、罗马音嵌在 `x-bg` 里面**（真实文件 One Last Kiss）。解析时和声里的 `x-translation` / `x-roman` 子 span 不算和声文字；只用手写的简单样例测不出来，要拿真实文件试。
  - 2026-11-18。行内注释与 Apple 头部的译文、转写均按原句保留。头部仅按 `for` 和 `itunes:key` 的完全匹配挂回主唱。多语译文先匹配应用目标语及文字系统，否则显示文件已有的一种。解析结果保留文件语言、元数据、和声与逐字；无时间文件按原序阅读，部分计时只给确有时间的行。旧库、锁定版本和用户译文选择沿用既有规则。[AMLL TTML 规范](https://github.com/amll-dev/amll-ttml-db/blob/main/instructions/ttml-specification-en.md)
- **流动用 WKWebView 跑 butterchurn**：声音由 App 每秒 30 次把 1024 个采样（`Levels.waveform`）以 base64 送进页面，页面不用麦克风也不联网（CSP `default-src 'none'`）。`render({audioLevels})` 接受外部采样。
  - 预设的公式要 `unsafe-eval`；网页视图 `hitTest` 返回 nil、滚轮转给下一个响应者，才不会挡住歌词的滚动和点击。
  - 资源以文件夹引用加进工程（`lastKnownFileType = folder`），整个 `Butterchurn` 目录原样进包。
  - 启动日志有一行 `FLOW page ready`；不是 ready 就是 WebGL 或脚本出错，后面跟错误文字。
- **动 Spotify 音量前当场读一次状态**：这次第二回验证时沿用了一小时前“播放中、音量 0”的印象，实际用户已改成暂停、音量 84，结果被调成 0，随后改回。每次调之前读状态和音量，记下原值，结束时恢复到原值而不是固定值；暂停时不调。

## L-033 改了 `some View` 的实际类型后，离屏图崩在 `initializeWithCopy`（2026-11-15）

- **现象**：把 `toolbarStyleControls` 从一个控件改成 `VStack` 后，更多面板的离屏渲染崩溃，栈顶是 `initializeWithCopy for HelpView`，在 `toolbarPanel(for:)` 里。
- **原因**：增量编译没有重编使用这个属性的另一个文件，它还按旧类型的内存布局复制。
- **做法**：`touch` 使用方的文件（这次是 `Views/MainWindow/*.swift`）再构建。看到这种栈先怀疑旧产物，不要先改代码。

## L-034 重读来源统计：先用现在的代码重查，再谈改匹配（2026-11-15）

- **统计里的「没找到」会过期**：`source-stats.jsonl` 只记每次查找当时的结果。很多歌最后一次查找早于后来的修正，之后没再播。判断要不要改匹配前，先用当前代码把这些歌在线重查一遍。
  - 做法：临时在测试文件里加一个 `TemporaryLiveSourceProbe`，用 `LyricsSearchManager` 和各来源直接 `search`，打印结果和 `LyricsSafeMatcher.decide` 的理由。只查不存，不碰正式数据库；跑完还原文件，不提交。
  - 歌名、时长从 `listening_history_sessions` 取（正式库先复制只读副本）。统计和历史里的 Spotify ID 是小写，嵌入页解析器用不了，所以探针缺「Spotify 认证歌手」这条证据，结果比 App 里略保守。
- **新规则都要同时满足「歌名一致 + 时长差 ≤2 秒」**，并且最高只到较低的自动档。歌手在署名里但不在第一位、歌名只差制作人标注、`X from Y`、罗马字 `oh` 长音。
- **改了匹配后，旧测试里拿真实歌当「需要核对」样本的会变**（这次是「活着」）。改样本让它仍是核对结果，不要放宽规则去迁就测试。

## L-035 来源排序：故障成片出现，让坏掉的来源先休息（2026-11-15）

- **读统计的结论**（`source-stats.jsonl`，10-24 至 11-15，598 次查找）：默认顺序本身是对的。首个命中的来源依次是 LRCLIB 214、网易 85、QQ 47、AMLL 24；酷狗、酷我、LinkCore、プチリリ、lyrics.ovh 从没给过直接命中，只给候选。按命中率重排换不来时间。
- **时间主要耗在两处**。
  - 一是故障成片：LRCLIB 在 10-30 连报 503 共 50 次；lyrics.ovh 在 11-12、11-13 超时约 90 次，且几乎都紧跟在上一次失败之后；QQ、LinkCore 也有短的连串。
  - 二是找不到时要换写法重查：每种写法一轮，一轮约 3–6 秒。
- **超时不用调**：按「有用结果多晚到」看，酷狗和プチリリ的有效结果恰恰是慢的那批（酷狗 >3 秒的 156 次里有 128 次有用），一刀切会丢歌词。并发从 3 提到 6 的模拟只把中位轮次从 2.8 秒降到 2.4 秒，却会给非官方接口加压，没做。
- **做法**：新增 `LyricsSourceHealth`。
  - 同一来源连续两次超时、断网、限流或 5xx，就休息 15 分钟。
  - 休息期间它被放进补充位：其他来源能采用时不再等它，什么都找不到时仍会问它，所以不丢结果。
  - 它任何一次正常回答（包括「没找到」「解析失败」）都立刻结束休息；取消不算数。
  - 现在播放、预览、预载、补全四处共用 `.shared`；启动时回放统计文件最后 15 分钟（跳过 0 秒的复用记录），重启后仍记得正在出的故障。测试各用新实例，互不影响。日志里有 `SEARCH resting`。
- **覆盖**：`LyricsSourceHealthTests` 4 项（连续失败与恢复、只算真故障、从统计文件恢复、休息中的来源不被等待但最后仍会被问）。完整原生 200 项：第一次跑出 1 个失败，没能定位是哪项；之后连续 4 次全部通过（1 跳过）。改动后在真实 App 里看过一次正常找词，但没有遇到真实故障，休息这一路只有单元测试证据。

## L-036 外来语歌名与毫秒级同长（2026-11-15）

- **用户报告**：Timeless (feat. mahiru)／TakaseToya 只有 LRCLIB 纯文本，别的 App 有时间轴。网易其实有「タイムレス (feat. 茉ひる)」／高瀬統也, 茉ひる，时长 174.892 秒，与 Spotify 一模一样，却因 `titleMismatch` 和 `featuredArtistOnly` 被拒。
- **人名读音靠不住**：MeCab 把「統也」读成 みつる＋未知字。人名的训读本来就猜不准，不要指望靠读音去对汉字人名和罗马字人名。
  - 这次顺带让 `artistsHaveSameReading` 能对上「连写 vs 分写」（TakaseToya / Takase Toya），但这首歌靠的不是它。
- **新规则**：
  - `titleLoanwordReading`：英文歌名对片假名歌名，用 `loanwordKey` 比较：只留辅音；l/r、v/b、m/n、th/s 合并；英文里写成长音的 r、w 去掉；至少 3 个辅音。这个比较很宽，单靠它最多只到「候选」。要自动采用，还得同一歌手（或下一条）、时长 ≤2 秒、无版本冲突，而且最多只到较低的自动档。
  - `durationExact`（≤0.05 秒）＋客串歌手在署名里＋歌名一致或外来语一致 → `featuredArtistExactLength`，进较低的自动档。同长到毫秒，说明两家用的是同一份母带。伴奏版常常也同长，但带版本词，会被版本冲突挡住。
- **已存纯文本会自己升级**：自动采用的纯文本（非用户锁定）再次加载时会再搜一次带时间轴的版本；带时间轴的排在纯文本前面（`bestAutomaticAdoption` 先比 timingPriority）。所以修完规则后，重启 App 或下次播放就会换掉，不用动数据库。实测重启后 2.2 秒换成网易逐行版。
- **全曲库重查（同日，正式库只读副本，245 首）**：110 首只有纯文本、136 首没词。用当前代码在线重查，62 首纯文本能换成带时间轴的版本，69 首没词的能找到（60 首带时间轴）。它们只差「再查一次」：自动采用的纯文本只在再次播放时才会升级，而「全部补全」只看一条版本都没有的歌。现在「缺歌词」把只有纯文本、且不是用户写的或锁定的歌也算进去（`PersonalLyricsLibraryEntry.hasSyncedLyrics`），点一次「全部补全」就会走正常的升级流程。
- **同轮补的三条**：
  - 歌名相同、时长到毫秒一致、歌手一边是罗马字一边是汉字或假名（Stay with me：TakaseToya／高瀬統也）→ `primaryArtistOtherScriptExactLength`。
  - 读音比较先去掉标点（Riria.／りりあ。）。
  - 罗马字歌名省略长音也算同读（resukyumi-!／れすきゅみー！）。
- **毫秒级同长只认带毫秒的时长**：酷狗等来源只给整秒。184.0 秒对 184.03 秒只是凑巧；翻唱常用原伴奏，长度几乎一样。`durationExact` 和 `primaryArtistOtherScriptExactLength` 都要求候选时长不是整数秒。
- **不做的**：翻译过的歌名（Starry Sea／星降る海）无法和「同一歌手、时长相近的另一首歌」区分开（L-037 只放行了毫秒级同长的情况）。重查里就有「星街の駅で」对上「零-zero-」、「不够」对上「千度雪寻」，所以这类继续留给核对。
- **来源时有时无**：网易上同一首「Stay with me」，一次返回、一次「没找到」。不要只凭一次查询就断定某个来源没有。
- **偶发失败**：`FloatingLyricsPresentationTests` 拿真实 NSCache 验证「换回原键能取回旧值」，但 NSCache 随时可能清掉内容，所以偶尔失败。L-035 那次没定位到的失败就是它。已改成直接比较缓存键的相等与哈希。

## L-037 核对页里证据已够的歌（2026-11-15）

- **方法**：上一轮在线重查后，仍有 125 首没自动选上（核对页 12、纯文本 45、没找到的约 60）。再用当前代码在线逐个列出未被自动采用的候选和原因。这次没有写正式库，临时探针用完已删。
- **放行的四类**（都最多只到较低的自动档）：
  - **来源多列了合作署名**：歌名靠读音或外来语对上（君と会う夜／kimitoauyoru、ディスタンス／Distance），歌手一致、时长 ≤2 秒，就算同一首。歌名完全一致时原本就这样处理。
  - **客串用双名**：`nayuta (葉月なの)` 用括号里外任一个名字都能对上标题里的 feat.。
  - **(Explicit)**：只是内容标记，比较歌名时忽略。(Clean) 是另剪的版本，不忽略。
  - **翻译歌名＋同一份母带**（`promoteSameMaster`）：同一歌手（一致或读音一致），时长差 ≤0.1 秒且候选时长带毫秒，版本标记相同，带时间轴且最后一句落在歌曲之内，就采用，即使歌名被翻译过。
    - 例子：もう一度 (Sped Up Ver.)／Again - Sped Up Ver.，the NOISE 括号里被采样的歌名被翻译。
    - 毫秒容差从 0.05 放宽到 0.1（`sameMasterTolerance`）：月詠み「メデ」在网易是 202.988 秒，Spotify 是 202.933 秒。另名写法规则（`primaryArtistOtherScriptExactLength`）同时接受来源自己声明的歌名别名，所以 春めくことば／Spring Words、メデ／Mayday 都能对上。
- **伴奏**：同一份母带的伴奏版长度一模一样。「伴奏、纯音乐、純音楽、オフボーカル」此前没有被标成伴奏，现已补上，「カラオケ」也标成卡拉 OK。带这些标记的候选永远不会因为同长被放行。
- **仍留给核对或不采用的**：
  - 整秒时长：不够／千度雪寻（200.0 秒）。
  - 时长差几秒的翻唱或 Live（VITA 演唱会版）。
  - 弾き語り 版（时长差 0.36 秒，算不上同一份母带）。
  - 同名不同歌手：网易用「Mayday」搜到五月天「如果我们不曾相遇」（202.388 秒），被拒。
- **实测**：用真实搜索流程，Distance、君と会う夜、oracle (Mwk Remix) 从核对或没词变成自动选中带时间轴的版本。网易单查时 春めくことば、メデ 判为自动采用，但连查第二次全部返回「没找到」，那次搜索只拿到 LRCLIB 纯文本。之后再次加载时会自动升级（L-036）。
- **网易限流**：短时间连续查询后，网易返回 noMatch 而不是错误，来源健康记录（L-035）把它当正常回答。要改得先有统计证据，不要凭一次现象去改。

## L-038 复查漏选（2026-11-15）

2026-11-18 的查询合同补上繁简转换的真实依赖。歌名排版规则可以折叠分隔短横和空格，词内像 Re-cover 的连字符会保留。版本后缀与短时差不足以覆盖缺少合作歌手的证据。保留后来认可的两种用法，完整标题和毫秒级时长可交叉确认客串署名，只按标题查时也可用实际返回的歌手和时长确认。独立查询合同同时覆盖确认与证据不足的输入。

- **方法**：用户要求「再测试确定不会漏」。先对 245 首用真实搜索流程逐首重查，每次只并发 2 首、每批间隔 1.5 秒；第一遍没选上的歌隔 90 秒再查第二遍。再对结果变差的和仍在核对的 75 首一首一首查，每首间隔 3 秒，并列出每首的全部候选和原因。
- **最大的漏洞：已存纯文本升级不了**
  - 一次搜索里，只要有来源给出能用的纯文本，就只再等 3 秒，没回答的来源全部取消。
  - 酷狗在实际顺序里排第 8，常常还没轮到就被取消。
  - 已存纯文本的歌每次加载都会「再查时间轴」，但再查也只等 3 秒，所以永远落回同一份纯文本。19 首里有 7 首卡在这里（アンコール、夜に駆ける 等）。
  - 修法：会话发现手上只有纯文本时，传 `plainAlreadyHeld`，这次搜索不因为又拿到纯文本就提前收工，要等所有主来源回答（`waitsForTiming`）。用户此时已经看到纯文本，多等不影响听歌。
  - 实测：19 首里 16 首升级为带时间轴的版本，靠酷狗的约 5 秒，其余不到 1.5 秒。剩下 3 首各来源都没有时间轴。
- **只按歌名搜到的结果**（`titleOnlyLoose`）以前最多只到「候选」。现在歌名完全一致（或同排版、双语对）、歌手一致（或读音一致、换了文字写法且毫秒同长）、时长差 2 秒内、没有版本冲突，就到较低的自动档（`looseQueryConfirmed`）。
  - 例子：just saying, the body is honest.／shikiura sougo，Kiddy／ロクデナシ。
- **双语歌名**（`titleBilingualPair`）：「愛℃ - Love°C」「最低な君 - You were worst」这类，一半是日文或中文、一半是拉丁字母，其中一半与 Spotify 歌名相同。两半都不能带版本词，所以「曲 - Live」不算。歌手一致、时长差 2 秒内，最多到较低的自动档。
- **发行方页面**（`publisherPageExact`）：LinkCore／TuneCore 页面上的纯文本，歌名和歌手完全一致、没有版本冲突时自动采用（例：Kuzuyan）。它在补充来源里，只在别的来源都没结果时才会被问到。
- **同一母带**（L-037）不再要求最后一句落在曲末附近，只要求不超出曲末、至少两行有字。例：822／0822 橙汁，时长都是 182.405 秒，歌词结尾较早。
- **刻意不放行**：
  - lyrics.ovh：只按搜索词返回一段正文，没有歌名、歌手、时长可以核对。
  - 时长差得远的版本：GIJIKOI 217 秒（韩语版）对 234.7 秒（原版），确是两首录音。（更正，见 L-039：这里原先还列了 shion 168 对 150.8、幽霊になって 267 对 240，那是用了幽灵记录的错误时长，按真实时长两首都对得上。）
  - 酷狗整秒且差 6 秒的 ノイズキャンセル。
- **来源时有时无**：
  - 网易短时间连查后会回答「没找到」。
  - 酷狗今天对 ハロ、晴る 也回答「没找到」，前一天却有。
  - LRCLIB 同一首歌有时给纯文本条目、有时给带时间轴的条目。
  - 所以批量重查必须放慢，单次没找到不能算漏选，要看第二遍。

## L-039 幽灵记录：同一首歌的重复行（2026-11-15）

- **用户指出**：shion 这类歌「时长其实一样，只是显示不一样」。
- **查证**：在正式库只读副本上查，同一首歌有多条 tracks 记录，stable_key 里带的时长不同，都没有 redirect。
  - shion（`spotify-id:0t5ddnfp…`）：一条 150.8 秒、无歌词，另一条是 Spotify 目录给的 168.0 秒，有带时间轴歌词。
  - 幽霊になって、WAITING AT 3AM：各有一条 240.0 秒的记录，共用另一首歌的 ID `5o45jo…`，封面也相同，是切歌瞬间读到的错数据。真实时长分别是 267.923 秒和 171.44 秒，都已有歌词。
  - 全库「缺歌词」243 条：21 条同 ID 的另一行已有歌词；11 条的 ID 被不同歌名共用。
- **影响**：
  - 「缺歌词」把这些行列出来。「全部补全」用错的时长去搜，结果搜不到或进核对。
  - L-038 的在线重查也用了这些错时长，误把 shion、幽霊になって 判为「时长差很远」。按真实时长，QQ 的 shion 168 秒、幽霊になって 267 秒都对得上。App 里有 Spotify ID 时用的是目录时长（见 `testShionSingleQQMatchUsesCatalogDurationRatherThanProviderConfidence`）。
- **修法**：只读，不写库，不迁移。`PersonalLyricsLibraryEntry.markingRowsCoveredElsewhere` 给被别的行覆盖的记录标上 `coveredByAnotherRecording`；`needsLyrics` 和两个界面的 `.missing` 筛选都跳过这类行。这些行仍留在歌词库里。
  - **同一个 Spotify ID**：另一行有歌词就算覆盖；如果这行已有纯文本，要求另一行有带时间轴的歌词。
  - **ID 被不同歌名共用**：ID 不可信，改看同歌名同歌手的另一行有没有歌词。
  - **ID 不同的同名录音不算覆盖**：GIJIKOI 原版（234.659 秒）与韩语版（216.875 秒）不能互相覆盖，没有 ID 的行也不按歌名合并。
- **教训**：用库里的时长做在线重查前，先确认那一行不是幽灵记录：查同 ID、同歌名的其他行。Spotify 目录时长才是准的。
- **批量补词接续（2026-11-19）**：主窗口和独立歌词库观察同一个 `PlaybackState.lyricsBatch`，切换窗口时继续，明确停止后保留已完成结果。保存状态取自 SQLite 写入结果，区分同步、纯文本、待核对、无新增、无匹配和失败。隔离 macOS App 从主窗口开始，独立歌词库接到 1/3，最后显示 3/3 条已存同步歌词，从结果点进歌曲确认版本已采用。原生定向测试 29 通过、1 跳过，覆盖停止、重复启动和保存结果。
- **批量补词核对（2026-11-19）**：每首候选随本次结果留在内存里，关闭核对页后仍可回看。确认采用走原词手动采用事务，归属校验使用录音档案和候选身份，后来新增锁定稿时仍受保护。保存后所有打开的歌词库刷新，选中原录音的档案，原搜索和筛选保留。候选预览沿用实际可保存的正文及时间轴，录音速度不同只能存文字的候选不再显示可采用的时间。隔离主窗按「雨のあと」筛选并补词，独立歌词库从「需要核对」预览、采用、查看原档案，结果变为「已存同步歌词」。相关原生测试分次核对后 58 项通过，1 项跳过。
- **批量补词续查和重试（2026-11-19）**：同一 App 会话内，「继续未查」按原批次顺序查剩余歌曲，「仅重试失败」只处理来源或保存失败的歌曲。当前筛选不会改变本批次名单，已保存、未找到和待核对结果都能继续查看。隔离窗口实点两项操作，从 2/3 继续到 3/3，再将失败的一首补为已存同步歌词。定向原生测试 33 项通过，1 项环境跳过，覆盖原候选身份和结果顺序。


## L-040 歌名和歌手都对时总显示最佳候选（2026-11-15）

- **用户报告**：shion（angelize）停在「核对歌词版本」，原话：「别人的永远都有歌词，我们的总是会漏掉部分歌不会自己选」。唯一的候选是 QQ 的 shion／Angelize，有逐行时间轴，长 168 秒；Spotify 自己显示 2:30（150.8 秒），所以判为 `durationFar`，只能进核对页。
- **结论**：一条一条补匹配规则永远会漏。别的播放器的做法是把最像的那份歌词直接显示出来。
- **策略改动**（`LyricsSearchManager.bestAvailableFallback`）：自动搜索走完所有查询仍没有可直接采用的结果时，从「候选」档里挑出符合下面条件的版本自动采用，原因记为 `bestAvailableFallback`，日志写 `MANAGER AUTO_ADOPT best-available`。
  - 有歌名证据：完全一致、排版一致、并列形式、读音、外来语、双语对、别名等。不能是 `titleFuzzy`（只是包含歌名）。
  - 有歌手证据：一致、读音一致、别名、在署名里，或另一种文字写法且时长到毫秒一致。部分同名（`primaryArtistPartialName`，可能是同名的另一位歌手）和只对上客串都不算。
  - 不是其他版本：没有版本冲突，没有 Live、Remix、翻唱、伴奏等标记，也没有 hardReject。
  - 有真正的歌词文字。
  - 多个候选时的排序：带时间轴优先，其次最后一句不超出曲末，再其次时长最接近，最后看分数。
- **核对页只留给**：歌手不符或只部分同名；明确是其他版本；歌名只是包含；只有 lyrics.ovh 那种无法核对身份的纯文本；手动搜索（带查询词时不兜底，用户自己挑）。
- **测试**：
  - 原 shion 测试改为期望自动采用（没有目录时长时走兜底）。
  - 新增 `testBestAvailableMatchIsShownButAnotherSingerOrVersionIsNot`，覆盖三点：带时间轴优先于纯文本、时长更接近者优先；另一位歌手、Live、只是包含歌名的标题都不会被自动采用。
  - 三个原本依赖「核对」结果的测试（预加载、来源重试、同一来源重复歌词），把候选歌名改成只是包含原歌名，测试本身要验证的行为不变。
- **同一首歌读不到已存歌词**（ラヴイットベイビー，同日）：这首歌用的是同一个 Spotify ID，但 Spotify 有时报「はてなぷれいりすと, Nqsi／166.168 秒」，有时报「はてなぷれいりすと／141.29 秒」。stable key 里含歌手和时长，所以这两种报法对应两条 key。
  - 10-26 先按 141 秒写下了一条没有 ID 列的空记录，后来网易的带时间轴歌词存在了 166 秒那条 key 下。
  - 同 ID 归并（`redirectNewSpotifyKey`）只在新 key 还没有记录、而旧记录带 ID 列时才生效，这里两个条件都不满足。所以 11-15 再报 141 秒时读不到，只能重新搜索，又因为时长不符被判为「身份待确认」。
  - 修法（`adoptedSameSpotifyTrackStableKey`，只读）：读取时本 key 没有可用版本，就去找同一 Spotify ID 前缀下、歌名规范化后相同、按正常读取规则有可用版本（已采用、锁定或高可信，且未撤销）的记录，直接用它的歌词。歌名不同的不沿用，因为切歌瞬间读到的 ID 可能属于上一首（L-039）。
  - 验证：正式库只读副本上，修复前读不到，修复后读到网易 40 行。新增测试 `testSameSpotifyTrackReadsItsSavedLyricsWhateverLengthThePlayerReports` 按真实库的状态造数据，不加修复时失败。
  - 后续：已有的 `redirectNewSpotifyKey` 归并时不看歌名，借来的 ID 可能被错并。这次没有改它。
- **2026-11-18 补上新别名的歌名校验。** 首次读到不同标题却带上一首 ID 的录音时，原实现会立即创建跨歌重定向，连这条录音后来出现物理记录也会继续读错词。新别名用现有 stableKey 中的规范歌名对照候选和最终档案；同名的歌手、时长更新仍可读取同一档案。已存重定向继续走原解析。两个连接同时提交同一条重定向时只留下首次写入和对应审计行。临时库复现并核了旧条目、已有原词、不同标题和同名元数据变化。
- **2026-11-19 已收到的译文可随录音的显示语言变化完成保存。** 版本 UUID、原词哈希、完整行与请求代次已核对时，同一 Spotify ID 的结果写回明确的原词版本，无需建立跨歌名重定向。仍以候选稿存入，采用独立决定。既有译文接收契约先复现失败，再核对日文标题切成英文后原词和请求账本仍对应。

## L-041 逐字优先与行切换准时（2026-11-15）

- **用户报告**：同一首 Lost My Mind (feat. nakotanmaru) / PIKASONIC，Lyrimuse 有逐字高亮，我们只有逐行，而且行切换比别人慢一点。
- **逐字的原因有两层**：
  - 库里存的是 10-26 的 QQ 逐行版本（`qq:003oOucp2MpXLz`，没有 `lyrics_timing_versions`），当时还不读 QRC。加载命中已存版本后不再搜索，所以永远停在逐行。直接请求 QQ `GetPlayLyricInfo`，这首歌有 QRC；网易这首没有 yrc（`/api/song/lyric` 与 `/v1` 都只回 lrc，别的歌会回 yrc，接口本身没问题）。
  - 首次搜索时，`probeNetworkProviders` 只要有一个带时间轴的结果（逐行也算）且排在前面的来源都返回了，就立刻收工，后面可能有逐字的来源被取消。
  - 正式库只读副本里，首选同步版本中只有约六分之一带逐字（LRCLIB 144 条全是逐行，网易 225 条里 27 条逐字）。
  - **第三层，也是 Lost My Mind 选不到 QQ 逐字的直接原因**：QRC、KRC、YRC 每行的 `[开始,时长]` 是单独取整的，最后一个字可能比行尾晚几毫秒（「また世界の底に」行尾 31.395，末字到 31.396）。`hasValidTimedSpans` 要求每个字都在行内，只要有一行不合格，整首就按逐行排序，于是与 LRCLIB 逐行比分数时落败。现在三个解析器都让行覆盖它的字（`TimedLineBounds.covering`）。这个函数只用于排序，画面上的逐字渲染原本不受影响。修正后用真实网络实测：Lost My Mind 首次搜索和「已存逐行再查」都选中 QQ 逐字（36 行）；アイドル 从 LRCLIB 逐行变为酷狗逐字。
- **改动**：
  - 搜索：有逐字结果才立即收工；只有逐行时显示临时版本，再给 3 秒宽限等逐字来源（和纯文本宽限同一个计时）。新参数 `lineTimingHeld`：已存逐行时只有逐字能结束这一轮，不问纯文本补充源。
  - 加载：已存在线逐行版本先显示，再由 `scheduleWordTimingUpgrade` 在后台找逐字。每个已存版本一次启动只完成一轮，批量会话跳过。刚搜完的版本复用搜索结果，只从缓存读过的队列歌曲在真正打开时仍可升级。
  - 2026-11-18 修正：此前把新来源设为首选，原译文仍在库里，当前歌曲却读不到。现由 `LyricsWordTimingUpgrade.addingTiming` 对齐两份歌词。至少八成原句能在一秒内对上同文，且至少一半原句能挂上有效逐字，才由 `attachWordTiming` 把时间、演唱者和和声作为时间轴子版本存到原词下。原词版本、内容指纹、文字、行起止与当前画面的行 ID 延续，已有译文、读音和歌词偏移可继续使用。写入时在同一 SQLite 事务检查当前采用、锁定和已有时间轴；手工、本地、排轴及 ASR 原词继续跳过。临时 SQLite 实测了逐字出现后仍能读到原先的锁定译文。
  - 同日实机比较《Pancake》和《風のたより》，两首本机原稿只有逐行，酷狗已有真实逐词。来源有拆行、合行和不同的衬词，按整行找同文会错过。整行方案不够时，按顺序把连续的有效字词对回已存的完整原句，首词最多差一秒，至少三分之二的已存行能接上才保存；没对上的行继续用逐行。正式库只读取样后在隔离 SQLite 走真实提供方和正常会话，分别挂上 26/35、34/44 行，截图里对比的句子均接上，读回同一个原词版本和文字。保护手工稿、锁定译文及行身份的检查也通过。
- **行切换慢的原因**（`[LINE_INDEX]` 日志，Lost My Mind 与 Shigoto yameta）：
  - 歌词源时间戳没有系统性偏差：QQ LRC 与网易 LRC 同句起点差在 ±0.45 秒内来回，平均约 +5 ms。
  - 读 Spotify 位置已按往返时间的一半补偿（上限 0.15 秒），不是主要原因。
  - 主要原因是行边界定时器。`Task.sleep(nanoseconds:)` 走 `dispatch_after`，系统允许把唤醒推迟最多延时的十分之一，3–7 秒的行间隔实测晚了 31–214 ms。改成 `Task.sleep(until:tolerance: .milliseconds(2), clock: .continuous)`，并在计算延时的同时定下截止时刻。之后实测晚 0.5–9 ms（日志 `BOUNDARY_WAKE late=`）。
  - 索引切换后，SwiftUI 还要 45–85 ms 才开始跟随滚动，而 0.40 秒的弹簧约 0.1 秒才走到一半。所以加了全局提前量 `PlaybackState.lineSwitchLead = 0.15` 秒，只作用于当前行索引；逐字填充仍按原时间戳。改后滚动在时间戳前约 85 ms 开始。日志里 `lead=` 字段显示提前量，`PRESENTATION_CLOCK_CROSS_TIME` 已含提前量。
- **测试**：`ProviderFailureContractTests` 新增四项：逐行先到时仍采用稍后的逐字；已存逐行时越过宽限等逐字；升级只接受同文字同时间线，且不动手工版本；QRC 行覆盖末字后仍算逐字。全量 220 项通过，1 项按原样跳过。
- **注意**：其他会话执行 `pkill -x SpotifyLyrics` 时，正在跑的测试宿主（同名进程）也会被杀掉，报 `Restarting after unexpected exit`，失败的用例是随机的。这种情况单独重跑即可。

## L-042 我的风格 v3：按定稿与 AI 稿逐行对照修订（2026-11-15）

- **依据**：库里 22 份 AI 译文都由 full-audit-v2-r1 生成，没有一份被用户在 App 里改过，所以没有「AI 稿 → 用户改稿」的数据。改用重合的三首对照：AI 稿对照 Vault「音乐与翻译/曲目」里的用户定稿，即 雪庇（逐句确认稿）、アーカイブ（共同打磨稿）、アオイハル（用户主导）。这次没有发新的翻译请求。
- **AI 稿大多没译错，差别稳定在五处**：
  1. 照日文断点切出半截短语。用户会把同一句话的词在相邻行之间挪动，让每一行中文都通顺。v2 的「尽量让每行保有原行承担的意义」和 Codex 合同的「never move meaning across lines」把 AI 卡死了。
  2. 主语、受话人省得太多。用户需要时就说「我」「你」。
  3. 缺少口语的分寸词，如「一点点」「还是」「都」。
  4. 压缩的说法被逐词搬运，例如「既読の速度で愛はかって」。
  5. 用了音译或字面词，例如 ミモザ 被译成「米莫萨」，用户用的是「银荆」。
- **v3 改动**：
  - 第 3、5、6 条补上以上要求。
  - 「逐行显示的结构约束」改为：同一句话的相邻行可以重新分配词语，每行必须有内容，不跨句，重复段分法一致。
  - 新增 8 组用户定稿示例，并注明只学取舍、不搬词句。
  - Codex 合同改为允许同一句话在相邻行之间重新分配。
  - 版本号改为 full-audit-v3-r1。预设 raw value 仍是 `translationPrompt.personalV2.v2`，用户设置不变。
- **范围**：已保存的 AI 译文不改，新的请求才用 v3（提示词哈希变了，旧稿仍可采用、可切回）。
- **实测（同日，用户同意，Codex gpt-6.1-sol / 高，各一次请求）**：
  - 雪庇、アーカイブ 用 v3-r1 重译后明显贴近用户定稿：
    - 说出了主语和对象（「如果我告诉你」「每次这样，我都会更讨厌自己一点」）；
    - 口语分寸到位（「还不都是因为你」「可真麻烦啊，我」）；
    - 「拿你已读消息的速度，衡量你有多爱我」「银荆」「其他女孩」都译对了。
  - 两个问题：
    1. 雪庇有 5 行就是提示词里的示例句，模型直接照抄了，所以示例歌不能用来评估。要评估得换不在示例里的歌。
    2. アーカイブ「ミモザみたいに揺れる / この気持ち全て / いっそ壊して咲き誇って」被整行往前平移，唱到某一行时显示的是下一行的意思。
  - 改为 v3-r2：明确挪动只修补被切断的短语、不得整行平移，并用这组的用户译法作正反例；示例句即使碰到同一首歌也要重新译。
- **第二次实测（同日，用户选 Codex gpt-6.1-terra / max，一次请求）**：
  - 歌曲用 nemüll《43h80min》：用户独立定稿，不在示例里。「嘘で殺して」不在歌词库，没有原文可用。
  - 结果：大部分行与用户定稿意思一致；「让我相信你说的『我睡着了』」比旧稿更到位。
  - 两处可推广的问题：
    1. 句末软化的「から」被译成悬空的「所以」。
    2. 「LINEしよう再度　Daphneの愛を」两个动作被并成一个，Daphne 也没译。
  - 改为 v3-r3：句末 から/けど/のに 按中文收住；拉丁字母写的花名、人名译成通行中文名（达芙妮）；一行里并列的短句分开译清。v3-r3 尚未实测。
  - 测试前 Codex app-server 的 account/read 连续两次返回 -32603，过了约一分钟就自己恢复了。登录本身正常；遇到时等一会儿重试即可，不要改认证逻辑。
- **用户反馈「差了好多」（同日，App 实际产出）**：
  - 歌曲：sakuma.《じたばた》，gpt-6.1-terra / ultra，提示词 v3-r3。推理只用了 422 个 token，几乎是逐行直译。
  - 与用户独立定稿对照，差距集中在没有还原整首歌的场景：
    - 「窓」没有译成车窗（人在末班电车上）；
    - 「指先踊る」没有落到在手机上打字（与「打っては消している」呼应）；
    - 「言葉躓いて 飲んで」把喝酒误解为「把话咽回去」，这是意思错误；
    - 「返事 成り行き」排成了词语清单；
    - 「それでも乗っている / 最終電車に乗っている」没有做跨行重组。
  - 改为 v3-r4：最前面加「先还原场景」一节，先通读整首弄清在哪、在做什么、对谁说，多义词与省略按这首歌自己的场景来定；仍禁止加歌里找不到依据的情节。加一组跨行示例，摘要里也补上这一条。v3-r4 尚未实测；以后用 じたばた 实测会被示例污染，要换别的歌。
- **按用户要求「先翻译完我有印象的歌」（同日，用户当前设置 gpt-6.1-terra / ultra，Codex 订阅）**：
  - 方法：从 Vault「音乐与翻译/曲目」解析出用户主导的 16 首定稿（原文与用户译文成对），先用 v3-r4 全部翻译、逐行对照。其中 じたばた、雪庇、アーカイブ、アオイハル 已有句子在示例里，会被污染。
  - v3-r4 的场景问题基本修好（车窗、打字、喝酒）。主要差距在语体：AI 对每首都用中性白话，用户按歌的口吻换说法。
    - 撒娇的歌：用户用「呐」「好不好」「根本」「早就」；AI 用「喂」，平铺直叙。
    - 许愿的歌：用户用「绝非虚言」「别无所求」「此心永恒」。
    - 句尾单挂的英文或名词：用户融进句意（「以流星为誓」「钻戒为证」）；AI 写成「流星啊」。
    - 反复出现的英文钩子（kill me baby、FAKE LOVER、Luv it）用户保留原文。
    - 随口的说法：用户用「无语」「酎嗨」。
    - 本身成句的行被拆去接下一行（「君はどこで覚えたんだい」）。
  - v3-r5：加「先定语体」一节，补钩子英文与句尾名词融入，禁止拆开已成句的行。示例只取 絶望luv、君と星空、涙なんか。
  - v3-r6：短句短译，能用现成说法（天各一方、重蹈覆辙、说明了一切）就不铺成长句。
  - 复测：r5 测 7 首留出歌，r6 测其中未进示例的 6 首（YOLO、紫菀、ラヴイットベイビー、色恋、tatoe、meaning of tears）。钩子保留、语气词、短句都明显改善（「伤上加伤」「我才不会哭呢」「没有我就不行，对吧」）。
  - 剩余差别多是用户个人的意译取舍（如「满溢而出的爱意」），不再泛化成规则。
  - 共约 29 次翻译请求。临时测试与语料文件已删，结果只记在这里。

- **2026-11-19 默认提示词缩短。** 以用户贴出的 45 行请求估算，同一份 JSON 的总请求从 8,506 字符降至约 3,100。固定版去掉重复规则和大段例句，保留全曲语境、语体、相邻行重组和逐行返回。自定义译风照原样发送。Codex 传输协议的行 ID 与校验沿用，已发请求仍使用相同日志键，精确关联的完整旧结果可继续作为候选。缩短后尚未付费评估译质。
- **同日模型目录与档位。** App 刷新日志走完 `initialize → account/read → model/list`，约 3 秒。本机 Codex CLI 0.169.1 的元数据探测也返回 10 个模型。原面板成功后列表相同时没有反馈。复用目录缓存时间显示读取结果，刷新中显示进度。GPT-6.2-Sol 设置和最近六次已记录翻译都是 `ultra`，此前界面只写「超高」。现在档位菜单显示原生档位名称，翻译中标发起时选择，预览展示该译文存储的模型和档位。Codex 每次请求仍按 `turn/start.effort` 指定档位。本轮只读目录和旧请求元数据，无模型调用。



## L-043 工作台与歌曲档案（2026-11-18）

工作台可以直接用已收藏的金句、上次打开的档案和本机搜索。歌曲、歌词、译文走歌词库既有的搜索缓存；设置页与金句在各自已有的数据里匹配。工作台、独立歌词库和最近播放的封面墙都按歌曲 stableKey 打开，选中和预取仍走两条路径。

主窗口默认在没有实时录音和歌词预览时显示工作台，进入播放时跟随到已选的歌词布局。主动从窗口菜单、菜单栏或灵动岛打开工作台时，新的播放事件不把它换走。空闲时也可以主动进入歌词窗口调布局。工作台宽窗并排放档案和文件，窄窗在收藏下方放文件动作。完整歌词与外观入口回到对应布局。隔离真窗从空闲启动，经窗口菜单在两处往返，再从工作台打开查句、空白歌本和手稿。

入口一多，固定写成“返回高级与数据”会把人带错。设置历史保留搜索词和歌曲选择；重新输入搜索词只更新本次搜索。歌词库按发起请求的键接收详情，SQLite 返回的规范键可以与入口携带的旧键不同。档案确实不存在或暂时读不到时要结束加载态。上次打开的档案只在浏览成功时记入偏好，播放预取与后台刷新不占这个位置。

主窗「最近播放」里的列表和封面墙都在面板中用录音键打开完整档案。「返回最近播放」保留原列表和显示方式；点击「在新窗口打开」把当前录音交给独立歌词库。工作台的普通档案入口也采用同一份独立窗口选择，携带精确版本或段落的入口继续走原阅读路径。用隔离曲库实际点过列表、封面墙、弹出独立档案，及工作台回到上次打开的档案后读歌词。

2026-11-19：仅有播放记录、没有封面和歌词的旧歌也能打开空档案，歌曲资料按同一个历史录音键读取。浏览不写入歌曲表；从空档案明确存入文件或手稿时才建立原词记录。临时库从无封面的历史项打开、存锁定歌词，再通过同一播放录音键读回。

2026-11-19：收听统计按时间范围共用查询，每处窗口保留自己的选择；刷新请求与错误都对应所选范围。某个范围读取失败时可以继续看上一份结果及其时间标签，生成回顾卡只使用所选范围的结果。主窗、独立歌词库和设置的歌曲排行复用最近播放打开档案的录音键，返回统计时保留时间范围。

隔离原生主窗从「最近 7 天」的排行打开指定录音并返回，独立窗口仍单独选择「全部时间」。三项定向原生测试通过，覆盖两个范围同时查询、临时库读失败时保留旧结果及解锁后重试。

2026-11-19：主窗、独立歌词库和设置共用全部、当前歌曲、缺歌词、有译文、手动编辑、已锁定筛选。主窗关闭面板后保留自己的条件和所选行；「在新窗口打开」把搜索词、筛选和录音键一次交给独立窗口。两个窗口后续各改各的。`PersonalLyricsLibraryService` 取消已过时的防抖查询，列表只取与输入相符的已读结果。批量补词等当前查询完成后才能启动；已在运行的任务仍可在各处查看或停止。主窗浏览状态由面板观察，避免逐字输入触发听歌画面重绘。

隔离真窗从「缺歌词」搜索「雨のあと」，带着唯一结果和选中的歌曲弹出独立窗口。独立窗口清空后显示三首缺词，返回主窗仍只显示原来一首。28 项定向原生检查通过，覆盖连续搜索时旧结果不会进入新范围。

2026-11-19：歌词库搜索从 `searchLibraryPassages` 一次拿到歌曲和命中的版本，仍可按筛选查缺词歌曲。主窗面板、设置和独立歌词库共用档案顶部的「读命中句」，展示片段并用原查询打开相应原词、译文或读音。清空或重输时不沿用旧命中；仅歌名、歌手等资料匹配时照常打开档案。隔离真窗用「译文二 · 3」从主窗打开并返回，弹出独立歌词库继续读，再从设置打开同一句，三处均为该译稿 1/1。65 项定向原生检查通过，1 项环境跳过，覆盖命中旧译文、只按歌名命中及原采用稿保留。

外观按主窗口、桌面歌词、灵动岛和菜单栏四处切换，搜索和后退都能回到其中一处。可视地图只导航；显示开关和停靠按钮调用现有窗口控制器。改桌面歌词版本时曾把另一处尚在试看的灵动岛一起保存。现在 `apply(category:stableID:)` 只提交用户选中的位置，灵动岛也只在自己的呈现选择改变时收起。经典布局与实验工作台的文字和翻译入口在原处展开，沿用相同设置值。

2026-11-19：`AppearanceControl` 把常用外观设置连到原页中的真实控件，支持「状态栏字号」或「桌面歌词暂停隐藏」这类连写搜索。设置历史保留地点和控件，现有页面滚到目标并加细边框；菜单栏弹窗继续复用同一套宽度、滚动和字号控件。隔离原生实测两处滚动与标记、原搜索的后退前进、暂停开关可改；定向测试 30 项通过、1 项跳过。


「找回一句」与工作台调用同一套本地匹配。歌曲信息与歌词可以同时命中；独立译文、读音优先于原词里附带的相同文字，阅读页保留版本 UUID。⌘K 通过 App 的编辑菜单打开，菜单栏和 macOS 服务进入同一窗口。系统服务只读取调用方提供的选区 pasteboard。macOS 发现应用服务时需要应用已安装到 Applications 目录或其子目录。[Apple Services 实现说明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html)

用短期安装在用户 Applications 目录的独立验收 App，经系统服务提交样例选区，回车读到了第二句的上下文，Esc 返回原搜索。在文档窗的编辑菜单读回启用的 ⌘K 项并实际点开。验收实例随后自行移除。

## L-044 状态栏跟随歌曲，也能回到自己的资料（2026-11-18）

系统菜单栏的宽度有上限，原文和译文选中时各给一行。只有当前句已选的文字进图；选择字上读音时优先使用现有 ruby 排版。外观页调用和真实状态栏相同的模板图绘制函数。歌词、演唱状态或外观改变时更新缓存，滚动沿用原有图层；换行和换歌不需要反复重开弹窗。

弹窗收藏采用屏幕所示的歌词与录音键。停播时从本机金句或歌词库进入工作台。播放与空闲的离屏检查使用临时数据库，截图宿主退出即清走自己产生的封面和工作目录。

日英混排原文和注音进模板图前把内嵌换行合成空格，原始歌词仍保留换行。直接用 AppKit 测量含换行的字符串会给出最宽一行的宽度，第二行画进固定 22 pt 高度的图时被裁掉。播放时超宽句的滚动以实际下一句的时间为限，保留看到句尾的时间。暂停或开启减少动态效果时使用带省略号的紧凑图，系统提示和弹窗仍可以读全文。

2026-11-19 双行滚动。原文和译文各用一个原生图层，以各自字宽判断滚动和省略。能完整放下的短行保持原位。系统栏、设置页和弹窗外观预览复用同一个 AppKit 视图，预览可试读日英混排长句，随设置切换宽度、文字层和溢出方式。隔离设置窗实点双行、固定宽度、滚动和省略，也核对只显示短译文时自适应缩窄。42 项相关原生检查通过，1 项环境跳过。真实系统栏的可用宽度与实播未参与这轮核对。

状态栏弹窗的封面和背景缩图按实际查询 URL 配对。旧实现等异步加载完成才替换，慢图时会把下一首的歌名配上上一首的封面。换歌时立即从当前 URL 选择图或占位，背景同步切换；阅读区域只在同一录音和同一歌词状态内做滑移动画，避免加载提示与下一首的原词重叠。隔离宿主用《インパーフェクト》切到《Complain》，把后者封面延迟六秒复现并复核，又通过「找一句」回读先前收藏的原句和译文。

2026-11-19：弹窗「完整歌词」快照携带原文档的行号，并复用声部和合唱行合并规则。打开时定位到眼前那句，正文继续用阅读页的和声、译文和读音组件，复制全文使用同一份冻结的文字。有已存原词时带确切版本去歌词库，匹配原稿和内容指纹的已选译文一并固定。在两处副歌同文时按原行号定位，临时未存歌词可留在弹窗阅读。

18 项菜单栏与本机检索测试通过。隔离窗口在 34 秒打开全文并标出对应英文句，从弹窗进入已存译文，在档案核到「刚才阅读」，再回读同一句。独立窗口运行的是实际弹窗视图，系统菜单栏的真实弹窗尺寸未单独测量。


## L-045 顶部灵动岛读句（2026-11-18）

刘海宽度取当前屏幕的辅助区域，深度取 safe area。在有摄像头的屏幕上，两边放封面与进度，歌词从深度线下开始，必须同时给 SwiftUI 布局和 AppKit 命中几何留出高度。平面屏幕直接在横条内读当句。展开后文字使用岛体的整行宽度，下一句与播放控件各占一行；全屏幕透明宿主、热区与鼠标穿透沿用现有控制器。

「定住这句」仅在展开的岛上暂存用户看到的行和录音、原词版本。小字继续显示正在唱的行，收起或换歌会回到跟随。收藏取所显示的行；进度拖动沿开始时的录音键提交。进句提示只用真实时间轴标出的间奏，在下一句前三秒出现。原生宿主构建及离屏图覆盖播放、收起和无歌；刘海位置是几何用例，未实测实体刘海与多屏切换。

2026-11-19：状态栏进度条和三种顶部胶囊使用同一个进度草稿。换歌立即清掉可见草稿并使旧手势失效，松手时即使播放器又回到同一首也不会执行旧跳转。实际隔离灵动岛通过辅助功能调到 73 秒，提供方收到一次跳转，收起后重开仍是 73 秒。定向用例覆盖跨录音、返回原录音和同一次拖动只提交一次。

同日接通全文阅读。三种展开灵动岛和桌面歌词的悬停工具栏与状态栏共用 `ListeningLyricsSnapshot` 和 `ListeningLyricsReader`。桌面歌词与灵动岛使用同一个可独立关闭的普通窗口。定住后读取时核对录音、版本和原行，保留该句的译文快照；没有存稿时仍可读全文，有存稿才提供回歌词库。隔离灵动岛在 3 秒定住第一遍副歌，跳到 26 秒后打开全文，焦点与译文仍在第一遍。实际 Esc 关闭阅读窗口，播放器保持 26 秒。桌面歌词验证显示第二遍，自动化未触发其悬停栏。43 项定向原生通过，覆盖播放前进、换歌拒绝旧的定住行及保留已打开内容。


## L-046 离线阅读按命中的版本和段落打开（2026-11-18）

歌词库搜索缓存按录音和版本区分 metadata、lyrics、translation、reading。工作台保留命中项的类型与版本 UUID：歌名/歌手打开档案，原词、译文、读音打开对应的阅读页。阅读时先在当前录音的版本清单核对归属；即使另一录音同名也不能借用版本。原词哈希一致时按行号组合原词与所选译文。不一致的历史译文单独读，仍保留原有资产。

收藏新增可选原词版本和行号，同一句重复时能跳回当时那一处。旧收藏沿录音和文字查找。查找光标、选中版本、收藏和实际播放器互相独立。版本菜单的预览也使用同一阅读页；时间轴保留原来的数值预览。真实回归另有一项：旧收藏文件若不能解码，先前会在下次收藏时被空列表覆盖。现在修改前读取文件，成功写盘才发布列表。

2026-11-19：阅读页共用「切换阅读版本」。`readLibraryPassage(..., includeEditions:)` 从已经读取的录音档案列出本机稿件，使用真实版本 UUID 和自定名称。切换时传入当前查询，同版原词保留行号和视口，其他原词按查询重新定位。收藏快照和歌本摘段仍指向原稿。隔离 ⌘K 实测搜「雨声」进入人工译文、切到歌词源译文并保留命中行，返回仍是原查询。临时库验证两种语言的译稿切换及原来的采用选择。

离线读原词时，读音取档案中的对应版本，手工锁定的旧行保留优先；和声取同版原词选用的有效逐字时间轴，在句内查找也可命中。收听、编辑、阅读都能取到同一句的和声。

收藏页有翻页和列表两种看法，原词、译文、歌名和歌手都可以找。离开再返回会记住查看方式和卡片。歌曲停播时也能从摘句生成分享卡。「接下一句」使用打开的本地原词版本，收藏中的行号区分重复副歌，旧收藏按完整原句定位。揭晓前后续歌词与它的译文、读音和和声一起收起。主窗口从正在显示的已存原词进入同一阅读页，搜索预览没有这个播放态入口。


2026-11-18 整理链路。收藏身份用录音键、原词版本、行号和确实投影到这一行的译文版本；旧收藏仍能按录音和文字回读。此前重复副歌虽然存了行号，按钮仍按文本全曲去重，一收藏第二处就移除第一处。主窗（含旧布局）、状态栏、灵动岛与离线阅读共用收藏记录；灵动岛定住时一起保留当时的译文。确切译文找不到时可凭已保存的原词版本打开，并带回收藏时的译文快照。工作台「继续阅读」保留实际段落；本机搜索与 ⌘K 返回原查询及选中项，收藏页保留筛选和位置。

歌曲档案从阅读入口继承当前看的原词或译文。档案顶部能阅读、对读、修订和收进歌本；时间轴和歌词来源从「更多」进入。歌本同时保存所见文本和实际版本出处。没有 SQLite 迁移，旧收藏与歌本的可选字段可继续解码。32 个相关原生检查通过。视觉宿主从本机只读导出的 《Complain》《風のたより》《愛をこめて花束を》三首歌测试状态栏快照、保存并重新读回收藏、搜索、定位原句和歌本出处；《Complain》阅读窗口实绘选择第 2/2 次。验证数据使用临时数据库。

2026-11-19：「继续阅读」改为记住实际打开的原词、译文或读音出处，以及阅读页最新一次查找命中或背词返回的行号。收藏带来的译文快照继续绑定原摘句；书签位置和阅读位置分别保存。只扩展现有本机偏好的可选字段。临时库先复现采用新稿后续读误跳新稿，改后能回到旧稿的第二处副歌、保留原收藏译文以及新稿的采用状态。共 10 项定向原生检查通过。隔离真窗在 ⌘K 的日文歌词译文里从第 1/2 处点到第 2/2 处，返回、清空搜索，再由「继续阅读」回到同一译稿第 2/2 处。

2026-11-19 补阅读与档案往返。原来独立歌词库的预览没有「版本档案」，有入口的窗口也只传版本分类。现在阅读页传已确认的录音、版本和阅读位置。档案把该版本放在分类首行并标「刚才阅读」，已采用照原选择显示。同窗「读歌词」、该稿预览与设置后退都带回这次位置；从主窗版本弹窗进入档案时，等 sheet 关闭再打开设置。旧收藏的译文版本已不存在时，档案定位原词，回读仍保留原摘句的译文快照。49 项定向原生检查通过。隔离原生从主窗打开独立歌词库，把未采用的「译文一」定位到第 2/6 处，打开档案再回读，仍是该版本第 2/6 处。

2026-11-19 续读记录增加视口首行，仍独立保存查找命中和收藏行号。SwiftUI 的滚动位置绑定在原生阅读窗翻页后未返回可靠行号，实际从行相对视口的位置取首行，滚动稍停或离开时保存。工作台和空白 ⌘K 共用最近五份按录音与版本区分的阅读记录；浏览档案仍沿用旧偏好，旧单份阅读记录可作为起始数据。隔离原生的长篇样例从首句查找进入，翻到第 9 行后关闭，从继续阅读回到第 9 行，查找仍为 1/1。另读《窗边的来信》译文后两份稿各自保留位置。定向原生检查覆盖同一首歌不同稿、旧偏好与收藏快照。

## L-047 本机空间和可恢复的数据库备份（2026-11-18）

设置的「本机空间」分别显示数据库及日志、手动与升级备份、封面与背景视频。可以在 Finder 定位备份，或把选中的一份移到废纸篓。缓存清理只清本应用的封面、生成文件名的 Canvas 和可重建的搜索索引。歌词原词、译文、读音、逐字与排轴来源文件都是用户资产。

旧清理实现直接删除了原词版本，外键同时删除已锁定原词的译文。旧手动备份先执行 FULL checkpoint 再复制主文件，在另一个窗口持有 WAL 读快照时会漏掉新提交。临时库均已复现。手动与升级备份现在共用原有 SQLite 在线快照实现，临时文件关闭后才取得备份名。统计、备份和清缓存的异步方法明确实现仓库协议，设置更新操作后直接重新取用量。对应原生用例在 LibraryRevisionsContractTests 与 ListeningBatchOneTests。[SQLite 在线备份](https://sqlite.org/backup.html)

2026-11-19：标准个人数据包在一个 SQLite 写事务内导入，任一曲失败就撤销本次全部写入。预览和提交都核对录音族和原词 UUID，接受已知的旧键重定向。私人文件夹的确认绑定所见文件内容，文件在预览后改变会要求重新检查，在写回前改变会保留新文件并提示本机已导入。两个歌词库入口共用状态文案。临时库复现了后曲失败却残留前曲、跨录音复用同版本 ID，并验证回滚后可重试；临时同步目录验证预览后替换、禁止旧版本写回和重新预览成功。使用 [macOS 文件协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28writingitemat%3Aoptions%3Aerror%3Abyaccessor%3A%29) 保护本机写回，未验证第三方云盘跨设备传输。

2026-11-19 隔离视觉宿主同时启动工作台和 `--saved-reader-fixture` 时遇到重复添加 `is_preferred`，定向原生测试又复现旧库升级时重复添加 `performer_id`，空库还产生了无内容的升级备份。播放和歌词库各用一个仓库连接。现在取得 SQLite 写锁后重读库版本，备份及所有迁移步骤由该连接负责，升级失败会整体回滚。备份通过独立读连接取得升级前的数据。新建空库无需备份，双窗口升级旧库只留一份。21 项歌词库原生测试通过，隔离工作台原路径启动成功。隔离用户目录另验证了 v5（含 WAL 提交和锁定歌词）、v10、v11、v12、v13 升级到 v14。真实用户库未参与。[SQLite 事务文档](https://www.sqlite.org/lang_transaction.html)

同日纳入 Apple Music 本机封面。过去导出的文件在临时目录，网络 `URLCache` 算不到，也不随设置清理。现在保留正式文件路径，完成导出才由 `AppleMusicArtworkCache` 发布。新封面把同类缓存控制在 64 MiB，按最近使用时间腾出空间。设置只统计和清理符合原生成规则的普通文件，跳过其他文件及符号链接，调试使用隔离目录。网络缓存、Apple Music 本机封面、背景视频分别列出；清空后，测试的系统 URLCache 仍报告约 82 KB，本机封面独立读回为零。隔离设置实读 33 KB 本机封面和 82 KB 网络缓存；81 项定向原生测试通过，用播放器脚本桩和临时库走统计、清理与锁定资产保留。

## L-048 把歌词文件当文档打开（2026-11-18）

TXT、LRC、TTML 共用系统的只读文档窗口。Finder「打开方式」、文件菜单和工作台拖放都能直接阅读。选了「存入」才关联到点选的录音，或用填写的歌名、歌手、专辑建立本机档案。歌曲档案里补词会先打开相同的预览，并记住具体录音。

工作台的打开面板还可编辑手稿和歌本。档案里的「从本机文件补上」只接收歌词文件，避免把手稿头部或歌本内容读成纯文本歌词。

同一份文件重复存入同一录音，只保留一份。独立原词、文件自带的译文、读音和逐字沿歌词库原有版本路径保存，既有锁定和取消采用均有效。源文件不改写。TTML 按 XML 字节编码读取，LRC 的零秒时间和无时间行在导入、导出后仍可区分。

多语 TTML 的每条译文按 XML 语言标记跟随原句排序。播放器、文档窗和编辑器按目标语言及文字系统选稿，整首保留同一语言，稀疏行留空。所有语言作为独立的词源译文入库；换显示语言、重复打开或后续 synchronize 均复用旧资产。同一文件的旧存档用录音、导入指纹与原词哈希识别。对旧的未标语种版本做人工修订时可指定子稿语种。

2026-11-19：文档窗「阅读已存版本」按点击当时显示的译文和查找位置继续。`continueFiledLyricReading` 在已导入原词下按正文指纹、语种和逐行文本找对应的词源译稿；沿用原来导入返回的原词 UUID，手稿归档和播放采用仍走原路径。找词时交接当前命中行，浏览时交接视口首行。隔离 App 以英语存入 TTML，切换到简体中文、查「信」后选第二处，进入已存稿仍显示 2/2 和该行译文。32 项相关原生检查通过，覆盖重复导入、多语及缺行留空。

已用独立 Bundle ID、临时数据库、停用 Keychain 和模型的 App 从 macOS 打开一个 LRC，经真实文档窗读取正文，点击存入并回读数据库。词库保护及 UTF-16 的证据在 LibraryRevisionsContractTests。

文件、离线阅读和编辑器共用「导出这份歌词」。TTML 写实际逐字区间，未唱的标点和间隔照原文保留。文件保留各语种，档案只导出这份阅读页选中的译稿，编辑器使用眼前草稿。TXT 能带上所选读音，缺匹配原词的历史稿也能单独导出。已在独立 App 的系统存储面板另存并重开混合时间的 TTML，比对原文件字节一致。v5、v10 至 v13 升级均使用合成库。

## L-049 两份原词或译文逐句对读（2026-11-18）

对读从档案当前稿或指定版本进入。读取时校验录音与原词哈希。同源行按真实行号对齐，稀疏译文缺行留空；不同原词按保序的相同正文定位，重复副歌前插句不会把后面整段错配。原词还能比对附文、时间与逐字区间。

只有同一原词版本且哈希一致的两份译文可以挑句。选句记录只存在对读窗口里，按参照稿分别保留；进入编辑器后，沿用底稿的父子关系与人工保存路径。键盘和辅助功能可以直接访问档案和版本行操作。覆盖见 LibraryIdentitySearchContractTests 与 LibraryRevisionsContractTests。

播放面板的「逐句对读」和档案使用同一个窗口，可更换两边的稿或交换底稿。收听入口仅取播放器当前原词下已经载入的版本；点击「采用」时再次匹配实时录音、原词 UUID 和译文状态。切歌、切原词或进入搜索试听时收起跟随播放的对读窗口，离线档案仍可独立修订原稿。

档案或对读保存的人工修订共用 `is_draft` 标记，保存后显示「待采用」。档案的默认译文和收听的自动选稿会跳过这类稿件，直接打开指定版本仍可阅读、对比或收录。属于当前原词的同语种新稿会立即补进收听面板，点「采用」后才会变更播放选择。原有的锁定和父稿关系照常保留。

2026-11-19：播放入口按采用的原词版本和原始行序定位编辑器。V3 右键「编辑这一句」可跳到任意可见原词行，同文副歌仍按行区分。编辑稿记住所选行，重开会保留未保存稿，切到另一首前可明确选择放弃。试听、播放及打点核对编辑稿所属录音和会话，试听按稿里原始时间，标记用实时录音时钟。隔离原生从 34 行的样例右键第二次副歌，选中第 28 行，试听读回 162 秒。播放器桩核了同句多次出现、重开、标记不自动前进与切歌后试听被拒。

两个 V3 歌词滚动与布局合约原先仍在拆分后的窗口文件找视图。现对准 `AppleMusicImmersiveV3Lyrics.swift`，检查按折叠后的可见行序滚动，保留对普通 `VStack` 和读取行序的位置断言。

2026-11-19：从阅读页进入版本档案再对读时，沿录音、版本 UUID 与原始行号定位，互换底稿和参照稿后仍跟随原来那版。刚读的句子若在两版相同，对读会展开全文定位。选择参照译文带入编辑时，从对应原词行打开，仍保存为独立人工子稿。隔离真窗从 30 行样例命中第 20 行的第二次副歌，档案「对读译文」标出刚才阅读的位置，带入后编辑器第 20 行显示参照译文。65 项定向原生检查通过、1 项环境跳过，覆盖换底稿后同文副歌的原行号和保留已采用版本。

## L-050 写手稿、编排段落和存人工版本（2026-11-18）

手稿使用 macOS 可编辑文档。文件为 UTF-8，头部记录标题、手稿身份及上次明确存入的录音和版本，正文保留空行。移动段落时只换正文内容，两段之间原有的换行和留白照旧。在结尾复用同一段会生成独立的文字，后续可以各自修改。纯文字和粘贴来的 LRC 共用已有解析和阅读入口。

归档以录音、手稿 ID 和正文指纹去重，局部时间也计入指纹。同一手稿再次归档时关联到它在这份录音中引用的父稿，其他录音不能借用。外部 TXT、LRC 和 TTML 继续用独立的阅读窗口；手稿 UTI 属于 `public.text`，这样系统不会把它交给通用纯文本阅读器。

2026-11-19：从歌曲档案开始写手稿时，存入面板先解析手稿带来的录音键。旧键定位到正式档案；只有播放记录的曲目以原键临时出现在本次面板里。普通选录音仍显示已知档案，打开面板也不提前写入歌曲表。隔离库验证了两种目标都能保存至原录音。

同日接上阅读页的「从这版写手稿」。手稿复制原词和已有的行级起点，首存时可把同一录音中明确打开的原词版本（包括手稿之外的版本）作为父稿。沿用现有手稿头部和去重规则。仅剩译文或读音的旧稿只走原有阅读和导出。

真实窗口验收在私有目录打开一份手稿，重复第二段，经文件菜单保存并回读正文，移动首段再存入同一录音。两版之间的父稿和原有采用选择均已读回。从已存稿打开阅读页后，通过启用的 ⌘N 菜单项新建了空白手稿。


## L-051 歌本保存已有版本，A5 印页带可跳转的目录（2026-11-18）

工作台、歌词阅读页、单行菜单和金句都能编歌本。打开已有歌本时可直接收录进去。歌曲按本次阅读的原词、译文或读音版本保留一份精简正文。摘句带录音键、版本 UUID 与行号，同一副歌的两个位置可以各自收录。母库变动后，本机歌本仍能阅读其收录时的文字。歌本文档自身只保存文本、顺序、封面和编者按。

排版使用 Core Text 按实际字形分页，长歌词可跨页。整首歌单独起页，连续摘句共用页面，A5 PDF 目录可直接跳到对应篇目。选到的原词、译文、读音和和声共用歌本的显示选项。导出前只生成内存数据。本机保存或打印由系统面板负责。

隔离真窗从 Finder 打开歌本，调整两首顺序，在收录窗口加入带出处的金句，经系统「存储」读回。系统面板导出 13 页 A5 PDF，抽查封面、目录、正文与末页。原生测试覆盖重复摘句、版本出处、PDF 跳转和跨页末句，明暗色离屏图覆盖封面与章节页。

2026-11-18 补：⌘K 读到的那一句原先只能右键「收录这句」，找不到。现在阅读页里选中或悬停的行在书签旁直接显示歌本按钮，带版本 UUID 与行号。加入已打开的歌本后，按钮约 1.8 秒显示「已收进《书名》」并发辅助功能播报。返回按钮写出原查询词，Esc 回到原结果和选中项。离屏图 `library-reader` 核过按钮位置；真实窗口未点验。

2026-11-19。歌词库、文件、接句、状态栏全文与歌本沿用播放的声部名称和合唱判定。阅读投影只折叠同一时段、同文且没有额外附文的后续行。后续独有译文、读音和和声保留。原行号仍用于收藏、摘句、导出和对读；打开已收藏的合唱行会定位到可见行。对读保留两份原稿的行序，原词比较可识别声部差异。歌本和 PDF 共用收录时的阅读行。新歌本只新增可选显示数据，旧歌本沿用保留的声部字段并显示可读名称。定向检查使用含合唱、独有和声和再次演唱的 TTML，经过存入、读回、对读、歌本与 PDF。

2026-11-19 歌本收录搜索原来会把命中的整首直接加入。现在点歌词命中先读确切版本，用已有行匹配及声部投影列出可单收的行，原文、译文、行号和实际时间一起显示。可以逐句收或收整首，返回保持搜索。原生歌本实测只收第二次唱到的英文样例，正文显示第二处的译文，回原稿命中 2/2。临时库还覆盖切换采用稿后收录旧稿第二处、歌本编码及读回。

同日补上摘段。阅读页的「摘一段」和歌本选段共用 `LyricBookExcerptPicker`；歌词命中可以从特定那次出现开始选。摘段作为同一篇保存，沿用完整原稿的声部投影，所以同唱只显示一次，选段边界的合唱标记、独有译文与和声照常保留。`LibraryPassageTarget` 新增可选结束行，旧歌本无需转换；篇目回原稿仍以原版本和起始行为准。隔离窗口分别从阅读页收第 3–4 行、从歌本搜索收第 1–2 行，读回两篇各自的译文，并回第二次命中的原稿 2/2。25 项相关原生检查通过，目录行号调整后复跑摘段用例；另核对导出的 PDF 有译文且未混入后面的句子。


## L-052 画面、情境和歌词显示共用当前配置（2026-11-18）

情境是一层效果，“整套换装”才带入版式、歌词样式、行宽、播放栏和控件材质。主窗口、全屏与画面面板统一用 `V3ListeningPresentation` 解析。试听歌曲、悬停试画面或试情境只影响当前窗口。之前的 `applySceneLayer` 直接写共享设置，打开另一窗口会相互覆盖，还会让情境默认版式挡住手动选择。再次点同一情境恢复它的推荐搭配；手动选择画面或样式只覆盖对应项，现有 rawID 和画面参数照旧保存，当前情境内用户自选记到 `v3.roomOverrides.v1`。背景和前景的调节即读写当前画面对应参数，预览状态有独立标记，套用情境仍可使用 Canvas、双色、窗光、暂停褪色等原画面效果。

听歌界面按实际显示的封面 URL 取同一颜色，换歌等待封面时先用白色。光色歌词保留外发光，当前字、读音、译文与进度/播放控件用接口给来的颜色；明确选择不同颜色模式的边缘线继续按其自己的设置。背景和情境仍有自己的材质与色彩。律动采集由各可见的听歌窗口表达当前需要，一个窗口退出或进入预览不会关闭另一窗口仍在使用的采集。

2026-11-19 自动环境光以本窗封面的亮度、细节与配色选择原版、羽化或双色。它进入 `V3ListeningPresentation` 后同时提供画面和面板的实际样式。主窗、全屏和搜索预览独立取各自封面，手选与情境指定的版式优先。旧实现会在换歌时把计算结果写回画面和每场景偏好。自动开关继续读取 `v3.ambient.automatic.v1`，关闭后恢复已保存的样式。定向测试核过两窗用不同封面、悬停预览、情境及重新打开偏好；隔离原生全屏在画面面板中点选窗光、再切回自动，读取两次选中状态。

2026-11-19 找回旧画面。之前柔和光晕和独立色场仍可渲染，但切走后没有明确返回入口。现从画面面板的折叠行和主窗口外观用同一组选择，搜索原名可直达。两者分别走旧渲染器和色场各自的参数；选中后覆盖当前情境的布局，情境效果及其它样式可照常使用。版本库沿外观入口带到主窗口、灵动岛或桌面歌词分类；取消预览对应这一类。隔离 App 设置实点两种画面和两个小窗口的版本入口，定向测试验证两份模糊值和按分类取消预览。

旧画面和新情境使用相同的 V3 行渲染。早期兼容布局共享歌手/声部标签和同唱合并规则，保持行首对齐。状态栏、桌面和顶部胶囊使用 `LyricsTimeline.presentedLyrics` 取同一套当句与相邻行，保留真实隔开重唱与不同的声部句子，索引仍指向原文档，收藏、时间轴、歌词库与人工版本无需迁移。雪角 Metal 画布的 Swift 计算显式区分 `CGFloat` 与 `Double`，兼容 Xcode 16.4 的类型推断。

2026-11-19：原先合并了同唱行但仍显示其中一个声部。`LyricsTimeline.VoicePresentation` 同时给出显示行和声部标签。合唱显示「合唱」，恢复独唱时重新标出声部；不同词或稍后重唱仍保留，合并只用于有时间轴的视图。V3 主窗、全屏、经典歌词行、桌面歌词、灵动岛和菜单栏弹窗共用判定。灵动岛定住歌词会记住所定行的声部；狭窄的系统菜单栏通过提示显示，歌词本身沿用原宽度。原文档行、时间轴与收藏出处沿用原索引。

隔离原生主窗在默认画面和雨滴玻璃中都显示一次同唱及单独的后续重唱；同一样例的离屏图核对桌面歌词、展开灵动岛和菜单栏弹窗的「合唱」。79 项定向原生检查通过。

2026-11-19：「只看译文」保留原来的罗马音、拼音开关，渲染使用实际可见层。`LyricTextLayers` 给主窗、旧布局、桌面歌词与灵动岛同一份文字判定；窄表面取首个可见内容，下一句也遵循当前偏好。关闭原文时，已开启的拼音以普通读音行显示；原文与假名相同时，只看读音仍显示假名。系统菜单栏沿用独立文字设置，保存的歌词与读音版本不因显示改变。

隔离原生核过只显示拼音的灵动岛（展开、收起）和全假名原句的主窗。桌面歌词指定读音作第二行时，离屏「只看译文」仍只显示译文；没有译文的灵动岛提示「该句暂无译文」。定向原生检查 9 项通过。视觉样例需要在创建设置对象前写入显示偏好，随后加载歌词才会以它们初始化各语言档案。

2026-11-19：单句循环在桌面歌词悬停栏、各款展开灵动岛与菜单栏弹窗提供同一操作，主窗和全屏仍可点具体原词行。按钮每次带上所见的录音和歌词会话代际。小窗可以循环眼前的当前句或定住的句子，也能取消另一窗口设下的循环。主窗口的搜索预览没有循环入口，仍可在全屏或小窗操作播放中的版本。手动跳出循环范围会取消，范围内的跳转会继续循环。

32 项播放事件用例通过，覆盖循环边界、预览隔离、换歌丢弃旧按钮和手动跳转。隔离原生菜单栏弹窗点过开始和取消；展开灵动岛取消了同一播放状态中已设的循环，再定住 16 秒处的歌词、把播放拖到 33 秒，从定句按钮跳回 16 秒。桌面歌词窗口用同一控制，悬停栏的指针交互未在隔离版中确认。

2026-11-19：搜索预览的「更多」和 Z/C/X 原先直接写后台播放版本的歌词偏移。现在两处根据本窗口展示内容选择 `LyricsPresentationOffsetTarget`，预览显示「试听的歌词暂不能校准」，全屏仍按后台实时录音的已存原词版本校准。秒数输入在切换版本时重读本版本的数值。隔离原生核对试听面板和快捷键的提示，再在全屏调整到 +0.1 秒并归零，播放进度始终是 18 秒。39 项定向原生检查通过，1 项按原环境条件跳过。

2026-11-19：状态栏弹窗与展开灵动岛的原词接入真实逐词进度。`WordTimedLyricText` 复用 CoreText 分行、已测量的字位和 `TimedLyricHighlight`，按当前播放时钟及歌词偏移推进，暂停停在当前字。弹窗长句可以换行并复制整句；岛的单行版式、注音和定句沿用原有展示约束。逐行或时间文字不匹配时使用普通正文。隔离 App 对同句的 18 秒和 21 秒暂停画面显示不同的填色位置，原生混排用例核对内嵌换行、各行进度和不相符的正文。

2026-11-19 集成检查：仅译文等显示层的 `LyricTextLayers` 放在 `JapaneseReadingPipeline.swift` 时，曲目匹配的独立编译也被迫依赖 `LyricsLanguageGate`，现有源码清单因此编不过。`9634553` 的 [云端运行](https://github.com/suifracti/aster-lyric/actions/runs/44419530181) 中完整原生套件通过，失败的是这个独立入口。本机复现相同编译错误。把显示投影原样移到 `LyricLineView.swift` 后，`Tests/query_identity_contract.sh` 编译并完成原有断言。下次把由界面偏好决定的投影留在显示侧，搜索的日语读音继续使用已有管线。

2026-11-19：透明桌面歌词暂停时原来会切到不带高亮的另一套视图。现在同一行用 `TimedLyricHighlight` 按时钟填色，播放和暂停共用视图，只有超宽行的横向滚动仍需动画刷新。旧版桌面卡片、经典主窗口接入 `CompactLyricTiming`，原词允许换行；展开灵动岛保持原来的单行约束。`synchronizedLivePresentationClock` 只给当前有同步稿的实时录音，经典主窗试听其它录音时不使用实时逐词时钟。隔离原生窗口离屏图复现旧版暂停全白，候选的透明版在 18 和 21 秒停在不同字位，旧版桌面卡片与经典主窗的 18 秒图也显示部分高亮。48 项定向原生检查通过、1 项环境跳过，签名构建通过。

本机 Xcode Debug 通过 6 项相关原生检查，涵盖多窗口情境解析、旧画面选择与读回、对唱及桌面歌词、真实词间时间断句、封面回补、错过通知时的切歌补读。对比 Claude 末尾 `c6c1104` 的 15 个可独立运行 Python 合同，7 个旧脚本在两边都失败；本轮更新现行场景合同的接线断言，现行原生用例验证行为。两个调用 Xcode 的包装脚本和一个需要测试参数的数据库矩阵未计入这次比较。

## L-053 逐字与声部版本、译文预览与批量缓存（2026-11-19）

- 对唱由词源声部标注驱动。《シュガーラッシュ》的普通在线候选缺少这些标注。手动「查找其他版本」可以读同一 Spotify 录音的 Lyrimuse 本机 YRC 和声部索引，核过 76 行、75 行有逐字时间，两个独唱声部加合唱。合唱保留独立标签。已核过的缓存先显示，在线候选继续加载。YRC 字词内的文本括号照原样显示。
- 《革命道中 - On The Way》的 LRCLIB 版本只有逐行。真实 QQ 结果有 51 行逐字。匹配仅接受 QQ 的括号并列曲名、同一英文半标题、相符歌手及 1 秒内的时长。原词列表与预览标时间能力，候选可和其他候选或已存版本并排看正文、附文、时间和声部差异，采用走现有歌曲身份与锁定规则。
- 预译接下来两首、播放队列及所选歌单都用 `TranslationSessionController` 的串行批次，复用同版原词、目标语言、模型及译风对应的结果和请求日志。取消时停止继续派发，结果可到歌词库「翻译缓存」找。译文面板预览当前歌曲已存译文，Codex 打开最近持久会话，其他已保存会话的 CLI 从终端续接。
- **同日对唱接续。** 已存稿优先命中使手动版本入口里的声部没有进入播放。实时会话先显示原稿，再按同一 Spotify ID、词句和时间补充能确认的声部，分行不同但确认为同一声部的相邻短句可以匹配。锁定和人工改过的稿沿用原数据，补充声部只改变显示，版本 ID、时间、译文与收藏出处照旧。实际《シュガーラッシュ》65 行 LRCLIB 旧稿在隔离会话补出 50 行，20 行合唱、17 行声部一和 13 行声部二。其余行留空。完整逐字稿仍走版本选择；本机索引在磁盘版本变化时才重新解码。
- **同日对唱视觉与翻译进度（Claude）。** 主窗口对唱按声部分左右：靠左排版时声部一在左、声部二靠右，合唱居中；居中排版时两声部各向一侧偏 26pt。声部一用封面色，封面色偏灰时改为柔和天蓝；声部二取色相转 0.36 的同亮度色。当前句外侧有 3pt 声部色竖条，留在歌词栏内（栏外会被裁掉）。用户看过后要求去掉「声部 1/2」「合唱」字样，说这些说不出是谁。现在只有词源给出的真实歌手名才显示，主窗口、桌面歌词、胶囊和菜单栏都按 `VoicePresentation.nameLabel` 过滤；歌词库版本对读仍保留声部名做对照。实机《シュガーラッシュ》暂停在 0:22 截真窗核过。
- 译文面板翻译中改为进度卡：准备 → 已发送 → 思考 → 写译文 n/N 行 → 校验，含已用时间和取消。行数来自 Codex app-server 的 `item/agentMessage/delta` 流里已出现的 `"lineID"` 个数，思考来自 `item/started` 的 reasoning；其他服务只显示步骤和时间。阶段只前进（`AITranslationLiveStage.advanced`）。工具栏「译文」右上角在翻译时显示小进度弧，不做无限旋转以免播放时持续重绘。翻译卡片未实机触发（需付费模型调用），只有单元测试与构建验证。
- **版本窗口接续。** 旧的「查找其他版本」等全部来源和别名探测结束才显示在线稿。现使用现有候选回调逐批回填，继续搜索时可预览、对读，已知别名也参与检索。候选与原词对读用同一个窗口和工作台样式，可换底稿、参照稿及对齐方式。按正文保序匹配，相似短句仍可成对，标题与不同种类的署名保留为各稿独有。按时间与行号由用户明确选。译文挑句仍按同一原词行号。
- **《Online》封面与逐字。** 现场日志中封面补读结束为空，直接请求同一大小写 Spotify ID 的 oEmbed 和两种封面尺寸均可用。封面补读会辨认 URI、裸 ID 和精确歌曲链接，跳过 AppleScript 空值与相对地址，解析不到则直接按已接收 ID 查公开封面。同一录音复用成功地址。只读抽查已存原词 73 行，有 61 行与本机 85 行逐字稿在一秒内同文。实时会话从本机确认过的逐字稿优先补轴，沿用原词、译文和行身份。若本机无合适时间轴，后台搜索可以继续查其他别名及可接入的逐字候选。
- **片假名注音。** `JapaneseRubyPresentation` 的共享显示投影把片假名片段转成平假名 ruby，保留原文与原始时间区间。它跟随原有注音显示和排版偏好，已有注音优先。
