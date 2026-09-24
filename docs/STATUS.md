# Spotify Lyrics Current Status

状态页最后更新：2026-09-25。
这是 repository 的唯一滚动工程状态入口；详细运行证据保留在 `docs/evidence/`，不在本页复制完整审计。

文档链：`README.md` → `docs/STATUS.md` → 具体 evidence / batch report / 已授权计划。

## Source Identity

- repo root：`/Users/apple/backup/sptifylyrics`
- branch：`codex/a0-capture-source-verification`（从包含 A0 的本地 `main` 后续核对分支建立；未配置 upstream、未推送）
- A0 follow-up production commit：`1f5389854dc63907cc79cf24ec46c4d549a787f3` (`fix: clarify automatic capture source and audio handling`)
- A0 原验证 production commit：`e775f39702361dff9dba7894e746927c660c257b` (`fix: bind capture handoff to active source generation`)
- release identity：正式 GitHub Release `v0.1.2`，release commit `6528be3103f75fd4f63757855b9d61cd30f757d8`
- status last updated：`2026-09-25`
- tracked/staged 状态：A0 production 与定向 contracts 已在本地提交；A0 evidence/STATUS 文档提交后 tracked/staged diff 应为零。三份既有 `PROJECT_FULL_AUDIT_*.md` 保持 untracked，不纳入 A0 提交。精确 checkout 仍以 `git rev-parse HEAD` 为准；文档提交不改变上述已验证 production commit 身份。

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
- **Next**：H1 — Hash Domain Boundary Repair

`NATIVE_INPUT_PENDING` 不是 PASS，也不表示 B0 发现的产品缺陷已经修复。

## B0 Confirmed Facts

- production clock：`presentation = raw anchor + elapsed + offset`，最后 clamp。
- `+offset` = 歌词提前出现；`-offset` = 歌词延后出现。
- 当前 offset 使用 global key `lyrics.presentationOffset.v1`。
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

详见 [B0 evidence](evidence/core-integrity/B0-clock-offset.md)；本页只保留结论，不复制运行输出。

## Open Core Risks

以下项目仍按当前 Master Plan / batch ownership 作为未关闭核心项；A0 本轮不判断它们已修复：

- H1 hash domain
- T1 read/projection fidelity
- T2 lossless edit/timing
- S1 manual adoption persistence
- O1 scoped offset
- R1 reading token consistency
- U1 honest experimental UI
- V1 M1 gate

## Known Test Drift

- `Tests/fullscreen_lyrics_contract.sh`：静态 literal assertion 与现实现别名写法漂移；不是 C1 clock failure，本轮未为此扩展修复。

## Source-of-Truth Rules

1. 当前用户指令 / 已授权 Batch 决定“现在做什么”。
2. cwd / worktree / HEAD / source 决定“实际改哪份代码”。
3. tag + GitHub Release metadata 决定“发布了什么”。
4. 运行证据 / 精确源码链决定“行为如何”。
5. `docs/STATUS.md` 决定“当前工程推进状态”。
6. Obsidian 保存长期决定、用户体验反馈、项目索引和当前阶段指针；不复制完整工程状态数据库。
7. archive / preview / `.local` / 历史 Agent 报告不能覆盖当前 HEAD。

## Next Executor Contract

**H1 — Hash Domain Boundary Repair**
等待 Planner 下发合同；A0 已结案，本轮不提前执行 H1。
