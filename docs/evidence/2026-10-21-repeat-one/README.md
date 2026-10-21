# 三档循环 — 8c9d1cf

在b877df9的两个现有按钮上补齐关→列表循环→单曲循环；沿用已有 repeat.1 图标与提示。Apple Music仍调用原生off/all/one。Spotify列表循环调用原生repeating；单曲模式关闭原生列表循环，由已有0.2秒播放时钟在结尾请求回到0:00，没有增加定时器或Premium接口。

生产AppleScript在当前歌曲ID完全匹配时才回跳；保留ID大小写并明确considering case。换歌后不seek新歌；在途请求不重复发送，旧轮询沿用原有失效机制。失败提示并退出本次App单曲模式，不排队重试。不新增设置或数据库迁移。

Debug arm64完整构建通过：/tmp/lyricsq-1021-repeat-verified-build.log。原生65项通过：/tmp/lyricsq-1021-repeat-verified-native.log。一个新增测试覆盖三档循环、Spotify原生只收到all/off/off、结尾只请求同一录音一次、0:00恢复播放时钟；还实际编译生产AppleScript，但没有执行它去控制真实Spotify。

之前测试发现使用旧身份归一化会使命令ID变小写，保留该失败日志于/tmp/lyricsq-1021-repeat-final-native.log；已修正本功能。没有改历史歌词资产的身份算法。现有喜欢接口的大小写问题将单独修复。

未完成的实机项：Spotify自然结束与桌面播放器自动跳曲的先后次序、真实循环按钮切换/图标截图、Apple Music真实循环。real-main.png只是候选App实际运行窗口记录，并非单曲状态的视觉通过证明。Claude视觉确认待完成。

资源记录：默认非单曲状态，10秒预热+30秒，CPU1.033%，RSS78.67→100.91MiB；窗口记录从105×102缩略图变为1438×879，不能和上批13.164%的完整窗口数据作同条件比较。性能验收NOT_RUN，不据此声称没有回归。最后补上的请求失效标记只在循环触发时运行，不影响本次默认模式采样路径。

参考：[Spotify的base62 ID](https://developer.spotify.com/documentation/web-api/concepts/spotify-uris-ids)、[AppleScript文本比较](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_operators.html)。
