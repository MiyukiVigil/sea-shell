# Changelog

All notable changes to **sea-shell** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.1.0] — 2026-07-15

A DAC release. The Moondrop equaliser lands in full — one-tap presets, an in-shell
import for AutoEQ files, a revert that actually works, and a **software EQ** escape
hatch so the same curves run on hardware this panel can't drive. Plus clipboard
thumbnails and real brand logos on the System page.

### Added

- **Moondrop DAC equaliser** — a native control panel (SUPER+SHIFT+E) for Moondrop
  USB DACs / DSP cables (DAWN PRO2, FreeDSP, Rays, MOONRIVER 3, …). Full 8-band
  parametric EQ with a **live, region-labelled frequency-response graph** (SUB →
  AIR zones so you can see what each part tunes) — drag any band point to set
  frequency/gain, scroll to change Q — an **all-bands column editor** (type · gain ·
  freq · Q per band), pre-gain, global offset, and save-to-flash. Edits apply to the
  DSP in real time and persist only when you save. Built on a reverse-engineered
  USB-HID protocol; the installer adds `python-hidapi` and a udev rule so it works
  without root. No-ops gracefully with no DAC connected.
- **One-tap presets** — eight starting curves (Flat, Bass, V-shape, Vocals, Warm,
  Air, Podcast, Loudness) fill every band and set a matching pre-gain, ready to
  tweak. Each preset is checked against the firmware's coefficient range, so none
  of them get silently altered on the way to the DAC.
- **Import, in-shell** — pick an AutoEQ / REW `ParametricEQ.txt` (or a previously
  exported `.json`) from a file dialog and it's applied live, so you can audition a
  measured preset for your headphones before committing it to flash.
- **Revert** — undo unsaved edits back to the DAC's last saved state. Reloading
  can't do this: edits go to the DSP live, so re-reading only ever returns what you
  just wrote, never what flash still holds. The panel keeps its own snapshot.
- **Universal (software) EQ — works on any output device** — the bands above run on
  the DAC's own chip, so they only exist on supported Moondrop hardware. The same
  curves can now be rendered as a PipeWire filter-chain instead, which applies to
  *anything*: another brand's DAC, laptop speakers, Bluetooth. Needs no Moondrop
  device at all — feed it an AutoEQ file directly:

  ```
  moondrop_control.py --to-pipewire eq.conf --from-rew ParametricEQ.txt
  cp eq.conf ~/.config/pipewire/pipewire.conf.d/
  systemctl --user restart pipewire pipewire-pulse
  ```

  Then select the “Universal EQ” sink. Software biquads are floating point, so the
  handful of shelf gains the DAC's fixed-point DSP has to refuse work fine here.
- **Built-in “how to tune” guide** — for anyone who's never touched an EQ: four
  rules, what each frequency region does (colour-matched to the graph), and quick
  recipes. Every filter shape and recipe is illustrated with a real response curve
  drawn from the same maths as the main graph, so the pictures can't drift from
  what the filters actually do.
- **Image thumbnails in the clipboard picker** — copied images now show a live
  preview in the `;` clipboard history (launcher) instead of a generic icon. Each
  image entry is decoded from `cliphist` to a small cached thumbnail
  (`/tmp/sea-clip-thumbs`, keyed by id), rendered rounded with an accent border;
  text entries are unchanged. Uses the existing `imagemagick` dependency.

### Changed

- **Real brand logos on the System page** — the *Settings → System* overview now
  shows proper logos instead of generic glyphs: the **distro** (CachyOS, Arch,
  EndeavourOS, Manjaro, Fedora, NixOS, … — ~30 mapped, with a Tux fallback for the
  rest), the **kernel** (Tux), the **compositor** (Hyprland), and the **session**
  (Wayland / Xorg). They recolour with the theme accent like every other icon.
  CachyOS ships no icon-font glyph, so its mark is drawn natively (`CachyLogo.qml`).
  Adds a dependency on `ttf-nerd-fonts-symbols` (the installer now pulls it in and
  warns if it's missing).

### Fixed
- Notification when multiple appears and close will have a rectangle shadow like box coming out when closing (hard to describe forgive me)

## [3.0.0] — 2026-07-14

The 3.0 release makes the shell comfortable on any display and hands you far more
control over it — display scaling, a Control Center, drag-to-reorder widgets, and
an auto-hiding bar — on top of a ground-up rework of the **Settings window** and
the **screenshot editor**, and a batch of smaller quality-of-life wins. Some were planned for 2.1 but then somehow with tons of additions and ideas I decided to push it as 3.0

### Added

- **Launcher emoji picker** — type `.` then a name (`.fire`, `.heart`, `.rocket`)
  to search a curated emoji set; ⏎ copies the glyph to the clipboard.
- **More launcher conversions** — the `= … to …` / auto-conversion now covers
  volume (ml/l/cup/gal…), data (kb/mb/gb/gib…), speed (kmh/mph/knots), time
  (min/hr/day…), stone/tonne, nautical miles, and more currencies — on top of the
  existing length / weight / temperature / currency support.
- **Night light** — warms the screen colour in the evening via `hyprsunset`.
  Toggle it from the Control Center, or *Settings → Display → night light*: set the
  warmth (2500–6000 K) and optionally have it **follow dark mode** so the screen
  warms whenever the shell goes dark. (`hyprsunset` ships with the installer.)
- **Bluetooth battery on the bar** — the Bluetooth pill now shows a connected
  device's battery percentage next to its name (already shown in the dropdown).
- **Persistent notification history** — the notification centre now survives a
  restart: history is saved to `~/.config/sea-shell/notif-history.json` (last 40)
  and restored on launch, apostrophes / emoji / any text intact.
- **Per-app do-not-disturb** — mute a noisy app straight from the notification
  centre (the bell icon on any notification, or the "muted apps" chips). Muted
  apps stop popping up but are still recorded in history; critical alerts always
  break through. Persisted to `~/.config/sea-shell/notif-mutes.json`.
- **Night light bar widget** — an optional one-tap night-light pill for the bar
  (off by default; enable it in *Settings → Bar widgets*). Glows warm while
  active; click to toggle the warm screen on/off.
- **Control Center** — a new bar pill (the `tune` icon) opens a quick-settings
  panel: one-tap toggles for dark mode, caffeine, do-not-disturb, Wi-Fi,
  Bluetooth and night light, a power-profile switcher (saver / balanced /
  performance), and a shortcut to full settings. Toggle it on/off and reorder it
  like any widget.
- **Auto-hide bar** — *Settings → Appearance → bar shape*: tuck the bar away and
  reveal it by pushing the cursor to the docked edge. Optional "hide only when a
  window is fullscreen" mode for video/games. Off by default.
- **Reorderable bar widgets** — *Settings → Bar widgets* now lets you drag the
  ⠿ handle on each widget to change the order it appears in on the bar (persisted
  to `appearance.json` as `widgetOrder`, and saved with appearance profiles). The
  Media Player stays centred; the screen recorder can be positioned too.
- **Reorderable left cluster** — the left side (logo · workspaces · window-title)
  is now drag-reorderable too, under *Settings → Bar widgets → left side*
  (persisted as `leftOrder`).
- **Per-monitor bar rules** — *Settings → Display → monitor*: turn the bar off on
  a specific output, or give that monitor its own UI-scale override (independent
  of the global scale). Ideal for a laptop-plus-TV setup — keep the laptop bar at
  1× while the TV bar scales up, or hide the bar on one screen entirely. Stored
  per output name in `appearance.json` as `monitors`.
- **Bar layout presets** — *Settings → Bar widgets → layout presets*: save the
  current widget order, left-side order and every on/off toggle as a named preset
  and restore it in one click (stored in `~/.config/sea-shell/bar-layouts.json`).
- **Rebuilt screenshot editor** — annotate a capture with brush, arrow, rectangle
  and text, crop it, or pull text out of it with OCR, then copy or save. The whole
  editing surface now works in the capture's native pixels, so crop, OCR and export
  all line up and the saved / copied image comes out at full resolution. New: a
  **rectangle** tool, **undo** (`⌃z`), selectable stroke sizes, hover tooltips, and
  keyboard shortcuts (`b`/`a`/`r`/`t`/`c` tools · `⌃z` undo · `x` clear · `⌃c` copy
  · `⌃s` save · `esc` cancel).
- **Display scaling for big / far screens** — the whole shell now scales up on
  high-resolution displays so it stays legible when projected to a 4K TV or a
  projector, instead of rendering tiny at native pixels. Every surface is
  affected: the bar, dropdowns, launcher, dashboard, Exposé, the power / wallpaper
  / screenshot overlays, notifications, the OSD, and the settings window.
  - **Auto (default)** — each monitor is sized from its own height, so a 4K TV
    scales up (~2×) while a 1080p / 1440p laptop is left untouched at 1×. In a
    mixed setup the laptop bar stays normal while the TV bar grows.
  - **Manual override** — *Settings → Display → display scale*: turn off
    "auto scale" and drag the UI-scale slider (0.75×–2.5×). Persisted to
    `~/.config/sea-shell/appearance.json` as `"scale"` (`0` = auto) and shared by
    every surface; also saved/restored with appearance profiles.

### Changed

- **Settings window redesigned** — every tab is rebuilt on a shared control kit
  (toggle cards, aligned slider rows, chips, section headers), so labels, sliders
  and switches line up on one rail across the whole window instead of drifting per
  tab. Easier to scan and navigate; same settings, cleaner surface.
- **Caffeine bar pill** is now always a mug icon — muted when idle, lit warm
  yellow while it's keeping the screen awake (was swapping to a moon glyph).
- **Simpler keybinds editor** — *Settings → Keybinds* is now a clean
  name-and-shortcut list; click any bind (or the ＋ button) to open a focused
  popup that shows the details and lets you pick modifiers and press the new key,
  instead of the old inline rebind bar and add-form. Add and edit share one
  dialog.

### Fixed

- **Screenshot editor buttons did nothing.** OCR, copy and save were called
  through a stale object reference (`root.<id>` instead of the `id`), so every
  click silently threw and no capture ever reached the clipboard.
- **Copied / saved screenshots were blank.** The editor exported only the
  annotation overlay, not the screenshot underneath it — the image now composites
  correctly and lands on the clipboard as a real `image/png`.
- **Bar-widgets toggle alignment** — the on/off switches now line up on the right
  edge instead of stair-stepping (a long description no longer pushes the toggle out).
- **Night light could get stuck on.** Dragging the warmth slider while night light
  was on clobbered the process's on/off binding, so turning it back off left the
  screen permanently warm. Temperature changes now update the running `hyprsunset`
  live over its IPC (smoother, no flash) and the on/off state always tracks
  correctly.
- **Night light did nothing if `hyprsunset` was installed after the shell started.**
  The one-time startup probe would cache "not available" forever; the shell now
  re-checks whenever night light is switched on, so it works without a restart.
- **Control Center rendering** — the Night light tile no longer shows a stray
  "OFF" (invalid icon glyph), and the "Do not disturb" tile no longer truncates.
- **Display-settings alignment** — the warmth / UI-scale / per-monitor-scale
  slider rows now line up with the setting cards above them instead of sitting
  flush against the panel edge.

## [2.0.0] — 2026-07-13

The 2.0 release turns the bar into a full desktop shell: a Mission Control
overlay, a dashboard, screen recording, and a much smarter now-playing panel
with synced lyrics and track details.

### Added

- **Mission Control / Exposé** (`SUPER+W`) — a full-screen overlay of every
  workspace and the windows inside it. Click a window card to jump to it and
  focus it; click the close icon on a card to quit that window.
- **Dashboard overlay** (`SUPER+D`) — a frosted full-screen HUD with a live
  resource monitor (CPU/RAM sparklines, disk, load average), quick-command
  tiles (Wi-Fi, Bluetooth, caffeine, lock, mute, wallpaper), and a persistent
  sticky-notes / todo list.
- **Screen recording** (`SUPER+R`) — region screen capture via `wf-recorder` +
  `slurp`, toggled from the keybind or the bar, saving to `~/Videos/Recordings`.
- **Now-playing "track details" sidecar** — a panel that opens beside the media
  dropdown (opposite the lyrics panel) showing large album art, album, source
  player, bit-perfect quality readout, and live length / elapsed / remaining.
- **Time-synced lyrics** in the media dropdown — fetched from lrclib.net
  (free, keyless), highlighted line-by-line and click-to-seek, with a plain-text
  fallback when no synced version exists.
- **Alt-tab window switcher** — hold `ALT`, press `Tab` to cycle a visual
  switcher of every open window; release to focus the pick.
- **Universal launcher modes** (`SUPER+Space` / `CTRL+Space`): `>` run a shell
  command, `=` calculator, `~` file search, `;` clipboard history.

### Changed

- **Media pill icon** is now a clear music-note glyph instead of the raw
  play/pause bars, which read as two stray blocks at bar size. Play state is
  still shown by the dropdown; right-click the pill still toggles playback.
- **Lyrics fetching is faster.** The exact-match lookup now short-circuits — the
  common case is a single request instead of two sequential ones — and falls
  back through artist+title search and finally **title-only** search, which
  recovers lyrics when the player reports a romanized artist but lrclib indexes
  the original (e.g. "Shihoko Hirata" vs "平田志穂子"). Requests use `--compressed`.
- **Lyrics sync is tighter.** Playback position is polled every 150 ms (was
  400 ms) and interpolated between reports, so the highlighted line tracks the
  vocal instead of stepping, with a reduced anticipation lead.
- **The lyrics button now forces a fresh retry** when a previous attempt found
  nothing, so a track is no longer stuck on "no lyrics found."
- **Dashboard and Exposé overlays are now near-opaque** (~0.94–0.96) with more
  solid cards, so their content stays readable over open application windows
  instead of washing out.
- Version bumped to **2.0** across `VERSION` and the settings / About panel.

### Fixed

- **Mission Control and the Dashboard "Caffeine" tile did nothing.** Their
  keybinds/buttons call `toggleExpose` / `toggleIdle` over IPC, but those
  functions were never registered on the `shell` IPC handler, so the calls
  silently failed. Both are now exposed and working.
- **Lyrics broke when switching audio source.** A slow fetch for the previous
  source could finish after the new one and overwrite it (a lost-update race).
  Each fetch now stamps its reply with the track it was issued for, and any
  reply that no longer matches the current track is discarded — so switching
  sources always lands on the right lyrics.
- **Removed the bar-pill mini-visualizer**, which rendered as flat 1 px
  "underscores" for bit-perfect players (SONE) that bypass PipeWire, leaving
  cava with only silence to draw. The full visualizer inside the dropdown is
  unaffected.
- **Track-details panel no longer clips its last row** — it grows to fit its
  content rather than being fixed to the media card's height.

## [1.3.0] — earlier

- Reworked bar padding and added more bar customization options.
- Major overhaul of the matugen colour-generation pipeline.

## [1.x] — earlier

- Light/dark mode with scheduling, improved calendar, and dropdown opacity.
- Video wallpapers with automatic pause under fullscreen windows.
- Caffeine toggle, improved locking, screenshot tool, and multi-monitor fixes.
- Network/Wi-Fi handling and icon fixes.

[2.0.0]: https://github.com/MiyukiVigil/sea-shell/releases/tag/v2.0.0
[1.3.0]: https://github.com/MiyukiVigil/sea-shell/releases/tag/v1.3
