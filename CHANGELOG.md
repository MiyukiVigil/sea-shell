# Changelog

All notable changes to **sea-shell** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [8.0.0] - 2026-11-22
I was a bit busy for a while so most of these changes are stucked without a single commit (I hate myself). Hey atleast it's here now.

The largest sea-shell release yet (jumping directly from `7.1.0` with weeks of stacked work):
five native Rust daemons/apps (`sea-files`, `sea-appmenu`, `sea-fand`, `sea-gamepad`, `sea-panel`),
a full-screen **Big Picture** console mode & dedicated **`sea-shell Gaming`** login session,
a **~65% shell RAM reduction** (~715 MiB → ~250 MiB RSS), **two-tier zero-overhead Game Mode**,
a **Wallpaper Picker & Video Wallpaper rework**, **Alt+Tab Window Switcher & Workspaces Expose**,
a **34-page modular Control Center**, **GitHub / AI / DevHub / Totem 2FA**, and a full suite of
lazy-loaded desktop power tools.

### Native Rust Suite (`native/`)

- **Native Files (`sea-files`, Rust/GTK4).** Replaces the retired 15,000-line QML/Python file
  manager (`FileManager.qml` / `sea-fm.py`, archived under `legacy/quickshell-fm/`). Ships with
  tags, duplicate finder, subfolder search, thumbnails, `FileManager1` D-Bus registration,
  double-click AppImage installer (`sea-appimage.py`), and fast Unix-socket window handover.
- **Native background daemons in Rust.** Added `native/sea-appmenu` (DBusMenu + AT-SPI fallback
  global menu), `native/sea-fand` (fan-curve daemon for Acer Nitro / custom fan presets),
  `native/sea-gamepad` (evdev controller reader for Big Picture), and `native/sea-panel`
  (automatic laptop panel off/on on external display hotplug or lid close).

### Wallpaper Picker & Video Wallpaper Rework

- **Reworked Wallpaper Picker (`WallpaperPicker.qml`, `WallShelf.qml`, `WallStills.qml`).**
  Cleaner gallery, day/night wallpaper pairing, lock-screen wallpaper shelf, and instant still
  indexing without stalling the bar.
- **Bottom Wallpaper Strip (`WallpaperStrip.qml`).** Appears along the foot of the screen when
  cycling with `Super+N` / `Super+Shift+N` (or `qs -c sea-shell ipc call wallpaper strip`)
  without stealing keyboard focus; click any thumbnail to switch.
- **In-bar Video Wallpapers (`VideoWallpaper.qml`, `VideoWallpaperPlayer.qml`, `sea-wallpaper-optimize.py`).**
  Replaces `mpvpaper` and `sea-wallpaper-autopause.sh` with a QtMultimedia background surface that
  fades in over the full-res poster (zero black flash), re-encodes once in the background with
  VAAPI to screen size & fps cap, and unloads cleanly in fullscreen, Game Mode, or on battery.

### Window Management, Workspaces & Networking

- **Alt+Tab Window Switcher (`WindowSwitcher.qml`).** MRU `Alt+Tab` and `Alt+\`` (same-app)
  switcher driven by Hyprland global shortcuts with live `ScreencopyView` thumbnails, quick-tap
  instant swap, hover preview, and middle-click close.
- **Workspaces Expose (`WorkspacesPanel.qml`, `Super+W`).** True-scale monitor-layout cards with
  live window thumbnails, drag-and-drop windows across workspaces (or onto `+ New workspace`),
  Stash/scratchpad support, and **type-to-filter quick jump** (start typing any app/title and hit
  `Enter` to jump straight to it).
- **Enterprise Wi-Fi (802.1X / eduroam) & Wi-Fi Join QR (`WifiEnterprise.js`, `WifiJoinCard.qml`, `WifiDrop.qml`, `sea-wifi-qr.sh`).**
  Full PEAP + MSCHAPv2 identity/password join flow (cleaning up failed profiles automatically),
  plus 1-click scannable `WIFI:` QR code sharing for your active connection.
- **Per-Display-Arrangement Desktop Setups (`sea-setups.py`).** Remembers separate widget, bar,
  and dock arrangements per monitor configuration (keyed by display EDID description) and swaps
  automatically when docking or undocking.
- **Modular 34-Page Control Center (`SettingsPage*.qml`, `sea-sys-settings.py`).** Split the
  monolithic `settings.qml` (-6,400 lines) into 34 lazy-loaded pages (~140 MB less RAM when
  closed) with macOS-style System Settings (Date & Time, Language & Region, Hostname, Startup /
  Login Items, Accessibility, Input/Gestures, Window Rules, Screen Time, Privacy, Default Apps,
  Theme Profiles, Needs Attention, Disk Usage & Disk Cleaner, OTA Updates with automatic rollback,
  and Pinned/Recent sidebar favourites).

### Performance & Architecture

- **~65% RAM reduction (~715 MiB → ~250 MiB RSS).**
  - Replaced the in-process SilentSDDM preview `Loader` in `SddmPreview.qml` (which previously
    permanently `dlopen`ed CUDA/FFmpeg/VAAPI/QtVirtualKeyboard plugins) with a pure QtQuick preview.
  - Switched all 17 bar dropdown `LazyLoader`s from `loading:` to `activeAsync:` so closed
    dropdown surfaces destroy cleanly instead of retaining Mesa GL contexts, shrank `notifWin`
    from fullscreen to popup bounds, lazy-loaded `PolkitDialog.qml` and `WallpaperStrip.qml`,
    gated `WallStills` on visibility, and added post-cool `gc()` sweeps.
  - Tuned `libjemalloc` (`narenas:2,dirty_decay_ms:1000,muzzy_decay_ms:0,background_thread:true`)
    in `sea-bar-supervisor.sh` and preferred `Inter Variable` (860 KB) over `Inter.ttc` (12.6 MiB)
    in `fontconfig/60-sea-fonts.conf`.
- **`seashell` process identity.** The bar now launches via `${XDG_RUNTIME_DIR}/seashell` so
  process monitors (`btop`, `htop`, `ps`, Dashboard) display `seashell` instead of `qs`.
- **Modularized `shell.qml` dropdowns.** Extracted `ControlCenterDrop.qml`, `AudioDrop.qml`,
  `BatteryDrop.qml`, `WeatherDrop.qml`, `NotifDrop.qml`, `WifiDrop.qml`, and `BluetoothDrop.qml`
  into standalone `Tok`-styled components.
- **Automated health & lint checker (`sea-check.sh`).** Validates all shell scripts (`sh -n`),
  Python scripts (`py_compile`), QML files (`qmllint`), and the full unit test suite in one command.

### Gaming Mode (Two-Tier Zero-Overhead)

- **Level 1 — Smart Hibernate (always active in Game Mode).** Freezes ~25 non-essential timers
  and background subprocesses while gaming (`nvidia-smi` polling no longer grabs the NVML lock
  every 3 s, 30 s `nmcli` Wi-Fi rescans stop to eliminate online ping spikes, `githubEmber` 9 Hz
  repaints pause, `paru -Qua` / AI / weather / clipboard / camera polls pause, `sea-wallpaper-rotate.sh`
  goes dormant). Immediately cools idle panels + runs `gc()`, disables the dock, unmaps the bar
  surface when *Hide bar while playing* is enabled, and strips/restores Hyprland `rounding`,
  `gaps_in`, `gaps_out`, `border_size`, and `inactive_opacity`.
- **Level 2 — Ultra / Zero-Shell Mode (opt-in toggle).** Available in **Settings → Gaming**,
  **Dashboard → Gaming** (`Hibernate` / `Zero-shell` pill), and **Control Center**. Cleanly
  stops `sea-bar-supervisor`, `seashell`, `awww-daemon`, `sea-wallpaper-rotate`, and clipboard
  watchers for 0 MB shell overhead while gaming, with native Hyprland toast notifications and
  automatic restoration on game exit or `Super+Shift+G`.

### Added

- **Visual Clipboard Manager, Pinned Snippets & Emoji Picker (`ClipboardPanel.qml`, `sea-clipboard.py`).**
  `Super+V` opens a searchable clipboard overlay with real image thumbnails for copied screenshots,
  color swatches, URL badges, persistent pinned snippets (`~/.config/sea-shell/clipboard-pins.json`),
  and a searchable Emoji & Symbols grid (`Super+.`).
- **Instant Scratchpad / Markdown Notes (`ScratchNotes.qml`).** `Super+Alt+N` opens a multi-tab
  markdown pad backed by `~/.config/sea-shell/notes/*.md` with debounced auto-save and clickable
  `- [ ]` / `- [x]` checklist chips.
- **File Drop Shelf & Instant LAN QR Share (`DropShelf.qml`, `sea-dropzone.py`).** `Super+Alt+S`
  holds files/screenshots across workspaces, converts images (`→WEBP` / `→JPG` / `→PNG`), and
  shares any file to your phone via a scannable QR code over an auto-expiring local LAN HTTP server.
- **Color Studio & Eyedropper History (`ColorStudio.qml`, `sea-colorpick.sh`).** `Super+Alt+C`
  tracks colors picked via `Super+Shift+C`, copies as HEX/RGB/HSL/OKLCH, builds a 5-step tint/shade
  ramp, checks WCAG contrast (`AA`/`AAA`/`Fail`), and applies any color as sea-shell's live accent.
- **Workspace App Sessions (`SessionsPanel.qml`, `sea-sessions.py`).** `Super+Alt+L` snapshots
  currently open Hyprland apps per workspace and relaunches entire workspace setups in one click.
- **Screen Ruler & Pixel Measurer (`ScreenRuler.qml`).** `Super+Alt+R` measures exact `W × H px`,
  aspect ratio, diagonal length, and screen coordinates (`C` copies `WxH`).
- **Screen OCR → Instant Translate (`TranslatePopup.qml`, `sea-translate.py`).** `Super+Shift+T`
  captures a screen region with `slurp`+`grim`+`tesseract` (or reads clipboard/text) and translates
  between EN / JA / ZH / MS / KO / ES with 1-click copy.
- **Wi-Fi Join QR Code (`WifiDrop.qml`, `sea-wifi-qr.sh`).** One click in the Wi-Fi dropdown
  renders a scannable `WIFI:` QR code for your active connection.
- **Hybrid dGPU Wake Monitor & Auto Battery Saver (`BatteryDrop.qml`, `sea-dgpu.py`, `sea-power-auto.sh`).**
  Zero-NVML-wake sysfs + `/proc` monitor showing whether the discrete GPU is sleeping (`0 W`) or
  listing the exact apps keeping `/dev/nvidia*` awake, opt-in AC/Battery auto power-profile + 60 Hz
  switching, and auto-detected battery charge-limit chips (`60%` / `80%` / `100%`).
- **Live Localhost Ports, Containers & Systemd Services in `DevHub.qml` (`sea-ports.py`, `sea-services.py`).**
  One-click browser launch or kill for listening local dev ports, Docker/Podman container stops,
  failed/core systemd service status chips, and inline `journalctl` log peek.
- **Screenshot Editor Power Tools (`screenshot-editor.qml`, `PinImage.qml`).** Added Redact/Mosaic
  brush (`M`), auto-incrementing step-number badges (`N`), and **Pin to screen (`P`)** floating
  reference windows.
- **Quick Window PiP & Focus Snapper (`sea-win-layout.sh`).** `Super+Alt+P` toggles a pinned
  16:9 bottom-right Picture-in-Picture window; `Super+Alt+F` toggles a centered 75% focus float.
- **Per-App Audio Mixer & Notification Priority.** Added microphone gain/mute, per-app mute toggles,
  and direct sink picker pills in `AudioDrop.qml`; added star (`★` / `P`) priority rules in
  `NotifDrop.qml` & `NotifGroup.qml` so critical apps bypass DND.
- **Workspaces Overview Type-to-Filter (`WorkspacesPanel.qml`).** Start typing any app or window
  title in `Super+W` Overview to highlight matches across workspaces and press `Enter` to jump.
- **Launcher Power Upgrades (`Launcher.qml`).** Redesigned with a mode bar, elevated detail card,
  live `#hex`/`rgb()` swatch preview, `:kill` process killer, number-base (`255 to hex`), CSS
  (`1920px to rem`), and timezone (`14:00 utc to myt`) conversions.

### Changed & Redesigned

- **Unified `Tok` UI refresh** across `DashboardPanel.qml` (interactive process focus/kill,
  power profile switcher, now-playing strip, battery/network telemetry), `ControlCenterDrop.qml`
  (2×4 quick-toggle grid + inline volume/brightness sliders), `DevHub.qml`, `GamingHub.qml`,
  `ScreenshotPanel.qml` (Quick Copy `C`, OCR `O`, Recent strip), `RecorderPanel.qml`, `PowerMenu.qml`
  (`Big Picture g` shortcut), `LockSurface.qml` (privacy-safe notification count pill),
  `PolkitDialog.qml`, `keybinds.qml`, and `welcome.qml`.

### Previous Unreleased Work Rolled Into 8.0.0

- **Totem bar widget (`wgTotem`).** Search paired 2FA accounts and copy codes from the bar via
  the Totem CLI (`sea-totem.sh` → `totem list|code --json`). Enable under Settings → Menu Bar
  Widgets. Requires a built `totem` binary and a paired phone (desktop Totem app hosts the
  relay). Account rows show brand badges (Simple Icons) or letter colours when no CC0 logo
  exists (e.g. LinkedIn).

### Fixed

- **Focus profiles actually apply from Settings.** Chips call the bar’s `applyFocus` (DND, mutes,
  caffeine, night light, game mode, open Dev/Gaming). Clear restores the previous mute list.
  Mutes update in memory so the list does not wait for a bar restart.
- **GitHub auth failure no longer leaves a green cache.** Rejected or missing tokens write the
  error into the cache; the refresh control on the GitHub dropdown bypasses the cache.
- **Theme export wallpaper path** no longer writes a doubled extension (`wallpaperjpg.jpg`).

### Added (Earlier 7.x → 8.0.0)

- **Antigravity in AI plans.** Bar, desktop widget and Dev hub show Antigravity quota —
  Gemini Session/Weekly plus Claude/GPT third-party windows — from Antigravity / `agy`
  sign-in (Linux keyring), a running language server, `~/.gemini/oauth_creds.json`, or
  `~/.config/sea-shell/gemini-token`. Uses the Antigravity mark. Toggle under Settings →
  Bar Widgets → AI plans.
- **Tide pool desktop widget.** A rock pool that is secretly a sysmonitor: water level is
  battery, chop is CPU, fish speed is network, bubbles are notifications (and bottles still at
  sea), and the hermit crab hides while the mic or camera is on. Drag it from the widget tray
  (Tide). Click opens the dashboard.
- **Message in a bottle.** Launcher `!note` (or `:Cast a bottle`) throws a reminder into the
  sea; it washes up 20 minutes to 6 hours later as a notification and on the lock screen.
  `qs ipc call bottle cast "…"`.
- **GitHub streak flame.** The bar pill becomes a fire icon while your streak is alive, and
  sputters amber until you commit today.

- **GitHub on the bar, desktop and Dev dashboard.** Contribution grid, streak and commits
  today (via `gh` auth or `~/.config/sea-shell/github-token`), plus watched-repo CI and open PR
  counts from `github-repos.json`. Desktop widget sizes small/medium/large; bar pill `wgGithub`.
  Super+D → **Dev** tab; launcher `gh` / `gh …` searches your repos, PRs and issues.
- **Focus profiles.** Coding, Gaming, Meeting and Clear in Settings → Notifications and the
  GitHub bar dropdown: DND, mute apps, caffeine, and open the Dev or Gaming dashboard.
- **Task due dates.** Dashboard todos accept ` @YYYY-MM-DD` or `due:YYYY-MM-DD`, sort by due,
  and remind once when a task is due today.
- **Desktop widgets:** GitHub, Pomodoro (mirrors the bar timer), Clipboard history (marks OCR
  grabs), and a large media **Now playing** face.
- **Settings favourites.** Pin pages with the star; Pinned and Recent chips sit above the
  sidebar list.
- **Theme export.** Actions → Export theme pack writes a tarball of appearance, desktop layout
  and wallpaper under Downloads (`sea-theme-export.sh`).
- **Calendar ICS copy** clarifies Google Calendar secret addresses work without OAuth.

- **Gaming session.** "sea-shell Gaming" on the login screen starts Hyprland with big picture mode
  and nothing else: no bar, wallpaper, blur, animations or idle daemon (`hypr/gaming.lua`,
  `gaming.qml`). Power → Log out returns to the login screen to pick the desktop. install.sh adds
  the session entry (one sudo step).
- **Big picture can set everything up on its own.** An on-screen keyboard for the controller joins
  Wi-Fi networks that need a password and hidden networks; Y forgets a saved network. New
  Bluetooth page for headphones, speakers and pads (pair, connect, forget). Display gains
  resolution, refresh rate, scale (kept only after you confirm, otherwise put back in 15 s) and
  variable refresh rate. Sound gains the microphone. New Games page for the launch defaults every
  game starts with, and a System page with screen sleep, keyboard layout (gaming session) and
  free space. Heroic, Lutris and TwinTail open full screen in the gaming session, with Home to
  come back.
- **Log out from big picture.** Power → Log out, held like Restart, in both the desktop and the
  gaming session.
- **Prism Launcher instances in the Gaming tab and big picture.** Minecraft instances (native or
  Flatpak) join the library with their icon, playtime, last played and size on disk, and Play
  starts them through Prism. Game mode comes on with Minecraft and goes off when it closes: Play
  turns on Prism's "Enable Feral GameMode" (so launches from Prism itself count too), and while
  Prism is open, so that setting cannot be written, it watches the Java process instead.

- **A second Cursor account in the AI usage widget.** A Cursor profile started with
  `--user-data-dir ~/.cursor-alt/data` shows as its own "Cursor alt" meter beside the main one,
  with its own on/off and "On top" choice in Settings → Bar Widgets → AI plans. More profiles can
  be listed one per line in `~/.config/sea-shell/cursor-profiles`. A profile signed into the same
  account as the main one is skipped.
- **AI usage refreshes faster and holds steady.** Every plan is fetched at once (about 3 s instead
  of 10+), and a plan whose fetch fails keeps showing its last good numbers for up to an hour
  instead of dropping out until the next refresh.
- **AI usage alerts at 80% and 95%.** Each window warns once per level per reset, alongside the
  existing "running out before reset" pace warning.
- **Hot corners.** Settings → Desktop → Hot corners sets each screen corner to Overview, Launcher,
  Dashboard, Notifications or Widgets. Corners that touch another monitor are skipped, and none
  fire during a game or fullscreen window.
- **Battery health in the battery menu.** Shows how much of its original capacity the battery
  still holds and its charge cycles, when the battery reports them.
- **Colour picker.** Super+Shift+C, "Pick a colour" in the launcher, or the menu's Color Picker
  copy the hex under the cursor and show a swatch. Needs `hyprpicker`.

- **Lutris games in the Gaming tab and big picture.** Installed Lutris games (native or Flatpak)
  join the library with their playtime, last played, size on disk and Lutris cover or icon. Play
  starts them through Lutris, which keeps its own runner and launch settings.
- **Game backgrounds.** Lutris and TwintailLauncher games without a background look one up in
  the background: SteamGridDB when an API key is set in Settings → Gaming, then the Steam store
  on an exact title match. Background on the dashboard banner sets your own picture for any game,
  and Reset background goes back to the default.
- **Lutris and TwintailLauncher games count in Last two weeks and Saved runs.** Their Wine/Proton
  windows are matched to the library by install folder, so the bar times them and saves runs
  with GPU stats like Steam games. Two-week time also follows the launchers' own totals, counted
  from the first time sea-shell sees each game.
- **Heroic games (Epic, GOG, Amazon and sideloaded).** Installed Heroic games, native or Flatpak,
  join the library with Heroic's art and playtime, and Play starts them through Heroic.
- **Wine and Proton games get the game window rules,** so `.exe` and `steam_proton` windows skip
  blur, shadows and animations like Steam games do. The dashboard's Playing now shows them too.
- **Big picture sound effects.** Moving, opening, going back, toggles, putting a game in, launching,
  start-up and exit each have their own sound. Settings → Sound → Sound effects sets them to On,
  Quiet or Off.
- **Favourites and launcher filter in big picture.** Add to favourites on a game's Manage tab puts
  a star on its cover and adds a Favourites first sort. X in All games shows one launcher's games
  at a time. Each game page shows which launcher it's from and has a button to open that launcher.
- **Big picture mode.** A full-screen console view for the couch, in the shell's own look: games
  are cartridges on a shelf, and Play pushes one into the dock. Opens with a sea-shell startup
  screen, from the Gaming tab or a controller's home button, and works with a controller or the
  keyboard.
  - **Game pages** with tabs for an overview, launch options and runs. Launch options cover
    MangoHud and its limit, look and corner, Gamescope (mode, output size, render size, upscaling,
    frame limit), game mode, gamemoderun, and Proton's Wayland and HDR switches.
  - **Stats** with tabs for playtime, the library, every saved run, and hardware.
  - **All games** as a grid, sorted by recent, most played or name.
  - **Menus** for sound and output, screens, Wi-Fi, controllers with battery and Bluetooth pairing,
    fans and power, suspend, restart and shut down.
  - Game mode comes on with it and goes back off when you leave, unless it was already on. Other
    screens go black, or can be left on.
  - Starting a game no longer cuts to a separate page. The slot's light runs out along the footer
    and rises off it, showing the game's own title screen (its hero art and Steam logo, or its
    name) while it starts. The footer's "Starting" and Cancel stay on screen, and cancelling runs
    the light back down into the slot.
  - Steam stays out of sight. Opening big picture starts Steam in the tray if it is not running,
    Play waits until Steam is actually ready, and any Steam window that opens meanwhile is
    tucked away. Leaving closes the library window to the tray and brings back any Steam prompt.
    The game goes full screen before the launch screen drops, so the desktop and a split layout
    with Steam no longer flash past.
- **TwintailLauncher games in the Gaming tab** and launcher search, with their art, play time and
  last played. Play opens them through Twintail, which keeps their launch settings.
- **MangoHud look and FPS cap.** Settings → Gaming and the game banner set the cap (60 / 120 / 144 / uncapped), overlay (FPS only, compact, full) and corner. “File” keeps `~/.config/MangoHud/MangoHud.conf`. Left Shift+F1 still toggles the cap in game.
- **Gaming hub in the dashboard.** Super+D → **Gaming**: banner for the selected game, a cover shelf that
  opens into a searchable, sortable **All games** grid once there are more than four, a one-line
  **preflight** status, per-game **launch options** behind a button on the banner (MangoHud,
  gamemoderun, game mode on play, Gamescope presets), and a full-height **saved runs** list with
  aligned FPS and GPU columns, for all games or the selected one, plus a notification when a
  session ends.
- **Gaming pill on the bar.** Elapsed time and live GPU % while a game window is open; stats are
  recorded for the whole play session, not only when game mode toggles off.
- **Settings → Gaming.** Global launch defaults (GameMode, MangoHud, Gamescope), hide the bar
  while playing, and the fan preset game mode applies.
- **Launcher `g` prefix.** Search installed Steam games and play from the bar launcher; `g` alone
  lists recent titles.
- **Double-click an AppImage to install it.** Files moves it to `~/Applications`, adds it to your
  apps with its own name and icon, and offers Open. Nothing runs until you say so. Installing a newer
  version replaces the old one, and Uninstall sits with the app's other actions in the launcher.
- **Native Files (`sea-files`).** Rust/GTK4 file manager: Super+E and the global menu prefer it when `~/.config/quickshell/sea-shell/sea-files` is installed. Includes tags, duplicate finder, subfolder search, thumbnails, FileManager1, and a Unix-socket handover so repeat launches stay fast.
- **Needs attention.** The top of Settings → System is now one short list of anything that needs
  you: a failing or very full drive, a bar that keeps crashing, a kernel waiting on a restart, a
  background service that failed, fans that aren't set up. When nothing's wrong it says so. Urgent
  ones show a count in the sidebar and send one notification, even with Settings closed.
- **See what an update changes before you take it.** The update panel shows the changelog for the
  new version and warns about config files you've changed.
- **Updates can be undone.** Each update saves the version you were on. If the bar won't stay up
  afterwards, that version goes back by itself, and Go back does the same whenever you like.
- **A map of your bar** at the top of Bar Widgets, following every switch and drag.
- **Test buttons in Audio.** Play a sound on the current output, or watch a level meter to see
  whether the microphone hears you.

### Changed

- **Video wallpapers are drawn by the bar, not mpvpaper.** Each monitor gets a background-layer
  QtMultimedia player that starts behind the still poster and fades in on its first frame, so a
  switch never flashes black. Clips are re-encoded once, in the background, to the largest
  screen's size and the frame cap (30 fps unless set), cached in `~/.cache/sea-shell/wallvideo/`
  (VAAPI on the iGPU when available). A fullscreen window, game mode, or battery (if enabled)
  unloads the player and leaves the poster. `sea-wallpaper-autopause.sh` and the mpvpaper
  dependency are gone; the frame cap chips are now 30/60/24 fps. New IPC verbs:
  `wallpaper pause|play|status|remap`.
- **Less background work while idle.** The system monitor only polls while something shows it,
  the mic follows PipeWire directly, and the recorder and camera checks spawn far fewer processes
  (about 5 per second down to under 1; idle CPU about 3.2% to 2.4%).
- **Super+E is native Files only.** Legacy PySide6 FM moved to `legacy/quickshell-fm/`; `sea-files-launch.sh` errors clearly if the binary is missing.
- **Settings uses much less memory.** About 140 MB less while it's closed, because each page is now
  built the first time you open it. The slowest page takes about a tenth of a second the first time.
- **Appearance has three tabs instead of six.** Look holds the preview, theme, accent, font and
  icons on one page; Wallpaper stays; Advanced has colour targets, app preference and stickers.
- **Audio makes sense at a glance.** Devices are called what they are ("Speaker", "HDMI / DisplayPort
  3") with the chip as a footnote. Each app is one row with its volume and its output together.
- **Updating no longer stops itself.** It runs separately from the bar, so restarting the bar can't
  interrupt it, and it no longer tries to run the package manager with nobody there to answer.
- **Installing swaps the shell in whole,** so a running bar never sees a half-written copy.

### Fixed

- **Desktop widgets no longer keep idle threads.** Every widget started a folder watcher that only
  the photo widget uses; now only a photo widget reading a folder has one. The clock dial and the
  system gauges are drawn as shapes instead of canvases, so the clock no longer redraws a picture
  of itself every second.
- **The test suite passes again.** Several tests had fallen behind the code (the launcher's
  settings list, the Files desktop entry, two Settings ids sharing a name), the window switcher's
  tests never ran under `unittest`, and the retired file manager's smoke test is now skipped.
  Run them from `tests/`.

- **Panels no longer stack.** The dashboard, Settings, launcher, power menu, recorder and tour
  close each other, and a bar dropdown or the widgets drawer closes them too. The screenshot
  picker leaves what is open alone so it can be captured, and only big picture opening closes
  the rest, never the other way round.
- **The Gaming tab's banner kept the previous game's art** behind a game that has none.
- **Restarting the bar from Cursor's terminal blanked the launcher's icons.** Cursor sets
  `XDG_DATA_DIRS` to its own folder only, hiding `/usr/share`; the supervisor now drops editor
  entries from it and from `PATH`.
- **Files (Super+E) would not open after installing.** The installer's build of `native/sea-files`
  sat in a function nothing called, so the program was never built or copied into place. It is
  now built on every install, into the repo's own target folder even when an editor sets
  `CARGO_TARGET_DIR`. gtk4 is in the package list, and rust is installed when there is no cargo.
- **Games launched with a sea-shell profile died within a second.** The launch wrapper removed every
  `--` from Steam's command, including the ones Steam's own launch chain needs. Gamescope works
  on Hyprland again now that this is fixed, so the option is no longer skipped there.
- **Game options did nothing.** The banner chips were ignored until a cover had been clicked; the
  second of two quick clicks was lost; "1080p window" passed Gamescope a broken `-w`; "Game mode on
  play" off was overridden by gamemoderun's hook; and options written to Steam's config while it
  was running were discarded. The first Play of a game now restarts Steam once to install the
  wrapper, and never while a game is running.
- **MangoHud ignored `MangoHud.conf`** when a game went through the launch wrapper, so the layout,
  FPS cap and hotkeys set there were replaced by MangoHud's default box.
- **A hung Gamescope no longer stays over the desktop** after its game exits.
- **First open of the dashboard jumped.** It now has its readings before it opens, and Gaming shows
  nothing rather than "No games installed" until the library has loaded.
- **Bar workspaces out of order** (2 1 3) when a workspace was created in the middle of the list.

- **Gaming dashboard playtime bars** no longer animate past their track on the first open of the
  Gaming tab.
- **The global menu could show another app's menu.** After switching from an X11 app like VS Code to
  a Wayland app like Firefox, the top row stayed right but the open menu showed VS Code's rows, and
  clicking one acted in VS Code. A menu now only ever comes from the window it's drawn for.
- **Switches you could barely see.** On switches in Bar Widgets, Colour targets and Calendar had a
  dark knob on a dark track.
- **Colour target switches** sat in the middle of their row instead of at the end.
- **"Up to date" could be wrong.** After a manual `git pull` with no install, Settings said you were
  current while still running the old version. It now says the new one isn't installed yet.

## [7.1.0] - 2026-11-03

### Added

- **Disks can free up space now.** Settings → Disks lists what could go and what clearing each
  thing costs: caches, old packages, the Trash, build folders. Only the free ones start ticked,
  and when it's done it tells you what the drive actually got back, not an estimate. You can also
  walk down through your home folder to see what's taking the room, and send your biggest files
  to the Trash from the same page. Each drive now shows its health, temperature, how much of its
  life is used and how much it has written, with no password needed.
- **Quiet hours.** A new Notifications page in Settings silences popups on a schedule and while
  the screen is shared or recorded. Everything still reaches the notification list, urgent ones
  still come through, and the DND button lifts it until that stretch of quiet ends.
- **See what is using your mic, camera or screen.** A pill appears in the bar, naming the app, only
  while something is.
- **Notifications show their own pictures.** A sender's photo or a song's cover fills the big icon
  space, with the app's icon as a small badge.
- **Files opens real windows.** Super+E, New Window (Ctrl+Alt+N) and folders opened from other
  apps now give you another window instead of a tab in the one you had. They share one process,
  so a new window takes about a third of a second and about 30 MB, and closing it gives that back.
- **The fans have their own controller now.** A small service, `sea-fand`, replaces both the
  firmware's curve and fancontrol. Auto speeds up sooner than the firmware did (which ran
  about 3,300 rpm at 89°C), and every speed change is a slow ramp, so a short burst of CPU
  use no longer sets the fans off. Quiet is actually quiet now: it was louder than Auto
  (about 5,500 rpm against 4,000 under the same load), and it also lowers the power profile
  to power saver. Max is only flat out once the machine is hot. If the service stops or fails,
  the fans go back to the firmware. It needs one setup step:
  `sudo sh quickshell/scripts/system/sea-fan-setup.sh`.
- **Alt+Tab now works like Windows.** Hold Alt, press Tab to move through your windows,
  and let go of Alt to switch to the one you stopped on. It never switched before: Hyprland
  dropped the Alt release as soon as Tab had been pressed, so the switcher just stayed open.
  A quick tap swaps to your previous window without showing anything, right Alt works too,
  and a pointer resting where the switcher opens no longer changes your pick.
- **Workspaces (Super+W) in the new design.** Frosted over the wallpaper, each workspace is a
  rounded picture of its monitor with your wallpaper behind the windows, named underneath.
  It opens on the monitor you are using, and windows on your other monitors now sit where
  they really are. Clicking a window goes straight to it, which did nothing before.
- **Move windows between workspaces from Super+W.** Drag a window onto another workspace, or
  onto the New workspace strip to start one (N does the same without a window). Hover a
  window for its name and a close button; a middle click closes it too.
- **Alt+` cycles the windows of the app you are in,** and Alt+Tab tiles can be closed the same
  way, with the cross or a middle click.
- **One voice across the shell.** Settings pages and the wallpaper picker were still in
  monospace with lowercase labels, and bar menus mixed lowercase, tracked capitals and tiny
  text. All of it now uses the interface font and sentence case. Monospace stays where it
  helps: window classes, file names, and the wallpaper number. Settings no longer repeats a
  page's name as a heading right under it.
- **Four new desktop widgets: network, notifications, photo and quote.** Network shows
  the connection and its signal, the download and upload rates, a minute of traffic and,
  large, each interface. Notifications shows how many are waiting and the newest ones.
  Photo shows a picture that changes every fifteen minutes or on a click, from your
  wallpapers (videos use their poster frame), Pictures or Screenshots. Quote shows a quote
  a day; click for another. All four come in small, medium and large, in the widget
  drawer, whose tabs show their names only for the chosen one now that there are ten.
- **Alignment guides while arranging widgets.** A dragged widget is pulled onto other
  widgets’ edges and centres, the middle of the screen and a margin from each side, and a
  line shows what it has locked onto. Hold Shift to place it freely.
- **The lock screen shows the weather and your next events.** They sit in small pills
  under the date. An event’s name is hidden when notifications are set to app names only.
  Turn them off under Idle & lock → lock screen.
- **A layout for each set of displays.** sea-shell remembers your widgets, the dock and the
  bar’s edge for every combination of displays, so docking and undocking bring back how
  each one was arranged. A combination seen for the first time keeps what you have. It is
  under Settings → Display → layouts, on by default.
- **A wallpaper strip.** Super+N and Super+Shift+N now show your wallpapers in a row along
  the foot of the screen for a moment, with the current one ringed, so you can see where
  you are in the collection; click any of them to switch to it. It never takes the
  keyboard. `qs -c sea-shell ipc call wallpaper strip` shows it on its own.
- **A What’s new page for 7.1**, shown once after updating, as 7.0’s was.

### Changed

- **The notification list matches the popups,** with the app's icon large on the left and the details
  beside it.
- **Settings gained Do not disturb and Muted apps** on its Notifications page, so a muted app can
  be found and unmuted.
- **Tidier wording and larger small text.** Settings' remaining lowercase sentences are now proper
  ones, 9-10 px text is 11 px across Settings, the bar and Files, and the launcher and Dashboard
  keep monospace only where figures need to line up.
- **The Files preview panel follows your accent and theme** like the rest of Files.
- **The media panel no longer names a character** next to your sticker.
- **Notifications lead with a big icon.** The app's icon sits large on the left with the details
  beside it, and the shell's own notifications carry the sea-shell logo and its name instead of
  a bell and "notify-send".
- **Quiet also caps the CPU.** The firmware will not let the fans run below its own curve, so less
  heat is what makes Quiet quieter. Auto and Max leave the CPU alone.
- **Game mode waits before turning off.** Steam's launch steps made it switch off and back on
  several times per launch; it now only turns off if nothing is using it 8 seconds later.
- **Less memory on hybrid laptops.** The bar and Files no longer load NVIDIA's graphics libraries
  when they draw on the integrated GPU, about 30-40 MB each.
- **The media panel is tighter.** Shuffle and repeat are icon buttons beside the transport
  rather than bare words below it, and a progress bar with times takes up the empty space.
- **The bar, its menus, notifications and the dock are glass now, done properly.** The old
  see-through setting let whatever app was underneath show straight through, so the bar
  went dark over a dark window and text was hard to read in places. Now Hyprland blurs the
  wallpaper behind them (never the app under a menu), the tint never goes below what keeps
  text readable on any picture, and a hairline edge and a soft sheen along the top give
  them the lit edge macOS's materials have. The blur no longer dims what it blurs. Settings
  → Appearance → material picks solid, frosted (the default) or clearer.
- **The bar's pills and every dropdown were redrawn to match.** Pills are quiet fills
  instead of outlined boxes (an "outline" widget style keeps its rim), and the rows,
  headers, chips and tiles inside the dropdowns and Control Center use see-through tints
  rather than solid grey steps that looked like patches on the glass.
- **Notifications look like macOS's.** Each popup shows the app's icon, its name and
  “now”, the title, the message and the app's buttons as pills, with a round close button
  on hover. The notification list uses soft cards without outlines.
- **The rest of the old outlined style is gone.** Files' dialogs (new folder, rename,
  properties, conflicts, batch rename, Preferences) get a lighter dim, filled fields that
  outline only when focused, pill buttons and the shell's switch. Arranging widgets (the
  gear menu, sizes, the gallery's buttons) and the lock-screen and login-screen settings
  pages lost their grey boxes and outlines too.

- **A new launcher.** Results sit on the left in groups (open windows, apps, files,
  clipboard, system), and the right side shows the selected one: a capture of the window,
  an app’s description, history and its own actions (New private window, …), a large
  copy of a clipboard image or the text inside it, the start of a text file, or a sum’s
  answer in large type. The frame keeps one size while you type, the footer names what
  Enter will do, and the prefixes are buttons along the bottom. One click selects a row,
  a second click opens it.
- **The wallpaper picker is the sea now.** The frames float on a waterline along the
  bottom of the screen, bobbing out of step, each with a rippled reflection, and the name
  and details are printed on the water. Choosing one sinks it, a tide rises up the screen
  in your accent colour and drains away to leave the new wallpaper. This replaces the
  cartridge-and-console animation; search, filters, sorting, import and video previews
  work as before.
- **The dashboard matches Settings and the widgets.** It opens as a sheet over the
  dimmed desktop instead of blanking the screen. CPU, memory, disk and GPU are ring
  gauges, as on the System widget, with the last minute on one chart. Wi-Fi, Bluetooth,
  Caffeine and Sound are Control Center tiles you click anywhere to switch. Today’s app
  time is shown as bars, and tasks have round checkboxes, with delete on hover. It now
  opens instantly: the shell keeps it ready instead of starting a new program on every
  Super+D, and it checks nothing in the background while closed.
- **Keyboard shortcuts (Super+K) are grouped.** Apps, Shell, Windows, Workspaces, Capture
  and Media each have their own panel. An action with two shortcuts is one row (Terminal:
  Super Enter or Super T), Workspace 1–10 is one row until you search, and keys are drawn
  as key caps. Unnamed helper binds no longer show up as “HL.Dispatcher(exec_cmd) 67”.
  Changing a shortcut happens in a bar along the bottom, and New shortcut opens a form
  at the top.
- **Screenshots and recording match the rest of the shell.** The screenshot picker is a
  capture bar near the bottom of the screen, with each target’s key on its button. The
  editor’s toolbar has round tools and swatches and named Copy and Save buttons, and pen
  text uses the shell’s font. The recorder uses segmented controls for audio, frame
  rate, format, encoder and countdown, shows capture targets as tiles, draws the
  countdown as a ring, and opens instantly. The screenshot picker’s “save to ~/Pictures”
  switch is gone: it never did anything, and the editor’s Save button does the job. The
  screenshot picker now stays loaded in the shell like the dashboard, so Print opens it
  at once.
- **A new look for the dock.** A rounder shelf, a dot under each running app (in your
  accent for the app you are in), a divider between kept and running apps, an icon that
  dips when pressed and bounces while an app launches, and a two-line label with the
  app’s name. The dock now follows the panel opacity setting, which it ignored before.
- **The welcome tour, password prompts and Wi-Fi password card match Settings.** Sans
  type in sentence case, quiet filled controls instead of outlines, pill buttons, round
  colour swatches and step dots that stretch for the current step. The password prompt is
  a centred sheet with your picture, the program in full, and two equal buttons.
- **Files looks like the rest of the shell.** The toolbar is soft capsules, the search and
  filter boxes are filled, the sidebar headings are in sentence case, and the tab strip
  only appears once there is a second tab (Ctrl+T or File → New Tab opens one). The path
  starts at Home inside your home folder, and when it is too long for the bar its start
  fades out instead of being cut mid-word.
- **Files opens instantly after the first time.** Closing the window now hides it, and the
  next Super+E (or any app asking to open a folder) hands over to it and shows it
  again, in about a tenth of a second instead of nearly a second. It comes back as a
  new window would: one tab, nothing selected. It quits by itself after 20 minutes
  unused, File → Quit Files (Ctrl+Q) quits at once, and Preferences → “Keep Files ready
  after closing” turns it off. The hidden split-view pane no longer scans your home
  folder at start-up.
- **Files works from the keyboard.** Arrow keys move the selection (Shift extends it),
  Home and End jump to the ends, Enter opens, Backspace goes to the enclosing folder,
  and typing a name jumps to it.
- **The lock screen is set under Idle & lock.** Its preview, the notification choice and
  the clock options moved from Your profile to Idle & lock → lock screen, next to the
  other locking settings. Your profile keeps the picture and name.

- **Widgets keep clear of the wallpaper’s subject, and line up when they move.** A
  widget now needs a little room around it, not just the space under it, so cards no
  longer sit flush against a face or a strand of hair. A widget that has to move goes
  somewhere comfortably clear, so the next wallpaper doesn't move it again, and it snaps
  into line with a nearby widget with an even gap.
- **Tidy up.** A new button in the widget drawer lays every unpinned widget out as one
  aligned block in the calmest part of the wallpaper: even gaps, small widgets side by
  side. It only runs when you ask; wallpaper changes still nudge widgets one at a time.
  Pinned widgets stay where you put them.

- **The shell starts more than twice as fast.** In testing, the bar appeared after about 2.4 seconds
  instead of about 6. Settings and the welcome tour used to load during startup, and
  the shell showed nothing until they were finished. They now load after the bar is up,
  at the first moment you are not using the keyboard or mouse, followed by the widget
  drawer. The bar’s dropdowns are also built in the background instead of at startup.
  Opening Settings before it has finished loading opens it as soon as it is ready.
- **The laptop screen can step aside for an external display.** Settings → Display has a
  new laptop screen section: turn the laptop panel off whenever an external display is
  connected, or only while the lid is closed (on by default). Its windows move to the
  external screen, and it comes back on at its own refresh rate when the external display
  is unplugged or the lid opens. The laptop panel is never turned off when it is the only
  screen.

### Fixed

- **Disks showed no root usage on btrfs.** "Root used" stayed blank and the system partition was
  labelled `/var/tmp`, because a partition mounted once per subvolume only reported one of them.
- **Notifications arriving together stay visible.** In a burst, the earlier cards were left stuck
  nearly transparent.
- **No more of the last app's menu under the new app's name.** Switching from an app with a global
  menu to one without showed its File, Edit, View for up to a quarter of a second before the
  workspaces came back. The strip now fades out as soon as focus moves.
- **Switching between an app with a menu and one without is quicker and stays smooth at speed.**
  Apps with no menu no longer wait on a slow lookup at every visit, interrupted fades carry on
  instead of blinking, and an app's raw class name no longer flashes before its menu.
- **The shell's password prompt is actually used.** `hyprpolkitagent.service` could take the only
  agent slot at login, so the styled prompt never appeared. The installer now disables the service.
- **Super+S works straight after login.** It used to do nothing until Settings had loaded.
- **Game mode switched on by hand now includes Feral gamemode.** The tile and Super+Shift+G
  only changed the desktop side; the CPU governor and process priority were left out unless a
  game had asked for them.
  Leaving also retries the power profile for a while, since the CPU driver refuses the change
  until Feral has let go of the governor.
- **A fan preset no longer comes back by surprise.** After a reboot the row showed Auto while
  the saved preset could still be Max, so the next game launched through game mode went to
  full speed. The preset now survives a reboot, so what the row shows is what is used.
- **Choosing Auto no longer reports "sea-fancurve not set up"** when it had in fact worked.
- **Restoring a saved display layout turns a switched-off display back on.** The layout
  was applied without saying the display should be on, so one that was off stayed off.

- **The health check no longer says the bar is not running when it is.** It only
  recognised the bar’s old command line, not the one the supervisor uses now.
- **The power menu, Settings, the dashboard, the screenshot bar and the recorder open after
  a display is switched off.** Each one sat on the display it last opened on, so when that
  display went away (lid shut, monitor unplugged) it had nothing left to draw on and the key
  did nothing. They now open on the display you are using, where the cursor is, and are
  rebuilt there whenever the old one is gone. The recorder also opens there now, instead
  of on whichever display came first.
- **A switched-off display stays listed in Settings → Display.** The laptop screen used to
  vanish from the page while an external display had it turned off. It now shows as off,
  says why, and has a button to turn it back on.
- **Previews in Files work for many more files, and big pictures load quickly.** PDFs
  showed no pages unless the optional PyMuPDF was installed, and Word, Excel and other
  Office files (previewed by way of a PDF) failed the same way; both now render with
  poppler, which nearly every desktop has. WebP, TIFF, AVIF, HEIC, JPEG XL, PSD and camera
  RAW files get a thumbnail and a preview through ImageMagick, since Qt here cannot read
  them. Archives list what is inside, and EPUBs show their cover and first page. Files
  with no preview no longer leave the panel loading forever, a name with #, ? or % in it
  no longer stops its picture loading, and large photos are decoded at the size they are
  shown rather than in full. Pages render at 200 DPI instead of 300, which is quicker
  and still sharp. The inspector’s heading and buttons now match the rest of the window,
  and it no longer lists the size twice.
- **The calendar widget lists your events.** Its medium and large sizes read the battery
  list by mistake and showed blank “Event” rows.
- **The bar’s log no longer fills with desktop widget errors.** A widget removed just after
  it was created threw an error each time.
- **Desktop widgets glide when the wallpaper moves them.** A widget nudged out of the way
  of a new wallpaper used to jump; it now travels there, and a dropped widget no longer
  flickers back to its old spot first.
- **Wi-Fi shows that it is connecting.** The bar icon steps through its bars, the dropdown
  and Settings mark the network being joined, and NetworkManager’s own reconnects show
  too. Before, nothing changed until the handshake was over.
- **The last panel on each Settings page is no longer cut off.** Pages scroll far enough
  to show its bottom edge.
- **Typing a Wi-Fi password in Settings survives the background scan.** The list used to
  be rebuilt every 10 seconds, taking the half-typed password with it.

## [7.0.0] - 2026-10-30

The lock screen, power menu and password prompts now share the shell’s design.
Notifications group by app, dropdowns share controls, and calendar and battery widgets
adapt to the wallpaper. The launcher finds open windows, while Settings and uninstall
handle navigation and restoration more reliably.

### Fixed

- **Settings ignores invalid page requests.** Bad tab numbers fall back to About;
  longer help text is shorter and repeated Apply boilerplate is gone.
- **Uninstall restores more of your desktop.** GTK fonts are saved before installation
  changes them, the kept idle configuration returns to hyprlock, and the previous file
  manager is recorded before selecting Files. Uninstall restores those saved values,
  preserves a later file-manager choice, and restores hyprpolkitagent at login. Missing
  backups are reported instead of guessing your previous settings.

- **Settings and the power menu open on the active workspace’s monitor.** Moving to
  another monitor before opening either panel no longer leaves it on the previous one.

### Added

- **A “What’s new in 7.0” page after upgrading.** Six short notes cover the lock, power
  menu, password prompts, notifications, dropdowns and widgets. It appears once; new
  installations keep the setup tour.

- **Papirus folders can follow the wallpaper accent.** Enable it in Settings → Appearance
  after installing `papirus-folders` and running `./install.sh --folder-helper`. Reset
  restores the default folder colour and turns following off. The helper only accepts
  named colours for the three stock Papirus themes.

- **Find open windows in the launcher.** Search an app or window title to see its open
  windows and workspaces above app launch results. Enter focuses the selected window.

- **A new lock screen, built into sea-shell.** The lock is now `lock.qml`, a Quickshell
  session lock that looks like the login screen it hands back to. It has two states:
  - **Clock.** Your clock in your profile font, the date, and the notifications that
    arrived while you were away, grouped by app. Each group shows the newest message and a
    count of the rest.
  - **Unlocking.** Any key or click switches to it. The wallpaper blurs and your picture,
    name and password field come up. Shown under the field, most urgent first: a wrong
    try (which also shakes the field and counts your tries), Caps Lock, PAM messages
    such as fingerprint prompts, and the keyboard layout when you have more than one.

  Now playing, battery, and a power menu (suspend, restart, shut down) stay along the
  bottom in both states. Restart and shut down need a second click.

  Settings → Profile shows a live preview of the lock with sample notifications. It also
  lets you choose how much of a notification the lock shows (all of it, only app names, or
  nothing) and switch back to hyprlock.

  The lock checks your password with the same PAM stack hyprlock used, so faillock and
  fingerprint readers behave as before.
- **A redesigned power menu.**
  - **Hold to confirm.** Log out, restart and shut down are now held instead of pressed
    twice: a ring fills around the icon, and letting go early cancels. This works with the
    mouse or the letter key (hold R). Lock and suspend still act at once.
  - **What will close.** For the three actions that end your work, the menu lists the
    apps that would close.
  - **Smaller header.** Your profile is a single row, with uptime and battery beside it.
  - **Two new options along the bottom.**
    - *Firmware setup*: hold F, or hold the button. Shown on UEFI machines only.
    - *Shut down later*: in 15 min, 30 min or 1 h, using a systemd user timer. The menu
      shows the scheduled time and can cancel it.
- **The lock cannot strand you.** The lock runs as its own process, so reloading or
  crashing the shell never touches it. `sea-lock.sh` waits for the compositor to confirm
  the lock. If the lock does not come up, or exits without a real unlock, hyprlock takes
  over the still-locked session. Two things make that work:
  - `misc:allow_session_lock_restore` is now on, so Hyprland accepts the second locker.
  - The lock records the unlock only *after* unlocking, so a crash at the worst moment
    costs a second password, never an open session.

  hypridle's `lock_cmd` now goes through `sea-lock.sh`, and install.sh updates a kept
  hypridle.conf that still has the old default.

- **Gaming fans in quick settings.** An Auto / Quiet / Max row under the power profile
  sets the profile and the fans together (`sea-perf.sh auto|quiet|max`). Auto hands the
  fans back to the firmware, Quiet runs a low lm_sensors fancontrol curve, and Max pins
  them at full speed. A fixed speed is used for Max because a curve hunts audibly when the
  temperature sits near one of its edges. The fan half needs root, so it goes through a
  small helper, `sea-fancurve`, that accepts only those three presets and is run through a
  sudoers rule. The row stays hidden until that helper is installed in `/usr/local/bin`.
- **The global menu fades in instead of popping.** Moving to a window with a menu bar
  now fades the workspaces and title out and slides the menu in where they were. Moving
  back fades the workspaces in. Reduced motion turns both off.
- **Game mode switches itself on and off.** Feral gamemode's start/end hooks
  (`~/.config/gamemode.ini`, written by install.sh when you have none) run
  `sea-gamemode.sh auto-on|auto-off`, so any game launched through `gamemoderun` turns game
  mode on, and it turns off when the last one exits. Game mode switched on by hand is never
  turned off by a game exiting.
- **Game mode handles the fans and the idle lock.** It applies the last "gaming fans" preset
  and restores the previous one afterwards, and it stops hypridle while you play, since a
  controller does not count as input and the screen would otherwise dim and lock mid-game.
  Picking a fan preset while game mode is on keeps the performance profile.
- **sea-shell answers password prompts itself.** The "allow this change?" dialog for
  pkexec, package managers, mounting and similar requests is now drawn by the shell.
  - **Who:** your picture with a lock badge, or a shield when the password is for another
    account.
  - **What:** a command is shown whole, in mono, instead of cut off mid-path.
  - **The field:** works like the lock screen's. It shakes on a wrong try and counts tries,
    and it also allows paste and has a show-password toggle.
  - **Details:** shows the polkit action and the account.
  - **Placement:** the dialog opens on the screen you are using.

  hyprpolkitagent no longer starts at login. The shell starts it as a fallback if it cannot
  register as the agent itself.
- **Notifications are grouped by app.**
  - **The centre** shows one card per app: the newest message in full, a line naming the
    next one, and the rest stacked behind. Click the card to see every message, each with
    its own dismiss.
  - **On hover:** mute, dismiss-app and expand controls appear.
  - **Keyboard,** while the centre is open: ↑↓ moves between apps, ⏎ shows all, Delete
    dismisses, M mutes, Ctrl+Z undoes.
  - **Undo:** every dismissal, including "clear all", can be undone for 8 seconds.
  - **Popups** group too: a new message from an app already on screen replaces its card
    and shows "3 new", instead of stacking a column of cards.
- **Two new desktop widgets: Calendar and Batteries.** Both come in all three sizes.
  - **Calendar:** small is today as a page with the next event. Medium puts the page
    beside what is coming up. Large adds the month, with dots on days that have events.
  - **Batteries:** shows this computer and every connected Bluetooth device that reports
    a level. Small is a ring, medium is a ring per device, and large is a list with time
    left.
- **Clear widgets keep their text readable.** The wallpaper map now records how light the
  picture is under each cell. A widget drawn straight on the photo (the clear look, a bare
  clock) uses dark text on a light patch and light text on a dark one.
- **Stickers.** Put a picture of your own on the corner of the power menu and the media
  dropdown in Settings → Appearance → theme → stickers. None by default; a GIF moves while
  its panel is open.

### Changed

- **The power menu and Settings open at once.** Both are now kept "warm".
  - **Settings** used to drop its window on close and rebuild it on every open, which was
    160–220 ms before the first frame. It now draws within about 10 ms and is fully up by
    about 65 ms.
  - **The power menu** started a fresh Quickshell process on every SUPER+ESC, about 310 ms
    plus Hyprland's open animation. It now lives in the shell and opens in about 40 ms.
    `power.qml` still runs on its own when the shell is not running.

  "Warm" means a closed window stays mapped as a single transparent pixel that takes no
  input, so opening it only grows it back.
- **The bar's power dropdown follows the new power menu.**
  - Lock and Suspend are two quick buttons.
  - Log out, Restart and Shut down are held rows: a fill sweeps across the row while you
    hold, replacing "click again".
  - A pending timed shutdown shows here and can be cancelled.
  - "More options" opens the full menu.
- **Bluetooth, sound, battery and calendar match the Wi-Fi dropdown.** They now share
  three building blocks (`DropHeader`, `DropSection`, `DropRow`): a title, a status line
  that says what is happening, section labels, and rows that tint the current choice.
  - **Bluetooth:** your devices are split from nearby ones. Battery level shows as a
    reading, and disconnect appears on hover.
  - **Sound:** outputs are called what they are ("Speakers", "HDMI 1"), with the sound card
    underneath, instead of four rows that all began "Alder Lake PCH-P High Definition Aud…".
  - **Battery:** says how long is left, or how long until full, and describes each power
    profile.
  - **Calendar:** opens on today's date and your next event.
- **New default fonts: Inter and JetBrains Mono.** Inter is the interface font and
  JetBrains Mono is used for numbers, code and the terminal. install.sh installs both. It
  points fontconfig's `sans-serif` and `monospace` at them (from `conf.d`, so your own
  fonts.conf still wins) and sets the GTK fonts when they were still on the stock Adwaita
  or Cantarell. The shell's mono font was Roboto Mono, which was never installed.
- **The bar's dropdowns follow your font.** 128 places in the bar (and 6 in the media
  player) had "Adwaita Sans" written in, so they ignored the font chosen in Appearance.
  They now use it.
- **Arranging widgets is easier on the eye.** The "busy" parts of the wallpaper show as a
  soft shadow instead of a grid of red squares. The shadow is one small image stretched
  smoothly, where it used to be 5,184 rectangles. Each widget gets a light outline instead
  of a solid frame, so glass and clear widgets still look like themselves while you move
  them.
- **The widgets handle is at the bottom.** It sits on the bottom edge, left of the dock,
  where the drawer actually comes from. Hovering shows a "Widgets" pill; click it or drag
  it up. It used to be a sliver on the left edge that you pulled sideways.
- **New widgets land in spaces their own size.** The wallpaper map now works out calm
  zones for the small, medium and large footprints, instead of three generic shapes.
- **The global menu has room to breathe.** Menu titles have 10 px of padding on each side
  instead of 7, so "File Edit Selection" no longer runs together. The app's name cell no
  longer squeezes its icon against the edge.
- **A new logo.** A moon setting over the sea, drawn in your theme colours: the sea takes the
  wallpaper accent and the sunset stays warm. It replaces the three waves everywhere sea-shell
  draws its own mark.
- **A shorter README**, led by pictures.

### Fixed

- **With two monitors, the global menu showed on the wrong bar.** Moving the pointer onto
  an empty screen focused that screen while the window kept the keyboard. The window's menu
  and title then jumped to the empty screen's bar, and the screen it was actually on went
  back to workspaces. Both now follow the monitor the active window is on.
- **SUPER+W, the screenshot pin, the launcher's Caffeine toggle and `openWidget` did
  nothing.** Two IPC handlers both claimed the `shell` target. Quickshell keeps only one
  handler per target, and the one with just `reload` was the one it kept. They are now one
  handler.
- **Settings opens and closes in one piece.** The panel was laid out against its one-pixel
  closed size, so every open rebuilt all 24 pages in view; it now keeps its size while
  closed. It also fades as one picture: before, each part faded on its own and the parts
  behind showed through, and closing greyed out every control for the length of the fade.
- **Settings tabs answer the first click.** A tap that moved by a pixel was read as scrolling
  the sidebar.
- **Reloading the shell no longer wipes notification history.** A notification arriving while
  history was still loading saved an empty list over it.
- **System and battery widgets update smoothly.** Gauges sweep to new readings instead of
  flashing as they were rebuilt.
- **`sea-bar-supervisor.sh --restart` brings the bar back.** It stopped the bar and then failed
  to start the new one.
- **Quickshell's "Config reloaded" card no longer sticks on screen.**

## [6.5.0] - 2026-08-26

**The file manager update.** sea-shell has shipped a file manager for a while; this is the
release where it stops being a viewer and becomes something you can keep your files in. It
was reworked against what Nautilus and Dolphin actually do — and against a fair number of
its own bugs, several of which quietly lost data.

Alongside it: the shell finally asks which applications you want things to open in, the menu
bar shows each application's real icon, and the colours derived from your wallpaper stop
inventing a hue when the picture has none.

### Added

- **Every file operation runs off the UI thread, and reports itself.** Copy, move, trash,
  delete, compress, extract and share all go through one engine with one progress contract,
  so a popover in the corner can show what is happening and stop it. Before this, only copy
  and move ran in the background at all: zipping a folder, extracting an archive or deleting
  a large tree froze the window with no indication anything was happening and no way out.

  It says **how long is left**, once that is worth saying. The estimate is held back for the
  first second and a half and until a fiftieth of the work is done — an estimate made from
  the first fraction of a second is worthless, and a number that reads "4 hours" and then
  "12 seconds" is worse than no number — and the rate behind it is a moving average rather
  than a running total, so a copy that speeds up is reflected instead of being averaged away
  by its own slow start. Measured against a controlled clock, the median error is 2%.

- **Conflicts are a question, not a silent overwrite.** Replace, keep both, skip, and
  apply-to-all, asked from the worker thread and answered by the window. What is replaced is
  moved to the trash rather than destroyed, so undo can put it back.

- **A faceted filter.** Kind, size, date and tag, combining freely — *images · 1–100 MB ·
  this week · Blue* — with a count of what is showing and what is filtered out. Modelled on
  the filter chips in Finder and the search filters in Windows Explorer.

- **`.7z` and `.rar` are browsable**, not handed to another application. Listed through
  `7z l -slt`, which emits one key per line, so a name with a space in it survives being
  parsed; `bsdtar` is the fallback. Members can be previewed and extracted individually.

- **Split view and tabs.** Right-click a folder to open it beside the current one, or drag
  one tab onto another to merge the two into a split.

- **Share to a phone.** The KDE Connect devices the shell already knows about are offered
  for any selection; folders are zipped first, because the share plugin takes files and
  silently sends nothing when handed a directory.

- **Default applications, as a settings page and a first-run question.** Which program
  opens web pages, folders, text, images, video, music and documents — written through
  `xdg-mime`, so it is the machine's association and every toolkit follows it, not a private
  idea this shell holds. The terminal is the exception: no standard covers it, so that one
  is sea-shell's own and is what "open in terminal" and the shell's command actions use.
  The welcome window asks for the first three on a fresh install.

- **The menu bar shows each application's own icon.** Taken from its desktop entry, beside
  the name it already took from there. The category glyph it used before was guessed from
  substrings of the window class, so Firefox and Chromium got the same picture and anything
  unrecognised got "apps"; that guess is now only the fallback.

### Changed

- **The colour scheme derived from a wallpaper is matugen's own choice, not ours.**
  `scheme-smart` measures the image's colourfulness — the Hasler–Süsstrunk metric over the
  red-green and yellow-blue opponent channels — and picks monochrome, neutral, tonal-spot or
  vibrant to match. That replaces a hand-rolled ImageMagick chroma gate with one threshold,
  tuned against a library of twelve wallpapers. ImageMagick is no longer called at all.

- **The accent follows the light/dark cut it is meant to.** Material publishes `primary`
  twice: a pale one to sit on a dark surface and a darker one to sit on a pale one. The dark
  cut was being read in both modes, so a light-mode accent measured **1.55:1** against the
  background, where 3:1 is the floor for something you are meant to be able to see. Choosing
  by mode takes the same wallpaper to 5.9:1, and switching mode re-derives it.

- **A hand-picked accent is remembered separately.** With matching on, matugen overwrites
  `accent` from every wallpaper, so the field was never a record of what you chose. It is
  now kept as `userAccent` and is what a failure falls back to — rather than to whatever the
  previous picture happened to produce.

- **The file manager follows the shell again by default.** Its own appearance panel must
  change the file manager and nothing else, and the fix for that was to give the window its
  own values — but defaulting to them left it in dark mode while the shell went light.
  Following is the default; choosing anything in its Appearance menu switches that window to
  its own copy, and that copy is still never written back to the shell.

- **Icons are Papirus where it is installed**, tinted to the accent where the theme carries
  a coloured folder, and they change **without a restart**. QML caches provider pixmaps by
  URL and an icon's name does not change when the theme does, so `image://fileicon/folder`
  kept serving the bitmap it fetched first — the new theme only appeared after a restart,
  which emptied the cache along with everything else.

- **Office and PDF previews are fast.** Every OpenDocument file is required to embed its own
  thumbnail and most OOXML files carry one, so that is read straight out of the container:
  **24 ms against 675 ms** for a LibreOffice conversion, and that is against a warm soffice.
  PDF and office pages publish progressively, so a thirty-page document shows page one at
  29 ms instead of after 647 ms.

### Fixed

- **Pasting could destroy a file without asking.** `shutil.copy2` over an existing path only
  de-duplicated when the source and destination shared a parent; anywhere else the file at
  the destination was overwritten in place with no prompt and no undo.

- **Renaming could destroy a file without asking.** `Path.rename()` overwrites silently on
  POSIX. Collisions are now refused, and a name containing `/` is rejected rather than
  quietly writing somewhere else.

- **The eject button was not clickable at all.** `z` orders an item against its own
  siblings; the button carried it, but the row's click handler is a sibling one level up and
  was declared last, so it hit-tested above the whole row. Every press went to the row and
  opened the volume instead.

- **The progress popover never updated.** Its job map was mutated and assigned back to
  itself — the same object reference, which QML does not consider a change — so no
  notification fired and it kept showing whatever the first frame said. It only appeared to
  work because a second operation starting rebuilt the delegates.

- **Ctrl-click did not add to the selection.** The press handler toggled and the click
  handler toggled the same row straight back, so ctrl-clicking an unselected file selected
  and deselected it in one gesture. Shift-click range selection, which was missing entirely,
  is in too.

- **Documents previewed as their raw text**, for as long as LibreOffice took and for ever on
  anything it could not convert. The extracted text is a fallback, not the preview; the panel
  says it is rendering and falls back only when the render reports that it failed.

- **A blank preview panel.** A document with a thumbnail but no pages yet matched none of
  the panel's cases and drew nothing at all.

- **Binary files were read as UTF-8.** An `.epub` is a zip, but the extension list called it
  a document and filled the panel with replacement characters. What is text is decided by the
  MIME database now — which also fixed the opposite error, where `.mjs`, `.jsonc`, `.bat` and
  `.sh` showed a grey icon. `text/x-shellscript` does not inherit `text/plain` in
  shared-mime-info at all, so an `inherits()` test alone called every shell script binary.

- **Dragging files crashed the window.** Every mouse move started a nested, blocking
  `QDrag.exec()`, inside which further moves arrived and nested again, without bound.

- **A descending sort put files before folders**, `.tar.gz` extracted to a folder named
  `photos.tar`, zipping dropped empty subdirectories, and the listing model inserted
  duplicate rows when the sort order changed — a re-sort moves every row at once, which the
  diff read as "missing here, new there".

- **The trash respects the volume a file was on.** Deleting from a removable drive used to
  move the file across the filesystem boundary into `~/.local/share/Trash`; it now uses
  `$topdir/.Trash-$uid` with a relative `Path=`, as the spec requires, so the drive can be
  unplugged and the file restored on another machine.

- **The render cache is bounded.** Nothing ever removed anything from `~/.cache/sea-fm`, so
  every PDF ever opened left up to thirty 300-DPI page images behind for good.

## [6.4.1] - 2026-08-23

**The menu bar, properly.** 6.4.0 put the focused window's menus in the bar; this is the
release where they stop misbehaving. Most of what follows is one mistake wearing different
clothes — treating a question that *failed* as a question that was answered "no" — and the
rest is a menu that finally looks like the thing it is imitating.

### Added

- **The application's name in the strip.** Mark, then the application, then its menus, the
  way a mac reads. Taken from the snapshot's own window class rather than from the
  compositor's idea of focus, so the name and the menus under it always describe the same
  window — reading focus separately would put the new window's name over the old window's
  menus for the frame between the two. It is a label, not a menu: what a mac puts under the
  app name lives in the File menu on Linux, and inventing a menu whose items came from
  nowhere would be worse than not having one.
- **`read all` in the menu search.** Search can only search what is known, and an
  application that builds each menu on first open is known only as far as you have happened
  to click. One button reads every unopened menu once, remembers it, and closes it — visible
  while it runs, because it opens real menus, and never paid twice in this session or the
  next.
- **Menus taller than the screen scroll.** A card was given the height its rows wanted, so a
  menu with more rows than the display had room for was pinned to the top and the rest drawn
  off the bottom — unreachable by pointer, invisible to the arrow keys walking onto them.
  Fine on a 1080p panel, not on a 768px laptop, which is the sort of thing that only shows up
  on somebody else's machine.
- **Icons and radio marks in menu rows.** The icon the application named, resolved through
  the theme; and a dot rather than a tick for one-of-these. Both share the column already
  reserved for checkmarks — an item is checkable or it has a picture, essentially never
  both, and two gutters would indent every label twice for the sake of a handful of rows.
- **Search across every settings page.** Twenty-two pages and sixty-odd sections, and
  nothing let you ask for one by name. Every section registers itself as it is built, so a
  section added later is findable without being listed anywhere by hand.
- **Jump chips on every settings page.** Each page's sections in one row, outside the scroll
  area so they never leave. The global menu settings were four sections down a page that
  opens with a twenty-row widget list.
- **A menu-bar step in the first-run tour**, with the per-app setup behind it — the one
  feature that needs something done to the *applications* rather than to the shell.
- **Keyboard shortcuts in the system menu.** The real ones from `keybinds.lua`. A menu that
  only works with the pointer teaches nothing; one that prints the keybind is how you stop
  needing it.
- **Motion that distinguishes arriving from leaving.** One curve for both is what makes an
  interface feel mechanical. Notifications fly in and the stack closes up behind a
  dismissal, the volume OSD grows into place instead of appearing between two frames, bar
  pills animate their width so the cluster slides over to make room, and the launcher's
  selection travels down the list rather than blinking between rows.

### Changed

- **The side bar is built from the same pill as the top bar.** `Pill` was written to serve a
  vertical bar and then had `vert` declared `readonly ... : false`, which locked every one of
  those branches off permanently — so a second, hand-written set of fourteen near-identical
  pills grew beside it. That duplication is why this bar has been broken: see below for what
  it cost. One definition now, and everything the horizontal bar gains the side bar gets
  with it.
- **The selected row is filled, not washed.** A 16% accent tint over a bar at 25% opacity is
  "slightly different grey". Filled accent with `accentInk` on top — the token that exists
  for exactly this — the same treatment the focused workspace chip already uses.
- **Menu rows are inset from the card**, so the highlight is a pill floating inside it rather
  than a band painted across it; separators inset to the text; accelerators capitalised, so a
  column of shortcuts reads as a column.
- **Hyprland is asked over its own socket** rather than by spawning `hyprctl`, whose entire
  job is to make that same request. 40ms to 0.2ms, several times per focus change.
- **Each window's menus are cached by pid**, so returning to a window you were using seconds
  ago is instant instead of asking the application again. Focus switching went from 170–350ms
  to under 25ms.
- **The settings window is 1240x880**, up from 960x780 — nearly half the width of a 1080p
  display was going unused while the pages inside scrolled.

### Fixed

- **A restarted Firefox read its menus again.** Three bugs, all the same shape. A failed
  `owner_pid` was cached as "no owner" for ever; a failed lookup **deleted** the window's
  registration outright, which cannot be undone because the application will not register
  again until it restarts; and menus were remembered only on the path that has to open them,
  so once demoted there was nothing to fall back on. The first two now distinguish "the bus
  says no" from "I could not ask", and the third saves either way.
- **The menu cascade flashed.** A Repeater regenerates *every* delegate when its model
  changes — true for a JS array whose identity changed, and equally true for a plain number
  that went from 1 to 2. Opening one submenu was rebuilding the parent card and all of its
  rows. The cascade is a fixed pool of cards now, shown and hidden.
- **A submenu opened and then closed a quarter-second later.** Hovering a row that must be
  fetched does not descend, so it scheduled the ordinary grace-period close; the click that
  followed opened the submenu but left that timer armed.
- **Submenus were unreachable by mouse.** Moving from a row into its submenu is a diagonal
  move, and passing over the rows below closed the submenu out from under the pointer
  heading toward it.
- **The bar served one window's menus under another window's name.** `_NET_ACTIVE_WINDOW`
  answers with the last *X11* window to have focus, and under Wayland most windows are not
  X11 at all — so a native window inherited whatever XWayland window came before it. Not
  merely stale: a live menu wired to the wrong window.
- **Switching workspaces showed the previous window's menus** for a quarter-second before
  correcting. Not slowness — the wrong answer published first, because an addressless event
  is not yet an answer.
- **A bottom-docked bar drew its menus at the top of the screen**, one bar-height from the
  wrong edge with nothing joining them to the thing that was clicked.
- **`ReferenceError: wxPillVert is not defined`** on every reload of a side bar: the weather
  card named a host that had never been written. The updates card pointed at a hidden
  horizontal pill. The mark drew the sea wave whatever logo you had chosen. The workspaces
  ignored the numbering and style you picked.
- **The global menu ran on side bars**, where a 42px column has no room for "File Edit View"
  — the cluster it lives in is hidden with `opacity: 0`, so it was still reading menus and
  still opening its dropdown off an invisible pill.
- **The system menu never opened.** It was not registered with the shared focus grab, so it
  was treated as a click *outside* itself and dismissed on the frame it appeared. Its
  Settings entry threw a `TypeError` besides.
- **The highlight flew the length of the card** when the pointer brushed a disabled row, and
  travelled across menus it had never been in once cards were pooled.
- **A ticked row printed its label on top of its own checkmark.** The column was sized on the
  assumption that the mark could overhang into the padding; it cannot.
- **Keyboard-opened menus hung off the wrong place** — the start of the strip, which now
  begins with the application's name, rather than the menu that was opened.

## [6.4.0] - 2026-08-21

**The desktop update.** The shell has never done anything with the largest part of your
screen: the bar is at one edge, the dock at another, and between them was a wallpaper and
nothing else. Now there are widgets and shortcuts there — and they know what is in the
picture behind them.

Alongside it, something that was supposed to be impossible: the focused window's own menu
bar, in the bar.

### Added

- **The desktop.** One surface per monitor, above the wallpaper and below every window, so
  nothing on it can cover something you are working in. Four widgets — a clock, weather, now
  playing and a system read-out — plus shortcuts to any installed application. `SUPER+SHIFT+A`
  arranges; drag anything, right-click to remove, right-click empty space to finish.

  Its input region is **exactly the widgets and nothing else**. A full-screen layer surface
  that accepts input swallows every pointer event that would have reached the desktop —
  scroll-to-switch-workspace, any mouse bind you have — and it does so silently, because
  there is nothing visible there to blame. Only while arranging does the whole surface
  listen.

  Positions are fractions of the screen, not pixels, so an arrangement survives a resolution
  change and a widget parked against an edge stays against that edge.

- **The desktop knows what is in your wallpaper.** Every desktop that has ever had widgets on
  it has the same failure: you choose a wallpaper because you like what is in it, and then
  you cover that part of it with a clock. Snapping to a grid does not help, because a grid
  does not know where the subject is.

  So the wallpaper is measured. New widgets are placed in the calm parts of the picture,
  dragging shows the busy areas as keep-clear shading, and a widget dropped on the subject
  moves aside — unless you hold **shift**, which places it exactly and pins it there for
  good. And a widget that lands on busy ground grows a backdrop; on calm ground it is bare
  text on your picture, which is the entire point of putting it on a wallpaper you chose.

  **A moving wallpaper is read as a picture** — the still the index already extracts for the
  picker. No video is ever decoded for this.

  Getting there took four attempts, and the failures are the interesting part. Measuring
  detail alone put the widget **on the character's face** on two wallpapers in twelve,
  because cel-shaded skin is the *smoothest* region in the frame and a detail map reads it as
  empty. Adding skin-tone detection made it worse — anime skin hue matches every warm
  background. What fixed it was morphology: a smooth face is a **hole inside a busy object**,
  not open space. Eleven of twelve now, and the twelfth is a solid black silhouette on white,
  which genuinely has nothing to measure. It is advice, never a rule, which is why anything
  it decides you can overrule with one drag.

- **When the wallpaper changes, the desktop follows it.** Three settings: **rescue** moves
  only what a new picture actually covers and only as far as it must — often nothing, which
  is correct; **arrange** re-places everything in the calmest space of every new wallpaper;
  **off**. Pinned widgets never move under any of them.

- **The global menu.** The focused window's own menu bar, drawn in the bar in place of the
  window title, for as long as the focused window has one.

  This was researched once before and called impossible, and half of that was right. The
  usual plumbing — DBusMenu plus the AppMenu registrar — keys every menu by an **X11 window
  id**, which does not exist under Wayland; KDE's protocol for it is not implemented by
  Hyprland and neither is the GTK equivalent. That road really is closed. But accessibility
  publishes the same menus addressed by **process**, and a process is something Hyprland will
  happily tell us about. **Qt, GTK, KDE and LibreOffice hand over their entire menu tree**,
  nested submenus included, for free.

  It is invisible unless it has something to say. Most windows export no menu bar — a
  terminal has none, GTK4 apps put everything behind a hamburger — and a global menu that
  answers those with an empty strip is worse than none at all, so the title simply comes
  back. The workspace pills stand down while a menu is showing, because a menu bar is long
  and it is the thing you are using right now.

  **Firefox is a special case handled specially.** It reports its menu labels but builds each
  menu only when it is first opened, and opening it is visible — the browser's own menu
  appears on screen. So it is opened **where nobody is looking**: a window on a workspace you
  are not on is still mapped and still answers, so its menus are read out of sight and are
  simply there by the time you click. Nothing is ever opened on a window you can see.

  Electron is not supported, and that is a decision rather than a gap: it builds no
  accessibility tree unless started with a flag, and VS Code draws its own menu bar two
  pixels from where ours would go.

### Changed

- **Widgets are instrument read-outs, not cards.** Every desktop-widget convention — a
  rounded translucent tile with a shadow — is the thing this shell's own components already
  refuse: depth here comes from rules and background steps, never shadow, never translucency.
  So a widget is a tracked label, a hairline, and a figure, built from the same `IndKpi`,
  `IndLabel` and `IndSpark` the bar and the panels are made of. On the clock the accent
  segment of that hairline is not decoration — it is the minute, filling as it passes.

  Each one takes a colour, a ground, an alignment and a size, in the same vocabulary the Bar
  Widgets tab already uses. The **figure's** colour still states a fact rather than a
  preference: a load that has gone critical says so even if you asked for green.

### Fixed

- **The desktop arrangement could silently lose everything on it.** The surface serialised
  its own copy of the arrangement — a copy made whenever it last read the file — so any
  moment that copy was stale, the next drag wrote the stale version over the real one. Five
  widgets became one, with no error anywhere.

  The surface no longer writes the file at all. Every change is a request to the one program
  that owns it, which reads, edits and writes back. Emptying the arrangement now has to be
  asked for, and every write leaves the previous one in `desktop.json.bak`.

### Notes

- One arrangement is shared across monitors. Correct on a single screen, wrong on two; it is
  the first thing to fix.
- `at-spi2-core` and `python-gobject` are new dependencies, for the global menu.

## [6.3.1] - 2026-08-21

A wallpaper patch. Sorting your wallpapers into folders broke every image in the picker, a
greyscale wallpaper handed the desktop an invented accent, and previewing motion cost more than
it was worth.

### Fixed

- **Sorting your wallpapers into folders broke every image in the picker.** A path is not a URL,
  and `"file://" + path` was how every wallpaper surface built one. The moment a path contains a
  **percent sign** that breaks, because that is where an escape sequence starts — Qt reads `%16`
  as a single byte and opens a filename nobody has. The indexer keys its thumbnail cache on
  `subfolder%name`, so the day you put your wallpapers in subfolders, every still, every rail
  thumbnail, the flying cartridge and the previews in Settings and the first-run tour all quietly
  stopped loading and the picker came up as a row of empty boxes.

  It is `Tok.fileUrl()` now, in the singleton every surface already imports, and it encodes each
  path *segment* rather than the whole string so the separators survive. Seven call sites were
  building URLs by hand; none are. Spaces and `#` in a wallpaper path had exactly the same
  problem and had had it all along.

- **A greyscale wallpaper got an invented accent.** Material's palette generation always returns
  a hue, including from an image that has none: a monochrome wallpaper came back **green** and a
  black-and-white manga page came back blue. Both arbitrary, and a green desktop under a
  greyscale picture reads as a bug because it is one.

  The image's chroma is measured first now — the distance of its mean a\*/b\* from neutral in
  LAB, *not* HSL saturation, which reads 0.81 for a page made of near-white and near-black pixels
  because S is ill-defined at both ends of lightness. Across a real twelve-wallpaper library the
  ones with colour in them sit at 0.013–0.22 and the two genuinely monochrome ones at 0.004, so
  the gate is 0.008. Below it your own accent stands, exactly as if match-colours were off. A
  picture with no colour in it does not get to invent one.

- **A white accent was drawn blue.** Pick pure white — or any grey — and the shell drew
  `#386375`, a muted blue, from an input with no blue in it. Two rules conspired: `hslHue` is
  **-1** for anything colourless, so the fallback handed it 0.55, and the saturation floor then
  pulled it up from 0 to 0.35. Every grey came out as the same blue.

  The floor is right for a *washed-out* colour, which is what it was written for — a pale pink at
  L≈0.80 has a hue worth keeping and simply cannot carry text. It is wrong for a colour with no
  hue at all, where it does not rescue an accent, it invents one. No chroma, no hue: the accent
  becomes a neutral of the same readable lightness, and the tint comes out of the grounds, inks
  and rules with it so the shell goes properly monochrome rather than accent-grey on faintly blue
  panels. For any accent with real colour in it, every value is bit-identical to before.

- **Picking an accent by hand did not stick.** With **auto colours from wallpaper** left on, the
  swatch you chose was written and then had a colour re-derived from the wallpaper over the top
  of it a moment later. Choosing a colour by hand now turns matching off — the same rule the
  light/dark source already follows, for the same reason: an override the next wallpaper silently
  undoes is not an override. Picking one of the **wallpaper's own** palette swatches leaves
  matching on, because that is choosing what matching would have given you anyway.

  There was a second hazard underneath it. `saveAppearance()` writes the config from its own
  detached process and the theme script reads that same file; started in the same instant, the
  script could read the accent you had just replaced and write the old one straight back.

- **A `Row` in the lyrics panel had been disabled since 6.1.1.** Its right-hand controls set
  `anchors.right`, and an item inside a `Row` may not set left, right, horizontalCenter, fill or
  centerIn — Qt disables the entire Row when one does, and says so on stderr where nobody was
  reading it.

### Changed

- **Motion in the picker is opt-in.** A moving wallpaper no longer starts playing because you
  arrowed onto it. The still is the preview, and a **play key on the deck** — or `ctrl+p` —
  starts the clip when you actually want to see whether the motion is a slow drift or a strobing
  city. A key rather than a line of grey text reading "ctrl+p plays": the deck is covered in
  text and this is the one part of it you can press, so it is built like the rest of the panel,
  with a lamp that lights while it is running and the shortcut printed on it.

  This is also what made the picker quick. 6.3.0 opened in 1178ms, and **~693ms of that was
  constructing `MediaPlayer` and `VideoOutput`** — one-time QtMultimedia plugin initialisation,
  paid per process, before a single line of the picker ran. It was paid whether or not you cared
  about motion. Now nothing loads a codec until you ask, and the picker opens in **216ms**.

  It briefly lived inside the bar instead, to keep a warm decoder between opens. That bought
  25ms over 216 and cost three separate state-reuse bugs — a surface that stops being a process
  stops getting its state reset by exiting, and the filter, the search and the commit animation
  each had to be put back by hand. Opt-in motion removed the reason for it, so it is its own
  process again and its state is reset the way it always was: by ending.

## [6.3.0] - 2026-08-21

**The bar update.** Every widget can be styled on its own now — its colour, what it shows, and
whether it has a ground at all — the right cluster stops running into the media pill when it
grows too long, and the bar finally says what the scratchpad is holding.

Around it: the theme can follow your wallpaper, clicking a link raises the browser it opened in
and marks it in the dock, the settings panel stopped flashing white on the way in, and the
wallpaper picker got its speed back.

### Added

- **Every widget can look how you want it.** The Bar Widgets tab could move a pill and turn it
  off; it could not change one. Each now opens onto three choices — **colour** (the accent, or
  iris/green/amber/red/plain), **shows** (icon and value, icon only, value only) and **ground**
  (filled, outline, or bare). A widget you have touched carries a dot, and anything left at its
  default is not written to disk at all, so a config file still says only what you actually
  decided.

  The colour choice deliberately does nothing while an accent is already meaningful on that
  pill — a widget that turns amber to warn you is not overruled by a preference, because the
  colour is carrying a fact at that moment and the preference is not.

- **The bar stops overflowing.** With enough widgets on, the right cluster grew until it sat
  against the media pill and then under it. It now measures what it has room for — the gap to
  the centre, less the media pill's reservation — and pushes the widgets furthest from the edge
  out of the row, newest-out-first, until what remains fits. A **`⋯`** mark takes their place
  with the count on it; clicking it opens the Bar Widgets tab, because the fix is a decision
  about which ones you want, not something the bar should quietly make for you.

  The pushed widgets leave no gap, and the cluster's own width excludes them — the first version
  of this measured them anyway, so the survivors floated in from the right edge of a cluster
  wider than its own contents.

- **The theme can follow the wallpaper.** Auto-dark used to be one switch tied to the clock.
  There are three sources now — **you**, **the clock**, or **the wallpaper** — and picking the
  wallpaper reads the mean luminance of the still and sets light or dark from it.

  With a dead zone: under 0.42 goes dark, over 0.60 goes light, and anything between changes
  nothing. Measured against a real folder rather than guessed — eleven wallpapers landing at
  .28 .31 .41 .45 .45 .49 .51 .51 .52 .74 .94 — because the mid-forties is where a wallpaper is
  genuinely neither, and a naive midpoint makes the whole desktop flip on a wallpaper that is
  only slightly darker than the last one.

  Toggling the theme by hand sets the source back to **you**. A manual override that the next
  wallpaper silently undoes is not an override.

- **Where the link went.** Click a link in your editor and the browser opens somewhere you
  cannot see. The dock icon of whatever was raised now pulses three times, and the shell can
  follow you to it — Hyprland's `focus_on_activate` is off by default, which is the whole reason
  a link never brought you anywhere. Both halves toggle separately in Settings → Dock, because
  wanting to be *told* is not the same as wanting to be *moved*.

  Built on xdg-activation, which Hyprland surfaces as `urgent`. It fires twice for one link, so
  a 400ms guard collapses the pair into the single event it actually was.

- **The bar says what the scratchpad holds.** `SUPER+SHIFT+\`` sent a window somewhere with
  nothing on screen to say so, which made it a way to lose a window until you remembered the
  other half of the binding. A mark in the left cluster now carries the count, fills in when the
  stash is pulled down, and exists only while it is holding something — stash the last window
  and it removes itself rather than sitting there reading zero.

  It is **not** the special workspace put back into the workspace strip. That exclusion was
  right: the scratchpad is an overlay on the workspace you are already standing on, not a place
  you travel to, and `focus({ workspace = -98 })` does nothing at all. The mark toggles it; it
  does not go to it. It reorders and hides like any other left-cluster widget.

- **Mission Control shows the stash.** A **stash** card at the end of the grid, with the windows
  inside it, whenever it holds any. Mission Control answers "where are my windows", and the ones
  in the scratchpad are precisely the ones no other card can show you. Choosing it pulls it down
  over where you are instead of travelling to it.

### Fixed

- **The settings panel flashed.** Two separate mechanisms, both of them `Binding`:

  The panel previews your theme edits by binding over the live tokens. `Binding`'s default
  `restoreMode` restores *the value it captured when the binding activated* — so closing the
  panel wrote a stale theme back over the shell. Switch to dark globally, open Settings, close
  it, and the bar was light again while the config on disk still said dark.

  The flash you actually saw was the other one. The panel reads `appearance.json` through an
  async `cat`, and the preview bindings were gated only on the panel being open — so for the
  frame or two before that read landed, the panel pushed its *default* mirror (light) onto the
  live tokens and the whole surface went white before snapping back. They are now gated on the
  mirror being fresh as well, and the tokens are re-synced from disk on the way out.

- **The wallpaper picker took a second to open.** 1178ms, measured. Not the QML — compiling all
  1845 lines of it costs about 50ms, and the folder index costs 37 — but **~693ms of it was
  constructing `MediaPlayer` and `VideoOutput`**, which spins up the whole ffmpeg backend before
  a single line of the picker runs. Importing `QtMultimedia` costs 20ms; building the objects is
  what pays.

  The player is no longer part of the window. It is built once the picker is already on screen,
  and in a folder that holds nothing moving it is never built at all. **1178ms → 299ms.**

  Warmed after the surface is up rather than on demand, because reaching a moving wallpaper and
  waiting most of a second for the backend would only have moved the stall from opening to
  scrolling.

- **The audio device lists lied about which device was in use.** Picking a row in any of the
  output/input tables set the table's own selection as well as acting on it — and the caller
  binds that same property to the real system default. Assigning over a bound property destroys
  the binding, so from the first click the table showed your last click forever, whatever
  PipeWire actually did afterwards. The tables now only report; what is selected is what the
  system says is selected. (Same class of bug as the 6.1.0 toggle fix — a controlled component
  writing to its own controlled property.)

- **A vertical bar drew a workspace chip reading `-98`.** The horizontal strip has excluded
  special workspaces since 6.0; the vertical one never got the same line, so the first press of
  `SUPER+\`` put a 24px circle around a four-character label in it.

- **`appearance.json` could be written torn.** Four theme scripts wrote the config in place while
  the bar was watching the file, so a read landing mid-write lost a theme change. All of them
  write a temp file and rename now, which is atomic.

- **The settings panel wrote its own config by hand.** Eighty-odd keys concatenated into a JSON
  string and shell-quoted into a `printf`, where a mistyped property name produced `undefined`
  and `JSON.stringify` silently dropped the setting entirely. It is one object now, base64'd
  past the shell so no value can break out of its own quoting, and written atomically like
  everything else.

## [6.2.0] - 2026-08-19

**The wallpaper update.** The picker learned to search, the folder stopped being a constant,
"previous" started meaning previous, and a video wallpaper stopped costing you memory while
nobody was looking at it.

Around it: the bar can be pills or circles with the numbers written seven different ways and
your distribution's mark on it, Mission Control became a map instead of a wall of tiles, and
there is a first-run tour so none of that has to be found by accident. The DAC panel is gone —
that work lives in [Hub Moon](https://hubmoon.miyukivigil.tech) now.

### Removed

- **The parametric EQ and the Moondrop DAC panel are gone.** `DacPanel.qml` (2 325 lines),
  `moondrop_control.py`, `sea-eq.py`, the DAC bar pill, the `dac` IPC target and the
  `SUPER+SHIFT+E` bind.

  Two reasons, and the second is the honest one. **[Hub Moon](https://hubmoon.miyukivigil.tech)**
  is where this work now happens — a whole application built for the device, moving faster than
  a panel inside a desktop shell ever could, and keeping two implementations of the same
  hardware protocol in step was work that improved neither. And a parametric equaliser for one
  manufacturer's USB DACs is *niche*: it was the single largest file in the project, and most
  people running a Wayland shell will never plug in the hardware it exists for.

  What stays is what is genuinely a *bar's* job: output routing, per-app volume, media, lyrics,
  and the bit-perfect badge. That last one survives because the ALSA scan behind it was never a
  Moondrop fact — "something has taken the card and pipewire cannot see the audio" is what the
  screen recorder needs to warn that system audio will record silence.

  Nothing is lost by moving: Hub Moon reads the same curves off the same device, and it has the
  Moondrop Hub library, per-slot management and firmware-level detail this panel never had. The
  installer offers to fetch it for you.

### Added

- **A Bar tab.** Bar-specific settings were sharing "Appearance → bar theme" with the shell-wide
  dark/light switch and the GTK/Qt app preference, neither of which is about the bar. They have
  their own tab now, and Appearance's first sub-tab is honestly called "theme".

- **The bar can be pills.** One continuous strip, or the clusters as separate floating grounds.
  Two, not three: the centre cluster is the media pill, which already has its own ground.

- **Workspaces three ways** — grow (a chip each, the active one stretching), pills (all the same,
  the active one filled, nothing moving) or **circles** (true circles that stretch into a true
  pill on the one you are on).

  Circles are the shape the bar used to have, and the reason it stopped having it is that grow's
  corner radius follows the roundness slider: at roundness 26 a 24px chip is a circle, and at 15
  it is a rounded square. Circles take half the height instead, so they are round at any setting
  rather than only at the top of the slider.

- **Workspace numbering.** Arabic, Roman, Mandarin, letters, circled numerals, dice, or one dot
  each. Every scheme falls back to the plain number once it runs out of symbols, and a scheme
  whose glyphs nothing on the machine can draw is not offered at all — CookieRun has the circled
  numerals and not the dice, which is exactly how three tofu boxes get onto somebody's bar.

- **The bar's mark is yours.** It was the sea-shell logo, hardcoded. It now defaults to whatever
  `/etc/os-release` says the machine is: CachyOS and sea-shell are drawn as QML shapes so they
  recolour with the theme, fourteen more distros come from a Nerd Font, and anything else can be
  a custom image. Read synchronously, so it is right on the first frame.

- **A first-run tour.** Five screens, shown once, reopenable forever after from
  Settings → System. Everything in it was already in the control center — and that is exactly
  the problem it solves: twenty tabs, and a shell you installed four minutes ago gives you no
  reason to believe any particular one of them holds the thing you are looking for. The tour
  makes the four decisions that change how the desktop *looks* — light or dark, accent, bar
  shape, workspace style — and then says where the other nineteen tabs are.

  **It writes as you go, not on finish.** Every choice lands in `appearance.json` immediately
  and the bar behind the card changes while you watch, which is the only honest way to choose
  between "grow" and "circles". Quitting halfway keeps what you picked; there is no cancel,
  because there is nothing to cancel.



- **The wallpaper folder is a setting.** `~/Pictures/wallpapers` was hardcoded in the cycle
  script, in the indexer, and by omission in the picker — three copies of a path that could
  not be changed at all. Settings → Appearance → Wallpaper now has a folder field with a
  folder browser behind it, and `sea-wallpaper-index.py` is the single place that answers
  "where are the wallpapers and what counts as one". Everything else asks it.

- **Collections.** The walk is recursive, so a wallpaper folder with any organisation in it
  is no longer indexed as empty. Each subfolder becomes a collection you can filter the
  picker by, beside the existing all / stills / motion chips. Four levels deep, hidden
  directories skipped.

- **Type to search.** Start typing in the picker and the rail filters live. The search
  window is built out of the deck's own parts — a raised legend plate, a sunken well, a
  raised counter — rather than a text field borrowed from somewhere else. Esc clears the
  query; a second Esc closes. `m` for match-colours moves to **ctrl+m**, because a bare
  letter is a search now.

- **A recent filter.** Tab cycles to it. It is an order as well as a set: the wallpaper on
  screen leads, then the ones you had before it.

- **A day and a night wallpaper.** Pin two and they swap on schedule — the *same*
  darkStart/darkEnd auto dark mode already uses, not a second pair of times. Chosen by
  clicking a cartridge and picking off a shelf of your actual wallpapers. It outranks
  auto-rotate: a pinned pair and a shuffle every thirty minutes are contradictory
  instructions, and letting the timer quietly overwrite the night wallpaper would read as
  the pair not working.

- **`wallpaper set` over IPC.** `qs -c sea-shell ipc call wallpaper set /path/to/image`
  runs the full sequence — path, daemon, lock screen, palette — behind the same travelling
  panel a keybind gets. Setting a wallpaper was previously something only the picker and
  the cycle script could do, because each carried its own copy of what it means.

- **Stills-only rotation.** Rotating into a video restarts a decoder every interval; some
  folders are mostly clips.

- **ctrl+v imports.** Everything here could *choose* a wallpaper and nothing could add one —
  the folder was filled by a file manager or it was not filled. ctrl+v in the picker takes
  whatever is on the clipboard (raw image bytes, a path, a `file://` URI, or an http URL it
  fetches), puts it in the wallpaper folder without ever overwriting, re-indexes, and lands
  focus on it.

- **Sort by newest.** The index hands rows over in name order, which is the one order that
  cannot answer "what did I just put in here". ctrl+s, or the chip in the header. Not
  persisted, like the filter and the collection — all three are ways of looking at the
  folder for as long as the window is open.

- **The lock screen can keep its own picture.** `sea-lockwall.sh` ran on every apply and
  unconditionally overwrote the lock background with whatever the desktop had switched to,
  so "a different picture on the lock screen" was not expressible. Pin one in Settings —
  it outranks the argument the wallpaper switch passes in.

- **A frame cap for moving wallpapers.** mpvpaper's options were hardcoded. Capping a 60fps
  clip to 30 halves the full-screen blits the compositor does for it, which on a machine
  whose iGPU composites while the dGPU renders is the cost that actually shows up. It does
  not reduce decoding, and the setting says so.

### Changed

- **A video wallpaper is freed while a FULLSCREEN window covers it, not just paused.** A paused mpvpaper
  keeps its decoder, its surface and its VRAM for as long as it lives, and the thing
  covering the wallpaper is usually a game that wanted exactly that memory. swww is already
  showing the same frame underneath, so the poster goes up *before* mpvpaper is killed and
  the swap has no black frame in either direction. Optional, and on by default. There is a
  matching "still frame on battery" for laptops, which the listener now notices within
  thirty seconds — unplugging the mains emits no window event, and window events were the
  only thing it used to listen to.

  "Covered" means **fullscreen** and nothing looser. The occlusion test used to also count a
  window sized to 95% of the monitor, and tiled windows adding up to 85% of it — both true of
  a single maximised editor, so it fired during ordinary work rather than during the game it
  was built for. It also pauses first and waits for a second opinion before killing anything,
  because going fullscreen is often momentary.

- **Random is a bag, not a die.** A fresh `shuf` every time repeats: over eleven wallpapers
  you see one twice long before you have seen them all, and nothing stopped it dealing the
  one already on screen. The bag deals without replacement and reshuffles when empty.

- **Theme profiles are cartridges.** Each saved preset now shows its own palette — the
  background steps, the accent as a band, its font and radius printed on the label — with a
  lamp lit on the one you are currently on. The row this replaces described a colour scheme
  as `accent: #dbc0c8`, which is the one format that cannot show you a colour scheme.

- **The slot reacts now.** The cartridge used to descend into a static black bar, and the
  only evidence the machine had taken it was the jolt. There is a **shutter** across the
  opening — two leaves in the plane between the bezel and the darkness behind, so the slot
  still reads as an opening when the picker is idle. It parts ahead of the falling card
  (130 ms against a 210 ms drop, so the way is open before the card arrives and the machine
  is never seen being hit by it) and snaps shut behind it, faster and with an overshoot,
  against the jolt.

- **The flying cartridge has a label.** It was an image with an accent border — anonymous,
  and a different object from the cartridges on the shelves in Settings. It now carries the
  same plate: filename, motion marker, keyed corner. The plate arrives during the
  anticipation dip rather than being there from the start, so the seam between rail panel
  and physical object stays invisible, and it is the only moment you can read what you are
  loading without looking somewhere else.

- **The mouth throws a shadow.** The clip boundary alone is a hard cut: the card was not
  swallowed so much as erased a row of pixels at a time.

- **The lamp reads the cartridge.** It used to go accent the instant you pressed enter and
  stay there, which says "busy" and nothing else. It is dim while the card is in the air,
  full at the moment of contact, and throws one ring at that instant. A lamp that lights
  when the thing lands is the deck responding; a lamp that lights when you press a key is
  the keyboard responding.

- **Mission Control is a map of your monitor, not a wall of tiles.** Every workspace card was
  a fixed 280x180 in a grid clamped to 1000x700 — so on a 1920x1080 screen three workspaces sat
  marooned in the top-left eighth of a full-screen overlay — and the windows inside them were
  fixed 122x60 chips in whatever order the compositor happened to list them.

  Cards are the **monitor's aspect ratio** now, and they fill the screen. Windows are drawn at
  their **real positions and real sizes**, scaled down from the actual geometry, so a workspace
  with a wide editor beside a narrow terminal *looks* like that. Which is the point: you
  recognise the workspace you want by its shape, in one glance, instead of reading four titles
  to find out which card is which. Arrow keys move the selection, 1-9 jump straight to a
  workspace, and an empty one says so rather than being a blank card.

- The picker, the keybinds, the rotate daemon and the IPC verb all route through one
  `sea-wallpaper-set.sh`. The picker used to write the config file, sync the lock screen,
  run matugen and call the apply script itself — its own copy of a sequence the cycle
  script also had a copy of, which is how the two drifted.

### Fixed

- **The wallpaper stayed frozen after the fullscreen window was gone.** Three separate bugs
  stacked into one symptom, and each one alone was survivable.

  The listener guards itself with `flock` so only one copy runs. It resumes the wallpaper by
  spawning the apply script, which `exec`s **mpvpaper** — and a child inherits open file
  descriptors, so mpvpaper held the lock for its entire life. Every listener started after that
  point silently lost the flock and exited, leaving nobody watching for the window to close. It
  closes fd 9 on every child now (`9<&-`), including the tick subshell.

  Underneath that, the socket race above meant that even a live listener had no working IPC to
  unpause through. And the freeze decision itself fired on any *covering* window, so ordinary
  work looked like a game — see the fullscreen rule under Changed.

- **The frozen wallpaper, and the picker's preview, were visibly soft.** Both showed the 1280px
  poster full-screen — a cache entry sized for a thumbnail rail, stretched to 1920 and wider.
  You saw it as a blur when a game let go of the screen, and as a half-second of mush before
  each preview started playing. The indexer now also cuts a **native-resolution** still
  (`--fullposter`, no scale filter, `-q:v 2`) and the freeze, the full-screen preview and the
  flying cartridge all use that instead. Measured at 101% of the playing video's edge detail:
  there is nothing left to see.

- **A theme change could be lost, and then every surface drawn from the design tokens kept the
  old palette for the rest of the session.** `sea-toggle-theme.sh`, `sea-toggle-night.sh`,
  `sea-theme-schedule.sh` and `matugen-accent.sh` all wrote `appearance.json` as
  `json.dump(d, open(cfg, "w"))` — which truncates the file to zero bytes before writing a
  single one of them.

  The shell *watches* that file. A watcher that wakes on the truncation reads an empty file,
  fails to parse it, keeps what it had — and no second change event follows, because the write
  that follows is part of the same change. The most visible casualty was the new first-run tour,
  which is drawn entirely from `Tok.qml` and would sit there in light mode on a dark desktop.

  All four write to a temp file and rename now, which is what `sea-set-appearance.py` already
  did and the reason it never showed the bug.

- **A stale mpv IPC socket left the wallpaper with nothing able to unpause it.** Restarting
  mpvpaper removed the socket after a fixed 0.2s sleep rather than after the old process was
  actually gone. Losing that race leaves the previous socket FILE on disk with nothing
  listening: mpv will not bind an address that already exists, so the new wallpaper comes up
  with no IPC, every pause/resume call fails silently, and a wallpaper paused before the
  restart stays paused forever. It waits for the process now.

- **`prev` could not undo `random`.** It found the current wallpaper's position in the
  name-sorted list and stepped back one, so after a random jump "previous" went to whatever
  sorted before where you had landed — somewhere you had never been. It now pops a back
  stack, exactly like a browser, and only falls back to name order when there is nothing to
  go back to.

- **The bar started in the wrong palette on every launch.** It flashed sea cyan — and, on a
  light-mode setup, the whole default *dark* theme — before settling into the real colours.
  Both config reads were asynchronous by construction: `Tok.qml` forked a shell to `cat`
  appearance.json and parsed its stdout, and shell.qml's own FileView started with an empty
  path and waited for a second `sh` to tell it where the file was. Everything on screen is a
  function of that file, so for the whole of those round trips the shell drew itself against
  the defaults. Both now read it synchronously with `FileView { blockLoading: true }`, so
  the first composed frame is already right.

  The subtlety that made the first attempt useless: with `blockLoading` the bytes are
  present when construction finishes and **no load signal is ever emitted**, so hooking
  `onLoaded` alone left the parse to never run and the flash exactly where it was. The parse
  is on `Component.onCompleted` as well.

- **The scrolling media title was cut mid-glyph.** The marquee clipped dead straight at both
  ends, so a long title showed half a character hanging at each edge — which reads as a
  rendering fault rather than as text continuing. It fades now, and only while it is actually
  scrolling.

- **matugen re-decoded the video on every switch, and read the wrong frame.**
  `matugen-accent.sh` ran `ffmpeg -vframes 1` on the raw clip each time the wallpaper
  changed — 0.42 s per switch — while a 1280px poster of that exact file was already in the
  cache. And it took frame **zero**, which is precisely the frame the indexer avoids by
  seeking a second in: a great many wallpaper clips open on black, and a black frame hands
  the whole desktop a palette derived from black. It asks the indexer for the poster now.
  0.42 s → 0.26 s, and the accent comes from a frame that has the picture in it.

- **The poster cache never pruned.** Twenty-two files for eleven wallpapers: eleven of them
  written under a naming scheme that predates the width suffix and unreachable by any code
  path, the rest belonging to wallpapers that had been deleted. `poster()` only ever
  created. Dead-scheme files go on sight; true orphans get a fortnight's grace, because
  that is also what every poster looks like the moment you point the folder somewhere else.

- **The file browser started at a literal `/home/miyukivigil`** — one specific machine's
  home directory, shipped inside the config.

- A wallpaper path containing a quote was a shell injection into the picker's `printf`. It
  is an argv element now.

### Packaging

- **The installer offers Hub Moon.** Since the EQ panel left, "how do I control my DAC now"
  needs an answer at the one moment somebody is already installing things. It asks, defaults to
  **no**, and takes `--hubmoon` / `--no-hubmoon` to decide in advance. A piped install never
  prompts — silence is not consent, and there is no terminal to answer with.

  It resolves the **latest** release from GitHub at install time rather than shipping a pinned
  version that goes stale between sea-shell releases. `/releases/latest` excludes pre-releases,
  so a beta does not become everybody's install. On Arch it takes the package and hands it to
  `pacman -U`; anywhere else it drops the AppImage in `~/.local/bin` as `hub-moon`, and says
  so if that directory is not on your PATH.

- `install_moondrop_udev` and its rule are gone with the panel. Hub Moon ships its own.

## [6.1.1] - 2026-08-16

Lyrics, four days of them in one afternoon. 6.1.0 shipped romanisation against a lyrics
source that turns out not to have the songs it was romanising.

### Added

- **A second lyrics source.** lrclib stays the first stop — keyless and fast — but its
  catalogue thins out badly outside Western releases. `syncedlyrics` now runs when lrclib
  misses, querying NetEase then Musixmatch, which is where the Japanese and Korean catalogue
  actually lives. *Ape* by RED in BLUE is absent from lrclib entirely; NetEase has it.

  The fallback searches artist **and** title, never title alone. It returns a bare LRC string
  with no duration, so the length check that guards lrclib results cannot apply to it —
  requiring both fields is what stands in for that.

### Fixed

- **Lyrics still matched a different song.** 6.1.0 filtered search results to ±7s of the right
  length, and Jinjer's *Ape* is 196s against RED in BLUE's 202s — it passed by one second. The
  window is now ±7s **only when the artist also agrees**, and ±2s otherwise: a romanised-artist
  miss is the same recording and matches almost exactly, whereas a different band's song
  sharing a title is only ever coincidentally close. A missing duration on either side is now
  a refusal rather than a pass.
- **Every NetEase result would have parsed as empty.** lrclib writes `[mm:ss.xx]`; NetEase
  writes `[mm:ss:xx]`, with a colon before the centiseconds. The timestamp pattern accepted
  only the dot, so a good lookup would have come back as an empty list and read as "no lyrics
  found".
- **Romanisation printed every English line twice.** The check that drops romaji when it only
  echoes a Latin line back compared the strings exactly, but pykakasi re-spaces around
  punctuation — `Yeah, yeah` becomes `Yeah , yeah` — so it never matched. Compared on letters
  and digits now.

### Packaging

- `python-syncedlyrics` added to the installer's AUR packages.

## [6.1.0] - 2026-08-16

**The widgets update.** Bar widgets you can actually configure, a rebuilt media panel, and
lyrics that tell you how to pronounce them.

The through-line is data that was already being collected and never reaching the screen.
`sea-sysmon.sh` had been sampling CPU, RAM, GPU, VRAM, temperatures and power every three
seconds since the pill was written — and the pill rendered exactly one of those numbers, so a
6GB card had its VRAM measured on every tick and displayed nowhere. Notifications recorded
their action buttons and drew them only on the popup. The Wi-Fi scan parsed each network's
security type and threw it away for a padlock glyph.

> **Nothing moves and nothing is lost.** Every new key defaults to the previous behaviour: the
> System Monitor still shows CPU alone until you add to it, the microphone widget is off, and
> lyrics romanisation is on only when the panel is open.

### Added

- **Lyrics pronunciation and translation.** Romaji under Japanese lines, Revised Romanisation
  under Korean, pinyin under Chinese — offline, via `pykakasi`/`pypinyin` and a pure-algorithm
  Hangul pass, computed once per track. Translation is opt-in and shells out to
  `translate-shell`. Both are stacked *under* the original rather than replacing it, because
  singing along needs both at once. Both are line-aligned with the lyrics or discarded
  entirely — the panel indexes them with the same `lyrIdx`, so a result off by one line would
  confidently show the reading of the wrong lyric.
- **The System Monitor pill is configurable.** Eight readings — CPU, RAM, GPU and VRAM, each as
  a percentage or an absolute, plus both temperatures — in any combination, chosen in
  *Settings → Bar*. GPU readings remove themselves on a machine with no discrete card rather
  than rendering a dash.
- **Microphone widget.** Input level on the bar, click to mute, red while muted. Off by
  default. Reads `@DEFAULT_AUDIO_SOURCE@` through `wpctl` so it follows the default source
  changing the way the volume keys do, and re-samples after a toggle instead of assuming.
- **The clock dropdown folds.** Calendar, Upcoming, Timer and World Clock each collapse from
  their header and stay that way. It stacked to roughly 720px with no cap, which ran off the
  bottom of anything shorter than 1080p; fully folded it is about 120px. A running countdown
  stays visible on the folded Timer header, since that is when you would look.
- **Notification actions in the centre.** They were recorded on every notification and drawn
  only on the transient popup, so anything that timed out or arrived during Do Not Disturb
  landed in history with a Reply button that existed in the data and nowhere on screen. They
  render dead once the server releases the notification rather than staying pressable.

### Changed

- **The media panel is rebuilt.** Square rounded album art as the anchor instead of an 84px
  thumbnail; the level meter rides the art's bottom edge instead of taking a 38px band of its
  own; remaining time rather than total, in tabular mono so it stops re-measuring on every
  tick; one filled primary control instead of five of equal weight; and the signal chain —
  *out via …*, bit-perfect, the DAC model — promoted from two 10px lines under the album name
  to a strip of its own. It is the most specific thing this panel knows and the one thing no
  other shell can tell you.
- **The Wi-Fi panel shows what it already knew.** Signal strength as a number, mono and
  tabular, next to the bars — the scan sorts on it and the panel re-probes every 8s to keep it
  moving, yet it only ever reached the screen as one of three icons. Security is named
  (`WPA2`, `WPA3`, `OPEN`, `WEP`) instead of a padlock at 60% opacity, with open and WEP
  networks flagged as warnings. The list also says when it has capped itself at eight.
- **Track details read like a readout.** Keys as tracked uppercase labels, values in mono —
  a bitrate, a release year and a sink name are readings, and the panel rendered them in the
  same face as prose.

### Fixed

- **Every toggle in the shell detached from reality after one click.** `IndToggle` assigned
  over its own `on` property before emitting, which destroyed the caller's binding — so from
  the first press onward Wi-Fi, Bluetooth, Caffeine, Audio and WARP showed what they had been
  clicked to rather than what was true. A WARP connect that failed, or a radio something else
  turned off, stayed wrong for the life of the session.
- **The DAC widget was missing from the bar widget list** — and from five other places. Most
  damaging: `saveAppearance()` rebuilds `appearance.json` from scratch, so every settings save
  silently deleted `wgDac`. The pill only survived because `reconcileOrder` re-added it from
  the default each boot, which is also why its position never stuck. The same list had
  `wgUpdates` and `wgNet` in it twice, so both showed as duplicate rows and dragging either
  wrote the duplicate to disk; `reconcileOrder` now de-duplicates so a damaged config heals.
- **Saved bar layouts dropped two widgets.** Network Speed and Updates were toggleable in the
  panel but absent from `barToggleKeys`, so switching between saved layouts left them wherever
  they happened to be.
- **Lyrics sometimes belonged to a different song.** The last search step queries lrclib by
  title alone — deliberately, since MPRIS and lrclib disagree on how to spell artists — and
  the parser then took the first result that had any lyrics. "Embers" returns every song ever
  called Embers. Results are now filtered by duration within ±7s with a fuzzy artist match
  preferred, and no match beats a confident wrong one.
- **Album art was never rounded**, in three separate panels. `clip: true` on a `Rectangle`
  clips children to the bounding box and ignores the radius, so no radius value would have
  worked; the art sat square-cornered inside a rounded frame. Now `ClippingRectangle`.
- **The media transport was not centred.** `Row` lays children out left to right and leaves
  `y` at 0, so the 48px play button hung 6px below its 36px neighbours. Hiding unsupported
  shuffle and loop compounded it — a `Row` drops invisible children and re-centres on what is
  left, so a player reporting loop but not shuffle pushed play off-axis. The row is now always
  five slots, with unsupported controls dimmed and inert rather than absent.

### Packaging

- `python-pykakasi`, `pypinyin` and `translate-shell` added to the installer's repo packages.
  All three are in `extra`, so the lyrics features need no AUR helper.

## [6.0.0] - 2026-08-15

**A dock, and an interface that reads like an instrument.**

Two headline changes sit next to each other. sea-shell grows a real **dock** — pinned and
running apps, magnification, per-monitor, on any edge. And every data-bearing surface is
rebuilt on one **industrial design language**: labelled regions divided by hairlines instead
of translucent cards nested three deep, tabular mono on every number, and a single accent that
marks the active thing and nothing else.

Underneath is the *"I am about to disappear for six months"* half of the release.
**Over-the-air updates**, a **health check**, **backup & restore** and a **bar supervisor**
exist for one reason: so a machine you are no longer actively ricing can be diagnosed,
repaired and updated without remembering how any of it works.

> **Nothing breaks and nothing moves.** Every existing key in `appearance.json` is read as
> before, and each new one defaults to the old behaviour — the dock is **off** until you turn
> it on, and the two new bar widgets are opt-in from *Bar Widgets*.

### Added

#### Dock  ·  Settings → *Dock*
- **Pinned + running apps** in one strip, per-monitor, on **any edge** (bottom/top/left/right),
  with macOS-style **cursor magnification**, running-app dots and hover labels.
- Three visibility modes: **always**, **auto-hide** (reveal strip at the edge), and
  **when free** — visible until a window would overlap it.
- Left-click launches, or focuses a running window — cycling by focus history when the app has
  several. Middle-click opens a new instance; right-click pins or unpins. Pins persist to
  `~/.config/sea-shell/dock.json`.

#### Staying alive, and staying current
- **Over-the-air updates**  ·  Settings → *System*. Checks GitHub for a newer sea-shell and
  updates in place. It **only ever fast-forwards**: if the repo has uncommitted changes,
  unpushed commits or a diverged history, it refuses and says which — an updater that can eat
  your own unpushed work is not one you should ever press.
- **Health check**  ·  Settings → *System*. Forty-odd read-only checks — dependencies, fonts,
  config JSON validity, deployment, compositor, and **the supervisor's crash log**. That log is the
  usual difference between fixing the bar and reinstalling it; nothing surfaced it before.
- **Backup & restore**  ·  Settings → *System*. One archive of every setting, pin, rule,
  gesture and keybind (`sea-backup.sh`). Restoring writes a `.pre-restore` archive first, so
  restoring the wrong file is itself undoable.
- **Bar supervisor** — Quickshell dies with `rc=255` when its Wayland connection drops, which
  a fullscreen client tearing down reliably causes: closing a game took the bar with it and
  left you barless until `SUPER+SHIFT+B`. The bar now runs under a supervisor that respawns it,
  logs every exit, and gives up after 5 failures in a row rather than spinning.

#### System
- **Package updates pill** — repo + AUR counts (via `checkupdates`, so it never touches the
  live pacman db), the full list with old → new versions in a dropdown, and one click to run
  the upgrade in a terminal. Opt-in from *Bar Widgets*.
- **Network throughput pill** — live up/down rates on the active interface. Opt-in.
- **Game mode**  ·  `SUPER+SHIFT+G`. Strips blur, shadows, animations and the video wallpaper,
  switches to the performance profile and silences notifications — then **restores every one to
  the value it had before**, not to a hardcoded default.
- **Disks**  ·  Settings → *Disks*. Drives grouped with model, bus and size; partitions with
  real used/free bars from `lsblk`; mount, unmount and eject through udisks. Unmounted
  partitions show **no bar** rather than an empty one, because their usage genuinely isn't
  knowable without mounting.
- **Screen time**  ·  Settings → *Screen time*. Per-app focus time, paused while the session is
  idle, with optional daily limits and a daily summary notification. History in `usage.json`.
- **Notification actions** — notifications with buttons now render them and invoke them.

#### Compositor
- **Window rules**  ·  Settings → *Window rules*. Float, size, position, centre, opacity,
  workspace, pin and no-blur per app class or title, written to `rules.lua` and applied live.
  Loaded *after* the shipped rules so yours always wins.
- **Touchpad gestures**  ·  Settings → *Input*. Swipe actions by finger count and direction.
  The valid action/direction sets were **probed against Hyprland**, not taken from docs, so the
  UI cannot offer you a combination the compositor will reject.
- **Input tab** — mouse sensitivity and acceleration profile, natural scroll, touchpad tap,
  scroll speed and disable-while-typing.
- **VRR** — off / always / fullscreen / fullscreen-video, per the compositor's own modes.
- **Games opt out of the glass** — `steam_app_*` and `gamescope` windows are forced opaque with
  no blur, shadow, rounding or animation. An unfocused game at `inactive_opacity 0.96` forces a
  4-pass blur that samples the *animated wallpaper* behind it every frame; on a hybrid laptop
  that blur runs on the same iGPU that is copying the game's frames across.
- **Laptop lid actions** — suspend · lock · display off · hibernate · shut down · ignore
  (Settings → *Power* / *Idle & lock*), written to `keybinds.lua` and applied live.

#### Wallpaper
- **Transitions** — 14 swww transitions with configurable fps and duration, and a **dip-to-black
  fade** drawn by the shell for the `SUPER+N` cycle (mpvpaper can't transition at all, so the
  shell covers the swap itself).
- **Auto-rotate** on a timer — next, previous or random, off by default and re-read from disk
  each tick, so toggling it needs no restart and leaves no daemon running when off.
- **One apply path** — the picker, the cycle binds, login restore and the rotator now all route
  through `sea-wallpaper-apply.sh`. The swww invocation used to be copy-pasted into two files
  with the transition hardcoded in both.

#### Misc
- **OCR a region to the clipboard**  ·  `SUPER+SHIFT+O` (needs `tesseract`).

### Changed

- **Every surface is rebuilt on the industrial design language.** The bar, control center,
  dashboard, launcher, keybinds, power menu, screenshot tools, recorder and DAC panel now share
  eleven components (`IndTable`, `IndPanel`, `IndKpi`, `IndChip`, …) and one token singleton.
  Data lives in **real tables** with declared columns rather than in per-surface hand-rolled
  rows — displays, keybinds, audio devices, VPNs and processes each had grown their own copy of
  the same header-plus-hairline layout.
- **Design tokens are a singleton.** `shell.qml`, `settings.qml` and `Dashboard.qml` each used
  to declare their own theme object and separately re-parse `appearance.json`; the three had
  already drifted. `Tok.qml` reads it once. The accent stays user-configurable and
  matugen-driven, and the neutral ramp is **derived from its hue** so the greys read as chosen.
- **The window glow follows matugen.** `matugen.lua` was `dofile`'d *before* the decoration
  block, so the shadow colour it wrote was immediately overwritten by the hardcoded sea-cyan
  below it — the glow never followed the wallpaper. It now loads after everything it may
  override.
- **`SUPER+SHIFT+B` restarts through the supervisor** instead of `pkill`-ing the bar, so a
  manual restart is no longer indistinguishable from a crash.

### Fixed

- **Settings could silently reset every appearance setting.** A read that caught
  `appearance.json` mid-write (a reinstall, or matugen rewriting it) failed to parse, left the
  in-memory settings at their declared defaults, and still marked the config *loaded* — so the
  next save wrote those defaults over your real file. The dock switching itself off was the
  visible symptom; the actual blast radius was the whole file. An empty read (no config yet) is
  now distinguished from an unparseable one (retry), and saving is blocked until a clean parse.
- **`install.sh` reported "bar restarted" when it hadn't.** `hyprctl dispatch exec` is a *Lua
  syntax error* under the 0.55+ parser, and the error went to `/dev/null`. It now dispatches
  correctly and confirms the process actually survived rather than trusting the exit code.
- **The updates pill was dead on click.** Every dropdown must be listed in the bar's grab set —
  one left out isn't merely unregistered, it counts as *outside* the grab, so it opened and was
  dismissed in the same frame.
- **The dock ignored every click.** Its input region pointed at an item inside the UI-scale
  wrapper, whose coordinates are pre-scale and one level down, while the region is interpreted
  in window space — so the dock rendered perfectly and accepted input somewhere else entirely.
- **The dock left its icons stuck at full magnification.** Clicking an icon focuses a window —
  often on another workspace — and the burst of Hyprland events that follows rebuilds the dock's
  item list, which makes the `Repeater` destroy the delegate the pointer was inside. A destroyed
  `MouseArea` never emits `onExited`, so the hover state was never cleared and the icons sat
  zoomed with the pointer nowhere near them. The card's own handler was clearing the hover *key*
  but not the hover *index* — which is why the label correctly vanished while the magnification
  it should have vanished with did not.
- **Right-clicking a dock icon looked like it did nothing.** It did toggle the pin, and it did
  write `dock.json` — but for an app that was already running, nothing on screen changed, so the
  binding read as dead. The hover label now states the pin, and names the binding when there
  isn't one.
- **Re-installing reverted the shell prompt to the default cyan.** `~/.config/starship.toml` is
  *generated*, not installed: the theme pipeline substitutes the wallpaper palette into
  `starship-default.toml` to produce it. `install.sh` was writing the shipped source straight over
  that output, so the prompt dropped back to `#63c7dd` while every other surface stayed on the
  wallpaper's accent. The shipped copy now updates the template, and the live prompt is seeded
  only when there isn't one.
- **Re-installing also discarded lock and idle settings.** `hyprlock.conf` and `hypridle.conf` are
  edited in place by the control center, and `copy_file` suppresses its backup for any file
  containing "sea-shell" — which both of them do — so they were overwritten with nothing kept.
  A file the shell or the user writes is no longer overwritten by an install at all.
- **The scratchpad put a `-98` chip in the bar.** Hyprland numbers special workspaces from -98
  down, and the workspace strip drew every workspace it was handed — so `SUPER + grave` added a
  chip whose label did not fit its own 24px circle, and whose click dispatched
  `focus({ workspace = -98 })`, which is not how a special workspace is reached. A special
  workspace is an overlay on the one you are already on, not a place in a list of places to go;
  its windows being on screen is what tells you it is open.
- **The launcher calculator rejected exponents.** `=2^10` returned nothing and the panel sat there
  saying "keep typing". The evaluator has always rewritten `^` to `**`, but the character
  whitelist that guards it was missing `^`, so the expression never reached the evaluator at all.
- **The settings sidebar overflowed** past the last tab once the new tabs were added; it now
  scrolls.


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
