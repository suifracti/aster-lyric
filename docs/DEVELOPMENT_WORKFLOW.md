# Spotify Lyrics｜轻量开发参考

> 这份文件只指导现有原生工程的安全操作，**不是另一份计划或任务清单**。先读 Obsidian Vault `03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md`（唯一当前活动任务）→ 必要时 `Decisions.md`（长期约束）。

## 本机工作树

- 原常用项目根为 `/Users/apple/backup/sptifylyrics`，但实际活动树可能不同，进入用户当前选择的工作树后读 `git status --short`、`git branch --show-current`、`git rev-parse HEAD` 和 `git diff --stat`。
- 保护已有 dirty/untracked、旧树和正式资产。不要默认新开临时 worktree，不执行清理／重置／覆盖式 checkout/pull。`.local/`、DerivedData、旧 ZIP、历史截图不等于当前源码或 App。
- 使用既有 `SpotifyLyrics/` Swift/SwiftUI/AppKit、`SpotifyLyrics.xcodeproj/`、`Tests/`、`Scripts/`、`Tools/`。旧 `generate_xcodeproj.py` 不能因普通小改动自动执行。

## 最少的编译和运行

- 输入不变的已通过测试直接复用；若可用现成对应二进制，优先实机看效果，否则只做必要构建。文档变更不编译 Xcode。
- 参考 unsigned Debug 构建（确实需要时才执行）：
```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/lyricsq-deriveddata build
```
- 只运行受影响的定向检查、真实用户要看的 App 画面；普通编译错误在已授权任务内修复，不把每个失败变成新增 Issue/PR/审计。
- 翻译请求、业务 Keychain、正式 SQLite、用户播放状态、`/Applications` 安装覆盖、数据迁移不因“轻量测试”自动允许。

## 版本、提交和发布

- 文件附件继续用 Google Drive；GitHub 只管理源码、发布信息与历史证据。默认不建新分支、PR、Issue，不自动 commit/push、改 main、覆盖正式 App/库或发起模型请求；具体动作按用户本轮许可。
- Git 写入若被本轮用户明确授权：限定仓库、分支和文件范围，先看 diff 与敏感数据，再按授权 commit/push；不依历史“每次小阶段必须 push”或“重大修改先 push checkpoint”执行。
- 在 Obsidian 当前任务页报告实际运行的源码、App/Bundle、数据目录、编译与体验范围；本机打包且需要共享时，附件放到既有 Google Drive，并回写实际链接。

## 历史与事实

- GitHub `docs/evidence/`、`docs/archive/`、`docs/superpowers/`、旧 PR/Issue 仅供查证过去发生了什么。`docs/STATUS.md` 是静态仓库参考，不含下一执行命令。
- 未被重新实测的模式、歌词质量、切行、数据迁移不能因为本轮修了代码或文件就升级为 PASS。

**一个活动任务做完并更新 Handoff，才推进下一项。**
