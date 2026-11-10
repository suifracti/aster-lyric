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

## 默认自动执行：不等用户提醒

开工把相关经验、现成成果和保留行为带进方案；遇错或文件找不到，在重复尝试、推倒重写或反问用户前查旧修复、别名/分支与真实运行版，核适用条件，不盲套旧根因。重要原因、取舍和反馈出现时更新原条目，收尾归并并自检一次，无新信息不硬写。

复发同时定位没记录、没找到、没采用、条件变了、修复不在当前版本或检查遗漏，修实际缺口。相同材料不重复提炼，相关经验仍要调用；保护既有行为而非冻结代码。没有权限或证据说明具体缺口，不假称已读/已写/已验。

处理故障、改变参数/行为、方案取舍或用户反馈就更新原条目；未解决也记录发现和假设，不凭“重要”筛掉。先把做法、原因、结果落到主源，再据此交付；无新结论不硬写。压缩恢复、换任务或改共享逻辑时，从本页索引与既有接续点找回相关约束、已做/已否定方案和下一步，不让用户重新讲。发现内容错误、过时或链接失效，按证据修原处并保留替代关系，不通过删用户要求或把失败改成通过来迁就新改动。

改旧功能时找回本次相关的已有能力、调好参数及权威来源、数据/接口兼容、旧修复；优先复用或等效替代。参数不能只靠截图回忆，迁移不能只验证新数据自建自读。

有 Obsidian 访问权限时，将本轮处理的问题、原因/假设、做法、结果边界与保留项同步到项目既有案例/体验页，附仓库路径和版本；它是可独立读懂的知识摘要，不是另一套待办。只写本地仓库、只留 Raw 或只放链接都不算完成这一步。有实质处理的交付简短注明两边实际落点及未同步项。另从 `03-项目与工程/Spotify Lyrics/README.md` 读相关私人体验与决定；仓库保留必要的脱敏行为约束和定位，不复制私人原话，也不把个人体验遗漏成只有 GitHub 提交。按用户要求先读 Obsidian 时，先完成其根 `AGENTS.md` 的工程必读组。无法访问 Vault 就使用本仓库自足规则并说明涉及的反馈缺口。

“给这个已有项目建立/补全记忆”和“整个项目、开发了 N 个月完整总结”默认补历史基线，复用下方已有覆盖，从未读范围接续，不能只建文件或总结最近提交就称完成；“最近 N 个月”才是时间窗。日常任务不以补完全部历史为前置，也不创建后台任务、审批或全量回归。

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

## 增量与全周期

沿 AGENTS 的模式判断执行。重要事件当下记录现象/来源、原因确定程度、实际试过的取舍、实现与测试指针、版本/反馈和下次触发；同一问题更新原条目，旧结论遇反例可替代。已有能力状态或阶段任务只引用所属主源。

覆盖记录必须区分 refs 目录、正文、diff、运行与体验。相同 SHA 和等价成果去重，反馈无新提交也可更新；保存并读回前不前移游标。

## 本次覆盖

2026-11-10，读取截点 `main@78d600a14270837dd3fffa3359dee47179a2150b`：全文读取原 AGENTS、DEVELOPMENT_WORKFLOW、SUBMISSION_BASELINE、STATUS；读取 TOOLBAR_BEHAVIOR 前 85 行和 Vault 相关交接/入口。本次修正启动路由与重复规则，不改产品规格和源码。

未完成全提交、全分支和全部源码审计，未访问本机工作树/安装版、未运行 Xcode/测试/模型调用、未取得新用户体验。因此**未建立全历史处理截止点**，上述 SHA 仅是规则读取截点。本次没有部署 Hook/CI 或恢复任何旧任务。

## 2026-11-10 接手与持续维护补充范围

本次从 `main@fd66ec3a2ebdba6eccb99d45a0022ddcfd1010bd` 读取现行 AGENTS/本页及项目入口，补自然称呼索引、每轮主动写回和上下文恢复/纠错做法。另核当前 Settings、Backdrop、工具栏规格有关段落，以及 L-004 的历史 Backdrop 原件；私人反馈留 Vault。未完成的历史覆盖仍按原记录；这次规则提交不前移全历史处理点，未重跑产品、部署拦截器或建立后台任务。
