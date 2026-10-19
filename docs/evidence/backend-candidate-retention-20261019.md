# 后端：搜索结束后保留歌词候选

输入基线：`a9f241424b5a1c2d0158814b3a894e2fa6a02fcb`。

修复三个结果传递断点：搜索最终候选未带入 alternatives、会话应用待确认结果时清空公开候选列表、保留纯文本缓存时丢弃新候选。现在渐进出现的候选在搜索结束后仍可预览；不会自动采用待确认结果，也不更改当前缓存与人工选择。

## 验证

- `bash Tests/session_candidate_retention_contract.sh`：真实 manager/session + 内存仓库；修改前4项失败，修改后9项通过。覆盖普通待确认结果、纯文本缓存回退、另一纯文本结果、版本/hash保留及零写入。
- `bash Tests/s1_durable_manual_adoption_contract.sh force-refresh-protected`：通过。临时 SQLite 中的人工选中、手动编辑、锁定版本在刷新全过程及重新打开后均保持，刷新结果仅进入候选。脚本原缺少 LinkCore 编译输入和测试要求的私有 home，已补齐后保留原断言重跑。
- 完整 Mac App：Debug、arm64、`SWIFT_OPTIMIZATION_LEVEL=-O`、`CODE_SIGNING_ALLOWED=NO`，编译成功。

未修改 UI、匹配阈值、正式数据库；未读 Obsidian、控制 Spotify 或重启日用 App。真实在线搜索及界面操作未复测。
