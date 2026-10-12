# lyricsQ / Spotify Lyrics — AI Handoff Rules

> **当前入口，2026-10-12**：用户当轮指令优先。先读 Obsidian Vault `03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md`（唯一当前活动任务）→ 必要时 `Decisions.md`（长期约束）。

## 唯一事实与任务主源

- Obsidian `03-项目与工程/Spotify Lyrics/README.md` 是唯一项目导航；`Handoff.md` 记录最新执行事实和**唯一活动任务**；`Decisions.md` 保存产品与安全边界。任务须**做完一个、回写一个、再进行下一个**。
- `03-项目与工程/Spotify Lyrics/资料与附件.md` 指向[既有私有 Google Drive](https://drive.google.com/drive/folders/1cm5KnwoYn82b7R61YrXvYiCfXHE37BEs)，用于截图、App、ZIP、日志附件。Drive 不放第二份当前交接正文。
- GitHub `main`/Commit 用于源码身份；当前实际 Mac 工作树可能含未提交修改，必须以本地状态与运行的 `.app`/数据目录核对，不凭旧截图或旧 Bundle 版本号判定。
- 仓库 README、docs/STATUS、已关闭的 Issue #30/#33、合并 PR、docs/archive/、docs/evidence/、旧 Craft/Slack 和历史计划**不是当前任务源**；历史记录保留但其“next/TODO/STOP”不自动生效。

## 开发协作与数据边界

- 文件附件继续用 Google Drive；GitHub 只管理源码、发布信息与历史证据。默认不建新分支、PR、Issue，不自动 commit/push、改 main、覆盖正式 App/库或发起模型请求；具体动作按用户本轮许可。
- 一个 Mac 执行者使用现有实际活动工作树；不要因旧文件要求而建立新的 worktree 或运行全量验证。普通编译问题在已授权范围内自行解决，只做必要构建与受影响检查。
- 不破坏本机用户改动、人工/锁定歌词、SQLite 版本资产、live/preview 隔离、录音身份及已发送请求去重；不为“简化”删除安全防护。新模型/收费、正式数据库迁移、覆盖 `/Applications` 与公开分发需对应授权。
- 严禁擅自 `git reset --hard` / `git clean` / 覆盖式 checkout / force push / 重写共享历史。正式 Release v0.1.2 不等于最新源码或当前日用安装版。

## 接手最小步骤

1. 打开 Obsidian 当前 Handoff 的**当前活动任务**；无法访问 Vault 时，不以旧 GitHub STATUS/Issue 代替，只执行用户当轮明确授权的狭窄部分，并说明障碍。
2. 在实际工作树运行 `git status --short`、`git branch --show-current`、`git rev-parse HEAD`，保护 dirty/untracked，明确实际 App 和 SQLite 来源。
3. 依当前任务运行／微调，保留已通过且输入不变的旧验证；结果写回 Obsidian 任务页与 Handoff，必要附件上传既有 Drive 再登记真实链接。

## 本仓库其余说明

- [README](README.md)：产品和正式发布；[STATUS](docs/STATUS.md)：静态能力、历史身份与证据指针，**不维护滚动任务**。
- [开发参考](docs/DEVELOPMENT_WORKFLOW.md)：最少源码操作；[提交前核对](docs/SUBMISSION_BASELINE.md)：仅授权 Git 写入/交包时使用，不是独立施工指令。

**如其它文件给出相反的“默认建分支、必须 push checkpoint、先跑 Nightly、继续 Issue #30”等命令，以用户当轮指令和 Obsidian 当前交接为准。**
