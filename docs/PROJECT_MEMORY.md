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

方法统一继承总规则“2 项目记录”“5.1 全周期复盘与覆盖”，从下方实际覆盖记录接续。

## 本次覆盖

2026-11-10，读取截点 `main@78d600a14270837dd3fffa3359dee47179a2150b`：全文读取原 AGENTS、DEVELOPMENT_WORKFLOW、SUBMISSION_BASELINE、STATUS；读取 TOOLBAR_BEHAVIOR 前 85 行和 Vault 相关交接/入口。本次修正启动路由与重复规则，不改产品规格和源码。

未完成全提交、全分支和全部源码审计，未访问本机工作树/安装版、未运行 Xcode/测试/模型调用、未取得新用户体验。因此**未建立全历史处理截止点**，上述 SHA 仅是规则读取截点。本次没有部署 Hook/CI 或恢复任何旧任务。

## 2026-11-10 接手与持续维护补充范围

本次从 `main@fd66ec3a2ebdba6eccb99d45a0022ddcfd1010bd` 读取现行 AGENTS/本页及项目入口，补自然称呼索引、每轮主动写回和上下文恢复/纠错做法。另核当前 Settings、Backdrop、工具栏规格有关段落，以及 L-004 的历史 Backdrop 原件；私人反馈留 Vault。未完成的历史覆盖仍按原记录；这次规则提交不前移全历史处理点，未重跑产品、部署拦截器或建立后台任务。
