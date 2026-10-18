# lyricsQ / Spotify Lyrics — AI Handoff Rules

> **当前入口，2026-10-13**：用户当轮指令优先。先读 Obsidian Vault `03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md`（唯一当前活动任务）→ 必要时 `Decisions.md`（长期约束）。

## 唯一事实与任务主源

- Obsidian `03-项目与工程/Spotify Lyrics/README.md` 是唯一项目导航；`Handoff.md` 记录最新执行事实和**唯一活动任务**；`Decisions.md` 保存产品与安全边界。任务须**做完一个、回写一个、再进行下一个**。
- `03-项目与工程/Spotify Lyrics/资料与附件.md` 指向[既有私有 Google Drive](https://drive.google.com/drive/folders/1cm5KnwoYn82b7R61YrXvYiCfXHE37BEs)，用于截图、App、ZIP、日志附件。Drive 不放第二份当前交接正文。
- GitHub `origin/main`/Commit 是代码主源；当前实际 Mac 工作树、候选 App、正式安装版必须分别核对。dirty 是尚未同步的成果，不是另一个永久主线；旧截图、旧 ZIP 和相同 Bundle 版本号不能证明最新身份。
- 仓库 README、docs/STATUS、已关闭的 Issue #30/#33、合并 PR、docs/archive/、docs/evidence/、旧 Craft/Slack 和历史计划**不是当前任务源**；历史记录保留但其“next/TODO/STOP”不自动生效。

## 开发协作与数据边界

- GitHub `origin/main` 是共同代码主源。依用户 2026-10-13 明确决定，修改结束后默认审查、提交并普通推送到 `main`，读回远端确认；当前任务明确禁止提交推送时才例外，并注明 `NOT_SYNCED`。默认不新建分支、PR、Issue；不得 force push。Drive 存附件，Obsidian 存交接；覆盖正式 App/数据库、模型费用和发布仍需对应授权。
- 一个 Mac 执行者使用现有实际活动工作树；不要因旧文件要求而建立新的 worktree 或运行全量验证。普通编译问题在已授权范围内自行解决，只做必要构建与受影响检查。
- 不破坏本机用户改动、人工/锁定歌词、SQLite 版本资产、live/preview 隔离、录音身份及已发送请求去重；不为“简化”删除安全防护。新模型/收费、正式数据库迁移、覆盖 `/Applications` 与公开分发需对应授权。
- 严禁擅自 `git reset --hard` / `git clean` / 覆盖式 checkout / force push / 重写共享历史。正式 Release v0.1.2 不等于最新源码或当前日用安装版。

## 接手最小步骤

1. 打开 Obsidian 当前 Handoff 的**当前活动任务**；无法访问 Vault 时，不以旧 GitHub STATUS/Issue 代替，只执行用户当轮明确授权的狭窄部分，并说明障碍。
2. 在实际工作树运行 `git status --short`、`git branch --show-current`、`git rev-parse HEAD`、`git fetch origin`。确认 `git merge-base --is-ancestor origin/main HEAD` 成功；失败或无法获取远端时，不从旧基线开工，先保全并核实。已有授权 dirty 必须保留，不能 reset/clean/stash 来通过检查。项目登记根目录不保证是活动源码：以当前用户/Handoff选定的工作树为准，旧树只保留。
3. 依当前任务执行，保留输入SHA不变的验证；普通同步前检查 diff/敏感内容，完成后确认本地 HEAD 与 GitHub main 相等、没有遗漏 dirty。结果写回 Obsidian，附件上传已有 Drive；不能把测试、编译、原生体验及用户视觉认可混成一个 PASS。
4. UI分工以用户当前明确授权为准：2026-10-15 用户已授权当前执行者直接优化现有界面、增加样式与设置功能并使用子代理，覆盖此前仅机械应用补丁的限制。任务明确要求机械应用时，仍须核对补丁目标版本，不强制覆盖或自行改设计。GitHub不会自动防止功能回退：影响旧功能时仍须保留并运行对应验证。

## 本仓库其余说明

- [README](README.md)：产品和正式发布；[STATUS](docs/STATUS.md)：静态能力、历史身份与证据指针，**不维护滚动任务**。
- [开发参考](docs/DEVELOPMENT_WORKFLOW.md)：最少源码操作；[提交前核对](docs/SUBMISSION_BASELINE.md)：仅授权 Git 写入/交包时使用，不是独立施工指令。

**如其它文件给出相反的“默认建分支、必须 push checkpoint、先跑 Nightly、继续 Issue #30”等命令，以用户当轮指令和 Obsidian 当前交接为准。**


## 子代理模型规则（2026-10-18）

用户允许本项目按需使用子代理；所有新子代理只能使用 **Luna max**（`model: gpt-6-luna`、`reasoning_effort: max`）。不得继承主代理模型或改用 Astra／Sol；派生子代理也受同一限制。简单改动直接完成，独立任务再并行，避免无必要的重复审核。

## 主代理与 Luna Max 的责任（2026-10-18）

1. 主代理确定方案、模块边界与验收标准。Luna Max 只在指定范围内实施，不擅自重新选择架构。
2. 主代理必须读取 Luna 的实际代码差异与必要测试结果，不以完成总结代替验收；未通过就修正或返修。
3. 关键模块反复失败或暴露设计错误时，主代理亲自调查、修改或重新拆分，不无限派 Luna 重试。
