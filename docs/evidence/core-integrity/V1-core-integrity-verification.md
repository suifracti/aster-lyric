# V1 — M1 Core Integrity Verification

- **结论：** `AUTOMATED_VERIFIED / USER_PENDING`
- **禁止外推：** 必要真人验收尚未完成；本报告不标记 `M1_READY`。
- **项目根：** `/Users/apple/backup/sptifylyrics`
- **隔离 worktree：** `/private/tmp/spotifylyrics-v1-core-integrity-verification`
- **分支：** `codex/v1-core-integrity-verification`
- **生产源码身份：** U1 最终 HEAD `d75789ee74b1a68c6caf02cd062b14b3c59dcd24`，其中最新生产提交为 `a33e9a160a413f928429fa976fc071f5e3f5fe27`。
- **基线关系：** H1 `449df0a6446dd01f250ff84eec34ff87efccf70d`、T1 `2963f710c85e0993963d0127514791ee6a19196f`、T2 `40cc1b57fd3a20345d292a5be0f9304f9d5df06d`、S1 `e566bbf51d1389e0279f0ba0412fa344bb449ac2`、O1 `69c922b37331bf42be7b00494d9ba2f0f5dda3f7`、R1 `bad730103632cedeb852bffec0836745879ce109` / 后续合同 `63498bc9e9a4f53474fe87577092513c1ea92f97` 及 U1 均在候选祖先链；逐项 `merge-base --is-ancestor` 检查退出码均为 0。
- **对照边界：** V1 生产路径没有修改；`git diff d75789e -- SpotifyLyrics` 为空。V1 仅增加聚合 runner、校正两个旧合同的过期预期及更新证据/状态文档。

## 基线与保护

U1 worktree 在开始时为干净状态，分支 `codex/u1-honest-experimental-ui` 的 HEAD 与其 upstream 均为 `d75789ee74b1a68c6caf02cd062b14b3c59dcd24`。新分支从该精确 SHA 建立，未从正式根的 H1 checkout、旧 `main` 或 v0.1.2 包取源码。V1 可回退检查点 `de7230c` 已提交并推送。

正式根仍是 `codex/h1-hash-domain-boundary` / `c062cfe371a2fcab3b1569888a6da35646627f0e`，未修改。U1 worktree 未修改。三份既有 `PROJECT_FULL_AUDIT_*.md` 报告未加入 V1 worktree、未暂存、未提交。

生产文件保持与 U1 源码一致。合同实际运行时的测试工作树包含以下变更，其 SHA-256 用于精确识别本次测试输入：

| 测试文件 | SHA-256 |
| --- | --- |
| `Tests/run_core_integrity.sh` | `0930449d32256513528948b2fa7a242fa61f52901c122ab79279a0135fd8dfb0` |
| `Tests/experience_library_contract.sh` | `7b0e25edc434c8f360d03cf47d55cf8c1a588abfbccbd4b68ad63e9158a8fa90` |
| `Tests/experience_library_contract.swift` | `3c23198e8b856c9659512f8733f18994eaf5f45756d67e6b99637c39781c1faa` |
| `Tests/direction_d_phase_3_3_contracts.sh` | `a07e1ffadba2b6e64bf827be58969fa41f09311e781c1920b0e675cc5171043c` |

当前 Obsidian `README.md` / `Handoff.md` 在执行前均指向 U1、V1 待验收；`Decisions.md` 的长期决定未要求改动。完成时仅更新 README 与 Handoff 的阶段指针，保留 Decisions 原文。

## B0—U1 证据矩阵

历史合同通过只代表其证据中列明的旧源码。本轮另在同一个 U1 生产源码候选上运行右栏所列合同。

| 批次 | 历史验证范围与原生产身份 | 原证据 | 当前候选重跑 | 仍未运行的真人 / 外部项 |
| --- | --- | --- | --- | --- |
| B0 | 在 v0.1.2 基线 `6528be3103f75fd4f63757855b9d61cd30f757d8` 描述 offset、时钟与 seek 输入事实；B0 是基线刻画，不代表当时全部行为正确。 | [B0](B0-clock-offset.md) | B0 clock / paused subscriber（合同 01） | 原生 mouse / keyboard / AX 与真实播放器输入由人工验收 1 覆盖。 |
| D0 | 文档 SOT 收敛；基于 `6528be3103f75fd4f63757855b9d61cd30f757d8` 的 docs-only 批次，无产品行为合同。 | [D0](D0-documentation-sot.md) | 不适用；V1 读取当前 README、Decisions、Handoff 与 STATUS。 | 无独立产品人验。 |
| C1 | 生产提交 `b95ebd1636ff0d8e847390f608886e18484a30a9`；offset 方向、presentation/playback 时钟域、暂停更新、V3/Fullscreen seek 与 preview identity。 | [C1](C1-playback-presentation-isolation.md) | B0 clock、C1 offset、V3 draft、raw pointer、preview identity（合同 01–05） | 原生输入和真实外部播放器仍由人工验收 1 覆盖。 |
| A0 | 生产提交 `e775f39702361dff9dba7894e746927c660c257b`；live capture source gate 与 source/track/generation 失效。 | [A0](A0-capture-source-containment.md) | A0 source / track / generation containment（合同 06） | 真实 Spotify/Music ScreenCaptureKit capture 继续 `USER_VERIFICATION_REQUIRED / NOT_RUN`；本轮不执行。 |
| H1 | 生产提交 `449df0a6446dd01f250ff84eec34ff87efccf70d`；规范源 hash 与显示 projection 分离、错误 hash 拒绝。 | [H1](H1-hash-domain-boundary.md) | H1 temporary SQLite canonical hash 合同（合同 07） | 真人 provider 版本切换后编辑保存并入人工验收 3。 |
| T1 | 生产提交 `2963f710c85e0993963d0127514791ee6a19196f`；partial mask、旧 locked-reading overlay、翻译切换时字段保真。 | [T1](T1-read-projection-fidelity.md) | T1 `all`（合同 08） | 与实际 partial fixture、锁定读音层共同进入人工验收 3。 |
| T2 | 生产提交 `40cc1b57fd3a20345d292a5be0f9304f9d5df06d`；editor/library 两入口保存重开、attachment 所有权与失败回滚。 | [T2](T2-lossless-editing-timing.md) | T2 `all`（合同 09） | 真人无损副本与不兼容编辑取消由人工验收 3 覆盖。 |
| S1 | 生产提交 `e566bbf51d1389e0279f0ba0412fa344bb449ac2`；低置信人工采用、持久选择、锁定、事务及异步归属。 | [S1](S1-durable-manual-adoption.md) | S1 `all`（合同 10） | 低置信采用重启和锁定取消由人工验收 4 覆盖。 |
| O1 | 最新生产提交 `69c922b37331bf42be7b00494d9ba2f0f5dda3f7`；歌曲/持久版本 scope、旧 global 保留、重启与 editor 异步 scope。 | [O1](O1-scoped-lyrics-offset.md) | O1 scoped offset 合同（合同 11），并由 C1 合同检查 clock/no-seek。 | scope 切换、跨窗口、重启和 editor 旧值由人工验收 2 覆盖。 |
| R1 | 生产提交 `bad730103632cedeb852bffec0836745879ce109`，数据库重开 / 选择合同 follow-up `63498bc9e9a4f53474fe87577092513c1ea92f97`；整行读音与 token、Ruby/romaji、点击纠音。 | [R1](R1-reading-token-consistency.md) | R1 `all` 与 click-correction 回归（合同 12–13） | V3 inline/独立/fullscreen/romaji/重启由人工验收 5 覆盖。 |
| U1 | 最新生产提交 `a33e9a160a413f928429fa976fc071f5e3f5fe27`；空操作不假成功、D 状态映射、实验说明与布局偏好。 | [U1](U1-honest-experimental-ui.md) | U1、Experience Library、selection store、Phase 3.3、D state/layout、layout compatibility（合同 14–20） | D / Classic 入口辨识和布局偏好由人工验收 6 覆盖。 |

## 两个已知失败 runner：复现、分类与修正

### Experience Library Capsule 断言

修正前在当前候选执行 `bash Tests/experience_library_contract.sh` 退出 `1`，原始断言为：

```text
FAIL: control-focused v2 must remain the current capsule
```

生产目录实际将 `capsule.controlFocused.v2` 标为 `.classic`、`.release`、可预览；`capsule.dynamicIslandDark.v4` 是 `.current`、`.release`。`PresentationSelectionStore.currentStableID(for:)` 在没有保存选择时取 catalog 当前可运行项，因此 v4 是默认当前项；明确保存 v2 时仍会使用可运行的 v2。Capsule 窗口通过该持久 selection store 读取版本。此事实与当前 STATUS 的“Capsule 为实验维护级别”并不冲突：整体维护级别不是某个版本的当前选择。

校正模型断言后，runner 继续暴露第二个未到达的旧设置路由断言并再次退出 `1`：它要求 `ForEach(SettingsCategory.allCases.filter { $0 != .experienceLibrary })` 与 `onOpenExperienceLibrary`。当前真实 Settings 路由已使用 `SettingsCategory.primaryCases` 隐藏侧栏一级入口，在“深入体验”按钮调用 `onOpenTool(.experienceLibrary)`，再由 `SettingsDetailView` 设置 selection 并创建 `ExperienceLibrarySettingsView(selectionStore: settings.presentationSelections)`。新增的合同逐段验证这条实际路由，同时断言体验库不在 primary sidebar；未删除入口，也未改生产代码。最终 `bash Tests/experience_library_contract.sh` 退出 `0`，输出 catalog、selection route 和 source contract 均 PASS。

**分类：过时测试预期 / runner 源路由漂移，不是产品回归。** 依据为当前实际 catalog、selection store、Settings 路由和现有 U1/Capsule 生产合同；早期失败完整保留在上面的记录，修正后结果见合同 15。

### Phase 3.3 Direction D 默认布局断言

修正前当前候选输出 `PASS=33 FAIL=1`，退出 `1`：

```text
[FAIL] no_d_default_layout — Direction D must not be MainWindowLayoutStyle
PASS=33 FAIL=1
```

实际 `MainWindowLayoutStyle` 有独立 `.directionDV4`，而 `AppSettingsStore` 对未设置布局的 fallback 明确是 `.appleMusicImmersiveV3.rawValue`。D 的目录身份标为 `.experimental`，且进入可选布局列表；这是可选实验布局，不是默认布局。当前 STATUS / U1 evidence 保留 V3 默认、D 可解析并可由用户选择的决定。

仅将失败断言替换为检查“无偏好时 fallback 为 V3，D 仍是显式可选项”。没有修改生产默认或删除 D。最终 runner 输出 `PASS=34 FAIL=0`，退出 `0`；Phase 3.4 layout recovery 与 main-window layout fusion 也分别通过。

**分类：过时测试预期，非产品回归。** Phase 3.3 runner 内部的 `priority_behavior` 是 Python mirror resolver，不视作生产运行证据；实际 D track-summary mapping / 导入取消与成功分支由 U1 合同编译并运行生产纯数据逻辑，D 的生产身份和布局恢复由其它合同检查。

### 相关历史 runner 边界

- B0 记录的 `Tests/v3_seek_draft_contract.py` fake 缺少生产 `presentationClock` 接口；C1 随后更新合同并通过。本轮合同 03 在当前候选再次通过，包含 Fullscreen shared-V3 路径。
- `Tests/fullscreen_lyrics_contract.sh` 仍是 STATUS 标记的静态字面量别名漂移。本轮没有重跑该宽泛静态脚本；C1 合同 01 与 03 已验证实际 clock / V3 / Fullscreen 路径，故不将旧字面量断言当成当前产品失败或 PASS。
- A0 历史 `apple_music_provider_contract.sh` 在本机因 `/System/Applications/Music.app` 不存在退出 `133`。本轮没有启动/依赖 Music.app；来源与 generation 门控合同 06 在临时 fixture 通过。真实 provider/capture 仍是上面明确的 `NOT_RUN`。

## 当前候选自动合同

聚合入口为本轮新增的 `bash Tests/run_core_integrity.sh`。未发现已有单一入口覆盖这些不重叠批次，因此只编排经检查可隔离执行的 20 项合同；逐项运行、打印 PASS/FAIL，任一失败会令总命令非零，必需合同缺失也不能产生成功结果。完整逐项输出、临时路径和合同内部诊断保存在 [V1 contract output](V1-core-integrity-contracts.txt)。

| # | 实际执行命令 | 退出码 | 核心覆盖 |
| --- | --- | ---: | --- |
| 01 | `bash Tests/b0_clock_offset_truth_contract.sh` | 0 | 生产 presentation clock、pause offset subscriber、共享路由和 no-seek。 |
| 02 | `bash Tests/c1_offset_semantics_contract.sh` | 0 | 正负 offset 的提前/延后语义及 subscriber/source route。 |
| 03 | `python3 Tests/v3_seek_draft_contract.py` | 0 | 生产 V3 seek draft/Coordinator 和 Fullscreen 共用路径。 |
| 04 | `python3 Tests/v3_seek_pointer_contract.py` | 0 | pointer → raw playback-domain seek mapping。 |
| 05 | `python3 Tests/c1_preview_seek_contract.py` | 0 | 跨 identity preview 拦截，same-live identity 保留。 |
| 06 | `bash Tests/a0_capture_source_containment_contract.sh` | 0 | source gate、track/source/generation 变化及迟到 capture/adopt 拒绝；不执行真实捕获。 |
| 07 | `bash Tests/h1_hash_domain_boundary_contract.sh` | 0 | canonical source hash、错误 hash mismatch 拒绝/no-write。 |
| 08 | `bash Tests/t1_read_projection_fidelity_contract.sh all` | 0 | partial mask、locked-reading overlay、翻译切换与字段保真。 |
| 09 | `bash Tests/t2_lossless_editing_timing_contract.sh all` | 0 | editor/library 保存重开、attachment 归属、取消/回滚。 |
| 10 | `bash Tests/s1_durable_manual_adoption_contract.sh all` | 0 | confidence 0/0.5、lock、失败事务和 stale result。 |
| 11 | `bash Tests/o1_scoped_lyrics_offset_contract.sh` | 0 | track/version scope、legacy global、重建 store、editor resolution / late callback。 |
| 12 | `bash Tests/r1_reading_token_consistency_contract.sh all` | 0 | line edit、token validation、三类投影、数据库重开和迟到生成。 |
| 13 | `bash Tests/ruby_correction_contract.sh` | 0 | 既有日文手工纠音 / token regression。 |
| 14 | `bash Tests/u1_honest_experimental_ui_contract.sh` | 0 | D/Classic 空操作、真实 TXT action、状态映射、Capsule/AI/alignment action 与实验边界。 |
| 15 | `bash Tests/experience_library_contract.sh` | 0 | 当前 Capsule catalog 与 Experience Library 实际 Settings 路由。 |
| 16 | `bash Tests/presentation_selection_store_contract.sh` | 0 | 临时 defaults 中 v4 默认、显式 v2、preview/apply 与重启恢复。 |
| 17 | `bash Tests/direction_d_phase_3_3_contracts.sh` | 0 | D host/adapter/router，V3 fallback 与 D 显式可选；34/34。 |
| 18 | `bash Tests/direction_d_phase_3_4_correctness_contracts.sh` | 0 | track change、late result、pause/product state 投影；22/22。 |
| 19 | `bash Tests/direction_d_phase_3_4_layout_recovery_contracts.sh` | 0 | D/V3 稳定 layout ID 与行 anchor recovery。 |
| 20 | `bash Tests/main_window_layout_fusion_contract.sh` | 0 | Classic/V3/D layout family、兼容身份和迁移。 |

最终汇总：`run=20 pass=20 fail=0`；`bash Tests/run_core_integrity.sh` 退出 `0`。没有 skip 项被计作通过。A0 real capture、手工 UI 和真实外部播放器不属于无头自动 runner，单独保持 `NOT_RUN`。

Fixture 隔离依据：C1 Python/Swift 合同使用临时编译目录；B0 使用唯一命名 defaults suite 和临时目录，且不打开数据库；H1/T1/T2/S1/O1/R1 使用合同建立的临时 SQLite，调试安全输出均为 `formal_database_opened=NO`（当前聚合日志 40 次该标记）；selection store 使用唯一 suite 并清理；其它 UI 源合同不启动 App。没有测试读写正式用户数据库、标准 defaults、真实播放进度或用户歌词资产。

## Debug 构建

执行命令：

```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics \
  -configuration Debug \
  -derivedDataPath /tmp/spotifylyrics-v1-core-integrity-deriveddata \
  CODE_SIGNING_ALLOWED=NO -quiet build
```

退出码 `0`，Build 成功。构建源码为 U1 production source `d75789ee74b1a68c6caf02cd062b14b3c59dcd24`；V1 未改生产源码。构建输出有 137 行重复 warning、21 条不同 warning、0 error。警告均在未修改文件：Swift 6 Sendable / actor 警告位于 `WhisperCLISpeechEngine.swift` 和 `WindowManager.swift`；其余为旧 macOS API 弃用、未使用或可改为 `let` 的局部变量。没有 V1 新引入的相关 warning。DerivedData 留在 `/tmp`，没有归档 `.app`。

## UI smoke 与真人验收边界

没有可证明安全隔离的产品 UI harness，因此 D/Classic 与 V3/Fullscreen/Desktop App UI smoke 为 `NOT_RUN`，没有启动 App。当前 Debug app 仍使用生产 bundle ID `com.spotifylyrics.app`；`AppSettingsStore` 默认 `UserDefaults.standard`，默认 `connectSpotifyOnLaunch == true`，SQLite 默认路径指向用户 `Library/Application Support/SpotifyLyrics/SpotifyLyrics.sqlite3`。`SPOTIFYLYRICS_DATABASE_PATH` 只覆盖 Debug SQLite 路径，D acceptance 环境变量只覆盖 adapter fixture，不会隔离 defaults、bundle identity 或自动连接。故仅给进程传环境变量不足以证明本轮 UI 操作不会碰正式 settings 或连接真实播放器。

以下是一次集中清单。所有项当前均为 `USER_VERIFICATION_REQUIRED / NOT_RUN`。只用可丢弃歌词、临时设置和隔离测试目录；不要在唯一原始歌词或正式用户库上做编辑。通过记录至少包含日期、待验收 app/build SHA、fixture ID、每项 PASS/FAIL/NOT_RUN 和可复核的截图或状态记录；遇到取消/失败分支时记录数据库保存前后状态。不要录音、启动自动捕获或调用 AI。

| # | 操作 | 预期 | 所需测试资产 | 记录方式 |
| --- | --- | --- | --- | --- |
| 1 | 暂停和播放时各调整歌词提前/延后；观察播放位置，再用鼠标拖动及必要的原生键盘/AX slider seek。 | 调 offset 只改变歌词展示；播放进度不因 offset 变化。拖动/输入 seek 仍落到预期真实播放位置。 | 可丢弃测试曲目及可重复控制的播放器；不使用 capture。 | 记录 offset 前后 raw 进度、歌词行与每类输入的目标结果；输入类型逐项标记。 |
| 2 | A/v1 → A/v2 → B/v1 → A/v1，跨主窗/全屏/桌面切换并重启；在 editor 明确打开已保存版本。 | pair 值互不串用，重启恢复；各窗口相同 pair 一致；editor 异步解析完成后显示存储值，不闪写/覆盖成 `0.00`。 | 临时库内 A/v1、A/v2、B/v1；三个明显不同的偏移值；孤立 defaults suite。 | 记录三 pair 值、窗口读取值和重启前后读数；确认 editor target version ID。 |
| 3 | 对同一可丢弃歌曲加载两个 provider 版本，再打开 editor 做无损修订/副本、保存、关闭并重开；辅助层切换；另对一份副本改原文或行时间，看到损失提示后取消。 | H1 正确版本身份可保存；T1 partial mask/locked reading/元数据在 session 与 draft 保持；T2 新副本的真实 spans/attachment 重开仍匹配。只改辅助层不无故建歌词版本。取消后数据库版本/attachment/选择不变；提示损失范围清楚。 | 有真实 TTML/YRC spans、重复文本、Unicode 边界、有效 0 秒与占位行的 fixture；含原始/第二 provider 版本、旧锁定读音及译文；可丢弃数据库。 | 记录选中版本 ID、span 值/时间、partial 行索引、attachment ID、辅助层切换前后字段；取消前后数据库行数/选择快照。 |
| 4 | 采用一个低置信候选，关闭并重启；对已有 locked current 触发另一候选的采用冲突并取消。 | 只在持久事务成功后显示当前采用；重启仍是同版本；取消锁定冲突保持原选择。 | 合法身份的 synthetic lyrics.ovh confidence 0 或 Kugou confidence 0.5 候选及独立临时锁定版本。 | 记录候选 source/provenance/confidence、持久 version ID、重启后当前项、取消前后选择。 |
| 5 | 在有手工 token 的日文测试行修改整行读音；切换独立读音/inline/fullscreen/romaji，保存重启后再点击词条纠音。 | 各投影一致采用新 readingText；无法映射时不出现旧 Ruby token；romaji 来自新读音；重启仍有效且点击纠音可用。 | 含重复词、局部修改、Unicode/组合字符边界的日文 fixture；手工词典项和可丢弃数据库。 | 记录每种投影文本、romaji 和手工纠音保存结果；以同一 fixture ID 对照重启前后。 |
| 6 | 用代表歌曲观察连续切行、长句；打开 D/Classic，检查行菜单、inspector 状态、实验说明，并恢复已保存的 V3/D/Classic 布局。 | 不出现假完成/当前状态；不可用操作有说明；真实操作仍可达；布局解析恢复且无明显缺项/崩溃。若切行卡顿复现，记录版本、界面、设置、操作和可用 trace，另立局部任务。 | 一首短行/长句 fixture；独立保存的 D/Classic/V3 布局偏好；无唯一原始资产。 | 逐项记录动作/状态/布局结果；若卡顿提供最小复现条件，不在 V1 内做性能改动。 |

真实 A0 capture、AI、自动排轴流程和 Capsule 实验全链路不是上述必要验收的一部分，本轮也未启动。

## 唯一剩余项与分类

| 项目 | 阻塞？ | 理由 / 证据 | 下一步 |
| --- | --- | --- | --- |
| 上表 1–6 必要真人验收 | **是，阻止 `M1_READY`；当前结论仍为 `USER_PENDING`。** | 自动证据无法替代真实播放器、原生输入、重启后的窗口体验与用户可理解性。各批次 `USER_VERIFICATION_REQUIRED / NOT_RUN` 尚未被用户结果关闭。 | Planner 定向审查完成后，使用隔离测试资产集中验收；每项记录结果。 |
| UI smoke 自动启动 | 否（已按明确隔离规则跳过） | 没有证明 bundle/defaults/DB/自动连接全隔离的产品 UI harness；Debug build 和 D fixture env 不是隔离证明。 | 不启动正式 App；若后续建成可证明隔离的 harness，再单独运行。 |
| A0 真实 capture | 否，本轮明确不要求 | gate/source/track/generation 自动合同通过；真机 capture 按用户边界保持 `USER_VERIFICATION_REQUIRED / NOT_RUN`，不因此扩大成 V1 blocker。 | 不强迫验收；只有用户以后要求真实 capture 时再单独授权。 |
| `fullscreen_lyrics_contract.sh` 旧字面量 drift | 否 | STATUS 已记录；当前 Fullscreen/V3 共享 seek 与 clock 路径合同通过。该旧静态 runner 未作为当前候选 PASS，也未重跑。 | 不新建开发项；需要清理测试漂移时另做小型 test-only 任务。 |
| A0 旧 `apple_music_provider_contract.sh` 环境退出 `133` | 否 | A0 原证据说明本机没有 `/System/Applications/Music.app`；本轮 source gate 合同通过，且未启动 Music。 | 保留 `NOT_RUN`/环境边界，不把缺失系统 App 伪装成 PASS。 |

没有发现需要当前修复的产品回归、数据完整性问题或未解释的核心合同失败。两个原 U1 runner 的静态预期现已按真实目录/路由最小校正并在候选通过；它们不再属于剩余问题。

## 生产与数据库边界、回滚

- 本轮无 `SpotifyLyrics/` 生产改动，无 schema、数据库、歌词资产、用户词典、UserDefaults 或 release 资产变更。
- SQLite 合同只对脚本生成的临时 fixture 数据库读写；40 条 DebugSafety 记录均为 `formal_database_opened=NO`。B0 clock fixture 标记 `databaseOpened=false`；持久选择合同使用临时命名 suite。未访问正式用户库或凭据。
- 未启动正式 App、播放器或 capture；未调用 AI；未运行 `generate_xcodeproj.py`；没有执行 reset、clean、覆盖或历史重写。
- 回滚范围为 V1 验证提交：移除聚合 runner、V1 evidence/status，以及三处测试预期修改即可回到 U1 文件状态。没有用户数据回滚。回滚测试修改会恢复两条已证实过时的断言和其失败；生产行为不受影响。Obsidian README/Handoff 阶段指针可恢复到 U1 待 V1 状态。

## 执行历史与下一步

- 初始 U1 候选两个失败按“修正前”记录；第一次 Experience Library 修正后再次触发旧 Settings 源表达式断言，按真实 route 最小改写合同后通过。所有修正均只改 Tests。
- `bash -n Tests/run_core_integrity.sh`、两个修改后 runner 的 `bash -n` 与 `git diff --check`：退出 `0`。
- 20 项 aggregate：退出 `0`；20 PASS、0 FAIL、无 skip。
- Debug build：退出 `0`；命令及 warnings 摘要见上文。
- Planner 定向只读复审确认聚合器、修正后的两个 U1 runner、生产源码边界及 USER_PENDING 结论无剩余 Blocker / 必要 Relevant；复审指出本节构建命令续行符格式需修正，已改为单反斜杠。没有启动真人/App 验证。本轮结论停在 `AUTOMATED_VERIFIED / USER_PENDING`，安排上述真人验收；不进入后续阶段。
