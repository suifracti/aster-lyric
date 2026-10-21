# Listening keys and current-recording likes

Requirements: docs/TOOLBAR_BEHAVIOR.md at67b5be9. Separate from further listening extras.

Main-window local key monitor: Space,A/D,Z/C,X,[/],comma/period,F,?,Esc. Input fields, inactive apps, non-key and other windows pass through. Only offset/fine-blur keys repeat. Changes use existing per-recording offset and blur preferences. Centred key list and shared one-second notices. F's state/notice is wired here; the focus-only presentation is the separate listening-extra item, not claimed complete here.

Heart in normal, compact focus-scene and edge players, shared live-recording state. S adds, or first arms removal for3s then removes on secondS. Click heart directly toggles. No-track/pending/permission/failure notices. Connection button opens existing playback settings. No new settings, queue, retry or timeout layer.

Spotify uses only user-library-read/user-library-modify via existingOAuth and token handling; no directKeychain changes. New calls target exactly one spotify:track URI in the current LibraryAPI (GET me/library/contains,PUT/DELETE me/library). Official references: [read](https://developer.spotify.com/documentation/web-api/reference/check-library-contains),[save](https://developer.spotify.com/documentation/web-api/reference/save-library-items),[remove](https://developer.spotify.com/documentation/web-api/reference/remove-library-items). No playlist/follow scopes. Missing old-token scopes require reconnect; no automatic browser authorization. No live account mutations were performed.

AppleMusic uses the local Music.app scripting dictionary's favorited property; captures currenttrack and checks its persistentID before changing it. LiveMusic favorite acceptance NOT_RUN.

Debug arm64 production build passed;61native tests passed including key focus/input gates, S confirmation, exactHTTPmethods/recordingURI/twoOAuthscopes and AppleMusic command targeting. No model requests. Production executableSHA2569aed9a65565f26b654f5048be609ab2c7f61084a35f3d1d6dad6cd8c63cbe788. Raw build/native logs retained in/tmp/lyricsq-1021-keys-*.

Edge positioning core:56checks peroptimization(-Onone/-O) pass. Original test's47pt point was inside the new four-button143pt cluster; now computes a point beyond the actual control corridor.30pt reveal/46pt keep thresholds unchanged. No transport-position logic change besides fitting the fourth button.

NativeAX confirms main-window/Light source/kyiku17%, toolbar labels include plain key hints. A picture-button attempt became stale as toolbar hid; no visible panel change claimed. StageManager capture remains a thumbnail. Realpanel/heart screenshots, realkeyboard input, liveSpotify/AppleMusic writes and Claude visual approval pending. Offscreen captures do not substitute.

30s resource comparison, same Debug/DD/cachedsong/mainwindow: previous search repeatCPU0.000%,RSS136.75→101.09MiB (priorUI pairedrepeatCPU0.033%,RSS139.39→131.00). Keys firstCPU5.831%,RSS126.11→123.31, with one10s CPU burst. Repeated without further UI operations:CPU0.033%,RSS67.89→54.14. Sustained increase did not repeat; no foreground stress/long-term or FPS claim. Raw samples retain first and repeat rather than discarding the higher run.
