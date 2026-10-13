# Spotify Lyrics｜必要提交与交付核对

> **用户已授权每次修改后同步GitHub，明确禁止同步的单轮任务除外；交付App的正式安装仍另行核授权。** 本文件不能创建任务、强制开分支/PR、自动 checkpoint 或恢复旧审批流程。先读 Obsidian `03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md` → 当前任务，再按 `Decisions.md` 保留数据与费用边界。

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

- GitHub `origin/main` 是共同代码主源。依用户 2026-10-13 明确决定，修改结束后默认审查、提交并普通推送到 `main`，读回远端确认；当前任务明确禁止提交推送时才例外，并注明 `NOT_SYNCED`。默认不新建分支、PR、Issue；不得 force push。Drive 存附件，Obsidian 存交接；覆盖正式 App/数据库、模型费用和发布仍需对应授权。
- 先审核 diff、目标main和敏感内容，执行 `git diff --check`，只暂存明确路径，再普通commit/push到main；不重写历史、不创建PR。推送前获取远端并确认它是当前HEAD祖先；若失败，保护现场后核对，禁止覆盖式拉取/force。
- 执行后读回 GitHub 实际 commit SHA、修改文件列表；Git 文档已更新 ≠ Mac App 已同步/安装。

## 文件交接

- 任务结果只回写 Obsidian `03-项目与工程/Spotify Lyrics/Handoff.md` 与对应任务页；成果文件交给 [原有私有 Google Drive](https://drive.google.com/drive/folders/1cm5KnwoYn82b7R61YrXvYiCfXHE37BEs)，上传成功才登记链接。
- 本文件不维护独立下一步或历史执行名单；完整旧状态留 [STATUS 归档](archive/status-before-obsidian-handoff-20261012.md)。

**完成同步的判据**：本地HEAD = 从GitHub实际读回的main SHA；工作树没有遗漏成果；本轮影响的检查有真实结果。仅commit未push、上传Drive源码ZIP或打包App都不等于同步完成。
