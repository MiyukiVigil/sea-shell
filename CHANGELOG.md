# Changelog

All notable changes to **sea-shell** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
