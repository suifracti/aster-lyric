# 夜间柔和 — 2026-10-21

在画面 → 更多画面选项增加一个默认关闭的开关。20:00–07:00 画布亮度降低 15%，动态最高轻柔，原场景偏好保持。只在两个时间边界唤醒。

Debug arm64、相同 DerivedData/config、CODE_SIGNING_ALLOWED=NO：完整构建成功；原生 63 项通过。日志：`/tmp/lyricsq-1021-night-build-final.log`、`/tmp/lyricsq-1021-night-native.log`。

本次同条件对照为暂停/静态主窗口，Light source / kyiku，1438×880，夜间开关默认关闭。用 App 内 ? / Esc 激活主窗，没有移动鼠标。预热 10 秒，采样 30 秒，ps 累计 CPU 时间与 RSS，单核为 100%。之前不同激活状态的采样不用于此对照。

| | 上一批 d81d9df | 本批 |
|---|---:|---:|
| CPU | 0.033% | 0.000% |
| RSS 开始 → 结束 MiB | 99.98 → 92.67 | 80.59 → 68.00 |

静态对照未观察到持续上涨；不能据此推断播放中、鼠标移动时的性能，更不能把 RSS 降低解释成优化。原始数值附在 JSON 中。

before-main.png / after-main.png 是真实 App 主窗口截图。白天默认关闭状态；夜间实际变暗和动态限制未实机观察，开关所在展开组的截图尚缺，Claude 视觉确认待完成。

另补上一批 ? 按键列表的真实 App 截图，位于相邻 listening-keys/real-app-key-list.png；? 打开、Esc 关闭已实际检查。
