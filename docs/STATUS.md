# Spotify Lyrics Current Status

状态页最后更新：2026-10-12。
这是 repository 的唯一滚动工程状态入口；详细运行证据保留在 `docs/evidence/`，不在本页复制完整审计。

文档链：`README.md` → `docs/STATUS.md` → 具体 evidence / batch report / 已授权计划。

## 2026-10-12 全分支整合

用户明确授权合并所有 PR 与分支。原 M1 整合保留所有本地/远端分支历史，包括 provider 模型目录、捕获来源跟进、预览安全及最新 ambient 样式；更早的下列状态是历史记录，当前产品规划仍以 Issue #30、执行证据以 Issue #33 为准。

本轮 10 项定向离线合同与 unsigned Debug 构建通过；普通编译/runner 依赖及设置文案兼容失败已保留并修正。没有新增真实模型请求、启动 App/播放器或操作日用数据。真实三 V3 中文视觉与所有窗口切行验收仍未完成，合并不替代实机验收。

## Source Identity

- repo root：`/Users/apple/backup/sptifylyrics`
- branch：`codex/nightly-auto-lyrics-stutter`（从已完成 V1 的 `ca98a9dea34df8f1cb9ce723543eb89ce2ed4595` 建立；隔离 worktree 位于 `/private/tmp/spotifylyrics-nightly-auto-lyrics-stutter`；最新生产源码提交为 `137be01c86434afc6e80dc688e1ed9e435abe11e`）
- U1 base：R1 final HEAD `44f949ac9d062a77d3adf6fede0e94e95b69b3f7`；pushed U1 checkpoint `9bbf14e7071a506ebff5b800dca9808a7ac1fd69`
- U1 production commits：`7299241839864dd345b713dea1323fb3b72bef33`、`c19a53c800d03ff5a09deb95f5a86cc0815e86dc`、`a33e9a160a413f928429fa976fc071f5e3f5fe27`；包含 H1/T1/T2/S1/O1/R1 祖先，已推送，尚未合并
- R1 base：O1 final HEAD `c31805467ae877e67ddd14e50af6b6587f719416`；pushed R1 checkpoint `f6e33debc35017fd900029dd1a98ac79f4154b51`
- initial R1 production commit：`4944a818b8c3059b5f575578eaef6194bdd8b373` (`fix: keep manual reading tokens consistent`)
- latest R1 production commit：`bad730103632cedeb852bffec0836745879ce109` (`fix: reject inconsistent kana tokens from all sources`)
- R1 test follow-up：`63498bc9e9a4f53474fe87577092513c1ea92f97`；关闭数据库后重开，并经生产 `select(versionID:)` 持久恢复旧读音版本；generated-source 冲突 token 拒绝合同随最新 guard 提交 `bad730103632cedeb852bffec0836745879ce109`
- latest O1 production source commit：`69c922b37331bf42be7b00494d9ba2f0f5dda3f7` (`fix: sync editor offset input on scope changes`；核心 scope 实现提交 `dd55087502f3aa5e767f79ed9595e0f0eff9cd5d`)
- O1 base：S1 final HEAD `6211bed5c2e31fa0325be00e5a2415d8563f0f25`；pushed O1 checkpoint `f228808169991b6448e60ab1e999a6069310215a`
- S1 base：T2 final HEAD `a427ea65b645931fe2d6fd94dcff5f463b4b1952`；pushed checkpoint `bee7ad106bfee7bfdc2ff96ba536b669cb53a41a`
- H1 production commit：`449df0a6446dd01f250ff84eec34ff87efccf70d`
- T1 production commit：`2963f710c85e0993963d0127514791ee6a19196f`
- release identity：正式 GitHub Release `v0.1.2`，release commit `6528be3103f75fd4f63757855b9d61cd30f757d8`
- status last updated：`2026-09-23`
- tracked/staged 状态：Nightly 源码与定向合同在 `codex/nightly-auto-lyrics-stutter`；证据/status 变化随后单独提交。正式根的三份 `PROJECT_FULL_AUDIT_*.md` 保持原样，不纳入本批。

## Product Boundary

- **Core**：V3 / Fullscreen
- **Supported Secondary**：Desktop transparent v2 / Menu Bar
- **Experimental**：Direction D / Capsule
- **Legacy**：Classic V1 / desktop legacy panel
- **iOS**：当前无 iOS target

这里的分类表示维护级别和工程边界：Experimental 不是不可达，Legacy 也不是死代码。AI、自动排轴和 Capsule 等入口存在不等于稳定支持或已完成用户验收。

## Current Milestone

**M1 — macOS Core Integrity Baseline**

## Batch State

- **B0 — CLOSED**
  - `BASELINE_CHARACTERIZED`
  - 原生 mouse / keyboard / AX：`NATIVE_INPUT_PENDING`
  - Evidence：[B0 clock & offset truth](evidence/core-integrity/B0-clock-offset.md)
- **D0 — CLOSED**
  - documentation source-of-truth convergence and narrow Obsidian sync
  - Evidence：[D0 documentation SOT](evidence/core-integrity/D0-documentation-sot.md)
- **C1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - `NATIVE_INPUT_PARTIAL`
  - `USER_EXTERNAL_PENDING`
  - Evidence：[C1 playback / presentation isolation](evidence/core-integrity/C1-playback-presentation-isolation.md)
- **A0 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - 真实 Spotify/Music capture：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Evidence：[A0 capture source containment](evidence/core-integrity/A0-capture-source-containment.md)
- **H1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - 真人 provider 版本切换后小修改保存：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Evidence：[H1 hash domain boundary](evidence/core-integrity/H1-hash-domain-boundary.md)
- **T1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - 真人验收：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Evidence：[T1 read / projection fidelity](evidence/core-integrity/T1-read-projection-fidelity.md)
- **T2 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - 真人验收：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Planner 定向审查：完成，未发现 Blocker / 必要 Relevant
  - Evidence：[T2 lossless editing / timing](evidence/core-integrity/T2-lossless-editing-timing.md)
- **S1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - 真人低置信候选采用后重启恢复：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Planner 定向审查：完成，无 Blocker / 必要 Relevant
  - Evidence：[S1 durable manual adoption](evidence/core-integrity/S1-durable-manual-adoption.md)
- **O1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - 真人切歌/切版本/重启、跨窗口一致性、编辑器版本身份和真实播放进度：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Planner 定向审查：完成；初次 Necessary Relevant 已修复复审，无 Blocker / 必要 Relevant
  - Latest production commit：`69c922b37331bf42be7b00494d9ba2f0f5dda3f7`，已推送，尚未合并
  - Evidence：[O1 scoped lyrics offset](evidence/core-integrity/O1-scoped-lyrics-offset.md)
- **R1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - V3 整行修改、inline/独立读音/full-screen、romaji 与重启的真人验收：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Planner 定向审查：完成，无 Blocker / 必要 Relevant
  - Latest production commit：`bad730103632cedeb852bffec0836745879ce109`（初始实现 `4944a818b8c3059b5f575578eaef6194bdd8b373`）；最终合同 follow-up：`63498bc9e9a4f53474fe87577092513c1ea92f97`；已推送，尚未合并
  - Evidence：[R1 reading/token consistency](evidence/core-integrity/R1-reading-token-consistency.md)
- **U1 — CLOSED**
  - `AUTOMATED_VERIFIED`
  - D / Classic 人工入口、状态表达与布局偏好验收：`USER_VERIFICATION_REQUIRED / NOT_RUN`
  - Planner 定向审查：首轮 1 项必要 Relevant 已在 `a33e9a1` 修复；最终复审无剩余 Blocker / 必要 Relevant
  - Latest production commit：`a33e9a160a413f928429fa976fc071f5e3f5fe27`（初始实现 `7299241839864dd345b713dea1323fb3b72bef33`）；已推送，尚未合并
  - Evidence：[U1 honest experimental UI](evidence/core-integrity/U1-honest-experimental-ui.md)
- **V1 — AUTOMATED_VERIFIED / USER_PENDING**
  - U1 精确候选源码 `d75789ee74b1a68c6caf02cd062b14b3c59dcd24` 上的 20 项定向核心合同均通过；生产源码无差异。
  - 两个旧 U1 runner 的过期 Capsule 与 D 默认断言经最小测试预期/路由修正后通过；生产代码未改。
  - Debug 构建通过；没有可证明完整隔离的产品 UI harness，因此未启动 App。真人 1–6 项均为 `USER_VERIFICATION_REQUIRED / NOT_RUN`；A0 真实捕获仍为 `USER_VERIFICATION_REQUIRED / NOT_RUN`。
  - V1 不标记 `M1_READY`。Planner 定向复审无剩余 Blocker / 必要 Relevant；必要真人验收仍待完成。
  - Evidence：[V1 core integrity verification](evidence/core-integrity/V1-core-integrity-verification.md)；逐项输出：[V1 contracts](evidence/core-integrity/V1-core-integrity-contracts.txt)
- **Nightly follow-up — AUTOMATED_VERIFIED / USER_PENDING**
  - 基于 V1 源码增加新曲自动搜索候选的 timing-quality 仲裁：先保留 SafeMatcher 身份/自动门槛，再按匹配质量、有效 word spans、行级 timing、provider/candidate 配置顺序选择；preferred/locked 仍优先。自动选择合同和临时 SQLite session/关闭重开合同通过。
  - Playback timer 抑制相同时间值的重复发布；桌面 timed Ruby geometry 使用 512-entry bounded cache。此为局部重复工作的源码/合同修正，没有隔离 SwiftUI 性能实测，因此不声称用户可见卡顿已解决。
  - 新增自动搜索关闭回归：切歌后仍先恢复已持久化的 preferred/locked 歌词，不调用 Provider、不写回；无缓存时明确解释自动搜索关闭并保留手动搜索入口。S1 全合同与最终 V1 聚合 20/20 通过。
  - Debug 构建通过。改动文件无新增编译警告；既有 AVFoundation、Sendable/actor isolation、Keychain deprecation 等警告及 AppIntents metadata skip 见 evidence。
  - 最新 production commit：`c51ef5df298630128569e8b1c7b41fe5408eaff6`（前一 Nightly production commit `137be01c86434afc6e80dc688e1ed9e435abe11e`）。Candidate App：`/tmp/spotifylyrics-nightly-final-deriveddata-20260923/Build/Products/Debug/SpotifyLyrics.app`；executable SHA-256 `09d3001314f07c835f6032848e9f6d668ec9c13d648fa6acb39b15ce36523856`。未启动。
  - 无完整独立 App 数据配置：候选与正式安装版使用相同 bundle ID、标准 defaults、Application Support SQLite/本地歌词/Provenance 路径；可能沿用播放器连接及用户已保存的 auto-capture / auto-translation 开关。因此没有在当前用户环境启动；完整边界和恢复方案见 evidence。
  - V1/Nightly 真人验收仍为 `USER_VERIFICATION_REQUIRED / NOT_RUN`；不标记 `M1_READY`。production commit 已普通推送；当前证据与状态更新为单独的文档提交。
  - Evidence：[Nightly automatic selection and stutter](evidence/core-integrity/Nightly-auto-lyrics-selection-stutter.md)；原始 V1 聚合：[Nightly contracts](evidence/core-integrity/Nightly-auto-lyrics-selection-stutter-contracts.txt)；最终源码聚合：[final Nightly contracts](evidence/core-integrity/Nightly-auto-lyrics-selection-stutter-final-contracts.txt)

`NATIVE_INPUT_PENDING` 不是 PASS，也不表示 B0 发现的产品缺陷已经修复。

## B0 Confirmed Facts

- production clock：`presentation = raw anchor + elapsed + offset`，最后 clamp。
- `+offset` = 歌词提前出现；`-offset` = 歌词延后出现。
- 当前 offset 按 canonical track key + 持久 lyrics version UUID 存在 `lyrics.presentationOffset.scoped.v1.*`；旧 `lyrics.presentationOffset.v1` 保留为未分配历史值，不参与运行时偏移。
- C1 后 V3 transport seconds / progress / slider value 使用 playback-domain time；歌词行与逐字 fill 继续使用 presentation time。
- mouse / drag pointer mapping 属 raw domain。
- keyboard / AX slider callback 现在从 playback-domain value 开始并提交 raw seek target。
- 调 offset 本身不会直接 provider seek。
- paused offset subscriber 现在使用 publisher 发出的新 offset 立即重算歌词 projection；transport 不变且不 seek。
- Fullscreen 复用 V3。
- search preview lyric-row 使用 identity guard；preview B 不得 seek live A，同一 live identity 仍允许。
- native mouse / keyboard / AX 外部事件本轮未在真实 AppKit host 中运行，保留 `NATIVE_INPUT_PARTIAL`。

## A0 Confirmed Facts

- Automatic live capture now accepts only explicit ready Spotify Desktop provenance; Apple Music, unknown, mock/preview, unavailable, and no-identity contexts fail closed before Spotify discovery.
- Source, track identity, and generation are carried through startup and final adoption checks; a source/track change during asynchronous startup stops the request and cannot adopt a late result.
- ScreenCaptureKit samples carry active stream/session generation; segment boundaries invalidate and drain queued callbacks before the next segment can receive samples.
- Automatic alignment requires a newly advanced coordinator generation and an exactly generation-matched handoff; it cannot reuse an older `lastPartialReport`.
- Local-file alignment remains independent of live capture and is not disabled by an active Music source.
- The automatic switch remains opt-in and Release-reachable. Real ScreenCaptureKit/Spotify/Music capture was not run; user verification remains `USER_VERIFICATION_REQUIRED / NOT_RUN`.
- Release 的自动对齐链会调用 partial-alignment 与 speech engine；已修正误称其为 Debug-only 的源码注释。实时捕获会临时写入本机 WAV 分段，正常任务结束时清理并在启动时尝试清理残留；设置仍默认关闭。真实捕获、权限流程和外部播放器均未运行。

详见 [A0 evidence](evidence/core-integrity/A0-capture-source-containment.md)；本页不复制完整运行输出。

## H1 Confirmed Facts

- provider/version `contentHash` 继续只承担版本记录与去重身份；既有算法和固定预期未改变。
- translation/reading/timing/editor compare-and-save 使用从 canonical stored `lyric_lines` 计算的 `sourceContentHash`。
- 可编辑版本的 `document` 可能已叠加 timing 或 locked reading；H1 不从该显示投影反算规范源身份。
- 首次打开、provider A → B → A、manual 选择、正确身份保存、保存后继续加载、错误身份拒绝/no-write 与迟到异步结果均已通过临时 SQLite 自动合同。
- repository `sourceContentMismatch` 防线保留；无 schema 迁移、历史 hash 重算或用户数据库访问。
- 真人“切 provider 版本后小修改保存”未运行，保持 `USER_VERIFICATION_REQUIRED / NOT_RUN`。

详见 [H1 evidence](evidence/core-integrity/H1-hash-domain-boundary.md)。

## T1 Confirmed Facts

- partial unsynchronized mask、有效零秒、占位行和行结束时间贯穿 repository → session → editor draft；model/session/draft 保留 `nil` 与空集合区别，SQLite 对无 timed row 的现有映射为 `nil`。
- 旧 locked-reading overlay 仍生效，同时原文、行时间、timed spans、performer、language、translation projection、同版本 timing attachment UUID 与 canonical source hash 保留。
- editor draft 内切换同一歌词版本的译文只改变译文文本；锁定读音、逐字 spans、performer/language、attachment UUID 与规范源身份保持一致。
- 重复加载与切换 session/editor 版本未改变隔离 fixture 的任何数据库表或 `data_version`；无 schema 或用户数据变更。
- 新版本保存是否继续 timing attachment 属 T2，本轮未处理。真人验收保持 `USER_VERIFICATION_REQUIRED / NOT_RUN`。

详见 [T1 evidence](evidence/core-integrity/T1-read-projection-fidelity.md)。

## T2 Confirmed Facts

- Editor copy 与 library revision 均把仍兼容的真实 spans 写入子版本自己的新 timing attachment；attachment 在同一事务中写入，绑定子版本和其 canonical source hash，父版本/父 attachment 保持不变。
- TTML/YRC 真实解析 fixture 经保存、关闭原 helper scope、重新打开 SQLite 后，spans、行时间、语言、performer（有值时）、部分时间轴 mask、renderer input 和 locked-reading layer 按各 fixture 保留。
- 原文或行时间使部分 spans 失配时，编辑器与 library revision 在写入前给出损失数量；取消不写入，确认后只保存兼容余量。只改译文继续通过 translation layer，不新增歌词版本或 timing attachment。
- timing payload 现在须通过文本、UTF-16 范围与时间约束校验，损坏 attachment 不参与自动 word-timing 优先级；用户 preferred/locked 版本优先级保持不变。
- attachment 插入注入失败会回滚子版本、attachment、选择更新及同事务内容。无 schema 迁移或历史 attachment 改写。
- T2 真人体验验收保持 `USER_VERIFICATION_REQUIRED / NOT_RUN`。

详见 [T2 evidence](evidence/core-integrity/T2-lossless-editing-timing.md)。

## S1 Confirmed Facts

- 人工采用候选使用独立于自动匹配的显式持久路径；自动保存的低置信拒绝门槛保持不变，provider/source/provenance/confidence 与独立身份声明原值保留并校验。
- 候选资产、必要 timing attachment 与 preferred 当前版本在同一 SQLite 事务提交；只有事务返回持久版本 ID/hash 后 session 才发布当前状态。关闭/重开数据库和新 session 后，confidence 0 与 0.5 的人工选择均恢复为同一当前版本。
- 锁定版本先返回明确冲突；取消无写入，确认时事务重新读取锁集合，确认后更改 preferred 而保留旧锁标记。事务注入失败、repository rejected/skipped 与异常均不改变当前成功状态或原选择。
- 带真实 spans 的重复采用复用版本及 attachment 身份；从已加载父版本创建副本时分配子版本自己的 attachment ID，父 attachment 归属不变。A→B 迟到保存只写回 A，同曲新请求覆盖旧请求。
- 自动验收保持 `USER_VERIFICATION_REQUIRED / NOT_RUN`；真人低置信候选采用后重启恢复尚未执行。

详见 [S1 evidence](evidence/core-integrity/S1-durable-manual-adoption.md)。

## O1 Confirmed Facts

- Live scope uses the session's persistent lyrics-version UUID only after the live track identity matches. The repository validates version ownership and resolves existing track redirects before the canonical track key + version UUID pair can activate.
- A/v1, A/v2 and B/v1 retain independent UserDefaults values across switching and a recreated store/session. New versions start at zero; unknown versions, unsaved drafts, mismatched ownership and unresolved editor identities fail closed.
- The editor resolves its selected saved version through the same repository boundary. Redirect-family records may retain a raw historical `trackStableKey`; O1 never uses that alias as the offset key. Dirty/stale/new editor drafts disable writes with an explanation.
- Main V3, fullscreen, floating desktop and settings share the scoped store/control; Capsule continues to consume the common live line projection. No production consumer uses the old global value as an offset.
- The old global value remains unchanged and unassigned. The scoped write changed no SQLite `data_version`; the ownership resolver is read-only. Offset changes still affect presentation time only and do not seek or change the playback-domain clock.
- Automated contracts and Debug build passed. Planner found the editor's asynchronously resolved saved-version scope could leave the offset text field at its initial `0.00`; commit `69c922b` syncs the field when its explicit scope changes. Follow-up review found no remaining Blocker / necessary Relevant. Real window/player experience remains `USER_VERIFICATION_REQUIRED / NOT_RUN`.

详见 [O1 evidence](evidence/core-integrity/O1-scoped-lyrics-offset.md)。

## R1 Confirmed Facts

- 整行读音修改以保存的 `readingText` 为准。文本变化时，该行旧 tokens 整体失效；无可靠逐词映射时不猜位置、不显示旧 inline Ruby，独立读音与 romaji 从新 `readingText` 投影。`readingText` 未变时保留正确 tokens；未改行保留原 tokens。
- 持久读音版本只把范围完整、文本对应且可重建 kana 的 token map 用于投影。SQLite 保存拒绝所有来源的冲突非空 kana/token 组合；明确空 token fallback 合法，加载历史冲突只在返回投影中失效 tokens，不重写历史数据。
- 手工保存先核验歌词版本与规范源 hash，取消并等待旧生成，再保存并采用持久子版本后发布当前状态。旧版本与歌曲作用域的点击纠音词典保持不变；延迟生成不能覆盖新人工读音。
- 临时 SQLite 合同确认原文、规范 hash、timing attachment identity、逐字 spans、行/结束时间、translation、performer、language 及 provider 元数据保留；加载/投影前后的 `PRAGMA data_version` 相同。
- R1 定向合同、受影响的 H1/T1/T2 与读音/Ruby 合同、Debug 构建均通过。真人 V3 切换/重启/点击纠音检查仍为 `USER_VERIFICATION_REQUIRED / NOT_RUN`。

详见 [R1 evidence](evidence/core-integrity/R1-reading-token-consistency.md)。

## U1 Confirmed Facts

- Classic immersive split 的 Favorite/More 空操作入口已移除；Direction D 行菜单保留发现与关闭行为，未实现的三项禁用并说明原因。D inspector 保留真实歌曲信息和导航，移除固定“当前/完成”假状态及空历史/操作入口。
- Direction D 的搜索、Settings 与 TXT 编辑路径按实际路由工作；没有 SwiftUI presentation route 的 Debug AppKit host 会禁用对应动作，TXT guard 在准备前返回。取消/失败不打开 editor，成功准备后打开一次。
- D inspector / small sheet 的歌曲摘要由真实播放或 mock-preview 状态决定：没有活动曲目显示“等待歌曲”，活动曲目没有标题时显示“歌曲标题未知”，已知标题原样保留；Debug product host 的 inspector 和 sheet 传递 adapter 的真实歌曲元数据。
- Capsule、AI translation、automatic alignment 与 local-file alignment 保留真实行为，并在相应入口标记具体实验边界。A0 Spotify Desktop 来源门控与 local-file alignment 独立性不变。
- V3 默认、可解析的 Classic / Direction D 布局与用户保存偏好未重置。该批不涉及数据库、歌词资产、用户词典、offset store 或 schema。
- U1 定向合同、受影响 D 3.4/layout/Capsule 合同及 Debug 构建通过。两个既存 runner 分别因过期的 Capsule 当前版本断言、D 默认布局断言失败，未计为通过；D/Classic 交互 smoke 和真人验收为 `USER_VERIFICATION_REQUIRED / NOT_RUN`。
- Planner 首轮发现的必要 Relevant 已在 `a33e9a1` 修复，U1 当时的最终复审无剩余 Blocker / 必要 Relevant。随后 V1 在同一候选源码上完成自动验收；其当前结论与真人待验状态见下方 V1 记录。

详见 [U1 evidence](evidence/core-integrity/U1-honest-experimental-ui.md)。

详见 [B0 evidence](evidence/core-integrity/B0-clock-offset.md)；本页只保留结论，不复制运行输出。

## Open Core Risks

以下项目仍按当前 Master Plan / batch ownership 作为未关闭核心项；自动合同通过不替代 V1 的必要真人验收：

- V1/Nightly 必要真人验收 1–6 尚未完成；候选数据与现有用户环境未隔离，阻止 `M1_READY`，当前为 `USER_PENDING`。
- 新曲自动搜索中 word-timed provider 的真实在线候选结果未在 UI 人工确认；网络返回具有不确定性。自动选择排序已有生产逻辑与隔离合同证据。
- 切行卡顿的实际用户影响和 Nightly 局部优化效果未在真实 UI 中测量；不得从代码缓存/纯数据合同推断真人体验已通过。

## Known Test Drift

- `Tests/fullscreen_lyrics_contract.sh`：静态 literal assertion 与现实现别名写法漂移；本轮未重跑该脚本，当前 C1 clock / V3 / Fullscreen 共享路径由 V1 合同 01、03 覆盖。该 runner 不记作当前候选 PASS。

## Source-of-Truth Rules

1. 当前用户指令 / 已授权 Batch 决定“现在做什么”。
2. cwd / worktree / HEAD / source 决定“实际改哪份代码”。
3. tag + GitHub Release metadata 决定“发布了什么”。
4. 运行证据 / 精确源码链决定“行为如何”。
5. `docs/STATUS.md` 决定“当前工程推进状态”。
6. Obsidian 保存长期决定、用户体验反馈、项目索引和当前阶段指针；不复制完整工程状态数据库。
7. archive / preview / `.local` / 历史 Agent 报告不能覆盖当前 HEAD。

## Next Executor Contract

**Nightly follow-up — AUTOMATED_VERIFIED / USER_PENDING**
当前候选在 V1 的 U1 源码链上；latest production commit `c51ef5df298630128569e8b1c7b41fe5408eaff6`，分支 `codex/nightly-auto-lyrics-stutter`。自动搜索关闭时仍恢复持久 preferred/locked 歌词且不查询 Provider；无缓存时提示原因并保留手动搜索。新曲 timing-quality selection、临时数据库重开、clock/tick、Floating/V3 合同及最终 V1 聚合 20/20 通过；task-specific Debug build 通过。候选 App：`/tmp/spotifylyrics-nightly-final-deriveddata-20260923/Build/Products/Debug/SpotifyLyrics.app`，未启动。相同 bundle ID 导致 defaults、SQLite、local lyrics 与 provenance 共用；当前用户的自动连接/capture/AI 设置未读取，且无完整 isolation configuration。卡顿无 runtime 性能测量；低置信 provider 人工流程及 V1 六项均为 `USER_VERIFICATION_REQUIRED / NOT_RUN`。优先在 dedicated macOS test account 完成真人验收，再由 Planner 定向审查；不得标记 `M1_READY`。
