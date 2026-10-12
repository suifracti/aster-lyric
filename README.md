# lyricsQ

### 跟着 Spotify / Apple Music 听歌，也认真看歌词。

lyricsQ 是一款原生 macOS 歌词应用，提供沉浸式主播放页、全屏歌词、桌面歌词、歌词版本管理和手动时间轴编辑入口。当前工程状态、成熟度边界和未关闭风险以 [docs/STATUS.md](docs/STATUS.md) 为准。

## 当前正式发布

- 正式 GitHub Release：**v0.1.2**
- 发布提交：`6528be3103f75fd4f63757855b9d61cd30f757d8`
- 下载：[GitHub Release v0.1.2](https://github.com/suifracti/lyricsQ/releases/tag/v0.1.2)
- 发布资产：`SpotifyLyrics-0.1.2.zip`、`SpotifyLyrics-0.1.2.dmg`
- 当前工程入口：[Spotify Lyrics Current Status](docs/STATUS.md)

v0.1.2 是当前正式发布身份。发布包面向 Apple Silicon（arm64）和 macOS 14 或更高版本；当前没有 Apple notarization 完成证据，不应把代码签名检查表述为公证。

## 产品边界

当前仓库包含以下产品入口，但入口存在不等于每个边界都已完成实机验收：

- 核心：V3 主播放页、原生全屏歌词。
- 支持的次级入口：透明桌面歌词 v2、菜单栏。
- 实验性入口：Direction D / Capsule，以及 AI、自动排轴等仍需单独验证的能力；不承诺稳定可用。
- 兼容路径：Classic V1、桌面 legacy panel。
- 当前没有 iOS target。

Spotify 与 Apple Music / 音乐.app 在本项目中是播放器来源；歌词来源、版本匹配、逐行时间和真实逐字 timing 仍受数据质量与具体歌曲影响。不要把实验入口、代码存在或单个 contract 通过解读成完整产品验收。

## 获取与构建

下载正式发布包后，将应用拖入 Applications。应用使用本地签名，未有 Developer ID 与 Apple notarization 证据；系统可能要求用户在确认来源后手动允许打开。

从源码构建：

```sh
git clone https://github.com/suifracti/lyricsQ.git
cd lyricsQ
open SpotifyLyrics.xcodeproj
```

也可以构建 Debug：

```sh
xcodebuild -project SpotifyLyrics.xcodeproj \
  -scheme SpotifyLyrics \
  -configuration Debug \
  -derivedDataPath /tmp/lyricsq-deriveddata \
  CODE_SIGNING_ALLOWED=NO build
```

开发流程、提交检查和当前工程推进状态：

- [当前工程状态](docs/STATUS.md)
- [开发流程](docs/DEVELOPMENT_WORKFLOW.md)
- [提交检查](docs/SUBMISSION_BASELINE.md)

## 数据、隐私与许可

- 歌词、修订版本和收听记录默认保存在本机 Application Support 数据库；偏好设置保存在本机。
- 授权令牌和 API Key 使用 Keychain；不要提交凭据、数据库或个人导出资产。
- 查询在线歌词会向相应来源发送匹配所需的歌曲信息；实验性 AI 路径不应被视为稳定能力。
- 本项目与 Spotify、Apple 及歌词来源服务无隶属或背书关系。
- 本仓库不是开源授权项目；原创源码、文档和设计保留全部权利，使用范围见 [LICENSE](LICENSE)。
