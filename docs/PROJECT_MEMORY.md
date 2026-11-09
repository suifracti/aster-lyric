# Aster · Lyric｜项目记忆

规则见 [AGENTS](../AGENTS.md)；规格继续维护在 [TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md)，不另建并列任务表。项目旧名 Spotify Lyrics / lyricsQ / Lyric Island 用于历史检索，不当成四个项目。

## 已有资产入口

- 工程：`SpotifyLyrics/`、`SpotifyLyrics.xcodeproj/`；既有检查 `Tests/`；脚本 `Scripts/`、`Tools/`。
- 工具栏行为：规格中的 `SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift`、`V3ToolbarPresentationTests` 与 `Tests/v3_toolbar_model_contract.sh` 是定位线索；核改动时仍需读当前实现。
- UI 离屏展示：`Scripts/ui-snapshots.sh`，不是用户 Mac 的真实操作证据。
- 当前操作/签名：[DEVELOPMENT_WORKFLOW](DEVELOPMENT_WORKFLOW.md)。历史版本核对：[STATUS](STATUS.md) 及其来源，旧通过只对原截点有效。
- 私人体验及历史决定在用户授权的 Vault 项目记录，公开仓库仅保存必要脱敏约束。

## L-001 外观和名称变化不能改掉数据身份

适用：项目更名、场景/工具栏重构、歌词库/翻译/预览调整。

依据：仓库既有 AGENTS 的正式资产保护，以及项目更名后的长期约束。保留 Bundle ID、数据库位置、UserDefaults/Keychain 身份、旧 rawID、人工/锁定版本、录音身份、live/preview 隔离和请求去重。更换 UI 实现不等于允许重置旧数据。

下次检查：先找已有持久化/会话与身份用例，按实际影响验证；本次只整理规则，未读全实现或使用正式数据库，因此不是新的功能 PASS。历史原因不足时保留未知，不编造迁移故事。

## L-002 图、构建、签名权限和真实体验分别取证

适用：截图失败、Debug 候选、性能对比、OAuth/Keychain 与“最新版”判断。

依据：既有开发参考区分 unsigned 编译与稳定 Apple Development 身份；截图脚本属于离屏展示。unsigned 构建成功不能验证 Keychain ACL/TCC；不同 cdhash、旧 Bundle 版本号或图片日期不能单独证明当前运行版本。

下次检查：记录实际源码/dirty、构建签名、App 路径及数据环境；性能记录歌曲、窗口和播放状态。复用适用证据，不为了文档打包或调用模型；没有实机条件写 NOT_RUN，不把视觉 fixture 当播放/缓存全链路通过。

## L-003 极简是保留能力、折叠入口

适用：减少控件、面板重排、快捷键/设置合并。

依据：[规格的设计原则](TOOLBAR_BEHAVIOR.md#design-principle-user-2026-10-21) 明确 folding, not cutting。先定位原有行为和入口，列出这次未冲突的保留项；新布局应能走原工作流，不能以更干净为由删除功能。以实际受影响行为验证，不用源码字符串数量或截图替代用户目标。

状态：以上三条是从现行规则/规格提取的要求和证据边界，不是本轮新运行结果，尚无新的用户体验确认。

## 增量与全周期

沿 AGENTS 的模式判断执行。重要事件当下记录现象/来源、原因确定程度、实际试过的取舍、实现与测试指针、版本/反馈和下次触发；同一问题更新原条目，旧结论遇反例可替代。已有能力状态或阶段任务只引用所属主源。

覆盖记录必须区分 refs 目录、正文、diff、运行与体验。相同 SHA 和等价成果去重，反馈无新提交也可更新；保存并读回前不前移游标。

## 本次覆盖

2026-11-10，读取截点 `main@78d600a14270837dd3fffa3359dee47179a2150b`：全文读取原 AGENTS、DEVELOPMENT_WORKFLOW、SUBMISSION_BASELINE、STATUS；读取 TOOLBAR_BEHAVIOR 前 85 行和 Vault 相关交接/入口。本次修正启动路由与重复规则，不改产品规格和源码。

未完成全提交、全分支和全部源码审计，未访问本机工作树/安装版、未运行 Xcode/测试/模型调用、未取得新用户体验。因此**未建立全历史处理截止点**，上述 SHA 仅是规则读取截点。本次没有部署 Hook/CI 或恢复任何旧任务。
