# Spotify请求保留ID大小写

修复喜欢接口把base62 ID转成小写的问题；单曲回跳也复用同一解析方法。请求接受裸ID、spotify:track URI和open.spotify.com链接，保留资源ID大小写。本地歌词资产仍使用原有小写身份键，未做迁移，也没有改授权范围。

先把原有请求测试的数字ID换成混合大小写ID，并让GET/PUT/DELETE分别走裸ID/URI/链接：原实现明确失败（/tmp/lyricsq-1021-liked-case-red.log）。修复后完整Debug arm64构建成功（/tmp/lyricsq-1021-request-case-build.log），原生65项通过（/tmp/lyricsq-1021-request-case-native.log），包括旧身份键不变、三种输入的实际请求URI均保留大小写、单曲回跳AppleScript编译。没有实际加入/移除用户的喜欢。

App已重新启动到本批构建。10秒预热+30秒单次记录：CPU0.500%，RSS181.16→115.77MiB，窗口1116×779保持；开始active true、结束false。由于与此前窗口尺寸和前台状态不同，这不是同条件性能通过证明。原始数据附后，不继续反复调整窗口。

这次仅调整请求ID解析，没有新增UI、轮询或定时器。后台逻辑和原生测试通过不等于真实账号端到端验收。Spotify自然结束单曲回跳、后续UI与性能验收仍待完成。

依据：[Spotify URI与base62 ID定义](https://developer.spotify.com/documentation/web-api/concepts/spotify-uris-ids)。
