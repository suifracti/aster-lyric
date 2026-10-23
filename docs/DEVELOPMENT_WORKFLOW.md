# Spotify Lyrics｜轻量开发参考

> 这份文件只指导现有原生工程的安全操作，**不是另一份计划或任务清单**。先读 Obsidian Vault `03-项目与工程/Spotify Lyrics/README.md` → `Handoff.md`（唯一当前活动任务）→ 必要时 `Decisions.md`（长期约束）。

## 本机工作树

- 原常用项目根为 `/Users/apple/backup/sptifylyrics`，但实际活动树可能不同，进入用户当前选择的工作树后读 `git status --short`、`git branch --show-current`、`git rev-parse HEAD` 和 `git diff --stat`。
- 保护已有 dirty/untracked、旧树和正式资产。不要默认新开临时 worktree，不执行清理／重置／覆盖式 checkout/pull。`.local/`、DerivedData、旧 ZIP、历史截图不等于当前源码或 App。
- 使用既有 `SpotifyLyrics/` Swift/SwiftUI/AppKit、`SpotifyLyrics.xcodeproj/`、`Tests/`、`Scripts/`、`Tools/`。旧 `generate_xcodeproj.py` 不能因普通小改动自动执行。

## 最少的编译和运行

- 输入不变的已通过测试直接复用；若可用现成对应二进制，优先实机看效果，否则只做必要构建。文档变更不编译 Xcode。
- 实机运行的 Debug 构建（Keychain ACL 与 TCC 授权依赖稳定的 Apple Development 身份）：
```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics \
  -configuration Debug \
  -derivedDataPath build/DerivedData build
```
  Debug 配置固定使用 `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = "Apple Development"`，由本机现有开发证书签名；Team 与证书不进仓库。不要为了“免签名”加 `CODE_SIGNING_ALLOWED=NO`：那会退回 ad-hoc，每次构建换一次 cdhash，钥匙串 ACL 与 TCC 授权都会失效。
- 只做编译检查时可用 unsigned 构建，但它不能用来验证钥匙串、自动化或截图权限。
- 只运行受影响的定向检查、真实用户要看的 App 画面；普通编译错误在已授权任务内修复，不把每个失败变成新增 Issue/PR/审计。
- 翻译请求、业务 Keychain、正式 SQLite、用户播放状态、`/Applications` 安装覆盖、数据迁移不因“轻量测试”自动允许。

## 版本、提交和发布

- GitHub `origin/main` 是共同代码主源。依用户 2026-10-13 明确决定，修改结束后默认审查、提交并普通推送到 `main`，读回远端确认；当前任务明确禁止提交推送时才例外，并注明 `NOT_SYNCED`。默认不新建分支、PR、Issue；不得 force push。Drive 存附件，Obsidian 存交接；覆盖正式 App/数据库、模型费用和发布仍需对应授权。
- 同步在本项目已经得到用户的持续明确授权；每轮只提交已审核的本轮成果，普通推送到已有main，网络/并发更新导致非快进拒绝就停止核对，不能force。明确不提交的单轮任务保留dirty并报告未同步。不要因为某次任务的临时限制，重新废止用户的长期同步要求。
- 在 Obsidian 当前任务页报告实际运行的源码、App/Bundle、数据目录、编译与体验范围；本机打包且需要共享时，附件放到既有 Google Drive，并回写实际链接。

## 历史与事实

- GitHub `docs/evidence/`、`docs/archive/`、`docs/superpowers/`、旧 PR/Issue 仅供查证过去发生了什么。`docs/STATUS.md` 是静态仓库参考，不含下一执行命令。
- 未被重新实测的模式、歌词质量、切行、数据迁移不能因为本轮修了代码或文件就升级为 PASS。

**一个活动任务做完并更新 Handoff，才推进下一项。**

## 每轮开始和结束的最小核对

开始先运行：
```sh
git status --short
git branch --show-current
git rev-parse HEAD
git fetch origin
git merge-base --is-ancestor origin/main HEAD
```
最后一项失败说明当前基线未包含远端更新；网络失败也不能用旧origin缓存冒充最新。先核清差异，保护dirty；安全快进只在不覆盖现有修改时使用，不恢复旧整文件。已有正在进行的授权dirty可以继续同一任务，不能擅自舍弃。

完成并审查/验证后，在现有活动M1工作树用 `git push origin HEAD:main` 普通同步，不另开分支/PR。推送成功后通过GitHub API或 `git ls-remote origin refs/heads/main` 确认远端SHA与本地HEAD一致，并检查状态清洁。明确禁止推送时写清NOT_SYNCED与差异，下一轮不能误认同步已完成。

源码提交、编译候选和正式安装是三件事。安装包需有源码提交/输入清单对应；缺记录就写身份未确认，不凭文件日期、版本号或二进制SHA差异推断先后。UI/模型/正式数据验收未做时保留NOT_RUN。
