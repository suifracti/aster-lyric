# Aster · Lyric 项目补充

继承：先读用户已授权的 Obsidian Vault 根 `AGENTS.md`（通过现有连接器或客户端入口定位），按其中的层级章节接手。本文件只维护项目身份、主源和补充要求；总规则不可达时说明缺口，依据当前用户指令与已读项目资料继续可做部分。

## 1 项目身份与主源

Aster · Lyric、星弦、lyricsQ、Spotify Lyrics 属于同一项目。仓库为 `suifracti/aster-lyric`，协作分支 main。

- 产品/UI 与阶段规格：[TOOLBAR_BEHAVIOR](docs/TOOLBAR_BEHAVIOR.md)。
- 技术经验与覆盖：[PROJECT_MEMORY](docs/PROJECT_MEMORY.md)的场景索引及相关条目。
- [STATUS](docs/STATUS.md)为有日期的历史状态；当前任务结合产品规格、最新完成证据与用户目标。
- Vault 项目 README 导航，《项目总览》提供规划、经验、当前接续摘要；Handoff 保存阶段体验，Decisions 保留决定沿革。
- 构建签名与本机操作：[DEVELOPMENT_WORKFLOW](docs/DEVELOPMENT_WORKFLOW.md)；同步参考：[SUBMISSION_BASELINE](docs/SUBMISSION_BASELINE.md)。

## 2 产品与数据补充

保护人工/锁定歌词、SQLite 版本资产、旧 rawID、live/preview 隔离、录音身份与已发送请求去重。Bundle ID、正式 Application Support 数据库路径、UserDefaults 键、Keychain 条目不随更名或 UI 重构变化。

保留已定环境光、羽化、经典模糊和用户手选数据；UI 简化用折叠入口保留功能。没有新的设计授权时沿用已定 UI。

业务 Keychain、正式数据库迁移、覆盖正式 App、付费模型调用、改变用户播放状态和公开分发按对应授权处理。

## 3 现场、展示与同步补充

沿用用户指定的活动 Mac 工作树。展示优先真实 App；截图接口失败可用 `Scripts/ui-snapshots.sh` 离屏图并注明。必要用户实机观察合并一份清单；性能证据注明歌曲、窗口、播放/暂停与构建条件。

已有持续授权：相关成果自检后普通 commit/push 到现有 main 并读回；用户明确禁止本轮同步时遵从。原始性能 JSON、大截图和日志按需放既有私有附件位置，用户明确要求的 README 图按其范围处理。

## 4 协作引用

模型、代理、记忆联动、验证和全周期复盘继承总规则；旧固定 Terra/max 和日期角色名单退出当前约束。实际权限仍按当前助手和本项目授权，历史设计任务不自动恢复。
