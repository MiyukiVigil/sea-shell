# sea-shell 🐚

A Hyprland rice by MiyukiVigil — a shell, by the sea. (yes.)

<!-- hosted on the site, not in the repo — clones stay lean -->
![sea-shell — the player dropdown with synced lyrics and the bit-perfect badge, over an animated whale wallpaper](https://seashell.miyukivigil.tech/images/showcase.webp)

**[seashell.miyukivigil.tech](https://seashell.miyukivigil.tech)**

Built for: **CachyOS · Hyprland 0.55 · Quickshell 0.3 · kitty · fish · starship**.
No external launcher needed — the app launcher, clipboard picker, power menu and
control center are all native Quickshell.

## Palette
```
iris   #63c7dd   frost  #a2e2e8   iris-deep #45b2cc
bg     #0d1420   panel  #161d2b   line      #24304a
text   #e2e9f4   sub    #a6b6cf   faint     #6f8099
radius 10px
```
(Catppuccin Mocha base + a custom sea-cyan accent.)

## Structure
```
sea-shell/
├── install.sh               # installer (--dev / --wallpaper / --uninstall)
├── quickshell/
│   ├── shell.qml            # the bar + dropdowns + notification daemon
│   ├── Launcher.qml         # resident app launcher (see below)
│   ├── settings.qml         # settings / control panel (SUPER+S)
│   ├── power.qml            # power / session menu (SUPER+ESC)
│   ├── keybinds.qml         # live keybind cheat-sheet (SUPER+K)
│   ├── wallpaper.qml        # wallpaper picker (SUPER+SHIFT+W)
│   ├── sea-toggle.sh        # toggle helper for the standalone overlays
│   └── logo.svg             # the site logo, used in the bar + settings
├── hypr/sea.conf            # borders, blur, shadow, animations, layer rules
├── hypr/keybinds.conf       # full Hyprland keybinds (SUPER-based)
├── hypr/hyprlock.conf       # sea-themed lock screen (clock + wallpaper blur)
├── hypr/hypridle.conf       # idle: dim → lock → screen off → suspend
├── kitty/sea-cyan.conf      # terminal colours
└── starship/sea.toml        # prompt — Tokyo Night gradient powerline
```
(fastfetch is intentionally left alone — you keep your own.)

## The bar
Rounded, translucent, cyan-bordered — Material-Symbol icons throughout, with
**click-to-open dropdowns** (one open at a time, click-outside closes, all
frosted by Hyprland layer blur):
- your **logo.svg** (click → launcher)
- workspaces: **circle when idle → pill when active**
- **app name** of the focused window
- **media** centered (Mpris: title + play/pause, right-click = next; dropdown
  has a full player with a cava visualizer)
- **weather** (wttr.in; location set in the control center)
- **system tray** — left-click activates, right-click opens the app menu in a
  frosted dropdown (single menu, replaces itself when you open another icon's)
- **clipboard** pill → launcher in clipboard mode
- **notifications** bell (the bar runs its own notification daemon — popups
  top-right + history dropdown; don't run mako/dunst alongside)
- **wi-fi** → dropdown: nearby networks, click to connect
- **bluetooth** → dropdown: paired devices, click to (dis)connect
- **volume** → dropdown: slider + output-device picker (scroll = change, right-click = mute)
- **battery** → dropdown: power-profile picker (state icon, hidden on desktops),
  plus **low-battery notifications** at 15% and a critical one at 5%
- **clock** (day · date · time) → dropdown: month calendar
- **power** button → session dropdown with user/uptime header; reboot and
  shut down ask for a **second click** so a stray click can't kill your session

## Launcher  ·  `SUPER+Space` / `CTRL+Space`
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

## Power menu  ·  `SUPER+ESC`
Full-screen session overlay: user@host + uptime, five cards (lock · suspend ·
log out · reboot · shut down). Drive it with the mouse or entirely from the
keyboard — `←→`/Tab to select, `⏎` to go, `l s o r p` hotkeys, `1–5` quick-fire.
Reboot/shut down arm to a red "sure?" and need a second press; Esc backs out.

## Lock & idle  (hyprlock + hypridle)
`loginctl lock-session` (power menus, `SUPER+ALT+L`-style binds, lid events)
locks via a sea-themed **hyprlock**: blurred wallpaper, big clock, iris input
field. **hypridle** dims the backlight at 2.5 min, locks at 5, screen off at
10, suspends at 30 (comment that listener out on a desktop), and always locks
before sleep. Both configs are installed to their canonical `~/.config/hypr/`
paths and start on login automatically once the packages are present.

## Control center  ·  `SUPER+S`
An overlay panel (Esc / click-outside to close):
- **Audio** — output & mic **sliders**, mute, and **output-device selection**
- **Display** — brightness slider (brightnessctl)
- **Wi-Fi** — nearby networks list, signal + lock icons, click to connect
- **Quick actions** — reload Hyprland, restart bar, terminal, wallpaper, screenshot
- **Session** — lock / logout / reboot / shutdown

## Keybinds  (`hypr/keybinds.conf` — searchable + editable via `SUPER+K`)
Every bind is a `bindd` with a human name, so the cheat-sheet shows "Wallpaper
picker" instead of a shell command. In the cheat-sheet: **type to search**, and
**click any bind to rebind it** — toggle SUPER/CTRL/ALT/SHIFT chips, press the
new base key; conflicts are refused with a "used by …" note. Rebinds rewrite
keybinds.conf, sync to the repo copy, and hot-reload Hyprland.

`SUPER+Space`/`CTRL+Space` launcher · `SUPER+V` clipboard history ·
`SUPER+Return` terminal · `SUPER+Q` close · `SUPER+E` files · `SUPER+B` browser ·
`SUPER+S` control center · `SUPER+SHIFT+W` wallpaper picker · `SUPER+ESC` power menu ·
`SUPER+F` maximize / `SUPER+SHIFT+F` true fullscreen · `SUPER+P` float · `SUPER+C` center ·
`hjkl` focus / `SHIFT` move / `CTRL` resize · `1–0` workspaces / `SHIFT 1–0` move-to ·
`` SUPER+` `` scratchpad · media & brightness keys · `Print`/`SUPER+Print`/`SUPER+SHIFT+S`
screenshots · `SUPER+SHIFT+R` reload · `SUPER+SHIFT+B` restart bar.

## Install (one command)
```bash
./install.sh                 # copies everything into ~/.config — reboot-proof
./install.sh --dev           # symlinks to this repo instead (live-edit mode)
./install.sh --wallpaper     # also generate + set the sea-gradient wallpaper
./install.sh --uninstall     # cleanly remove everything it added
```
The installer:
- **copies** the Quickshell config to `~/.config/quickshell/sea-shell` and the
  hypr confs to `~/.config/hypr/sea-shell` — the repo can be moved or deleted;
  re-run after pulling updates (`--dev` symlinks instead while you're ricing)
- wires Hyprland (look + keybinds + `exec-once = qs -c sea-shell`) and kitty via
  replaceable `# >>> sea-shell >>>` marker blocks, so **everything autostarts
  on login**
- installs the starship prompt to `~/.config/starship.toml`, and the
  **hyprlock / hypridle** configs to `~/.config/hypr/` (previous files are
  backed up, and restored on `--uninstall`)
- wires the idle daemon + **polkit agent** (hyprpolkitagent) into autostart —
  both are runtime-guarded, so installing the package later Just Works
- wires swww + wallpaper restore at login when swww is installed
- backs up every foreign file it touches (`.bak-<timestamp>`), and reloads
  Hyprland + restarts the bar if you run it inside a session

Deps: `grim slurp wl-clipboard cliphist fd playerctl brightnessctl swww
hyprlock hypridle hyprpolkitagent` are all optional — features degrade
gracefully, and the installer prints one `pacman -S` line for whatever's
missing. Icons need the **Material Symbols Outlined** font. Disable any other
bar's autostart so you don't get two.

## Try it without installing
```bash
qs -p quickshell/shell.qml       # bar (launcher + tray menus included)
qs -p quickshell/settings.qml    # control center
qs -p quickshell/power.qml       # power menu
qs -p quickshell/wallpaper.qml   # wallpaper picker
```

## Wallpaper picker  ·  `SUPER+SHIFT+W`
A grid of `~/Pictures/wallpapers` (jpg/png/webp); click to set. Needs **swww**
(`pacman -S swww`). `./install.sh --wallpaper` generates a matching sea-gradient
(`~/.config/sea-shell/sea-wall.png`) and restores it on every login.

## Notes / gotchas
- **Hyprland 0.55 rule syntax changed** — rules are `field value, match:prop regex`
  (e.g. `layerrule = blur on, ignore_alpha 0.2, match:namespace sea-shell:drop`).
  The old `layerrule = blur ns` form is accepted **silently as a no-op**, so a
  wrong rule shows no error and no effect. `sea.conf` uses the new syntax.
- Duplicate binds both fire in Hyprland — if a toggle (fullscreen, float…)
  "does nothing", check you're not sourcing two keybind files.
- Quickshell 0.3: starting an `Animation` imperatively from
  `Component.onCompleted` on a layer-surface window makes the process exit
  silently — use property flips + `Behavior` instead (Launcher.qml does).
- The bar is a **starting point** — Quickshell's QML API can shift between
  releases. If a workspace pill doesn't highlight, swap `modelData.active`
  for `modelData.focused` in `shell.qml` (comment flags the spot). Check
  `qs log` for any binding errors.
