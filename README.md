# sea-shell 🐚

**`v3.3.0`** — A Hyprland rice by MiyukiVigil — a shell, by the sea. (yes.)

<!-- screenshots are hosted on the showcase site, not committed here — clones stay lean -->
![sea-shell — the desktop: translucent bar, animated whale wallpaper, and the player with track details, cava and synced lyrics](https://seashell.miyukivigil.tech/images/hero.webp)

**[seashell.miyukivigil.tech](https://seashell.miyukivigil.tech)** · **[changelog](https://seashell.miyukivigil.tech/changelog.html)**

Built for: **CachyOS · Hyprland 0.55 · Quickshell 0.3 · kitty · fish · starship**.
No external launcher or status-bar helper needed — the bar, app launcher, clipboard
picker, notification daemon, power menu and control center are all native Quickshell.

## Quick install (Arch-based)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MiyukiVigil/sea-shell/main/bootstrap.sh)
```
Clones the repo, installs every dependency (pacman + AUR), and lays down the configs.
Use `bash <(…)` — not `curl … | bash` — so `sudo`/`pacman` can still prompt. Full options
and how it works are under [Install](#install) below.

## Palette
```
iris   #63c7dd   frost  #a2e2e8   iris-deep #45b2cc
bg     #0d1420   panel  #161d2b   line      #24304a
text   #e2e9f4   sub    #a6b6cf   faint     #6f8099
radius 10px
```
Catppuccin Mocha base + a custom sea-cyan accent — but that's the **default, not the point**.
Turn on *match colours* in the wallpaper picker and `matugen` pulls a palette out of the image:
every surface follows the accent's hue, and kitty, starship, hyprlock and the window borders
come with it. There's a light palette too (`SUPER+SHIFT+D`).

| dark · blue | light · warm | the bar follows too |
|:---:|:---:|:---:|
| ![the control center in dark mode with a blue accent from an underwater wallpaper](https://seashell.miyukivigil.tech/images/control-center.webp) | ![the same control center in light mode with a warm taupe accent from a garden wallpaper](https://seashell.miyukivigil.tech/images/control-center-light.webp) | ![the desktop with a pink wallpaper and the bar recoloured to match](https://seashell.miyukivigil.tech/images/theme-pink.webp) |

The same panel, same build — only the wallpaper changed. The terminal palette is generated with a
WCAG contrast floor rather than matugen's raw base16, so it stays readable on *any* wallpaper
(that base16 gives you maroon text on a maroon background for a hot-pink image).

## The bar
![the bar — workspaces, centred media, tray, and the status pills](https://seashell.miyukivigil.tech/images/bar.webp)

Rounded, translucent, cyan-bordered — Material-Symbol icons throughout, with
**click-to-open dropdowns** (one open at a time, click-outside closes, all
frosted by Hyprland layer blur):
- your **logo.svg** (click → launcher)
- workspaces: **circle when idle → pill when active**
- **app name** of the focused window
- **media** centred (Mpris: title + play/pause, right-click = next, scroll = prev/next);
  width auto-clamps to the free space so a long title never overflows the bar
- **system monitor** — live **CPU / RAM / GPU** with usage bars, **temps, VRAM and
  power draw**; the pill tints amber→red as the CPU heats up (see below)
- **weather** (wttr.in) with a **3-day forecast**; location/units set in the control center
- **system tray** — left-click activates, right-click opens the app menu in a
  frosted dropdown (single menu, replaces itself when you open another icon's)
- **clipboard** pill → launcher in clipboard mode
- **notifications** bell (the bar runs its own notification daemon — popups
  top-right + history dropdown; don't run mako/dunst alongside)
- **wi-fi** → nearby networks + inline password + **Cloudflare WARP** and
  **NetworkManager VPN** toggles
- **bluetooth** → paired devices, battery %, click to (dis)connect
- **kde connect** → your phone's battery and cell signal, then one tap for **ring,
  ping, send file, push clipboard, browse its storage, messages** — pairing (with the
  verification key) is in the same dropdown, no external app
- **volume** → slider + output-device picker (scroll = change, right-click = mute)
- **battery** → power-profile picker (hidden on desktops), plus **low-battery
  notifications** at 15% and a critical one at 5%
- **clock** (day · date · time) → month calendar with **event dots** (ICS import)
- **power** button → session dropdown with user/uptime header; reboot and
  shut down ask for a **second click** so a stray click can't kill your session

## Media, lyrics & bit-perfect audio
![the player dropdown — album art, cava visualizer, synced lyrics sidecar, and the gold bit-perfect badge](https://seashell.miyukivigil.tech/images/player.webp)

Click the centre pill for a full player: album art, seekable progress, shuffle/loop,
per-player volume, and a live **cava visualizer**. It fetches **time-synced lyrics**
(lrclib.net — free, keyless) into a side panel that follows playback and lets you
click a line to seek. When a player opens the DAC directly over ALSA (e.g. TIDAL in
exclusive mode), a gold **bit-perfect** badge shows the true bit-depth / sample-rate,
and the visualizer switches to an ambient wave since pipewire can't see the stream.

## Equaliser  ·  `SUPER+SHIFT+E`
![the equaliser — a DAWN PRO2 with eight parametric bands, a live response graph, pre-gain and one-tap presets](https://seashell.miyukivigil.tech/images/eq.webp)

An 8-band parametric EQ with a live frequency-response graph, an all-bands column editor,
pre-gain, one-tap starting presets, and AutoEQ/REW import.

**It works with or without a Moondrop DAC.** Plug one in (DAWN PRO2, FreeDSP, Rays,
MOONRIVER 3, …) and the filters run on the DAC's own DSP chip — edits are live, and
save-to-flash keeps them after you unplug. With no DAC the same panel drives a **software
EQ** through PipeWire instead, which works on anything: laptop speakers, another brand's
DAC, bluetooth. It picks automatically, and a `DAC | software` toggle in the header lets
you force software even with a DAC plugged in — worth doing, since software has no Q2.30
limit, so the shelf gains the DAC has to refuse work there.

Two differences in software mode, both stated in the panel: **nothing is audible until you
press apply** (PipeWire 1.6 ignores per-band live control writes, so a change means
re-rendering the graph), and the first apply asks before creating the virtual output. That
setup writes one config to `filter-chain.conf.d` and starts `filter-chain.service` — a
separate PipeWire instance, so **your main daemon is never restarted and nothing playing is
interrupted**. Remove it any time from the same panel.

| No DAC — the same panel in software | The community library |
|:---:|:---:|
| ![the equaliser in software mode — titled Software EQ, marked not created yet, with a create and apply button](https://seashell.miyukivigil.tech/images/eq-software.webp) | ![the community preset browser — a searchable list with download counts and a preview curve](https://seashell.miyukivigil.tech/images/presets.webp) |

**Community presets** — the *community* button opens the public library behind
[Moondrop Hub](https://hub.moondroplab.tech/): ~59,700 user-made curves, searchable by
name, author or description, sorted by downloads. **Click one to see its curve** — only
the *apply* button touches the DAC, so you can audition without writing. The preview
also says whether that curve would clip at your pre-gain, which the preset itself can't
tell you. Reading the library needs no account, and the panel only ever reads — it never
publishes, likes or comments. You get your device family's whole pool (a DAWN PRO2 sees
~6,900 curves, not just its own 1,270). Two things to know: applying is **live only**
until you press save, and published presets **carry no pre-gain**.

The graph toggles (top-right) between the **editor** — region-labelled, per-band curves,
draggable handles — and a **readout** drawn the way the official app draws it: normalised
with the flat reference at 60 dB, one curve, pre-gain paid for. The editor also shows a
dashed *output* line with pre-gain applied, so a +6 dB boost doesn't look free.

Two scripts sit behind it, deliberately with no overlap: `moondrop_control.py` is the DAC
(USB HID, its DSP, the community library) and knows nothing about PipeWire; `sea-eq.py` is
the software EQ (PipeWire only) and knows nothing about Moondrop. The panel is the one
place they meet, which is what keeps either usable without the other. The DAC half is
vendored from [hub_moon](https://hubmoon.miyukivigil.tech/), which documents the protocol
and the Hub API; the installer adds `python-hidapi` and a udev rule so it works without root.

## Screen recording  ·  `SUPER+R`
![the screen-recorder chooser — capture and audio options, a bit-perfect warning, quality and countdown settings](https://seashell.miyukivigil.tech/images/recorder.webp)

`SUPER+R` opens a chooser: **what to capture** (drag a region · the focused screen ·
a named output) and **which audio** (none · microphone · system audio · both at once),
plus framerate, container, and CPU/GPU encoding. It remembers your last choice, so
`SUPER+R` `⏎` is still two keystrokes. While a recording is running, `SUPER+R` stops it.

A red dot and a timer appear in the bar. **Left-click stops and keeps** (the file lands
in `~/Videos/Recordings`, its path goes to your clipboard, and the notification tells you
how big it is). **Right-click discards** — but it arms first and the pill says `discard?`,
so one stray click can't delete a take.

Some things worth knowing:

- **System audio** is captured from an output's *monitor*, and *Default* re-reads the
  default sink when recording starts — so it follows your DAC when you plug one in.
- **Mic + system together** is not something wf-recorder can do (it takes exactly one
  audio device), so the shell builds the mix itself: a null sink with both looped into
  it, recorded via its monitor, torn down on stop. If a recording is killed outright,
  the next `SUPER+R` — or the bar's own status tick — sweeps the leftovers, because a
  stranded loopback would hold your microphone open.
- **Bit-perfect playback is invisible to this.** A player holding the DAC directly over
  ALSA never goes through pipewire, so the monitor is real, readable, and *silent*. The
  chooser says so up front when it detects an exclusive hold — record the mic instead,
  or take the player out of exclusive mode. (See *Media, lyrics & bit-perfect audio*.)
- **mp4 finalises its index on stop**, so a recording that dies with the machine is a
  write-off. **mkv** keeps every frame written so far. The chooser says which you're on.

Needs `wf-recorder` (plus `slurp` for region drags and `jq`); the installer pulls them in.

## Status dropdowns
Every pill opens a frosted card. A few of them:

| System monitor | Weather | Wi-Fi + VPN |
|:---:|:---:|:---:|
| ![CPU/RAM/GPU usage, temps, VRAM and power draw](https://seashell.miyukivigil.tech/images/sysmon.webp) | ![current conditions + 3-day forecast](https://seashell.miyukivigil.tech/images/weather.webp) | ![networks with WARP and VPN toggles](https://seashell.miyukivigil.tech/images/wifi.webp) |
| **Volume** | **Notifications** | |
| ![volume slider + output-device picker](https://seashell.miyukivigil.tech/images/volume.webp) | ![notification centre with history](https://seashell.miyukivigil.tech/images/notifications.webp) | |

## Launcher  ·  `SUPER+Space` / `CTRL+Space`
![the launcher — fuzzy app search with match highlighting and frecency ranking](https://seashell.miyukivigil.tech/images/launcher.webp)

Native, **resident inside the bar process** — opens instantly, no spawn delay
(`qs -c sea-shell ipc call launcher toggle`). Solid card, no blur needed.
- fuzzy app search with match highlighting + **frecency ranking** (apps you
  launch often float up; history in `~/.config/sea-shell/launcher-history.json`)
- `>cmd` — run a shell command (⏎ detached · CTRL+⏎ in a kitty window)
- `=expr` — calculator with functions (also auto-detects plain `2+2`) · ⏎ copies
- `~query` — file search in `$HOME` (needs **fd**) · ⏎ opens via xdg-open
- `?query` — web search
- `;query` — **clipboard history** (cliphist): fuzzy-filter text + images, ⏎ copies
- `:` — system actions (settings · wallpaper · lock · suspend · reboot · …)
- `↑↓`/Tab navigate · PgUp/PgDn jump · `ALT+1–9` quick-launch · Esc closes

## Control center  ·  `SUPER+S`
![the control center — audio sliders, output/input device pickers, per-app volume](https://seashell.miyukivigil.tech/images/control-center.webp)

An overlay panel (Esc / click-outside to close): **Audio** (output & mic sliders,
mute, device selection, per-app volume) · **Display** (brightness) · **Network**
(wi-fi) · **Bluetooth** · **Appearance** (radius / opacity / height / accent /
font) · **Weather** · **Keybinds** · **Idle & lock** · **Actions** (reload,
restart bar, terminal, wallpaper, screenshot) · **Power**.

**Big screens / TVs / projectors** — under *Display → display scale*, the shell
sizes itself to each monitor automatically (a 4K TV scales up, a 1080p/1440p
display stays 1×). Turn off *auto scale* to set the multiplier by hand (0.75×–2.5×)
if a projected picture still reads too small. Stored in
`~/.config/sea-shell/appearance.json` as `"scale"` (`0` = auto).

## Power menu  ·  `SUPER+ESC`
![the power menu — user@host, uptime, five session cards](https://seashell.miyukivigil.tech/images/power-menu.webp)

Full-screen session overlay: user@host + uptime, five cards (lock · suspend ·
log out · reboot · shut down). Drive it with the mouse or entirely from the
keyboard — `←→`/Tab to select, `⏎` to go, `l s o r p` hotkeys, `1–5` quick-fire.
Reboot/shut down arm to a red "sure?" and need a second press; Esc backs out.

## Keybinds  ·  `SUPER+K`
![the keybind cheat-sheet — searchable, click any bind to rebind it](https://seashell.miyukivigil.tech/images/keybinds.webp)

Every bind in `hypr/keybinds.conf` is a `bindd` with a human name, so the cheat-sheet
shows "Wallpaper picker" instead of a shell command. **Type to search**, and
**click any bind to rebind it** — toggle SUPER/CTRL/ALT/SHIFT chips, press the new
base key; conflicts are refused with a "used by …" note. Rebinds rewrite
keybinds.conf, sync to the repo copy, and hot-reload Hyprland.

`SUPER+Space`/`CTRL+Space` launcher · `SUPER+V` clipboard history ·
`SUPER+Return` terminal · `SUPER+Q` close · `SUPER+E` files · `SUPER+B` browser ·
`SUPER+S` control center · `SUPER+SHIFT+W` wallpaper picker · `SUPER+ESC` power menu ·
`SUPER+F` maximize / `SUPER+SHIFT+F` true fullscreen · `SUPER+P` float · `SUPER+C` center ·
`hjkl` focus / `SHIFT` move / `CTRL` resize · `1–0` workspaces / `SHIFT 1–0` move-to ·
`` SUPER+` `` scratchpad · media & brightness keys · `Print`/`SUPER+Print`/`SUPER+SHIFT+S`
screenshots · `SUPER+R` screen recording · `SUPER+SHIFT+R` reload · `SUPER+SHIFT+B` restart bar.

## Wallpapers  ·  `SUPER+SHIFT+W`
A grid of `~/Pictures/wallpapers`; click to set. **Static** images go through swww
(or its awww fork) → hyprpaper → mpvpaper fallback. **Animated** wallpapers
(mp4/webm/gif) play via **mpvpaper**, and a small listener **pauses the video
whenever a fullscreen window covers it** (and resumes when it's visible again) —
so a fullscreen game or video costs no wallpaper CPU/GPU. "Match colours" runs
`matugen` to recolour the whole shell from the wallpaper. The pick is persisted and
restored on every login. `./install.sh --wallpaper` generates a matching
sea-gradient (`~/.config/sea-shell/sea-wall.png`) as the default.

## Lock & idle  (hyprlock + hypridle)
`loginctl lock-session` (power menus, lock binds, lid events) locks via a
sea-themed **hyprlock**: blurred wallpaper, big clock, iris input field.
**hypridle** dims the backlight at 2.5 min, locks at 5, screen off at 10, suspends
at 30 (comment that listener out on a desktop), and always locks before sleep. Both
configs install to their canonical `~/.config/hypr/` paths and start on login.

## Structure
```
sea-shell/
├── install.sh                    # installer (--dev / --wallpaper / --uninstall)
├── quickshell/
│   ├── shell.qml                # the bar + dropdowns + notification daemon
│   ├── Launcher.qml             # resident app launcher
│   ├── settings.qml             # control center (SUPER+S)
│   ├── power.qml                # power / session menu (SUPER+ESC)
│   ├── keybinds.qml             # live keybind cheat-sheet (SUPER+K)
│   ├── wallpaper.qml            # wallpaper picker (SUPER+SHIFT+W)
│   ├── screenshot.qml           # screenshot tool (region / window / full)
│   ├── RecorderPanel.qml        # screen-recorder chooser + countdown (SUPER+R)
│   ├── DacPanel.qml             # Moondrop DAC parametric EQ (SUPER+SHIFT+E)
│   ├── sea-record.sh            # wf-recorder + the pipewire mix for mic+system
│   ├── moondrop_control.py      # reverse-engineered Moondrop USB-HID controller (vendored)
│   ├── sea-eq.py                # software EQ — a pipewire filter-chain, no DAC needed
│   ├── sea-sysmon.sh            # cpu/ram/gpu sampler for the monitor pill
│   ├── sea-wallpaper-restore.sh # restore last wallpaper at login
│   ├── sea-wallpaper-autopause.sh # pause video wallpaper under fullscreen
│   ├── sea-import-ics.py        # import .ics events into the calendar
│   ├── matugen-accent.sh        # recolour the shell from the wallpaper
│   └── … (lock, clipboard, rebind & toggle helpers)
├── hypr/sea.conf                # borders, blur, shadow, animations, layer rules
├── hypr/keybinds.conf           # full Hyprland keybinds (SUPER-based)
├── hypr/hyprlock.conf           # sea-themed lock screen
├── hypr/hypridle.conf           # idle: dim → lock → screen off → suspend
├── kitty/sea-cyan.conf          # terminal colours
└── starship/sea.toml            # prompt — Tokyo Night gradient powerline
```
(fastfetch is intentionally left alone — you keep your own.)

## Install

**One line** (Arch-based only — clones + installs packages + configs):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MiyukiVigil/sea-shell/main/bootstrap.sh)
```
> Use `bash <(…)`, not `curl … | bash` — the pipe steals stdin so `sudo`/`pacman` can't prompt.
> Append installer flags too, e.g. `… bootstrap.sh) --wallpaper`.

**Or clone and run it yourself:**
```bash
./install.sh                 # packages (pacman + AUR) THEN configs — reboot-proof
./install.sh --deps          # only install the packages
./install.sh --no-deps       # skip packages, only lay down configs (any distro)
./install.sh --dev           # symlink configs to this repo (live-edit mode)
./install.sh --wallpaper     # also generate + set the sea-gradient wallpaper
./install.sh -y              # non-interactive (--noconfirm)
./install.sh --uninstall     # cleanly remove everything it added
```

**Packages are Arch-only** (Arch · CachyOS · EndeavourOS · Manjaro · Artix). The installer
`pacman -S`'s the repo deps, uses an AUR helper (paru/yay — **bootstraps paru** if you have
neither) for `quickshell`, `matugen`, `ttf-material-symbols-variable` and `mpvpaper`,
then enables NetworkManager / Bluetooth / PipeWire / power-profiles-daemon. On a non-Arch
distro, install those yourself and run `--no-deps`.

Then the installer:
- **copies** the Quickshell config to `~/.config/quickshell/sea-shell` and the
  hypr confs to `~/.config/hypr/sea-shell` — the repo can be moved or deleted;
  re-run after pulling updates (`--dev` symlinks instead while you're ricing)
- wires Hyprland (look + keybinds + `exec-once = qs -c sea-shell`) and kitty via
  replaceable `# >>> sea-shell >>>` marker blocks, so **everything autostarts on login**
- installs the starship prompt to `~/.config/starship.toml`, and the
  **hyprlock / hypridle** configs to `~/.config/hypr/` (previous files backed up,
  restored on `--uninstall`)
- wires the idle daemon + **polkit agent** (hyprpolkitagent) into autostart —
  both runtime-guarded, so installing the package later Just Works
- wires the wallpaper restore at login
- backs up every foreign file it touches (`.bak-<timestamp>`), and reloads
  Hyprland + restarts the bar if you run it inside a session

Deps are installed for you on Arch. On a `--no-deps` run the bar still degrades
gracefully when something's absent, and `check_deps` prints a `pacman -S` line for
whatever's missing. Icons need the **Material Symbols Outlined** font
(`ttf-material-symbols-variable`, pulled in above). GPU stats on the monitor pill
use `nvidia-smi` when present. Disable any other bar's autostart so you don't get two.

## Try it without installing
```bash
qs -p quickshell/shell.qml       # bar (launcher + tray menus included)
qs -p quickshell/settings.qml    # control center
qs -p quickshell/power.qml       # power menu
qs -p quickshell/wallpaper.qml   # wallpaper picker
```

## Notes / gotchas
- **Hyprland 0.55 rule syntax changed** — rules are `field value, match:prop regex`
  (e.g. `layerrule = blur on, ignore_alpha 0.2, match:namespace sea-shell:drop`).
  The old `layerrule = blur ns` form is accepted **silently as a no-op**, so a
  wrong rule shows no error and no effect. `sea.conf` uses the new syntax.
- Duplicate binds both fire in Hyprland — if a toggle (fullscreen, float…)
  "does nothing", check you're not sourcing two keybind files.
- `pkill -f <pattern>` matches a process's **whole command line**, including the
  shell running the `pkill` itself — bracket a letter (`sea-…-auto[p]ause`) to
  stop a cleanup command from killing its own shell.
- Quickshell 0.3: starting an `Animation` imperatively from `Component.onCompleted`
  on a layer-surface window makes the process exit silently — use property flips +
  `Behavior` instead (Launcher.qml does).
- The bar is a **starting point** — Quickshell's QML API can shift between
  releases. If a workspace pill doesn't highlight, swap `modelData.active` for
  `modelData.focused` in `shell.qml`. Check `qs log` for any binding errors.
</content>
