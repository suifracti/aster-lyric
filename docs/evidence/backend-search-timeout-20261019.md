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

## 追加：官方歌曲信息补查取消

输入基线：`5a403b7e089001da23e42eaba6570aca6393788d`。

首轮无自动结果后的 Spotify 官方别名补查直接等待共享元数据请求，未经过前述单来源超时边界。现在每个消费者能独立取消等待；共享加载本身负责写缓存及清理在途记录，其他消费者不会被取消，也不会因等待者退出而重复发请求。

- `bash Tests/spotify_alias_cancellation_contract.sh`：实际 resolver/search + 延迟 HTTP，修改前3项失败，修改后8项通过。单消费者取消从约0.861秒降至立即返回；最后一个消费者退出、全搜索取消、其他消费者正常完成、缓存和请求去重均通过。
- `bash Tests/search_concurrency_manual_contract.sh`：再次通过，含官方别名、自动采用、录音不符拒绝和译文保留。
- 完整 Mac App：同配置 Debug、arm64、`-O`，编译成功。

此处数值仅为离线复现；真实在线歌曲和界面体验未复测。UI、匹配规则及正式数据未修改。
