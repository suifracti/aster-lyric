# Spotify Lyrics｜仓库状态参考（不是当前交接）

> 自 2026-10-12 起，**当前施工任务与产品路线只在 Obsidian**：`03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md` → 当前唯一活动任务；长期规则在 `Decisions.md`。本页不维护“唯一滚动工程状态”或下一位执行者。原 18 KB 历史状态全文已保留在 [迁移前快照](archive/status-before-obsidian-handoff-20261012.md)，其旧任务不得恢复。

## 源码、附件和执行者如何查

- 当前源码与未提交差异：实际 Mac 工作树和 `git status` / `git rev-parse HEAD`；`main` SHA 会随文档提交变化，不代表程序功能升级。
- 实机截图、候选 App/ZIP 与脱敏日志：Obsidian `03-项目与工程/Spotify Lyrics/资料与附件.md` 指向 [已有私有 Google Drive](https://drive.google.com/drive/folders/1cm5KnwoYn82b7R61YrXvYiCfXHE37BEs)；没有上传即没有可用附件。
- 项目当前唯一状态：Obsidian `Handoff.md`；禁用从本仓库状态、历史报告或已关闭 GitHub Issue/PR 直接选择下一阶段。

## 已知的不同证据截点（非本轮新验收）

- 此次文档修改前，2026-10-12 GitHub `main` 合流源码 SHA 为 `d90c8ee2f57c51670f4e7ac2d66c1c6d02829853`，包含原合并分支成果及 V3 环境光两处微调。
- Sol A 曾报告某隔离候选下，GIJIKOI 日语原曲 `0ZLWH8kZv299eRlEoMelAD` 的 52 行中文保存、退出重开复用且无新增请求；自动选词/切行、定向合同和 Debug 构建证据另属不同情景。**不能合成一个最新正式 App 的全部 PASS**。
- 截至该事实截点，三种 V3 与菜单栏、桌面、全屏的最终原生中文体验尚待真实用户确认，安装 App 与数据库身份亦需区分。
- [Issue #30（关闭）](https://github.com/suifracti/lyricsQ/issues/30) 与 [Issue #33（历史执行证据）](https://github.com/suifracti/lyricsQ/issues/33) 不再担任规划／当前任务主源。

## 正式发布身份

- 2026-10-12 核实的最后正式 GitHub Release 为 [v0.1.2](https://github.com/suifracti/lyricsQ/releases/tag/v0.1.2)，发布提交 `6528be3103f75fd4f63757855b9d61cd30f757d8`；签名/公证边界依该 Release 的实际资产记录，不把文档提交当新发行。
- 原生 SwiftUI/AppKit 工程保留 V3 `ambient/stage/classic`、菜单栏/Popover、桌面/全屏与歌词、翻译、读音、SQLite 能力；旧 V1/V10/Capsule 兼容代码不代表当前新增需求。代码入口存在不等于最终实机已验证。

## 历史保留

- [旧 STATUS 全文](archive/status-before-obsidian-handoff-20261012.md)：各历史批次、风险、下一执行合同、源身份均仅供追溯。
- [仓库 AI 入口](../AGENTS.md) · [必要开发流程](DEVELOPMENT_WORKFLOW.md) · [必要提交核对](SUBMISSION_BASELINE.md)。

**本文件不规定新的开发任务或自动 Git／模型／正式资产操作权限。**
