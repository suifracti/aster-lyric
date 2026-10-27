# Round 6 实施与复核报告

输入规格：`37b6f533`，实施前已 fetch 并快进到最新 main。没有重复开发 Round 4/5，也没有改场景、旧 renderer rawID、环境光、经典模糊或羽化。

## 提交

| 项目 | 提交 | 实际变化 |
| --- | --- | --- |
| R6-1 | `b6d001f` | 边缘合同编译真实 SwiftUI 命中带，检查四边、横竖窗口及 3pt/6–20pt；固定工具窗合同检查同一外观包装用于创建和更新，保留悬停玻璃与固定实体面板隔离。修正旧函数名留下的合同截取边界。生产交互不回退。 |
| R6-2 | `b9b75ee` | 空队列、空歌单加载完成后不再留白；队列使用自己的加载状态。受控 401/403 显示错误，不显示空歌单提示。 |
| R6-3 | `2f4ca6f` | 复现并修复空白歌词被缓存为“其他语言”、切走日语显示偏好的问题。空白内容不判语言、不切偏好。其余三个 Round 4 功能沿用现有实现。 |
| R6-4 | `365024e` | Piano 独立测试脚本因遗漏当前依赖而编译失败，原有离线断言已迁入现有 XCTest 入口；补充 A→B→A 不再次搜索的验证。匹配阈值和采用逻辑未改。旧脚本的 live 参数现在明确返回 NOT_RUN，不把离线检查当在线通过。 |

## 构建、CI 与来源检查

- 最终代码 `365024e10d64f3a950036f574d42be44121f10cd` 的 [GitHub Actions 40542265913](https://github.com/suifracti/aster-lyric/actions/runs/40542265913) **SUCCESS**，source 与 native 两个 job 均成功。未跳过合同或弱化 CI 成功条件。
- 本机完整原生 XCTest：**112 PASS、1 SKIP、0 FAIL**。跳过的是既有 `testAtmospherePresetRespondsInItsPaddedArea` 的原生承载条件，不计作通过。最终本机稳定 Apple Development 签名 Debug 构建成功。
- CI 相同的五组来源合同本机全部 PASS：edge、scenes、publisher-parser、provider-config、query-identity。真实边缘几何/状态在 `-Onone`、`-O` 各 131 项通过；场景/偏好/外窗几何 85 项通过。
- HANABI / SACBEN：实际公开发行页身份及 **32 行未同步正文**解析成功。没有把正文写进仓库。
- WAITING AT 3AM：本轮目录请求 HTTP=0 / NSURLError，在线结论 **NOT_RUN**；不能沿用历史“无正文”作为这次实时结论。
- Piano Ver. 与普通编曲分离 PASS；错误来源、无正文、纯文本、身份冲突的既有原生来源测试 PASS。A→B→A 存储命中离线检查 PASS，真实 HANABI 的“在线搜索→采用→用户主窗→切歌返回”完整链路 **NOT_RUN**。

## 重要界面与联动的实际证据

| 范围 | 已做 | 尚未实机操作 |
| --- | --- | --- |
| 大字与注音 | 真实主窗当前歌《運命のふりをして》及注音可读；精确长句两行/缩字测试通过。复用 Round 5 封面、环境光离屏图。 | 大字开关、长句滚动及两个场景的真实手感 NOT_RUN。 |
| 边缘进度与胶囊 | 原生 Shape 几何、旧歌曲拖动身份保护、四边定位 reducer、顶栏避让及浮层关闭模型的既有检查通过；复用竖排离屏图。 | 3pt 窗口缩放、横竖短条拖动、四边鼠标移动与跨歌曲拖动实机 NOT_RUN。 |
| 歌词库与搜索 | 版本视图仍共用；预览读取不采用；已存/人工/锁定资产的现有测试通过。本地先显示、不同 Spotify ID 不误合并的检查通过。 | 真实点击采用/编辑/新窗口及多标签选择手感 NOT_RUN。 |
| 歌单与队列 | 原有第 3 首 context_uri + offset=2、可见行勾选缓存、空状态和 401/403 的受控检查通过；本轮新增歌单离屏截图成功。 | 真实 Spotify 播放、Premium 403、添加/移除歌单 NOT_RUN。没有发送真实 Spotify 写请求。 |

Round 4 联动：语言独立记忆及首次偏好复制、批量补词取消后不再发新搜索、切歌触发睡眠暂停的既有测试通过；批量路径仍仅调用免费搜索会话、排除人工/锁定版本、记录 batch，不连接翻译观察者；当前句发光仍仅作用于当前行，0 值无新增白色光。15/30/60 分钟真实等待、发光在减少动态效果下的实机视觉未代用户验收。

## 30 秒 CPU / RSS 筛查

同一 Mac，稳定签名 Debug `-Onone`，两版均重新启动、采样器预热 10 秒后逐秒采样 30 秒。同一首缓存歌、暂停位置 68.936 秒、封面场景、正常字号和注音层；截图均为 1116×779，App 日志均为 45 行缓存命中、同一句、歌词列宽 602.1pt。没有操作 Spotify 或移动指针。

| 可执行代码 | CPU 均值（一个核=100%） | RSS 起点→终点 | RSS 峰值 |
| --- | --- | --- | --- |
| `91e1814`，与 R6 规格基线生产代码相同 | 0.000% | 105.8→82.3 MiB | 107.2 MiB |
| `365024e` | 0.033% | 69.1→70.8 MiB | 79.0 MiB |

暂停主窗的短窗口内未见明显资源回归。CPU 差仅 0.033 个百分点，RSS 不能据此宣称普遍优化；播放、拖动、歌单加载压力场景及长期内存增长 **NOT_RUN**，WindowServer 未采集。早期隔离样本未稳定显示、久置进程的尝试不纳入上表。

## 附件与交付边界

- 本轮证据只留本机：`.local/round6-20261027/`，含 `final-contracts.json`、`r6-final-xctest.log`、`r6-signed-debug-build.log`、`ci-run.json`、两份 `real-*-perf.json`、两份 `real-*-state.log`。
- 原生截图：`native-main.jpg`、`native-candidate.jpg`；新增离屏图：`screenshots/navigation-playlists.png`。其余复用 `.local/round5-20261027/verified-screenshots/` 和 `big-after/`，明确属于隔离样本，非真实 Spotify 交互证据。
- 最新 Debug App 已通过 `open -g` 后台启动：`build/DerivedData/Build/Products/Debug/SpotifyLyrics.app`。未替换 `/Applications` 正式 App，未执行正式数据库迁移或覆盖，不改 Keychain 存储/权限，不覆盖人工/锁定歌词；`.planning/`、`.workbuddy/` 保留。
- 本轮不新增功能。剩余 NOT_RUN 项集中留给一次日用实机确认，不能把测试和截图记成全部原生验收通过。
