# D0 — Documentation Source of Truth + Narrow Obsidian Sync

日期：2026-09-22
状态：`D0_CLOSED`
项目根：`/Users/apple/backup/sptifylyrics`

本轮只做 repository 文档收口、B0 evidence 版本化和 Spotify Lyrics Obsidian 窄同步。不修改 `SpotifyLyrics/` 生产源码，不进入 C1，不连接正式 App、Spotify/Music、SQLite、AI、录音或 Keychain。

## 1. Source identity 与初始状态

本轮开始前的产品/发布基线：

```text
branch: main
source/product baseline HEAD: 6528be3103f75fd4f63757855b9d61cd30f757d8
release: v0.1.2
upstream: origin/main at the same baseline
```

B0 交付结束时已核对的既存 untracked 文件为：

```text
PROJECT_FULL_AUDIT_2026-09-22.md
PROJECT_FULL_AUDIT_ASTRA_2026-09-22.md
PROJECT_FULL_AUDIT_GROK47_2026-09-22.md
Tests/b0_clock_offset_truth_contract.sh
Tests/b0_clock_offset_truth_contract.swift
docs/evidence/core-integrity/B0-clock-offset.md
```

这些文件没有被删除、覆盖或恢复旧版本。为了遵守规划技能的持久化要求，本轮中间临时创建了 `task_plan.md`、`findings.md`、`progress.md`；它们是 agent scratch，未进入 D0 提交，交付前已删除。

## 2. Repository 修改

### README

`README.md` 已收敛为稳定产品入口：

- 将当前正式身份改为 GitHub formal Release `v0.1.2`。
- 下载链接改为正式 `v0.1.2` Release，不再把 `preview.1` 当当前版本。
- 保留 release commit、资产、平台和签名/公证边界的准确说明。
- 添加并突出 `docs/STATUS.md` 当前状态入口。
- 将 V3/fullscreen、透明桌面 v2/menu bar、Direction D/Capsule、legacy 路径标为对应维护边界。
- 明确 AI、自动排轴和 Capsule 等入口仍是 experimental / unverified，不把代码入口写成稳定支持。
- 移除 README 中的完整 Feature Matrix 和详细风险/历史状态表，避免形成第二份工程数据库。

### `docs/STATUS.md`

已重写为短的唯一滚动工程状态页，包含：

- Source Identity：repo root、branch、B0/v0.1.2 产品基线、release identity、更新时间和 tracked/staged 边界。
- Product Boundary：Core、Supported Secondary、Experimental、Legacy、无 iOS target。
- Current Milestone：`M1 — macOS Core Integrity Baseline`。
- Batch State：B0 `CLOSED / BASELINE_CHARACTERIZED / NATIVE_INPUT_PENDING`，D0 `CLOSED`，下一项唯一为 C1。
- B0 Confirmed Facts 的短摘要和 B0 evidence 链接。
- 未关闭的 Open Core Risks、Known Test Drift、Source-of-Truth Rules、Next Executor Contract。

`NATIVE_INPUT_PENDING` 没有被写成 PASS；B0 发现的缺陷也没有被写成已修复。

### B0 evidence 版本化

以下 B0 内容保持已执行语义与结论不变；仅清理提交时的 Markdown 尾随空格，作为以后可重跑的 core-integrity evidence 纳入 D0 提交：

- `Tests/b0_clock_offset_truth_contract.sh`
- `Tests/b0_clock_offset_truth_contract.swift`
- `docs/evidence/core-integrity/B0-clock-offset.md`

没有修改 B0 测试语义来隐藏旧测试的错误用户语义。三份 `PROJECT_FULL_AUDIT_*.md` 没有纳入提交，继续保持 untracked。

## 3. Narrow Obsidian sync

结果：`SYNCED`

重新按当前 Obsidian 路由定位到：

```text
/Users/apple/backup/obsidian/03-项目与工程/Spotify Lyrics/README.md
/Users/apple/backup/obsidian/03-项目与工程/Spotify Lyrics/Handoff.md
/Users/apple/backup/obsidian/03-项目与工程/Spotify Lyrics/Decisions.md
```

写入前已核对三份文件的 SHA-256，没有发现并发修改；只修改了这三个 Spotify Lyrics 项目文件，没有移动其它项目、历史笔记、Archive、全库索引或模板。

同步内容：

- README：加入 repository `docs/STATUS.md`、M1、B0 结论、D0 当前指针和 C1 下一项；注明详细运行证据以 repository evidence 为准。
- Handoff：加入当前阶段索引、B0 `NATIVE_INPUT_PENDING`、D0 已完成和 C1 next；保留已有用户验收/反馈与历史上下文。
- Decisions：把“按歌曲/歌词版本保存 offset”明确为目标交互，而不是当前实现事实；补充 B0 已确认当前仍是 global key、O1 未关闭，并链接 repository evidence。

Obsidian 没有复制测试输出、完整 B0 报告或完整工程状态数据库。

## 4. 验证命令与结果

文档层最小验证：

```text
rg -n -i 'preview\.1|不是正式发布版|不是正式版|预发布测试版' README.md docs/STATUS.md
  -> no matches, exit 1 from rg; guarded check overall exit 0

test -f docs/STATUS.md
test -f docs/evidence/core-integrity/B0-clock-offset.md
test -f LICENSE
  -> exit 0

git diff --check
  -> exit 0

git diff --name-only -- SpotifyLyrics
git diff --cached --name-only -- SpotifyLyrics
  -> empty; production source diff = zero
```

已检查的新增 repository 文档目标在提交前均存在；D0 不需要运行产品测试或 Debug build。B0 runtime/source verification 沿用已交付的 B0 结果，不因文档改动重复运行全量测试。

## 5. 最终边界与提交

- 生产源码 `SpotifyLyrics/` diff：zero。
- 没有修 offset sign、seek、transport clock、paused subscriber、hash、timing、editor、candidate、reading、capture、provider 或 performance。
- 没有运行正式 App、Spotify/Music、正式 SQLite、AI、录音或全量 Tests。
- 本轮只做一个本地 D0 文档提交；禁止 push、PR、merge、tag、release。
- 最终 commit SHA 以提交完成后实际 `git rev-parse HEAD` 输出为准；本报告与该提交中的文档共同交付。

## 6. Next

只交给下一执行者：

**C1 — Playback / Presentation Semantic Isolation**
等待 Planner 下发合同；D0 不展开实现方案。
