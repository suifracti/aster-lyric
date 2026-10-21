# Cover accent

67b5be9 listening extra, separate implementation commit. Reuses LyricIslandArtworkColors' per-cover cache. One main-window task per artworkURL sets an environment accent used by active plain/ruby/timed lyric text, standard progress and panel controls. Edge artwork-colour mode uses the same accent; explicit manual/flow/random edge modes remain. Saturation below0.08 or the existing missing-artwork neutral palette leaves the previous white lyric/progress and system panel accents. No new setting, row sampler or frame-driven global state.

Debug arm64 production build succeeded;62native tests passed, with one new neutral/coloured-cover case. Temporary archive contains committed c97e1d1 production code plus only this batch's source diff, same Debug configuration/DD as earlier. ExecutableSHA256ac64957abf7afe34389f3570be66d2b541e679ffabf1e93f0c891d8c60c9863e. No model request or live-account writes.

NativeAX after initial connection confirms the same cachedLight source/kyiku and17% rail. Fresh30s CPU0.000%,RSS107.80→100.78MiB; preceding keys fresh observationCPU5.831%,RSS126.11→123.31 (repeat0.033%,67.89→54.14 after longer idle). No increase in the fresh-launch windows, no sustained growth in this sample. Do not compare long-idle compressed RSS as though it were the same warmup, or infer foreground-playback/frame-time performance. Raw samples attached.

Real coloured-cover/panel pixel acceptance and Claude visual approval pending. The established CUA capture failure/StageManager thumbnail limitation prevents usable screenshots; previous generated fixtures do not substitute. No screenshot-tool rewrite or physical mouse movement.
