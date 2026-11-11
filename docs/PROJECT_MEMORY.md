# Aster · Lyric｜项目记忆

规则见 [AGENTS](../AGENTS.md)；规格继续维护在 [TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md)，不另建并列任务表。项目旧名 Spotify Lyrics / lyricsQ / Lyric Island 用于历史检索，不当成四个项目。

## 按用户说法找经验

先读此索引，再读命中的条目正文与实际实现；索引只帮助定位，不替代原因和证据。无匹配时再查项目任务源、相关差异和历史，不能因此断言以前没做过。

| 用户说法或本次触及范围 | 到哪里找 |
|---|---|
| 改名、换界面、旧数据或人工歌词不能丢；改持久化/身份逻辑 | L-001 |
| 新包、截图、构建/签名、实际运行是哪份 | L-002；DEVELOPMENT_WORKFLOW.md |
| 极简、减少按钮、保留旧功能 | L-003；TOOLBAR_BEHAVIOR.md |
| 找回旧环境光、模糊/缩放参数、样式合并；改 renderer/偏好 | L-004；AppSettingsStore.swift 与 authenticAmbientArtworkLayers |
| 已采用歌词突然被挡住、同一首重复入库、歌单已存却不打勾；改 Spotify ID | L-005；TrackIdentity、SQLiteLyricsRepository、PlaylistPickerTests |
| Desktop 时长跳变、合作歌手待确认、错误的时长差提示 | L-006；SpotifyTrackArtistResolver、LyricsSearchManager |
| 搜索慢、本地结果等网络、预加载同一首重复搜索；新歌首次找词要十几秒 | L-007；searchCachedLibrary、TrackSearchManager、LyricsSessionController、JapaneseMeCabEngine |
| 队列不更新、循环列表被裁掉、隐藏后点第三首多跳 | L-008；PlaylistBrowserModel、V3PlaylistQueuePreview |
| 版本弹窗挂在悬浮窗、关后黑着、大歌词库关闭或丢选择 | L-009；PersonalLyricsLibraryService、PersonalLibrarySheets |
| 有歌词源译文却不显示、部分行没有译文、重复补存 | L-010；TranslationSessionController.synchronize 与 chooseVersion |
| 悬停歌词库转圈、版本列表开得慢 | L-011；prefetchCurrentTrack、currentDetail |
| 边缘线内移/加粗、胶囊热区、封面卡片不同宽、分段选中块乱动 | L-012；V3EdgeRailView、V3ResponsiveGeometry、V3SegmentedPicker |
| 在窗口边缘拖进度会变成缩放窗口、进度线靠近时下移不好看、胶囊和工具栏像两套控件、画面面板底部被截断 | L-015；V3EdgePillScrubber、V3ControlBarSurface、V3ThemeSelectorView |
| 来源里有词却被拒、歌手写法不同（括号别名、只对上一部分）、同名歌手误进核对 | L-014；artistGroups、parentheticalArtistNames、artistNameParts、primaryArtistPartialName |
| 加歌词源、日文独立歌曲找不到词、酷狗酷我是否已接、哪个源慢 | L-013；PetitLyricsProvider、LyricsProviderConfiguration、supplementProviderNames |

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

## L-006 匹配信任精确 Spotify ID 的曲库元数据，进度仍用播放时长

Desktop 对同首歌报出不同 duration、合作歌手被误判或时长差提示异常时，用精确 track ID 取得的曲库标题、全部歌手和时长做歌词匹配；播放时长只服务进度，不改现有身份键。

`c9f9252` 修正了曲库条目因与 Desktop duration 相差超过 2 秒而被拒绝的判断。`SpotifyLyrics/Lyrics/TrackMetadata.swift` 的 `SpotifyTrackArtistResolver.matchingTrack` / `TrackArtists.matches` 对精确 ID 命中信任曲库信息，`LyricsSearchManager` 用该元数据匹配且保留原 identity；`V3SearchPanel.catalogDuration` 用同一曲库时长计算提示。

现有 `testCatalogDurationOverridesDesktopDurationWithoutChangingIdentity` 覆盖播放报 150.8 秒、曲库为 168 秒时，168 秒来源结果可采用且不显示错误时长差。本轮静态复核，不把它写成今天全部歌词源的网络通过。下次不能为修匹配改 duration 身份键，或反过来用曲库 duration 改播放器进度。

## L-007 本地搜索复用版本内存文本，预加载尝试按运行期去重

本地已存结果应先显示，在线结果到达后补上。规范化文字和罗马音按版本缓存，后续查询做子串匹配；库有变化只重建受影响歌曲/版本，不能每次查询重新生成全库罗马音。

架构来历在 `7905f04`。此前搜歌结果直接携带歌词正文，歌曲目录与歌词来源职责混在一起。该提交拆出 metadata-only `TrackSearchManager`、独立 `LyricsSearchManager` 与共用只读 `LocalLyricsIndex`。当前接线仍是 `PlaybackState` 持有同一个 repository，搜歌只返回元数据，选择后由实时或隔离预览会话加载歌词。旧研究文档列出的待接来源及阶段限制是历史方案，不能自动恢复为今天的任务。

`188ce6f`、`f693196` 对应搜索缓存与变更接线。`SQLiteLyricsRepository.searchCachedLibrary` / `refreshLibrarySearchCache` / `cachedSearchVersions` 用 data_version、total_changes 感知变化，再比较逐歌曲签名，复用未变版本。`SpotifyLyrics/Search/TrackSearchManager.swift` 先发布本地 isLocal 结果再加在线结果。这里是内存缓存，不是数据库迁移或全文索引。

预加载的另一处重复请求由 `c7bdf04` 收敛：`LyricsSessionController.attemptedPreloadSpotifyIDs` 只在 isPreload 路径使用运行期内存集合，任何结果（包括 review/无结果）本次运行仅尝试一次；`preloadedRecordingIDs` 另外记录成功项，真正播放仍走正常加载。`PlaybackState.preloadUpcomingLyrics` 只预取歌词，不进 AI 翻译；`SpotifyCatalogService.upcomingTracks` 默认取接下来的两首。

现有 `LibraryIdentitySearchContractTests`、`testReviewedQueueSongIsPreloadedOnceButStillSearchedWhenPlayed`、`testPreloadedQueueTrackPlaysFromStorageWithoutAnotherSearch` 是回归入口。下次保留本地先出、单曲失效、正常播放不受尝试集合阻挡和绝不提前 AI 翻译。

2026-11-11 用 `0c9a4be` 的生产查询函数，在本机缓存的私有 SQLite 副本上测量。Xcode 26.6、Debug `-Onone`，556 首已存歌曲、754 个歌词版本，首次构建搜索缓存耗时 2.171 秒。随后 10 个中日英/罗马音查询平均 4.12 ms，范围 2.09–5.35 ms，规范化计数不再变化。暖缓存的仓库查询达到原“390 首 0.1 秒”目标，首次查询仍有缓存建立成本。实际搜索入口的闭包持续捕获同一个 `resolvedRepository`，没有逐次新建缓存。测量借用隔离归档中的原生测试宿主，临时测量方法和原始 JSON 仅留本机，未加入 CI。未测真实面板绘制、在线等待或并发写入期间的延迟。

2026-11-11 核对本机 `source-stats.jsonl`（10-24 至 11-10，235 条）：10-31 之后正在播放的新歌首次找词 16 次，中位 19 秒，8 次无结果。各来源自身多在 1–2 秒内返回，差额来自读音引擎。`JapaneseMeCabEngine.run` 每次调用都新起一个 MeCab 进程，并以 10 ms 间隔轮询退出；同一句歌词会在预览候选、正式候选、每个查询变体和最终文档里各补全一次，匹配器比较标题和歌手读音时也走同一入口。`2026-10-30` 报告已定位这段重复工作但当轮未修。

现在 `JapaneseMeCabEngine` 在本次运行内按“可执行文件、参数、文本”记住成功输出，失败不记；轮询间隔改为 1 ms。没有改匹配规则、候选流程、来源或数据库，读音结果与原来逐字相同。新增 `testRepeatedLyricLineStartsTheReadingProcessOnce` 先复现同一句启动 3 次进程，修复后为 1 次。同机 Debug 测得 46 行日文补全首次 0.62 秒降到 0.17 秒，重复 0.007 秒；20 次匹配判定首次 0.066 秒，重复 0.016 秒（10-30 报告用另一组数据测得 0.574 秒，条件不同，只作参照）。完整原生 130 项中 129 通过、1 跳过、0 失败。真实新歌的端到端找词耗时要等统计文件积累新样本后再比，本轮没有实测。

同一批无结果歌曲逐首向 LRCLIB 复查：8 首中 7 首确实没有条目，拒绝的是同名的其他歌曲，属于正确拒绝。只有《KILL MY LOVE》存在歌手写作 `Miliyah`、204 秒的带时间轴条目，播放侧是 `加藤MILIYAH`、198 秒，因 `primaryArtistConflict` 被硬拒。这是歌手别名规则的已知边界，本轮未改，其他来源未逐一复查。

## L-008 队列刷新保留稍后重复项，点击按原始 offset 前进

启动时空队列、开始播放后打开仍为空，或循环歌单/隐藏行使跳转错位时，复用旧列表并刷新；刷新成功只去掉开头连续的当前歌曲，不能删掉稍后再次出现的同一首。`firstIndex` 的前缀裁剪只留在切歌通知路径。

`075d578` 恢复 `V3PlaylistQueuePreview` 打开时的 `loadQueue()`，`24cfa3a` 分开网络刷新与 `currentTrackChanged` 的裁剪，`e91ffca` 删除 queueJump intent 和 X 的当前歌特例。权威是 `SpotifyLyrics/Spotify/PlaylistBrowserModel.swift` 的 rawQueue、queueItems、jumpToQueuedTrack 和 `V3PlaylistPanel.swift`。隐藏行仍保留原始 offset；跳转先用掉跨过的 skip 标记，再发 offset + 1 次 next，X 一律标记。

现有 `testQueueThirdPositionUsesThreeNextCallsIncludingHiddenSong` 覆盖首次空载再刷新、稍后重复曲目和隐藏第二首后点原第三首恰好三次 next。`e91ffca` 当轮报告 Debug 构建和 31 项相关检查通过，本轮只核既有证据，未对真实 Spotify 发写请求。下次保留原始队列位置、旧列表和一次性标记语义，不恢复已删的时序/跳转来源补丁。

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

## 实际覆盖与接续

方法继承总规则“2 项目记录”“5.1 全周期复盘与覆盖”。以下区分枚举、定向源码阅读和运行证据，**仍未建立全历史处理截止点**。

- 此前2026-11-10 在 `main@78d600a14270837dd3fffa3359dee47179a2150b` 全文读原 AGENTS、DEVELOPMENT_WORKFLOW、SUBMISSION_BASELINE、STATUS，读 TOOLBAR_BEHAVIOR 前 85 行及 Vault 入口/相关交接；后来在 `fd66ec3a2ebdba6eccb99d45a0022ddcfd1010bd` 核 Settings、Backdrop、L-004 历史原件并补自然场景索引。这些是规则/局部资料覆盖，不是全产品审计。
- 本轮在2026-11-11 固定 `main@3f069781b6c9f2b5bdf2c5e26ccbfc9f1581cb82`。完整枚举本机 refs 与可达提交数：main 794 个，全部 refs 795 个；项目可见根提交 `50045ecccfab88bf88a824ff67acab6295d6bb81`，2026-07-26 21:10:12 +08:00，首次 Spotify Lyrics App 实施。现有 main、origin/main/HEAD、4 个 tag、4 个 Codex snapshot commit ref 和 1 个 checkpoint tree ref；main 之外仅历史 snapshot `5a96753184e763908abb87c71949a4acd47fb904`。这些数字是枚举结果，不代表正文已读。
- 本轮全文读现行 AGENTS、PROJECT_MEMORY、Vault 项目 README/项目总览；定向读 TOOLBAR_BEHAVIOR 的 Round 11/12、Handoff 开头的 Round 6 历史及有关决定片段。核 L-005～L-012 列出的身份、匹配、缓存/预加载、队列、sheet、译文、详情预取和轨道的当前实现、关键差异与现有用例；查看 `075d578`、`24cfa3a`、`e91ffca`、`8e85fe6`、`23a378e`、`7144775`、`ff823a2` 等提交的相关 diff/说明，以及 L-002 所列本机作废性能日志。源码静态核对、提交中的当轮报告和本轮运行验证分别表述。
- 本轮没有重跑 Xcode/测试、启动 App、读正式库/Keychain、操作 Spotify 或调用模型；正式安装版和用户实际运行版未核。尚未逐一读从根到截点的全部提交正文/源码，也未完整枚举与阅读 GitHub PR、Issue、Release、远端其他历史 refs/附件及全部用户会话；4 个 tag 和本机 snapshot 仅枚举，不能称全分支审计。
- 全周期正文从根提交 `50045ecccfab88bf88a824ff67acab6295d6bb81` 开始，先核该阶段来源与后续真实差异；本次已经定向核过的主题/版本可复用去重，不用重新验证一遍。新提交和文档补记不前移产品历史处理点。产品开发仍按用户当轮任务，不由未完成复盘自动恢复。
- 后续自主推进又定向读取了根提交的 Mock 模型/播放状态、`5f20b8d` 的 Desktop provider 与状态实现、`4a0997c` 的明确 Mock Preview/请求代际与歌曲会话分离、`c8283ab` 的恢复/seek 差异，以及 `7905f04` 的搜歌/歌词模型和管理器。最早 14 个提交只枚举了身份与变更目录，早期审计/研究正文仅选读相关部分，UI 图片未复查，因此全历史完成游标仍未前移。当前修复所需的分工原因归入 L-005/L-007，未把旧 Mock 回退或旧来源规划恢复成现行行为。
