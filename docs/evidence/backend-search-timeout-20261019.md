# 后端歌词来源超时与取消

输入基线：`d5c73c88579df0818dabeef13f3242472780c057`。

## 修改

只调整 `LyricsSearchManager` 的单来源等待边界。原有任务组即使调用
`cancelAll()`，仍会等待正在读取共享目录请求的来源退出，拖延已就绪结果和切歌取消。
现在由一次性结果竞争返回；超时或取消会取消对应工作，迟到结果无法再次发布。
共享目录请求可按既有网络期限收尾，不取消其他消费者，也不更改匹配规则或来源顺序。

## 定向验证

使用真实 LinkCore provider 和搜索器，只有 HTTP 通过 URLProtocol 延迟 0.8 秒；
无真实网络、正式数据、播放器控制或 UI 修改。数值为离线复现耗时，不是在线歌曲测速。

| 场景 | 修改前 | 修改后 |
| --- | --- | --- |
| 单来源设定 0.1 秒超时 | 0.879 秒 | 0.110 秒 |
| 已就绪歌词等待慢来源取消 | 0.856 秒 | 0.058 秒 |
| 调用者取消搜索 | 0.852 秒 | 0.0002 秒 |

- `bash Tests/search_timeout_contract.sh`：修改前 3 项失败；修改后 9 项通过。超时/取消类型、所选歌曲身份、另一个共享消费者正常完成、HTTP 去重均通过。
- `bash Tests/search_concurrency_manual_contract.sh`：通过，包括来源优先级、并发上限、版本浏览、取消、官方艺人别名与译文保留。补齐脚本此前遗漏的 LinkCore 编译输入。
- 完整 App：Xcode Debug、arm64、`SWIFT_OPTIMIZATION_LEVEL=-O`、`CODE_SIGNING_ALLOWED=NO`，编译成功。

UI 手感、真实歌曲在线覆盖、配对 CPU/RSS 测量：`NOT_RUN`。
未读取 Obsidian，未改正式数据或 `/Applications` 安装版；未重启当前日用 App。
