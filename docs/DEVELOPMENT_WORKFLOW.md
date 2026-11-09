# Aster · Lyric｜轻量开发参考

本页只指导现有原生工程操作，不维护任务或另一套协作规则。先读 [AGENTS](../AGENTS.md)、[相关规格](TOOLBAR_BEHAVIOR.md) 与 [项目记忆](PROJECT_MEMORY.md)。Vault 的私人反馈按实际授权读取，不把历史 Handoff 当独立滚动计划。

## 本机工作树

沿用户当前指定的活动树，不依据旧登记路径另建工程。先检查 `git status --short`、`git branch --show-current`、`git rev-parse HEAD`、`git diff --stat`，再 fetch 并比较远端。获取失败或基线未包含远端时先核差异，保护 dirty/untracked；不 reset、clean、覆盖式 checkout/pull 或自动 stash。

复用 `SpotifyLyrics/`、`SpotifyLyrics.xcodeproj/`、`Tests/`、`Scripts/`、`Tools/`。普通小改不运行旧 `generate_xcodeproj.py`，不默认另开 worktree。`.local/`、DerivedData、ZIP 和截图不是源码身份。

## 必要构建与签名

文档变更不编译 Xcode。相关输入与条件未变的已有通过证据可以复用；需要构建时只做必要检查。用于实际运行、Keychain ACL/TCC 的 Debug 构建必须核稳定签名：

```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics \
  -configuration Debug \
  -derivedDataPath build/DerivedData build
```

Debug 签名只由 `SpotifyLyrics/Config/DebugSigning*.xcconfig` 决定，工程不写死证书或 Team。默认无身份，保持其他 checkout/CI 行为；需要稳定身份的机器在 gitignored `DebugSigning.local.xcconfig` 设置 `CODE_SIGN_STYLE = Manual`、`CODE_SIGN_IDENTITY = Apple Development` 和 `DEVELOPMENT_TEAM`。

实机验证钥匙串时不加 `CODE_SIGNING_ALLOWED=NO`：ad-hoc 构建的 cdhash 变化会影响 ACL/TCC。unsigned 构建只能证明相应编译，不能验证钥匙串、自动化或截图权限。本次文档没有修改签名配置，也不证明某台机器已配置。

只运行受影响的定向检查。业务 Keychain、正式 SQLite、模型费用、播放状态、正式安装覆盖与迁移仍需对应授权。原生图与 `Scripts/ui-snapshots.sh` 离屏图明确区分；无法完成的范围写 NOT_RUN。

## 同步与交付

现有持续授权允许相关成果普通提交/推送到已有 main；单轮明确禁止时例外。不要默认创建 PR/分支、强推或遗漏他人改动；具体核对见 [SUBMISSION_BASELINE](SUBMISSION_BASELINE.md)。

任务结果更新所属规格/当前任务，新的有效经验更新原记忆条目，私人体验回 Vault 原项目页；需要共享的附件沿已有私有位置。源码提交、候选构建和正式安装分别识别，不能由一个 SHA 或旧截图拼成完整成功。

旧 PR/Issue、`docs/evidence/`、`docs/archive/`、`docs/superpowers/` 和有日期的报告只作历史证据。用户已授权连续工作时按有意义的小批次推进，不因旧文档的逐步审批阻断，也不自动恢复未授权的历史任务。
