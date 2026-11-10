# Aster · Lyric｜轻量开发参考

本页只指导现有原生工程操作，不维护任务或另一套协作规则。先读 [AGENTS](../AGENTS.md)、[相关规格](TOOLBAR_BEHAVIOR.md) 与 [项目记忆](PROJECT_MEMORY.md)。Vault 的私人反馈按实际授权读取，不把历史 Handoff 当独立滚动计划。

## 1 原生工程入口

工作现场规则继承 [AGENTS](../AGENTS.md)。沿用 `SpotifyLyrics/`、`SpotifyLyrics.xcodeproj/`、`Tests/`、`Scripts/`、`Tools/`；普通小改不运行旧 `generate_xcodeproj.py`。

## 2 构建与稳定签名

构建触发与验证范围见 AGENTS。用于实际运行、Keychain ACL/TCC 的 Debug 构建必须核稳定签名：

```sh
xcodebuild -project SpotifyLyrics.xcodeproj -scheme SpotifyLyrics \
  -configuration Debug \
  -derivedDataPath build/DerivedData build
```

Debug 签名只由 `SpotifyLyrics/Config/DebugSigning*.xcconfig` 决定，工程不写死证书或 Team。默认无身份，保持其他 checkout/CI 行为；需要稳定身份的机器在 gitignored `DebugSigning.local.xcconfig` 设置 `CODE_SIGN_STYLE = Manual`、`CODE_SIGN_IDENTITY = Apple Development` 和 `DEVELOPMENT_TEAM`。

实机验证钥匙串时不加 `CODE_SIGNING_ALLOWED=NO`：ad-hoc 构建的 cdhash 变化会影响 ACL/TCC。unsigned 构建只能证明相应编译，不能验证钥匙串、自动化或截图权限。本次文档没有修改签名配置，也不证明某台机器已配置。

业务数据与真实应用操作范围见 AGENTS。截图工具使用 `Scripts/ui-snapshots.sh`，离屏结果按实际范围说明。

## 3 同步入口

提交授权与项目主源分工见 [AGENTS](../AGENTS.md)，日常收尾继承 Vault 根总规则“3.4 收尾清单”。
