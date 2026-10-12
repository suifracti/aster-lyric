# Spotify Lyrics｜必要提交与交付核对

> **只在用户确实授权 commit/push 或交付 App 时使用。** 本文件不能创建任务、强制开分支/PR、自动 checkpoint 或恢复旧审批流程。先读 Obsidian `03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md` → 当前任务，再按 `Decisions.md` 保留数据与费用边界。

## 核对

```sh
git status --short
git branch --show-current
git rev-parse HEAD
git diff --stat
```

- 实际源码版本是当前 HEAD（若脏树则为 `base HEAD + 未提交差异`）；实际运行 `.app`、数据目录、正式 Release 需独立识别。
- 只能包括本轮授权文件，不能覆盖 dirty/untracked，也不能公开凭据、OAuth、正式 SQLite、受限制歌词/音频或私有日志。
- 代码修改做最少必要编译与受影响检查；仅文档修改验证文字、链接与导航，无须为了文档重跑整个 Mac App。
- App 视觉只据真实前台窗口和同曲已采用译文判断，不能以截图缩略图或旧 PR 结论代替。没有新验证写 NOT_RUN。

## Git 操作只按授权

- 文件附件继续用 Google Drive；GitHub 只管理源码、发布信息与历史证据。默认不建新分支、PR、Issue，不自动 commit/push、改 main、覆盖正式 App/库或发起模型请求；具体动作按用户本轮许可。
- 如当轮明确授权提交/推送：先审核具体 diff 与目标分支，执行 `git diff --check`，只暂存指定路径，再做明确许可的 commit / push；**不隐含更新 main、重写历史或创建 PR**。
- 执行后读回 GitHub 实际 commit SHA、修改文件列表；Git 文档已更新 ≠ Mac App 已同步/安装。

## 文件交接

- 任务结果只回写 Obsidian `03-项目与工程/Spotify Lyrics/Handoff.md` 与对应任务页；成果文件交给 [原有私有 Google Drive](https://drive.google.com/drive/folders/1cm5KnwoYn82b7R61YrXvYiCfXHE37BEs)，上传成功才登记链接。
- 本文件不维护独立下一步或历史执行名单；完整旧状态留 [STATUS 归档](archive/status-before-obsidian-handoff-20261012.md)。
