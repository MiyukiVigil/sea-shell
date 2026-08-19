# sea-shell

**A Hyprland desktop shell, not a status bar.** The bar, dock, launcher, control center,
notification daemon and screen recorder are one Quickshell process — not six
tools glued together. The whole palette follows your wallpaper.

**`v6.2.0`** · [seashell.miyukivigil.tech](https://seashell.miyukivigil.tech) ·
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
| **Audio** | Output routing, per-app volume, synced lyrics, bit-perfect detection. (Parametric EQ and DAC control live in [Hub Moon](https://hubmoon.miyukivigil.tech) now.) |
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

Set the shell up how you like it and save it as a **preset**, and it becomes a cartridge on a
shelf: its own background steps, its accent as a band, its font and radius printed on the label,
and a lamp lit on the one you are currently running. Click it to load it. The list this replaces
described a preset as `accent: #dbc0c8`, which is the one format that cannot show you a colour
scheme.

The same object turns up wherever something is *loaded* rather than merely set: the wallpaper
picker's commit, the day/night pair, and the theme shelf all use it.

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

### The EQ moved to Hub Moon

sea-shell used to carry an 8-band parametric EQ — a Moondrop DAC controller with a software
PipeWire fallback, a response graph, and a browser for the public Moondrop Hub library. It is
**gone**, and everything it did is done better by [**Hub Moon**](https://hubmoon.miyukivigil.tech),
which is a whole application built for exactly this rather than a panel bolted to a desktop shell.

The other half of the reason is that it was *niche*: the single largest file in the project, in
service of one manufacturer's USB DACs, on a shell most of whose users will never plug one in.
`install.sh` offers to fetch Hub Moon for you if you are one of the people who will — asked, never
assumed, and skipped entirely on a piped install.

sea-shell keeps the parts that are genuinely a *bar's* job: output routing, per-app volume, media
control, lyrics, and the bit-perfect badge below.

**Media and lyrics** — the centre pill opens a full player with album art, seekable progress,
per-player volume, a live cava visualiser, and **time-synced lyrics** from lrclib.net that follow
playback and let you click a line to seek. When a player holds the card directly over ALSA, a gold
**bit-perfect** badge shows the true bit-depth and sample-rate, and the visualiser switches to an
ambient wave — because PipeWire genuinely cannot see that stream.

---

## Wallpapers · `SUPER+SHIFT+W`

The picker **is** the wallpaper: the focused one fills the screen at full size and **moving ones
play**, so you are looking at the thing you are choosing at the size *and the speed* you will get
it — a poster frame cannot tell you whether the motion is a slow drift or a strobing city, and
that is most of what you are choosing between. It opens on whatever is already up.

In front of that sits **a deck**, built the way rack gear is. A front panel does three things —
it contains, labels and indicates — so: a *raised* bezel with the cartridge slot cut into it and
alignment marks either side, then a panel divided into functional modules by hard rules. A counter,
the readout, a vent grille, an indicator lamp. Depth is three background steps (raised bezel over
surface panel over a darkened well), never shadow. There is no nameplate, no serial and no fake
fixings: *"a lack of superfluous controls, styling or excessive markings"* is the point, and
invented hardware markings would be exactly that.

The accent obeys the same rule — **one accent, in isolation, never as decoration**. It marks the one
thing happening now: the index while you are choosing, the step while the deck is loading, never
both.

Above the deck the wallpapers are **projections**: panels held between two guide rails, the
unfocused ones carrying a fine raster because they are not resolved yet, the held one clean and
locked with registration corners. The deck is on screen the whole time rather than conjured at the
last moment, so the machine is the one fixed thing and everything else happens in relation to it.

`←` `→` choose, or **drag the rail** — the preview tracks your thumb and snaps to whatever you let
go over. The wheel steps too. **Just start typing to search**: the rail filters live, and the query
lands in a window built out of the deck's own parts — a raised legend plate, a sunken well, a raised
counter — rather than a text field borrowed from somewhere else. `enter` applies, `tab` cycles the
filter (all · stills · motion · **recent**), `ctrl+s` sorts by name or by newest, `ctrl+m` toggles
match-colours, `esc` clears the search and then closes. Clicking a frame focuses it; clicking the
focused frame applies it.

**`ctrl+v` imports.** Everything here could *choose* a wallpaper and nothing could add one — the
folder was filled by a file manager or it was not filled. ctrl+v takes whatever is on the clipboard
— raw image bytes out of a browser, a path, a `file://` URI, or an http URL it fetches — puts it in
the wallpaper folder without ever overwriting anything, re-indexes, and lands focus on it.

The folder is **`~/Pictures/wallpapers` unless you say otherwise** — Control center → Appearance →
Wallpaper, with a folder browser behind the field. The walk is recursive, so **subfolders become
collections** you can filter by, in a chip row beside the type filter. `sea-wallpaper-index.py` is
the single definition of where the wallpapers are and what counts as one; the picker, the keybinds
and the rotate daemon all ask it rather than each carrying a path of their own.

Frames keep their own aspect ratio and share a baseline, so a folder of portrait and landscape
wallpapers packs into a skyline instead of being cropped to a uniform grid. Away from centre they
fall off in scale and opacity only — no perspective, no shadow.

Applying it is a **cartridge insert**, and two things make that read. The card **never changes
size** — growing it to fill the screen is a zoom, which is what the first attempt looked like; a
cartridge is a fixed object that *travels* and is swallowed. And the machine is at the **bottom**,
where the rail already is and where your hand already is, rather than floating mid-screen: a
console sits on the desk in front of you, so you pick the cartridge up, hold it over the slot, and
push it *down*.

So: the ground clears and the machine appears — a console across the bottom with the slot cut into
its top surface and a mono readout on its face, two **guide rails** down the card's travel, a
**tick scale** along the stretch it actually moves through, and the **gate** it comes to rest on.
That structure is the part that was missing when a 300 px card crossed four fifths of a blank
screen: there was nothing for the motion to be measured against, so it read as small and
arbitrary. Every mark has a job — the rails say where the card can go, the ticks say how far it has
come, the gate says where it stops. None of it is texture.

Then the card **dips** before it rises, which is the oldest trick in animation and the cheapest:
80 ms of the wrong direction is what makes the pop read as force applied to an object rather than a
position changing. **A label plate comes up in that same 80 ms** — filename, motion marker, keyed
corner — so the projection on the rail becomes a physical cartridge exactly as you take hold of it,
with no frame where an object with a nameplate appears out of a panel that never had one. It is
also the one moment you can read what you are loading without looking anywhere else.

It pops up the guides to the gate, overshooting a hair and settling, and holds for a beat. Then the
**shutter parts** — two leaves across the slot, in the plane between the bezel and the darkness
behind, so the opening reads as an opening even when the picker is idle. They open over 130 ms
against a 210 ms fall, so the way is clear before the card arrives and the machine is never seen
being hit by it. The **deck's lip throws a shadow** on the last of the travel, because a clip
boundary on its own does not swallow a card so much as erase it a row of pixels at a time. The
console takes the impact, the leaves snap shut behind the cartridge — faster than they opened, with
an overshoot — and the **lamp reads contact**: dim while the card is in the air, full at the instant
it lands, one ring thrown off and spent. A lamp that lights when the thing lands is the deck
responding; a lamp that lights when you press a key is the keyboard responding. The readout names
each step: `READY` · `INSERT` · `SEATED` · `LOADED`.

And the wallpaper comes **out of the aperture it just went into** — the lid is eaten from its
bottom edge upward with an accent hairline riding the boundary like a print head, and the deck
follows a beat behind and travels off the bottom. In goes the cartridge, out comes the image,
through one opening.

The reveal is where fluidity is won or lost, and three things decide it. It **decelerates**
(OutQuint, not InOutCubic — accelerating into the middle of the sweep is exactly where a
thousand-pixel boundary is most visible as a boundary). It **softens as it travels**, so the edge
stops being a line. And nothing is switched off at the end: the bezel, the well and the lip leave
by *moving* with the deck, because four elements cutting to zero opacity on the last frame is a
snap no easing can hide. Roughly 1.2 s, with the daemon running its own transition underneath, so
the flourish costs no time the switch was not already going to spend.

**Static** images go through swww (or its awww fork) → hyprpaper → mpvpaper. **Animated**
wallpapers (mp4/webm/gif) play via **mpvpaper**, and a listener watches for a window going
**genuinely fullscreen** — not merely filling the screen, because an ordinary maximised editor
does that and pausing your wallpaper while you work is not what anyone means by "nobody can see
it". When one does, it does not merely pause: a paused mpvpaper keeps its decoder, its surface and its **VRAM** for as
long as it lives, and the thing covering the wallpaper is usually the thing that wanted that
memory. So the poster frame goes up on swww *underneath* — where it is invisible, because mpvpaper
is still drawing over it — and only then is mpvpaper killed, which means the swap has no black
frame in either direction. It comes back when the wallpaper does. There is a matching **still frame
on battery** for laptops; unplugging the mains emits no window event, so the listener carries a
slow tick of its own to notice. `ffprobe`
measures every file — size, dimensions, length — and `ffmpeg` cuts a poster frame out of each clip
once, both memoised in `~/.cache/sea-shell/` (2.8 s cold, 28 ms warm). Playback in the picker is
Qt's own ffmpeg backend, one clip at a time, released the instant focus moves or you commit, so it
is never competing with mpvpaper for a decoder. All of it is optional: without ffmpeg the picker
still lists and applies everything, it just cannot preview the moving ones.

- **Transitions** — fourteen swww transitions with your own fps and duration. `SUPER+N` /
  `SUPER+SHIFT+N` cycle the folder, and because mpvpaper cannot transition at all — switching one
  means `pkill`, a gap, then a fresh process — the shell covers the seam itself, for every backend.
  It does that with **a panel that travels**: it enters from the side you are coming from,
  decelerating as it arrives; the swap happens behind it; then it accelerates away towards the side
  you are going to. One accent lip on its leading edge, and while it is covered it names the file it
  landed on and **loads it**: the wallpaper you are about to get, in a cartridge, dropping into a
  slot — the same event as the picker's commit, in the same language. The drop is gated on the
  thumbnail rather than on a clock, because a blank frame going into a slot is worse than no
  cartridge at all. Under it, a hairline fills for exactly the length of the wait. A dip to black stated nothing
  except that something had stalled, looked identical forwards and backwards, and gave the eye
  620 ms of nothing to do — and that hold is fixed by how long mpvpaper takes to show a first frame,
  so it cannot be shortened, only spent better. Same vocabulary as the picker's console: the shell's
  ground moving over a seam, never a light going out.
- **Auto-rotate** — off by default. Change every *n* minutes, going next, previous or random, and
  optionally **stills only** (rotating into a video restarts a decoder every interval). The setting
  is re-read every tick, so toggling it needs no restart and leaves no daemon running when it's off.
- **`SUPER+SHIFT+N` is back, not minus one.** It used to find the current wallpaper's position in
  the sorted folder and step back — so after a random jump, "previous" went to whatever sorted
  before where you had landed, which is somewhere you had never been. It pops a back stack now,
  exactly like a browser, and falls back to folder order only when there is nothing to go back to.
  The same stack is the picker's **recent** filter.
- **Random deals from a bag.** A fresh `shuf` every time repeats — over a folder of eleven you see
  one twice long before you have seen them all, and nothing stopped it dealing the one already on
  screen. The bag deals without replacement and reshuffles when it runs out.
- **A day and a night wallpaper.** Pin two and they swap on schedule, using the *same*
  `darkStart`/`darkEnd` auto dark mode already uses rather than a second pair of times. You choose
  them by clicking a cartridge and picking off a shelf of your actual wallpapers. It outranks
  auto-rotate: a pinned pair and a shuffle every thirty minutes are contradictory instructions.
- **The lock screen can keep its own picture.** It used to be overwritten on every apply,
  unconditionally, so wanting a different one there was not expressible. Pin one and it outranks
  whatever the desktop just switched to.
- **A frame cap for moving wallpapers** — 60 / 30 / 24, or as filmed. Capping halves the full-screen
  blits the compositor does for a clip, which on a machine whose iGPU composites while the dGPU
  renders is the cost that shows up. It does not reduce decoding, and the setting says so.
- **Anything can set the wallpaper** — `qs -c sea-shell ipc call wallpaper set /path/to/image`
  runs the whole sequence (path, daemon, lock screen, palette) behind the same travelling panel a
  keybind gets. One script, `sea-wallpaper-set.sh`, is what a wallpaper change *consists of*;
  `sea-wallpaper-apply.sh` remains the only thing that talks to the daemons.

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
│   ├── wallpaper/sea-wallpaper-set.sh     # what a wallpaper change CONSISTS of
│   ├── wallpaper/sea-wallpaper-import.sh  # clipboard → a file in the wallpaper folder
│   ├── wallpaper/sea-wallpaper-apply.sh   # the one place a daemon is talked to
│   ├── wallpaper/sea-wallpaper-index.py   # the one definition of where wallpapers are
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

Built by [MiyukiVigil](https://miyukivigil.tech). For parametric EQ and DAC control, use
[**Hub Moon**](https://hubmoon.miyukivigil.tech/) — it is the same author's application for exactly
that, and it does the job properly. Palette generation is
[matugen](https://github.com/InioX/matugen); the shell itself is [Quickshell](https://quickshell.org/).

---

## Licence

[MIT](LICENSE). Use it, fork it, package it, or lift a single widget out of it — the only
condition is that the copyright notice travels with the copy.
