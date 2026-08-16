# sea-shell

**A Hyprland desktop shell, not a status bar.** The bar, dock, launcher, control center,
notification daemon, screen recorder and a parametric EQ are one Quickshell process — not six
tools glued together. The whole palette follows your wallpaper.

**`v6.1.0`** · [seashell.miyukivigil.tech](https://seashell.miyukivigil.tech) ·
[changelog](https://seashell.miyukivigil.tech/changelog.html)

![The sea-shell desktop — translucent bar at the top, animated wallpaper, and the dock at the bottom](https://seashell.miyukivigil.tech/images/v6/hero.webp)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MiyukiVigil/sea-shell/main/bootstrap.sh)
```

> Use `bash <(…)` — **not** `curl … | bash`. The pipe steals stdin, so `sudo` and `pacman` can
> no longer prompt you.

Built for **CachyOS · Hyprland 0.55+ · Quickshell 0.3 · kitty · fish · starship**.
Arch-based for the package install; the configs work anywhere with `--no-deps`.

---

## Contents

- [What you get](#what-you-get) · [The desktop](#the-desktop) · [Theming](#theming)
- [Control center](#control-center) · [Keeping it running](#keeping-it-running)
- [Audio](#audio) · [Wallpapers](#wallpapers) · [Keys](#keys)
- [Install](#install) · [Structure](#structure) · [Gotchas](#gotchas)

---

## What you get

| | |
|---|---|
| **Bar** | Workspaces, focused app, centred media, tray, and status pills for CPU/RAM/GPU, weather, network throughput, package updates, wi-fi + VPN, bluetooth, KDE Connect, volume, battery, calendar and power. Reorderable, individually toggleable. |
| **Dock** | Pinned + running apps, any edge, per-monitor, cursor magnification. |
| **Launcher** | Apps with frecency ranking, plus commands, maths, file search, web, clipboard history and system actions. |
| **Control center** | 20 tabs — appearance, widgets, dock, window rules, input, audio, display, network, bluetooth, disks, weather, calendar, keybinds, screen time, idle, power. |
| **Notifications** | Its own daemon: popups, history, and action buttons. Don't run mako or dunst alongside. |
| **Audio** | 8-band parametric EQ on a Moondrop DAC's own DSP, or through PipeWire with no DAC at all. Synced lyrics. Bit-perfect detection. |
| **Capture** | Screenshots with an editor, region OCR to clipboard, and a screen recorder with mic + system audio mixing. |
| **Upkeep** | Over-the-air updates, a health check, backup/restore, and a supervisor that respawns the bar. |

Nothing here needs waybar, rofi, mako, wofi or swaync. The `bootstrap.sh` line installs every
dependency it does need.

---

## The desktop

Everything below runs inside a **single Quickshell process**, so the launcher opens with no
spawn delay and the dock already knows what the bar knows.

### The bar

![The bar — workspaces, focused app, and the status pills](https://seashell.miyukivigil.tech/images/v6/bar.webp)

Every pill opens a card: the system monitor with temps, VRAM and power draw; a 3-day forecast;
nearby wi-fi with inline password entry and **Cloudflare WARP** / NetworkManager VPN toggles;
paired bluetooth devices; your phone's battery and signal over **KDE Connect**, with ring, ping,
send-file, clipboard push and file browsing; an output-device picker; a month calendar with
event dots; and a power menu that asks for a second click before it kills your session.

**Bar Widgets** in the control center toggles each pill and drags them into the order you want.

### The dock

![The dock — pinned and running apps with the hovered icon magnified](https://seashell.miyukivigil.tech/images/v6/dock.webp)

Off by default; turn it on in **Settings → Dock**. It appears on every monitor, on whichever edge
you pick, with cursor magnification, a dot under anything running, and hover labels.

- **Left-click** launches, or focuses a running window — cycling by focus history when the app
  has several
- **Middle-click** opens a new instance · **right-click** pins or unpins
- Three visibility modes: **always**, **auto-hide** (a reveal strip at the edge), and
  **when free** — visible until a window would overlap it

Pins live in `~/.config/sea-shell/dock.json`, so they survive a reinstall.

### Launcher · `SUPER+Space`

![The launcher — a search field with mode chips above a filtered list of applications](https://seashell.miyukivigil.tech/images/v6/launcher.webp)

| Prefix | Mode |
|---|---|
| *(none)* | Apps, fuzzy-matched, with **frecency ranking** |
| `>` | Run a command — `⏎` detached, `CTRL+⏎` in a kitty window |
| `=` | Calculator with functions (plain `2+2` is auto-detected) |
| `~` | File search in `$HOME` (needs `fd`) |
| `?` | Web search |
| `;` | Clipboard history — text and images (needs `cliphist`) |
| `:` | System actions — settings, wallpaper, lock, suspend, reboot |

`↑↓`/Tab to move · PgUp/PgDn to jump · `ALT+1–9` to quick-launch · Esc to close.

### Dashboard · `SUPER+D`

![The dashboard — clock, system KPIs, sparklines, a process table and app usage](https://seashell.miyukivigil.tech/images/v6/dashboard.webp)

System figures, 60-second CPU and memory sparklines, GPU readouts, the top processes, and
today's app usage — with wi-fi, bluetooth, caffeine and audio toggles on the right.

---

## Theming

Turn on **match colours** and `matugen` pulls a palette out of your wallpaper. Every surface
follows it: the bar, the dock, the control center, kitty, starship, hyprlock, the window borders
and the window glow.

The same build, four wallpapers — only the image changed:

| | | | |
|:---:|:---:|:---:|:---:|
| ![](https://seashell.miyukivigil.tech/images/v6/wp-whales.webp) | ![](https://seashell.miyukivigil.tech/images/v6/wp-zelda.webp) | ![](https://seashell.miyukivigil.tech/images/v6/wp-selena.webp) | ![](https://seashell.miyukivigil.tech/images/v6/wp-minecraft.webp) |
| `#bdc8d3` | `#d6c4aa` | `#e0bfb9` | `#c1c6d6` |

### Light and dark

Both modes are first-class — not a dark theme with an inverted afterthought. Every neutral is
re-picked per mode so contrast holds, and the accent is re-derived rather than reused, because a
pastel that reads well on near-black is far too pale on white. `SUPER+SHIFT+D` toggles, and an
auto-schedule can follow sunrise and sunset.

| Dark | Light |
|:---:|:---:|
| ![The dashboard in dark mode](https://seashell.miyukivigil.tech/images/v6/dark-dashboard.webp) | ![The dashboard in light mode](https://seashell.miyukivigil.tech/images/v6/dashboard.webp) |
| ![The control center in dark mode](https://seashell.miyukivigil.tech/images/v6/dark-system.webp) | ![The control center in light mode](https://seashell.miyukivigil.tech/images/v6/system.webp) |

The terminal palette is generated against a **WCAG contrast floor** rather than matugen's raw
base16 — base16 will happily hand you maroon text on a maroon background for a hot-pink image,
and this doesn't.

Not into any of it? Set a fixed accent, pick a matugen scheme, or leave the default sea-cyan.

---

## Control center · `SUPER+S`

Twenty tabs in five groups, in the same process as the bar.

![The System tab — kernel, compositor, session, hardware, memory and disk](https://seashell.miyukivigil.tech/images/v6/system.webp)

| Group | Tabs |
|---|---|
| **Overview** | System · Appearance · Bar Widgets · Dock · Window rules · Theme Profiles |
| **Devices** | Audio · Display · Network · Bluetooth · KDE Connect · Disks |
| **Daily** | Weather · Calendar · Keybinds · Input |
| **Session** | Screen time · Idle & lock · Actions · Power |

### Window rules and gestures write real Lua

![The Window rules tab](https://seashell.miyukivigil.tech/images/v6/windowrules.webp)

Float, size, position, centre, opacity, workspace, pin and no-blur per app class or title — saved
to `rules.lua` and applied live. Touchpad gestures work the same way into `gestures.lua`. Both are
loaded **after** the shipped rules, so a rule you set here always wins.

The valid gesture actions and directions were **probed against the running compositor** rather
than taken from documentation, so the picker cannot offer you a combination Hyprland will reject.

### Disks

![The Disks tab — drives grouped with model and bus, partitions with usage bars](https://seashell.miyukivigil.tech/images/v6/disks.webp)

Partitions grouped under their physical drive with model, bus and size, real used/free from
`lsblk`, and mount / unmount / eject through udisks. An unmounted partition shows **no usage
bar** rather than an empty one — its usage genuinely isn't knowable without mounting it.

### Screen time

![The Screen time tab — apps with time used today and their limits](https://seashell.miyukivigil.tech/images/v6/screentime.webp)

Per-app focus time, **paused while the session is idle**, with optional daily limits and a
summary notification.

---

## Keeping it running

Four features for the machine you are *not* actively ricing — six months from now, when you no
longer remember how any of this works.

### Over-the-air updates

Checks GitHub for a newer sea-shell and updates in place, from **Settings → System**.

It **only ever fast-forwards.** If your clone has uncommitted changes, unpushed commits or a
diverged history, it refuses and tells you which. Your clone is a working copy, not a read-only
channel — an updater that can quietly eat your own unpushed work is not one you should press.

### Health check

Forty-odd **read-only** checks: dependencies, fonts, whether each config file is valid JSON,
what's deployed, which Hyprland parser you're on, and **the bar's crash log**.

Invalid JSON is the quiet killer here. Every parse in the shell is wrapped, so a corrupt file
never crashes anything — it just silently reverts that whole area to defaults, with no error to
tell you why your settings "reset themselves".

### Backup and restore

One archive of every setting, pin, rule, gesture and keybind. Restoring writes a `.pre-restore`
archive first, so restoring the wrong file is itself undoable.

### Bar supervisor

Quickshell exits with `rc=255` when its Wayland connection dies — which a fullscreen client
tearing down reliably causes, so closing a game used to take the bar with it and leave you barless
until `SUPER+SHIFT+B`. The bar now runs supervised: respawned, every exit logged, and it gives up
after five failures in a row rather than spinning.

### Game mode · `SUPER+SHIFT+G`

Strips blur, shadows, animations and the video wallpaper, switches to the performance profile and
silences notifications — then restores **every one to the value it had before**, not to a
hardcoded default.

Steam and gamescope windows are separately forced opaque with no blur, shadow, rounding or
animation. An unfocused game at `inactive_opacity 0.96` drags a 4-pass blur that samples the
*animated wallpaper* behind it every frame, and on a hybrid laptop that blur runs on the same iGPU
that's copying the game's frames across from the dGPU.

---

## Audio

![The equaliser — 8 bands, a live response graph with labelled frequency regions, pre-gain and presets](https://seashell.miyukivigil.tech/images/v6/eq.webp)

An **8-band parametric EQ** with a live frequency-response graph, an all-bands column editor,
pre-gain, one-tap presets, and AutoEQ/REW import — `SUPER+SHIFT+E`.

**It works with or without a Moondrop DAC.** Plug one in (DAWN PRO2, FreeDSP, Rays, MOONRIVER 3…)
and the filters run on the DAC's own DSP chip; edits are live and save-to-flash survives
unplugging. With no DAC the same panel drives a **software EQ** through PipeWire — laptop
speakers, another brand's DAC, bluetooth. It picks automatically, and a `DAC | software` toggle
lets you force software even with a DAC plugged in (worth doing: software has no Q2.30 limit, so
the shelf gains a DAC has to refuse work there).

Two things the panel tells you up front in software mode: **nothing is audible until you press
apply** (PipeWire 1.6 ignores per-band live control writes), and the first apply asks before
creating the virtual output. That writes one config to `filter-chain.conf.d` and starts
`filter-chain.service` — a *separate* PipeWire instance, so your main daemon is never restarted
and nothing playing is interrupted.

**Community presets** — the public [Moondrop Hub](https://hub.moondroplab.tech/) library, ~59,700
curves searchable by name, author or description. Click one to see its curve; only *apply* touches
the DAC. The preview also tells you whether that curve would clip at your pre-gain, which the
preset itself cannot. Reading needs no account, and the panel only ever reads.

**Media and lyrics** — the centre pill opens a full player with album art, seekable progress,
per-player volume, a live cava visualiser, and **time-synced lyrics** from lrclib.net that follow
playback and let you click a line to seek. When a player holds the DAC directly over ALSA, a gold
**bit-perfect** badge shows the true bit-depth and sample-rate, and the visualiser switches to an
ambient wave — because PipeWire genuinely cannot see that stream.

---

## Wallpapers · `SUPER+SHIFT+W`

A grid of `~/Pictures/wallpapers`; click to set. **Static** images go through swww (or its awww
fork) → hyprpaper → mpvpaper. **Animated** wallpapers (mp4/webm/gif) play via **mpvpaper**, and a
listener pauses the video whenever a fullscreen window covers it, so a fullscreen game or video
costs no wallpaper GPU.

- **Transitions** — fourteen swww transitions with your own fps and duration. `SUPER+N` cycles the
  folder; because mpvpaper cannot transition at all, the shell draws a dip-to-black fade over the
  swap so animated wallpapers change as cleanly as static ones.
- **Auto-rotate** — off by default. Change every *n* minutes, going next, previous or random. The
  setting is re-read every tick, so toggling it needs no restart and leaves no daemon running when
  it's off.

---

## Keys

Every bind carries a `description`, so the cheat-sheet (`SUPER+K`) shows "Wallpaper picker"
instead of a shell command — and you can **click any bind to rebind it**, with conflicts refused
and a "used by …" note.

| Bind | Does |
|---|---|
| `SUPER+Space` / `CTRL+Space` | Launcher |
| `SUPER+S` | Control center |
| `SUPER+D` | Dashboard |
| `SUPER+W` | Mission control |
| `SUPER+V` | Clipboard history |
| `SUPER+K` | Keybind cheat-sheet |
| `SUPER+ESC` | Power menu |
| `SUPER+R` | Screen recording — again to stop |
| `Print` / `SUPER+Print` / `SUPER+SHIFT+S` | Screenshots |
| `SUPER+SHIFT+O` | OCR a region to the clipboard |
| `SUPER+SHIFT+E` | Parametric EQ |
| `SUPER+SHIFT+G` | Game mode |
| `SUPER+N` / `SUPER+SHIFT+N` | Next / previous wallpaper |
| `SUPER+SHIFT+W` | Wallpaper picker |
| `SUPER+SHIFT+D` | Toggle light / dark |
| `SUPER+Return` · `Q` · `E` · `B` · `F` · `P` · `C` | Terminal · close · files · browser · maximise · float · centre |
| `SUPER+hjkl` | Focus — `SHIFT` moves, `CTRL` resizes |
| `SUPER+1–0` | Workspaces — `SHIFT` sends there |
| ``SUPER+` `` | Scratchpad |
| `SUPER+SHIFT+R` · `SUPER+SHIFT+B` | Reload Hyprland · restart the bar |

---

## Install

```bash
./install.sh                 # packages (pacman + AUR) THEN configs
./install.sh --deps          # only the packages
./install.sh --no-deps       # only the configs — any distro
./install.sh --dev           # symlink configs to this repo (live-edit)
./install.sh --wallpaper     # also generate + set the sea-gradient wallpaper
./install.sh -y              # non-interactive (--noconfirm)
./install.sh --uninstall     # remove everything it added, restore backups
```

**Requires Hyprland 0.55+** with a Lua config at `~/.config/hypr/hyprland.lua`. hyprlang (`.conf`)
is deprecated upstream and goes away around 0.57 — see [hypr/README-lua.md](hypr/README-lua.md) to
migrate an existing `hyprland.conf`. Flip it with a logout/login, **not** `hyprctl reload`.

**Packages are Arch-only** (Arch · CachyOS · EndeavourOS · Manjaro · Artix). The installer
`pacman -S`'s the repo dependencies and uses an AUR helper — bootstrapping **paru** if you have
neither paru nor yay — for `quickshell`, `matugen`, `ttf-material-symbols-variable` and
`mpvpaper`, then enables NetworkManager, Bluetooth, PipeWire and power-profiles-daemon. On any
other distro, install those yourself and run `--no-deps`.

Then it:

- **copies** the Quickshell config to `~/.config/quickshell/sea-shell` and the hypr configs to
  `~/.config/hypr/sea-shell`, so the repo can be moved or deleted afterwards (`--dev` symlinks
  instead while you're ricing)
- wires Hyprland, kitty and starship through replaceable `# >>> sea-shell >>>` marker blocks, so
  everything autostarts on login
- installs **hyprlock** and **hypridle** configs, the idle daemon, a polkit agent, the wallpaper
  restore and the bar supervisor — all runtime-guarded, so installing a package later Just Works
- **backs up every foreign file it touches** (`.bak-<timestamp>`) and restores them on `--uninstall`

Icons need the **Material Symbols Outlined** font (pulled in above). GPU stats use `nvidia-smi`
when present. Disable any other bar's autostart so you don't end up with two.

### Try it without installing

```bash
qs -p quickshell/ui/shell.qml       # bar + dock (launcher and tray menus included)
qs -p quickshell/ui/settings.qml    # control center
qs -p quickshell/ui/power.qml       # power menu
qs -p quickshell/ui/wallpaper.qml   # wallpaper picker
```

---

## Structure

```
sea-shell/
├── install.sh                        # installer (--dev / --wallpaper / --uninstall)
├── quickshell/ui/
│   ├── shell.qml                     # the bar, dropdowns, notification daemon, IPC
│   ├── Dock.qml                      # the dock (pinned + running, per-monitor)
│   ├── Launcher.qml                  # resident launcher
│   ├── settings.qml                  # control center (SUPER+S)
│   ├── Dashboard.qml                 # dashboard (SUPER+D)
│   ├── power.qml · keybinds.qml · wallpaper.qml · screenshot.qml
│   ├── RecorderPanel.qml             # recorder chooser + countdown (SUPER+R)
│   ├── DacPanel.qml                  # parametric EQ (SUPER+SHIFT+E)
│   ├── Tok.qml                       # design tokens — one singleton, read by every surface
│   └── Ind*.qml                      # shared components (table, panel, kpi, chip, …)
├── quickshell/scripts/
│   ├── system/sea-bar-supervisor.sh  # respawn the bar when wayland drops it
│   ├── system/sea-update.sh          # over-the-air updates (fast-forward only)
│   ├── system/sea-doctor.sh          # read-only health check
│   ├── system/sea-backup.sh          # back up / restore everything the shell owns
│   ├── system/sea-gamemode.sh        # game mode, with real restore
│   ├── system/sea-window-rules.sh    # window-rules.json → rules.lua
│   ├── system/sea-gestures.sh        # gestures.json → gestures.lua
│   ├── system/moondrop_control.py    # Moondrop USB-HID controller (vendored)
│   ├── system/sea-eq.py              # software EQ — a pipewire filter-chain, no DAC needed
│   ├── wallpaper/sea-wallpaper-apply.sh   # the one place a wallpaper is applied
│   ├── theme/matugen-accent.sh       # recolour the shell from the wallpaper
│   └── … (lock, media, calendar, keybind and clipboard helpers)
├── hypr/sea.lua                      # borders, blur, shadow, animations, layer + window rules
├── hypr/keybinds.lua                 # every bind, each with a description
├── hypr/hyprlock.conf                # lock screen        (stays hyprlang — separate daemon)
├── hypr/hypridle.conf                # idle: dim → lock → screen off → suspend
├── kitty/sea-cyan.conf               # terminal colours
└── starship/sea.toml                 # prompt
```

Config and runtime data live in `~/.config/sea-shell/` — `appearance.json`, `dock.json`,
`window-rules.json`, `gestures.json`, `usage.json` and the launcher history. All of it is what
**Backup & restore** archives.

(fastfetch is intentionally left alone — you keep your own.)

---

## Gotchas

- **The Hyprland config is Lua**, and two of its edges fail *quietly*. `hyprctl keyword` is inert
  under the Lua parser, so anything setting values at runtime has to go through `hyprctl eval`;
  and `hyprctl dispatch exec …` is a **Lua syntax error**, not a dispatch — the correct form is
  `hyprctl dispatch "hl.dsp.exec_cmd('…')"`. Neither tells you it did nothing.
- **`hl.workspace_rule({ layout = … })` returns `ok` and does nothing** on 0.56. Per-workspace
  layouts were tested on both fresh and existing workspaces; they don't work, which is why the
  settings panel doesn't offer them.
- **Duplicate binds both fire.** If a toggle "does nothing", check you aren't sourcing two keybind
  files.
- **`pkill -f <pattern>` matches the whole command line**, including the shell running the `pkill`
  itself — bracket a letter (`sea-…-auto[p]ause`) so a cleanup command can't kill its own shell.
- **Quickshell 0.3:** starting an `Animation` imperatively from `Component.onCompleted` on a
  layer-surface window makes the process exit silently. Use property flips plus `Behavior`
  instead, the way `Launcher.qml` does.
- **`Region.item` is resolved in window space.** Point one at an item nested inside a scaled
  wrapper and you get a rect that renders perfectly and accepts input somewhere else entirely.
- The bar is a **starting point** — Quickshell's QML API shifts between releases. If a workspace
  pill stops highlighting, swap `modelData.active` for `modelData.focused` in `shell.qml`, and
  check `qs log` for binding errors.

---

## Credits

Built by [MiyukiVigil](https://miyukivigil.tech). The DAC half is vendored from
[hub_moon](https://hubmoon.miyukivigil.tech/), which documents the Moondrop protocol and the Hub
API. Palette generation is [matugen](https://github.com/InioX/matugen); the shell itself is
[Quickshell](https://quickshell.org/).

---

## Licence

[MIT](LICENSE). Use it, fork it, package it, or lift a single widget out of it — the only
condition is that the copyright notice travels with the copy.
