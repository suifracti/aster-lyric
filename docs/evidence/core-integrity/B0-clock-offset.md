# B0 — Clock & Offset Truth Verification

日期：2026-09-22
项目根：`/Users/apple/backup/sptifylyrics`
结案状态：`BASELINE_CHARACTERIZED`；原生输入另标 `NATIVE_INPUT_PENDING`

本轮只做时钟、offset、显示进度和 seek 输入链验证。没有修改生产源码，没有连接 Spotify/Music，没有打开正式用户 SQLite，没有读取 Keychain，没有录音或调用 AI，也没有执行 D0/C1 或提交任何 Git 变更。

## 1. 基线与 Git 状态

预期审计基线与实际基线一致：

```text
branch: main
HEAD:   6528be3103f75fd4f63757855b9d61cd30f757d8
release identity: v0.1.2
```

开始前实际检查命令及结果：

```text
pwd                              -> /Users/apple/backup/sptifylyrics
git status --short --branch      -> ## main...origin/main
git branch --show-current        -> main
git rev-parse HEAD               -> 6528be3103f75fd4f63757855b9d61cd30f757d8
git diff --stat                  -> empty
git diff --cached --stat         -> empty
```

开始时仅有以下既存 untracked 文件，均未删除、覆盖或提交：

```text
?? PROJECT_FULL_AUDIT_2026-09-22.md
?? PROJECT_FULL_AUDIT_ASTRA_2026-09-22.md
?? PROJECT_FULL_AUDIT_GROK47_2026-09-22.md
```

报告写入及 harness 执行后的实际状态：

```text
## main...origin/main
?? PROJECT_FULL_AUDIT_2026-09-22.md
?? PROJECT_FULL_AUDIT_ASTRA_2026-09-22.md
?? PROJECT_FULL_AUDIT_GROK47_2026-09-22.md
?? Tests/b0_clock_offset_truth_contract.sh
?? Tests/b0_clock_offset_truth_contract.swift
?? docs/evidence/core-integrity/
```

该 untracked 目录中实际新增文件为 `docs/evidence/core-integrity/B0-clock-offset.md`。

结束时 `git branch --show-current` 仍为 `main`，`git rev-parse HEAD` 仍为上述基线；`git diff --name-only -- SpotifyLyrics` 与 `git diff --cached --name-only -- SpotifyLyrics` 均为空，`git diff --check` 退出码为 0。因此生产 diff 为零，未执行 commit、push、PR、merge、tag、release、reset、clean、stash 或历史切换。

## 2. 本轮新增文件与隔离

允许的新增文件只有：

- `Tests/b0_clock_offset_truth_contract.swift`：编译真实生产 `SpotifyLyrics/Models/Models.swift` 中的 `LyricsPresentationClock`，不复制实现、不建立 fake clock。
- `Tests/b0_clock_offset_truth_contract.sh`：用临时编译目录、命名 `UserDefaults` suite 和临时数据库路径运行 clock probe，并对当前生产路径做只读源码断言。
- 本报告。

B0 runner 的 source/test identity：

```text
swiftc -parse-as-library \
  SpotifyLyrics/Models/Models.swift \
  Tests/b0_clock_offset_truth_contract.swift
```

运行时输出确认：

```text
suite=com.spotifylyrics.tests.b0-clock.<temporary-suffix>
temporaryDatabase=/tmp/spotifylyrics-b0-clock.<temporary-suffix>/b0.sqlite3
databaseOpened=false
```

runner 断言命名 suite 不等于 `UserDefaults.standard`，只写入并清理自己的 suite；临时数据库路径仅用于证明隔离边界，没有打开文件。fake 只在已有静态/小型 contract 中代表外部 I/O；本轮生产 clock 证据没有用 fake clock 证明生产正确。

## 3. 实际执行命令与结果

退出码 0 的已有最小 contract：

```text
bash Tests/presentation_clock_contract.sh
bash Tests/lyrics_presentation_offset_contract.sh
python3 Tests/v3_seek_pointer_contract.py
bash Tests/settings_contract.sh
bash Tests/presentation_line_index_contract.sh
bash Tests/automatic_alignment_seek_contract.sh
bash Tests/continuous_progress_contract.sh
bash Tests/floating_lyrics_contract.sh
bash Tests/capsule_lyrics_contract.sh
bash Tests/b0_clock_offset_truth_contract.sh
```

对应结果摘要：

```text
PASS: Presentation clock contract verified
PASS: shared lyrics presentation offset contract
V3 seek pointer mapping: PASS
settings contract passed
PASS: presentation line index contract
automatic_alignment_seek_contract: PASS
PASS: Continuous progress contract verified
floating lyrics pure-data contract passed
capsule lyrics contract passed
PASS: B0 production clock raw/elapsed/offset/presentation and clamp cases
PASS: @Published ordering probe for paused offset update path
PASS: B0 source routing assertions (clock/settings/V3/fullscreen/no offset seek)
```

退出码非 0 的已有 contract：

```text
python3 Tests/v3_seek_draft_contract.py  -> 1
bash Tests/fullscreen_lyrics_contract.sh -> 1
```

这两个意外失败没有修改生产或旧测试：详见第 7 节。

没有执行全量 `Tests`、完整 AppKit UI 运行、真实播放器运行或正式数据库运行；这符合本轮隔离要求。

## 4. Clock 与 offset 的事实

生产 `LyricsPresentationClock.presentationTime(at:)` 的实际关系是：

```text
elapsed      = isPlaying ? max(0, now - receivedAtMonotonicTime) : 0
presentation = clamp(authoritativePosition + elapsed + presentationOffset,
                     0, trackDuration)
```

`PlaybackState.currentTime`/playback anchor 保存 provider 的 raw position；`PlaybackState.presentationClock` 把 `settingsStore.lyricsPresentationOffset` 传入 clock。`LyricsPresentationClock` 不改变 `authoritativePosition`，也不调用 provider。

给定 `raw=10`、`duration=60`、playing 时 `elapsed=1.25`、paused 时 `elapsed=0`，真实生产 clock 的运行输出如下：

| case | raw / elapsed / offset | presentation | visible progress | input origin | seek target | 证据 | 状态 |
|---|---:|---:|---:|---|---|---|---|
| playing, offset 0 | 10 / 1.25 / 0 | 11.25 | 11.25/60 = 0.187500 | 无输入 | — | 真实生产 clock 运行 | PASS |
| playing, offset +2 | 10 / 1.25 / +2 | 13.25 | 13.25/60 = 0.220833 | 无输入 | — | 真实生产 clock 运行 | PASS |
| playing, offset -2 | 10 / 1.25 / -2 | 9.25 | 9.25/60 = 0.154167 | 无输入 | — | 真实生产 clock 运行 | PASS |
| paused, offset 0 | 10 / 0 / 0 | 10 | 10/60 = 0.166667 | 无输入 | — | 真实生产 clock 运行 | PASS |
| paused, offset +2 | 10 / 0 / +2 | 12 | 12/60 = 0.200000 | 无输入 | — | 真实生产 clock 运行 | PASS |
| paused, offset -2 | 10 / 0 / -2 | 8 | 8/60 = 0.133333 | 无输入 | — | 真实生产 clock 运行 | PASS |
| lyric timestamp 10, offset 0 | raw arrival 10 / elapsed 10 / 0 | 10 | 10/60 = 0.166667 | 歌词时间线 | — | 真实生产 clock 运行 | PASS |
| lyric timestamp 10, offset +2 | raw arrival 8 / elapsed 8 / +2 | 10 | 10/60 = 0.166667 | 歌词时间线 | — | 真实生产 clock 运行 | PASS |
| lyric timestamp 10, offset -2 | raw arrival 12 / elapsed 12 / -2 | 10 | 10/60 = 0.166667 | 歌词时间线 | — | 真实生产 clock 运行 | PASS |
| lower clamp | 0 / 0 / -2 | 0 | 0 | 无输入 | — | 真实生产 clock 运行 | PASS |
| upper clamp | 59 / 0 / +2 | 60 | 1 | 无输入 | — | 真实生产 clock 运行 | PASS |
| paused offset mutation to +2 | raw 10 / elapsed 0 / +2 | 12 | 0.200000 | settings offset control | 不直接 seek | clock 运行 + source routing | PASS（事实） |

因此歌词时间戳 `L` 的 raw 到达位置是 `L - offset`：`+2` 在 raw 8 到达，属于提前；`-2` 在 raw 12 到达，属于延后。播放和暂停两种状态都已验证。offset 改变可见 V3 秒数和进度，但不会改变 raw/provider position，也不会由 offset control 直接产生 provider seek 调用。

## 5. 输入链与时间域

| case | raw / elapsed / offset | presentation | visible progress | input origin | seek target | 证据 | 状态 |
|---|---:|---:|---:|---|---|---|---|
| absolute mouse pointer | 例：x=150, width=300, duration=240 → raw 120 | 不参与 pointer mapping | 120/240 = 0.500000 | `pointerPosition(x,width,duration)` 的绝对位置 | 120 raw | 映射函数实际运行 + source | PASS（映射） |
| drag end | 例：最后 x=270 → raw 216 | 不参与 pointer mapping | 216/240 = 0.900000 | mouseUp/最后一个 drag event 的最新 draft | `min(max(draft,0),duration)`，即 216 raw | source；原生事件未运行 | NOT_RUN（事件） |
| keyboard / accessibility，offset=+2 | raw 10 / 0 / +2 | 12 | 12/60 = 0.200000 | `updateNSView` 从 `value=visiblePosition` 写入 `slider.doubleValue`；`Coordinator.changed` standalone 再读这个值 | 数值 12 直接交给 `state.seek`，被解释为 12 raw | 完整 source call chain；原生事件未运行 | NOT_RUN（事件；已证实混域） |
| offset control “提前 0.10s” | raw 不变 / elapsed 不变 / offset -0.1 | presentation 减 0.1，歌词实际更晚 | V3 visible position 也减 0.1 | `LyricsPresentationOffsetControl.adjust(-0.1)` | 无 `state.seek` / 无 provider seek | source + B0 clock | FAIL（用户语义反向） |
| offset control “延后 0.10s” | raw 不变 / elapsed 不变 / offset +0.1 | presentation 加 0.1，歌词实际更早 | V3 visible position 也加 0.1 | `LyricsPresentationOffsetControl.adjust(+0.1)` | 无 `state.seek` / 无 provider seek | source + B0 clock | FAIL（用户语义反向） |
| paused offset subscriber | raw 10 / elapsed 0 / 新 offset +2 | 最终为 12 | 最终为 0.200000 | `PlaybackState` 监听 `resolvedSettings.$lyricsPresentationOffset` | 不产生 seek | `@Published` runtime probe：callback 收到 2，但 callback 内读取 stored value 为 0，最终才为 2 | FAIL（存在短暂旧值读取路径） |
| fullscreen | 与 V3 同一 clock/settings/slider | 与 V3 相同 | 与 V3 相同 | `FullScreenLyricsView` 复用 `AppleMusicImmersiveV3WindowView(..., liveOnly: true)` | 复用 V3 的 seek 链 | source routing | PASS（复用已证实；原生事件未运行） |
| 切歌 / 换歌词版本 scope | raw/presentation 公式不变 | 使用同一 offset | 依 consumer | `AppSettingsStore.Key.lyricsPresentationOffset` | 不涉及 seek | source：global key，无 track/version identity；track change 未重置该 key | PASS（确认当前是 global scope） |

关于“拖拽是否每次额外加 offset”：没有这种笼统结论。绝对鼠标位置和 drag-end 路径都直接生成 raw 数值，没有额外加 offset。只有 V3 keyboard/AX 的起始 `slider.doubleValue` 来自 presentation `visiblePosition`，随后又把同一个数值送入 raw `state.seek`，这是独立的混域问题。

`draftPosition` 的来源也分开：pointer 路径由 `pointerPosition` 写入 native slider，再经 binding 形成 raw-domain draft；keyboard/AX standalone 路径先由 `updateNSView` 把 presentation-domain `visiblePosition` 写入 slider，再由 `Coordinator.changed` 写入 presentation-domain draft。结束编辑时两条路径都把 draft 数值直接作为 raw seek target 交给 `state.seek`。

原生 keyboard/AX/mouse 事件本身没有在本轮 headless 隔离环境中运行，故表中明确标 `NOT_RUN`。上表的 source call chain 与纯函数/生产 clock 运行证据不冒充真人操作或真实播放器验证。

## 6. 直接相关的源码路由

- `SpotifyLyrics/Models/Models.swift:1143-1181`：生产 clock；raw anchor、playing elapsed、offset、duration clamp。
- `SpotifyLyrics/Services/PlaybackState.swift:24, 312-319, 1227-1255, 2405-2410, 2527-2535`：`currentTime` raw 状态、offset subscriber、`seek` provider 路由、presentation clock 构造。
- `SpotifyLyrics/Settings/AppSettingsStore.swift:181, 378-389, 487-490`：global key `lyrics.presentationOffset.v1`、持久化与 `[-10,10]` clamp。
- `SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift:117-177`：offset control、按钮方向、没有 seek 调用。
- `SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift:1125-1134, 1199-1205, 1227-1280, 1309-1312, 1368-1371`：V3 可见位置、progress、slider update/Coordinator/提交、pointer mapping、clock label。
- `SpotifyLyrics/Views/Fullscreen/FullScreenLyricsView.swift:18-19`：fullscreen 直接复用 V3，并传 `liveOnly: true`。
- V3 lyric document/timed row 使用同一个 `presentationClock`，因此歌词选择、逐字高亮和 V3 clock label 均在 presentation domain。
- `CapsuleLyricsView.swift` 的 lyric selection 使用 `liveCurrentLineIndex`，但 transport progress/label 使用 raw `currentTime`；`PlaybackControlsView.swift` 也使用 raw `currentTime`。这是另一个已确认的 consumer 混域。

## 7. 缺陷、旧测试语义、意外失败、尚未执行

### 已证实缺陷

1. `LyricsPresentationOffsetControl` 的用户语义反向：生产公式决定 `+offset` 使歌词更早、`-offset` 使歌词更晚，但按钮把“提前”绑定到 `-0.1`、把“延后”绑定到 `+0.1`。
2. V3 transport displayed position/progress 使用 presentation clock，因此 offset 改变会改变可见播放秒数和进度；这与 control 文案“只影响当前歌词的显示……不改变播放进度”不一致。raw/provider 播放进度本身没有改变。
3. V3 keyboard/AX slider 的 starting value 是 presentation domain，最终 `state.seek` 的参数被按 raw domain 解释；offset 非零时会产生数值相同但语义不同的 seek target。
4. `PlaybackState` 的 offset subscriber 忽略 Combine 发出的新值，而在 `@Published` will-set 回调期间再次读取 `settingsStore.lyricsPresentationOffset`；暂停状态下存在短暂读取旧 offset、再由后续 render 使用新 offset 的路径。
5. Capsule/legacy consumer 让 lyric selection 走 presentation clock，而 transport label/progress/seek 走 raw `currentTime`；它们在 offset 非零时显示与歌词时间域不一致。

### 旧测试的错误用户语义

`Tests/presentation_clock_contract.swift` 中名为 `advanceByTwoSeconds` 的 case 使用 `presentationOffset: -2.0`，并把结果 8 秒描述为“提前 2s”；`LyricsPresentationOffsetControl` 也把“提前”绑定到负 delta。数值断言本身符合生产公式，但“提前/延后”的用户语义是反的。该测试绿色不能被汇总为 offset control 语义正确。

### 意外失败

- `python3 Tests/v3_seek_draft_contract.py` 退出码 1：它抽取了真实 V3 `visiblePosition`，该实现要求 `state.presentationClock`；测试 fake 只有 `currentTime`、`seeks` 和 `seek(to:source:)`，缺少当前生产 getter 所需接口。这是 test fake 过时，不是证实生产 clock 正确的依据。
- `bash Tests/fullscreen_lyrics_contract.sh` 退出码 1：静态断言要求字面量 `LyricsCopyText.format(documentLines)`，而当前生产代码先令 `let lines = documentLines` 再调用 `LyricsCopyText.format(lines)`。fullscreen 的 V3/`liveOnly` 复用和 clock 路由实际存在；这是旧静态断言与当前别名写法不一致，不是本轮 clock 失败。

### 尚未执行 / 明确 NOT_RUN

- 未运行原生 AppKit mouse/keyboard/AX 事件；因此不能声称真人输入或系统辅助功能事件已通过。
- 未运行完整 `PlaybackState` 实例化及真实 provider I/O；这样可避免触碰正式数据库、Keychain 或播放器。`PlaybackState` 的 source routing 已检查，生产 clock 已实际运行。
- 未连接 Spotify/Music，未打开正式 SQLite，未依赖 Release 数据库环境变量，未运行全量测试或发布构建。
- 未实现 per-track/per-version offset storage；本轮只确认当前 global key 行为。

## 8. C1 应修的具体 consumer / 动作（仅定位，不实现）

1. `LyricsPresentationOffsetControl.adjust` 及“提前/延后”按钮文案/方向：按生产公式统一用户语义；同步重命名或修正旧 clock contract 的语义名称和断言描述。
2. V3 `AppleMusicImmersiveV3PlaybackProgress.visiblePosition`、`progressFraction`、`V3PresentationClockLabel` 及其 Stage/focus HUD consumer：明确 transport displayed position 是否应保持 raw domain；不要把 presentation-only offset 静默传播成 transport progress。
3. `V3PlaybackInputSlider.updateNSView`、`Coordinator.changed`、`handleEditingChanged`：为 pointer、drag-end、keyboard、AX 明确同一个输入坐标域；若 transport seek 是 raw，应在入口处显式转换 presentation→raw，而不是复用同一个数字。
4. fullscreen 不需要独立修一套 callback；它复用 V3，C1 应以 V3 consumer 修复覆盖 fullscreen，并保持 `liveOnly` 复用关系。
5. `CapsuleLyricsView` 的 progress/label/seek 与 `PlaybackControlsView`：与 lyric selection 的 presentation domain 做明确边界，决定哪些是 raw transport、哪些是 presentation display。
6. `PlaybackState` offset subscriber：不要在 `@Published` will-set 回调中通过 getter 重新读取旧 settings；使用收到的新 offset 或在存储完成后再同步 line index。这里只记录动作，不提供实现代码。
7. `lyrics.presentationOffset.v1` 当前应继续按本轮 scope 作为 global key 处理；per-track/per-version storage 是后续独立决策，不在 B0 实现。

以上定位不等于已修复。B0 到此停止。
