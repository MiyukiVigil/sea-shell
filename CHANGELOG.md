# Changelog

All notable changes to **sea-shell** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Laptop Lid Close Options**: Select what happens when the laptop lid is closed (Settings → *Power* or *Idle & lock*):
  - **Suspend** (lock & suspend system)
  - **Lock screen** (lock display, keep system running)
  - **Turn off display** (DPMS off, keep system running)
  - **Hibernate** (hibernate system to disk)
  - **Shut down** (power off system)
  - **Ignore** (do nothing on lid close)
  - Options persist to `hypr/keybinds.conf` via `sea-lock-settings.py` and apply live with `hyprctl reload`.


## [5.0.0] - 2026-08-02

**sea-shell's Hyprland config is now Lua.** Since Hyprland 0.55, hyprlang (`.conf`) is
deprecated and will be removed around **0.57** — so the compositor config is fully migrated
to the new Lua format, validated against Hyprland's own `--verify-config`.

> **Breaking:** requires **Hyprland 0.55+**, and your top-level config must be
> `~/.config/hypr/hyprland.lua`. See [hypr/README-lua.md](hypr/README-lua.md) to migrate an
> existing `hyprland.conf` (flip with a logout/login — **not** `hyprctl reload`).

### Changed

- **`sea.conf` → `sea.lua`, `keybinds.conf` → `keybinds.lua`.** Every binding keeps its
  description (the SUPER+K cheat-sheet reads `hyprctl binds`, so it's format-agnostic), and
  the look — general/decoration/blur/shadow, the two bezier curves + six animations, and the
  layer rules that frost the bar/dropdowns — is reproduced exactly in `hl.config` / `hl.curve`
  / `hl.animation` / `hl.layer_rule` / `hl.window_rule` form.
- **matugen now emits `matugen.lua`** alongside its live `hyprctl` apply, so the wallpaper
  accent persists and re-applies on login via `sea.lua`'s `dofile` (no runtime re-theming
  needed). A plain colour becomes a string; the gradient becomes `{ colors = {…}, angle = N }`.
- **Settings tooling writes Lua.** Keybind add/rebind and the lid-action setting edit
  `keybinds.lua` (falling back to `keybinds.conf` when present), producing valid `hl.bind`
  lines — verified against Hyprland.
- **`install.sh` is Lua-only.** It deploys `sea.lua` / `keybinds.lua`, wires a marker-wrapped
  `dofile` block into `hyprland.lua`, **purges any legacy `sea.conf` / `keybinds.conf` /
  `matugen.conf`** from a prior install, and strips the old hyprlang block from `hyprland.conf`.

### Kept on hyprlang (unchanged)

- **`hyprlock.conf` and `hypridle.conf`** — separate daemons that keep hyprlang per upstream;
  they are *not* the Hyprland compositor config and are unaffected by 0.57.

## [4.0.0] - 2026-07-27

A release in two halves: the **audio** and **window-management** surfaces grew real depth,
and four genuinely new tools landed — **display profiles**, **timers & pomodoro**, a
**world clock**, and a **screen magnifier**.

### Added

- **Display profiles** (Settings → Display → *layout profiles*). Save the whole monitor
  arrangement — resolution, position, scale, transform, enabled-state — and restore it in
  one tap when you dock or unplug:
  - monitors are matched by their **description** (make/model/serial) first and connector
    name second, so a profile still applies when an external screen returns on another port
  - a saved layout whose monitor set matches what's connected right now is flagged with a
    green check; apply and delete are inline
  - backed by `sea-display.py` (`--current` · `--save` · `--apply` · `--delete` · `--list`
    · `--match`), storing to `~/.config/sea-shell/display-profiles.json`
- **Timers & Pomodoro**, folded into the clock dropdown — no new bar widget to manage:
  - quick countdowns (1 / 5 / 10 / 15 / 25 min) plus a full **pomodoro** cycle with
    pause · skip · stop and a live progress bar
  - **focus auto-silences notifications** (flips DND on during focus, back off on breaks,
    restoring whatever DND state you started with), and every phase change fires a
    notification + completion chime
  - the **clock pill itself becomes the countdown** while a timer runs (🔥 focus / ☕ break
    / ⏱ timer), so it's visible with the dropdown closed
  - focus / break lengths and the DND behaviour persist to `~/.config/sea-shell/timers.json`
- **World clock**, also in the clock dropdown: add cities from a quick-pick list
  (New York, London, Tokyo, Sydney, UTC, …), each showing local time + day, refreshed every
  minute; chosen zones persist alongside the timer settings.
- **Screen magnifier** (Hyprland `cursor:zoom_factor`): `SUPER +` / `SUPER -` step the zoom
  (hold to repeat), `SUPER 0` resets. The level flashes in the shared volume/brightness
  **OSD** as a `1.5×` readout. Driven by a new `zoom` IPC target (`inc` · `dec` · `reset`
  · `toggle`).

### Changed

- **Audio got a proper mixer and routing layer** (bar volume dropdown + Settings → Audio),
  backed by a new `sea-audio.py`:
  - **per-app volume sliders** and **per-app output routing** — send any stream to any sink
    from the dropdown, no `pavucontrol` needed
  - **device format readout** — each sink shows its negotiated rate + bit depth (e.g.
    `48k · 24-bit`) and, when idle, the rate it will run at, with an "up to" hint for higher
    capabilities
  - **Bluetooth codec switching** — pick SBC / SBC-XQ / AAC / aptX / LDAC on a connected
    device (via the A2DP card profile), addressed by the sink's stable node name so the
    choice survives the sink being recreated on switch
- **Alt-Tab window switcher** now shows **live thumbnails** of every window (most-recently-
  used order), on the focused monitor only, with an app-icon fallback and click-to-focus —
  replacing the old icon-only strip.
- **Exposé / Mission Control** (`SUPER W`) now renders **live thumbnails** of each window in
  its workspace instead of a text list; click a tile to jump to it.

### Fixed

- Window-thumbnail overlays no longer leak a stray preview into a screen corner — the
  `ScreencopyView` texture node is contained to its card via an FBO layer.
- The switcher no longer mirrors onto every monitor (which read as a duplicate switcher
  "behind" the real one); it renders only on the focused output.
- **Caffeine mode is now sticky.** The desired state persists to
  `~/.config/sea-shell/caffeine`, is re-applied at startup, and is enforced on every poll —
  so a login or `hyprctl reload` can no longer silently drop you back to idle-sleep while
  caffeine is on. No more re-toggling it every session.

## [3.3.0] - 2026-07-20

### Added

- **Native KDE Connect integration.** Your phone lives in the bar — no external app, no
  KDE session pieces, nothing to run alongside:
  - a status pill (`wgKdeconnect`) showing the device icon and its **battery percent**,
    tinted the way the laptop battery is (green charging, red under 20%)
  - a **dropdown** in the same frosted style as wi-fi and bluetooth: battery bar and
    charging state, **cell signal strength + network type**, and one tap for
    **ring · ping · send file · send clipboard · browse files (sftp) · messages** —
    each greyed out when that device hasn't loaded the matching plugin
  - **pairing in place**: accept or reject against the verification key, or request a
    pair, plus a device switcher once more than one device is known
  - a **KDE Connect tab** in the control center with the same per-device actions, for
    when you want the whole list at once

  Everything goes through `sea-kdeconnect.py`, which talks to `kdeconnectd` over D-Bus.
  `--watch` is a resident process that re-reads the daemon only when D-Bus says something
  changed (battery, reachability, pairing), so the bar is live without polling anything;
  properties come back as JSON from `busctl --json`, one call per interface rather than
  one process per property, and the script starts `kdeconnectd` if it isn't on the bus.
  It also reports which plugins each device has actually loaded, which is what greys out
  the actions a given device can't do. `kdeconnect` and `zenity` — the file picker behind
  "send file", optional — were added to `install.sh`.

### Fixed

- **Display tab monitor refresh**: Modified the Display settings tab to automatically re-read connected monitors via `hyprctl` on open, making hotplugged screens appear instantly.
- **NVIDIA HDMI audio auto-routing**: Added automatic detection and activation of the NVIDIA HDMI audio controller profile (`output:hdmi-stereo`) and set it as the default output sink upon monitor connection.
- All of the above was spotted by me myself funny enough as I was watching the WC Final (Congrats to Spain btw) when I needed to plug in my monitor into my TV

## [3.2.1] - 2026-07-16

### Fixed

- **The EQ and recorder panels ignored matugen.** Change your wallpaper and the whole shell
  recoloured — except those two, which kept whatever accent the bar happened to start with.
  Two separate causes, both from being the newest panels and never having been wired up the
  way the others are:
  - They read `appearance.json` **once, at bar startup**, and never again — while matugen
    rewrites `accent` on every wallpaper change. Every other panel re-reads on open
    (`settings.qml` has done `apReadProc.running = true` in `showTab()` all along); these
    two had no `id` on the `Process` at all, so nothing could re-run it. Only restarting
    the bar picked up a new colour.
  - Their surfaces were hardcoded to `#0d1420` / `#e8eef5` and only the accent was tinted,
    so even after a restart they sat at a fixed navy while the rest of the shell followed
    the accent *hue* at low saturation. With a near-white matugen accent (`#cfcfd5`) in
    light mode, that read as a plain white box.

  Both now match `settings.qml`: hue-derived surfaces, re-read on `open()`. Verified by
  changing the accent with the bar left running — the panels open in the new colour instead
  of the startup one.

## [3.2.0] — 2026-07-16

A recorder and an equaliser release. **Screen recording** stops being a blind region
drag: pick what to capture and which audio — including mic and system together, which
wf-recorder can't do alone — and it no longer interrupts anything. The **equaliser stops
needing a DAC**: with no Moondrop plugged in the same panel runs the filters in PipeWire
instead, on your speakers or anything else. And it gains **Moondrop Hub's community
library** — ~59,700 user-made curves, searchable, previewed before you apply.

### Added

- **The EQ panel no longer needs a DAC.** With a supported Moondrop device the filters run
  on its DSP as before; without one, the same panel drives a **software EQ** through a
  PipeWire filter-chain — laptop speakers, another brand's DAC, bluetooth. It picks
  automatically, and a `DAC | software` toggle forces software even with a DAC plugged in
  (software has no Q2.30 limit, so the shelf gains the DAC must refuse work there).
  Community presets, AutoEQ import, the graph and the preset row all work either way.
  DAC-only controls (device slot, global offset) hide themselves in software rather than
  sitting there doing nothing.
- **`sea-eq.py`** — the software EQ is now sea-shell's own script, standalone: pipewire only,
  no Moondrop code, no `hidapi` import, usable from a terminal without this shell
  (`sea-eq.py --apply --from-rew ParametricEQ.txt`). It previously lived in
  `moondrop_control.py`, which is vendored from hub_moon and had no business knowing about
  pipewire — that file is now purely a USB-HID DAC controller. Its response maths is an
  independent standard-RBJ implementation (the DAC's uses Moondrop's swapped coefficient
  layout, which would be wrong here); checked against the old one across 12 real community
  presets, agreeing to within 0.42 dB — the difference 48 kHz vs 96 kHz explains.
- **Software EQ setup is managed, and doesn't interrupt anything** — the first apply asks,
  then writes one config to `filter-chain.conf.d` and starts `filter-chain.service`. That's
  a *separate* pipewire instance, so unlike the usual `pipewire.conf.d` recipe the main
  daemon is never restarted and no stream on the machine is dropped. Verified: main
  pipewire's pid is unchanged across install, apply, re-apply and remove.
  Editing is apply-based: pipewire 1.6 still advertises per-band control params but
  silently ignores writes to them (the graph moved under `audioconvert.filter-graph`), so
  a change re-renders and reloads — ~1s, on that sink alone. The panel says so.

- **Community presets in the DAC panel** — a *community* button opens a browser over
  the ~59,700-curve public library behind Moondrop Hub, searchable by name, author or
  description (the search runs over the whole library, not just the page you can see),
  sorted by downloads. Applying one fills every band through the same path the built-in
  presets use. You get your device family's whole pool — a DAWN PRO2 sees ~6,900 curves,
  not just its own 1,270 — because the server pools by shared config group. Reads need
  no account, and the panel never publishes or likes. Browsing opens no hidraw handle,
  so it can't collide with a band write in flight.
- **Preview before you apply** — clicking a preset draws its response; only the *apply*
  button touches the DAC. Titles like "三角洲" tell you nothing about what happens at
  3 kHz, and auditioning 59,700 strangers' curves one write at a time is not a plan.
  The preview also reports whether that curve would clip at your current pre-gain, which
  a published preset can't tell you — they carry bands and nothing else.
- **Back to top** in the preset list, once you're scrolled past the first rows.
- **Official-style response readout** — the graph gets a toggle (top-right) between the
  editor and the readout `hub.moondroplab.tech` draws: normalised so the flat reference
  sits at 60 dB, one curve, pre-gain paid for. Verified against the official app's own
  chart for the same preset — same dip at 200 Hz, same peak at 5.5 kHz, same rolloff.
  The editor view now also shows the *Flat* reference and a dashed **output** curve with
  pre-gain applied, so a +6 dB boost no longer looks free.
- **Screen recorder, rebuilt** (`SUPER+R`) — a chooser instead of an instant region
  drag: pick **what to capture** (region · focused screen · a named output) and **which
  audio** (none · microphone · system · **mic + system together**), plus framerate,
  container (mp4/mkv/webm) and CPU/GPU (VAAPI) encoding. Choices persist to
  `~/.config/sea-shell/recorder.json` and are passed as flags too, so a bare
  `sea-record.sh start` in a terminal reproduces exactly what the panel last did.
  `SUPER+R` stops a running recording rather than opening the chooser.
- **Mic + system audio at once** — wf-recorder takes exactly one `--audio` device, so
  the shell builds the mix itself (null sink + two loopbacks, recorded via its monitor).
  Torn down on stop, and swept on the next start *and* on the bar's status tick, so a
  killed recording can't strand a loopback holding the microphone open. The default sink
  is saved and restored across the mix, so loading it can't silently re-point playback.
- **Bit-perfect warning** — a player holding the DAC directly over ALSA bypasses
  pipewire, which makes the monitor system audio records from real, readable and
  *silent*. The chooser detects the exclusive hold and says so before you record.
- **Countdown** (off/3s/5s) drawn by the shell, click-through so it can't steal the
  pointer from whatever you're about to record, and gone before the first frame.
- **Recorder pill** — pulsing red dot + timer. Left-click stops and keeps (path to the
  clipboard, file size in the notification); right-click discards, arming first and
  showing `discard?` so a stray click can't delete a take.
- Device names in the chooser resolve the way a person would name them: a card with one
  output *is* the device ("DAWN PRO2"), a card with several is named by port ("Speaker",
  "HDMI / DisplayPort 2 Output") — instead of four chips all reading "Alder Lake PCH-P…".

### Fixed

- **The recorder could SIGTERM an unrelated process.** Liveness was `kill -0 <pid>`,
  which after the recorder exits is a question about whoever the kernel handed that pid
  to next. Stopping a dead recording would signal that stranger, then SIGKILL it five
  seconds later; status would also report a phantom recording forever. It now verifies
  the pid is still `wf-recorder` via `/proc/<pid>/comm`.
- `sea-record.sh status` exited non-zero when idle, breaking `&&` chains.
- A recording that fails to start (bad codec, missing render node, busy device) now says
  why, instead of silently never showing the pill.
- `wf-recorder` and `jq` were missing from the installer's package list, so screen
  recording was quietly unavailable on a fresh install.

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
- **Import and export, with a file browser built into the panel** — no external
  dialog: the panel is a layer-shell overlay holding exclusive keyboard focus, so a
  zenity/portal window would open *underneath* it and never take focus. Browse
  straight from the panel instead (Home / Downloads / Documents shortcuts, folder
  navigation, filtered listing). **Import** an AutoEQ / REW `ParametricEQ.txt` or a
  saved `.json` — applied live, so you can audition a measured preset for your
  headphones before committing it to flash. **Export** either a full JSON backup or
  a ready-to-use PipeWire software-EQ config.
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
