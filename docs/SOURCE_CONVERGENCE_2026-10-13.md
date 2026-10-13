# Spotify Lyrics 源码版本核对｜2026-10-13

本轮检查版本丢失/分叉风险，不是完整日用验收。用户要求围绕GitHub开发，修改后同步；旧单轮不推送限制已经结束。

## 核对结论

- 检查前GitHub main为 `0c04f050c35a2abc420cc81dd582da76b54fc224`，活动M1为 `ee53ae50b5af0098b4ef0a8ceafa01ad222dde16` +8 dirty。已提交的app/工程/测试/脚本/工具树逐文件无差异；落后5个提交只涉及合流历史与交接文档，没有漏掉远端业务代码。
- GitHub所列27个已合并PR的merge commit全部属于main祖先；20个本地分支头也全部属于检查时的main祖先。没有再把历史树重新合并或当活动树，没有删除/清理其它树。
- Sol B查询测试 `e3c89e4` 的原SHA不在main祖先链，但 `git cherry origin/main e3c89e4` 输出 `-`，与主线 `756dc7e` 补丁等价；不是丢失成果。预览安全 `5b597e2`、M1 `a888271`、候选 `01d90434b293`、`aa7b1be`、hash修复 `449df0a`、capture绑定 `e775f39` 均在main祖先链。
- 真正未同步的是最近8项已授权本地修改：AI优先/原生独立版本/多AI保留与恢复，及ChatGPT的ambient和比较UI补丁。先快进远端文档，8项文件SHA全部不变，再以 `ab0d6e59a8b6b22267de05df8a0f7b9648e46a41` 普通推送main；GitHub API已读回同一SHA。未创建分支、PR、Issue或force push。

## 验证与限制

| 能力 | 本轮证据 | 不能宣称的范围 |
|---|---|---|
| 原词身份/安全查询 | fresh query_identity_contract exit0；Sol B补丁等价且保留 | 所有歌曲准确匹配 |
| AI默认/原生与多稿保留/选择恢复/人工锁定 | TranslationSession此前prepare/swiftc/runtime=0，全部编译输入SHA本轮逐项重新匹配 | 真实新歌和真实付费请求 |
| v13请求原子完成/两连接并发/回滚/重开 | TranslationPersistence此前prepare/swiftc/runtime=0，全部输入SHA重新匹配；核心迁移和CAS代码保留 | 正式日用库迁移 |
| P0播放/预览隔离/设置与选择作用域 | Playback此前prepare/swiftc/runtime=0，全部输入SHA重新匹配；UI静态入口fresh exit0 | 全部播放器实机操作 |
| 当前App源码编译 | 最近Mac unsigned Debug exit0；当前Swift/pbxproj全部输入SHA完全匹配 | 正式安装/用户视觉认可 |
| 新多译文比较UI | 精确ChatGPT patch/output SHA匹配；隔离启动及正常退出0 | 比较/对齐/切换/手动采用仍NOT_RUN，缺原词与两份同源稿 |

本轮没有任何SwiftUI设计、生产代码修复、模型请求、正式App/SQLite/Keychain操作。未把离线、构建与真人体验合成整体PASS。

## 不同源码与应用身份

- 活动树：`/private/tmp/lyricsq-m1-daily-convergence-20261011`。源代码完成同步后以GitHub main为主；此文档所在后续提交只修改防分叉说明，不改变App编译输入。
- 项目登记根 `/Users/apple/backup/sptifylyrics` 仍在旧 `codex/h1-hash-domain-boundary`/c062cfe，有用户README和历史未跟踪资料。不是本轮活动源码，全部保留未写入、未清理；不能因工作目录默认在那里就继续旧代码。
- 最新私有UI候选exe SHA：`196ced541db9fa8110cb324d40b3da113ed4301074a8991eb58b7476ef39169e`，与最近编译输入关联。正式安装exe SHA：`c6af2a1439d8d7bbc660fb694933213ff350430d8f3316622e2dfdff1b335b1a`，bundle版本0.1.2/build3没有Git提交字段。两者不同不能仅据SHA或时间认定版本先后；安装版的源码身份/最新功能仍未确认，不擅自替换它。

## 防止复发

1. 接手先fetch、核main祖先及活动工作树，不从旧树/ZIP/安装包倒推最新代码。
2. 保留dirty，只做安全快进或核实冲突；禁止reset/clean/stash绕过版本核对、历史整文件覆盖、重写历史/force。
3. UI精确补丁绑定当前提交与目标SHA，过期就交ChatGPT更新，不强行套旧文件。
4. 默认每轮审查、定向验证、普通commit/push到main，实际读回远端SHA与clean状态；禁止推送的单轮任务明确标NOT_SYNCED。
5. GitHub保留代码历史并防普通非快进覆盖，但不会自动发现语义回退；受影响旧功能仍保留定向检查。源码、安装、真实功能验收分别记录。

详细私人源码/编译输入及核对JSON保留在本机任务私有目录；不提交截图、歌词库、预算/历史日志或凭据。当前交接继续读Obsidian，本文是当轮核对记录，不启动旧Issue/PR任务。
