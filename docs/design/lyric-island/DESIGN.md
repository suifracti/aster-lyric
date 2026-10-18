# Lyric Island — listening spaces

Implementation baseline: 3cc1a98. Approved merged design, 2026-10-18.

## Product identity
Album image, current lyric, translation/reading and song time form one listening space. A small paired-line mark (original/translation) identifies the product; no generic dashboard tiles. Shared action semantics, distinct eight scenes.

## Eight scenes
|Identity|Composition|Light and controls|
|---|---|---|
|authenticAmbient|Full cover atmosphere and clear foreground cover|Bright natural diffusion, understated warm translucent control strip|
|classic / 柔和光晕|Clear cover over independent spatial color field|Three slow drifting light fields, no breathing faces; softly rounded controls|
|ambientFeathered|Clear subject blending softly into space|Feathered boundary with peripheral glow, airy spacing|
|ambient / 封面柔焦|Photographic crop with image texture|Stable artwork, directional reading veil, compact editorial controls|
|classicGaussian|Even blurred color plane|No extra colored halo; restrained thin controls|
|stage|Full artwork as a stage|Localized spotlight/readability curtain, bottom stage controls|
|lyricsOnly|Generous text column and original/translation rhythm|Quiet colors, compact song byline, no decorative motion by default|
|albumPoster|Record sleeve: artwork, title, artist, lyric column|Printed-style rules, serif title, monospaced time, stable reading|

## Shared visual roles
Use existing fonts and macOS 14 SwiftUI/AppKit. Listening text white with stable local contrast; management uses semantic primary/secondary on neutral window background. Accent is artwork-derived. Header: paired-line mark + small uppercase LYRIC ISLAND/context caption + useful title, never repeat decorative badges everywhere. Body controls 13–14pt, secondary 12pt. Spacing 8/12/16/24/32. One material surface, no nested shadows. Selected is check+fill, preview is outline+label, focus is system ring.

Root will expose `LyricIslandSongTint` ViewModifier through `.lyricIslandSongTint(artworkURL: URL?, accent: Binding<Color>)`, and environment `lyricIslandAccent: Color` (default accentColor). Modifier asynchronously derives cached palette by URL and cancels stale work. Root listening views keep the returned accent in State; descendants use the environment accent. This avoids reading an environment value above the modifier that injects it. Management remains neutral. Root adds shared scene descriptors in existing LyricsDesignTokens.swift; agents should use existing tokens or local private helpers, not depend on unimplemented APIs beyond the above.

## Navigation
Main: Library / Search / Adjust / More. Adjust: Picture / Text / Current Song. Hover temporary, click pin, click again/Escape/close dismiss. Pinned panel ignores other hover. >=1180pt pinned right inspector width340, content reflows; smaller uses retained independent NSPanel host. Temporary remains popover. Theme hover previews without persisting. More retains windows/fullscreen/versions/time/settings. AI daily actions retain result/status; configuration in Settings.

## Small surfaces
Menu: record header, current lyric and adopted translation, discreet next-line label, transport and compact destinations; appearance collapsed. Desktop: transparent type with accent only on highlight/short rule, hover tool rail, visible lock/pass-through recovery via menu. Capsule: compact/preview/expanded, existing notch/multi-screen geometry; shared song accent for tiny rail, never large background animation. Library: record shelf/sidebar, single artwork header, adopted version first, fine rules, source/state alignment; four asset editors create new versions. Settings: clear task sections, stable neutral background. Search: query/track context/candidates and source status.

## Motion and persistence
Keep eight raw IDs and all stored preferences. New per-theme atmosphere off for existing users by absent key; demo explicitly on/off. Light moves independently of lyrics at <=30Hz, freeze phase on pause/hidden/reduce-motion. Image sampling cached once per artwork. Native app inactive but visible remains valid. Edge progress always visible, top-center clockwise, existing seeking and color modes unchanged; only buttons hover-hide.

## Deliverables
Interactive `index.html`, no external runtime/assets; eight visual scenes, sample bright/dark/no artwork and multilingual original demo lines (not copyrighted lyrics), wide/narrow, all window mockups, motion toggle, functionality map and clear demo label. Source-native implementation then one necessary build plus affected checks, static/render/performance evidence kept distinct from user visual approval.


## Migration additions beyond the original 24 settings
|Existing capability|New location|Preserved behavior|
|Menu destinations and full lyrics|Menu playback sheet / compact destination rows|Main, library, settings, desktop, capsule and drag recovery remain reachable|
|Desktop drag, lock and pointer pass-through|Hover tool rail / menu recovery|Window interaction mode is explicit; pass-through recovery remains outside the transparent window|
|Capsule compact, preview, expanded|Existing capsule window|Notch, screen choice and geometry are retained|
|Original lyrics and timeline editing|Library asset rows / Current Song|Edits save a new version, original stays available|
|Translation and reading editing|Library corresponding version rows|Adopt, lock, archive and version lineage stay separate|
|Candidate inspection and adoption|Search / version comparison|Preview is distinct from adoption; source and matching details stay visible|
|AI service, model, reasoning and conversation|Global Settings → AI|Current Song retains daily actions and a direct configuration route|
|Recent listening and statistics|Library tabs|Local historical records remain independent of the current track palette|
|Loading, provider errors and retry|Relevant lyric/status surface|Existing state messages and recovery commands remain bound to their real operations|

Implementation evidence is recorded separately in DELIVERY.md. The HTML is a demonstrator with original sample art/text and simulated playback, not a screenshot of the native application.
