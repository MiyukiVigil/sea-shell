# Next sea-shell work

User requested using the remaining allowance for useful work, then stopping until
the five-hour reset and continuing afterward. A one-time thread heartbeat named
`resume-sea-shell-after-reset` is scheduled for 2026-10-29 23:57 Asia/Kuching.
The account reported reset at 23:55:01. Check fresh limits before resuming; do not
consume a usage reset or credits. Remove the heartbeat after it resumes.

## Current checkpoint

- File-manager hybrid Rust/Python/QML rework installed; prior goal completed.
- Latest suite: 35 passing tests, including real QML keyboard Cut/Paste and new-folder creation.
- Added `sea-register-files.py`; installer registers desktop entry automatically.
- Registered Files as `sea-fm.desktop`, made it `inode/directory` default, installed
  `org.freedesktop.FileManager1` user D-Bus activation service. Validated desktop
  entry and `xdg-mime query default inode/directory` returns `sea-fm.desktop`.
- Desktop Exec parsing now handles quoted paths. Registration regression tests added.

## Next requested improvements

1. Shared icon-theme integration: user wants a coherent desktop, not only sea-fm's
   Papirus preference. Papirus is not installed; Adwaita/Breeze are available.
   Inspect current GTK/Qt/icon settings before choosing/installing a theme. Add one
   shared appearance setting, light/dark variants, fallbacks, and synchronize file
   manager/launcher/dock where feasible. Preserve user preferences.
2. Settings UI rework: currently 23 pages in `quickshell/ui/settings.qml`. Proposed
   groups: Appearance, Desktop, Devices, Connectivity, Apps, System. Keep existing
   functionality/search while improving hierarchy, controls and apply feedback.
3. Test cold FileManager1 activation when no other manager owns the bus name;
   existing managers must not be killed or their windows closed without reason.
4. Registration uninstall cleanup should remove only sea-shell-owned entries and
   restore prior defaults rather than remove other apps' files.

## Preserve these confirmed machine fixes

- `render.direct_scanout = 0` in `hypr/sea.lua` and installed copy: user confirmed
  disabling direct scanout stopped purple game flashes.
- CachyOS `~/.config/hypr/config/windowrules.lua` no longer routes games to named
  gaming workspace. Original backed up as `windowrules.lua.before-game-routing`.
- `hl.env("AQ_DRM_DEVICES", "/dev/dri/card0:/dev/dri/card1")` in user Hyprland
  environment config. Checked vendor IDs: card0 NVIDIA, card1 Intel. Applies after
  starting a new compositor session.

Many unrelated user changes exist in the worktree. Do not reset or overwrite them.

## Resumed after reset

At 23:57 Asia/Kuching the five-hour allowance reported 0% used. The one-time
heartbeat was deleted after resumption. Shared icon synchronization is installed
(`sea-icons.py`, called by `sea-apply-mode.sh`), using available Breeze light/dark
variants across GTK3/4 and Qt5/6 configuration; Files defaults to following the
desktop instead of preferring missing Papirus. Settings navigation is regrouped
into six categories, with all 23 page IDs preserved. Duplicate audio-route chip
IDs found by lint were renamed; no critical/syntax diagnostics remain. Ordinary
pre-existing lint warnings remain. Suite: 37 passing tests.

Remaining: expose the shared icon choice in Appearance with preview; continue
settings page layout/apply-feedback redesign; FileManager1 cold activation and
registration uninstall/default restoration audit noted above.

## Settings redesign completed — 30 October

Installed and visually checked the Appearance preview in its own tab, consistent
page headings/guidance, shared icon picker and explicit apply/reopen feedback.
Preview drafts remain isolated until Apply. Appearance writes are serialized,
atomic and preserve unknown settings; dependent actions await successful saving.
Search opens the correct Appearance subtab; section shortcuts exclude hidden tabs.
All 23 pages remain. Validation: 43 tests passed, no critical/syntax QML lint
errors, running shell loaded successfully. Existing unrelated Qt warnings remain.
FileManager1 private-bus cold activation passed and GTK/Qt both resolved the user's
selected AdwaitaLegacy icons. Current icon choice was preserved.

Theme recommendation: Bibata Modern Ice cursor (compact rounded material design),
Papirus folders/icons (Papirus-Light / Papirus-Dark plus folder color variants).
Sources: https://github.com/ful1e5/Bibata_Cursor and
https://github.com/PapirusDevelopmentTeam/papirus-icon-theme and
https://github.com/PapirusDevelopmentTeam/papirus-folders . These themes were
researched and selected, not installed or substituted for the current user theme.
A future folder tint integration should follow the Matugen accent, rather than
assume Papirus recolors itself automatically.

Correction to older device note: the user has since commented out AQ_DRM_DEVICES;
preserve that current choice. Registration uninstall/default restoration remains
a separate follow-up, beyond the completed activation/settings checks.

## Motion pass — 30 October

Installed SurfaceMotion.qml shared open/close controller for Settings and Launcher:
260ms entrance, 140ms exit, short fade/translation/scale; reverses from the current
frame when reopened. Launcher retains results through exit and releases keyboard
focus immediately. Settings page and Appearance-subtab changes use a small arrival
transition; chips/buttons have press feedback. Settings → Bar → reduced motion
persists to appearance.json and zeros shared Tok durations; it affects shell motion,
not Hyprland's independent window/workspace animation configuration. Settings layer
has no compositor animation so the shell controls its transition once.

Validation: 44 tests passed including intermediate progress, close/reopen reversal,
finished exit and instant reduced motion. QML lint has no critical/syntax errors;
live Settings and Launcher opened/closed, shell stayed loaded, Hyprland reported
no config errors. Existing Qt portal/accessibility warnings remain. Game graphics
and workspace settings were preserved. No frame-rate benchmark was claimed.

## Dropdown redesign reference: Wi-Fi — 30 October

Deployed the first dropdown rework with a wider card, clear connection/scan status,
comfortable network rows, and a standalone WifiJoinCard outside the scan Repeater.
Draft state belongs to the shell, not disposable network delegates. Scans cannot
remove the editor even when its SSID disappears from the capped list. Password
show/hide, explicit Connect/Cancel, busy state and inline retry errors are included.
The secure join uses an argument array and nmcli exit status, retains failed drafts,
and clears its command arguments after completion. Saved-profile retry also uses
exit status rather than matching English output. No real connection was changed
for validation. Tests: 45 passing; synthetic keyboard typing with repeated list
replacement preserves text/cursor/focus; failed attempt preserves retry text.
Installed shell loads with no new QML errors; existing Qt warnings remain.

Full visual rework direction: build shared dropdown header/status/section/row
components, then use the Wi-Fi reference for Bluetooth, audio, battery/power,
calendar and notifications. Preserve working service integration; audit loading,
empty, failure and retry states along with visual changes. This first pass is not
a completed redesign of every dropdown. Settings' separate Wi-Fi editor needs a
corresponding lifecycle audit as part of that broader pass.

## Compact popup visual pass — 30 October

User requested macOS-inspired compact dropdowns and readable opacity. All shared
Drop surfaces now use solid Tok.surface independently from bar opacity (including
other users of dropOpacity such as notification material). Shared chrome uses 18px
corners and a subtle border; widget menu prose/headings use Adwaita Sans, with
higher-contrast secondary labels. Existing explicit mono data widgets remain.
Wi-Fi is 320px wide, shows four networks initially, puts the connected network
first and offers an expander. Credential editor remains outside the scan model.
Sound gains clearer section labels, 320px width and middle-elided output names
so suffixes remain distinguishable. Bluetooth gains compact spacing and explicit
searching/empty/off status. Existing actions, profiles, volume/routing and VPN
controls remain. Settings' opacity control now applies only to translucent bars;
solid dropdowns are explained there. Public shell.openWidget IPC opens the same
menus as pills on the focused monitor, useful for keyboard binds and verification.

Checked live Wi-Fi, Bluetooth, sound, battery and power menu screenshots over a
dark app. Both light/dark secondary-ink contrast were evaluated across all hues
(minimum 6.79:1 light, 7.48:1 dark for the shared secondary palette). This measures
the palette, not every semantic/accent glyph. QML critical/syntax checks passed;
existing unrelated Qt warnings remain. No Wi-Fi connection was changed in tests.
This establishes the shared visual base; more elaborate per-widget features or
new control-center layouts are separate work, not claimed completed here.

## Shell-wide solid-surface audit — 30 October

User explicitly prefers no transparent reading surfaces. Audited all QML surfaces;
updated 14 components: Launcher, Dock, GlobalMenu, RecorderPanel, WallpaperPicker,
keybinds, power, screenshot editor/capture, Settings, shell, AppearancePreview,
DesktopItem, and Files image-label material. Root backgrounds and floating menus
are opaque. Launcher secondary text now uses the readable secondary ink; its
old glass rim is removed. Desktop widgets have a solid ground. Bar material is
solid regardless of legacy config values. Removed transparency controls and the
preview's transparency toggle; actual appearance opacity=1/barOpaque=true.
Shell-layer blur is disabled for bar/drop/notification/OSD/launcher; unrelated
application graphics, direct-scanout fix and workspace settings were preserved.

Animations, dimming outside dialogs, disabled-control feedback, image previews,
and accent tints over solid parent surfaces remain intentional. This is not a
claim that every alpha value was removed from the code. Existing Files windows
need reopening to load their updated QML. Validation: 47 tests passed, all QML
files checked with no critical/syntax lint errors, Hyprland configerrors empty,
live launcher screenshot inspected after animation settled. Existing unrelated
Qt warnings remain. The temporary validation launcher is closed afterward.

## Material widget drawer and saved shortcut repair — 30 October

Deployed WidgetsDrawer.qml: solid Material-style cards using Matugen palette for
clock, weather, system usage and now playing. One drawer opens on the requested
monitor. Drag right from the small left-edge trigger or use Super+Alt+W; Escape,
close button or outside click closes it. The permanent text tab was removed at
user request: the trigger is invisible normally and reveals a small › arrow on
hover. Edge trigger is hidden for fullscreen apps. Desktop widget cards also use
rounder corners and sans prose. Drawer settings link opens Desktop page 21.
Live drawer screenshot inspected; weather and readings match actual data.

Settings shortcut editor now uses sea-keybinds.py to map live records to exact
saved Lua lines. Lua runtime dispatcher arguments are numeric opaque handles,
not executable commands; saved Code shortcuts now resolve to code and
visual-studio-code-bin. Source identities disambiguate duplicate descriptions;
edit and delete fail safely if the source changed. Atomic writes retain other
bindings, make a backup, mirror the existing repo copy, reload Hyprland and report
errors in the editor. Delete is explicitly confirmed in the editor. Command edits
are offered for plain exec strings; other sourced actions retain their expression
when their shortcut changes. Unsupported/external source bindings stay read-only.

Validation: 50 tests pass, including exact record edit/delete, preserving duplicate
description siblings, stale IDs, non-exec actions and resolving numeric live args.
Source list resolved 74 live bindings; both user Code records mapped correctly.
QML critical/syntax lint clear; running shell loads; compositor configerrors empty.
No existing user shortcut was deleted or changed during testing; only the new
Super+Alt+W drawer shortcut was added. Existing game fixes remain intact.

## Expressive widgets and media — 30 October

User supplied Caelestia/end-4 reference screenshots and requested further online
research. Consulted maintained project pages and Caelestia's dashboard media
CoverVisualiser.qml / BackgroundShapes.qml. Implemented original shared
MaterialWidget.qml rather than copying their source: scalable scalloped clock
with hands, ticks and large face numerals for square footprints; illustrated
weather; usage rings; media album art surrounded by radial audio bars, responsive
metadata, seek, time and capability-aware transport with a morphing play button.

Shared implementation is installed in desktop widgets, WidgetsDrawer and the
bar media popup. Legacy media player switching, shuffle/repeat, output/signal
chain, volume and lyrics/details sidecars remain. Radial motion uses the existing
CAVA data (ambient decorative fallback for existing exclusive/bit-perfect mode),
stops when paused/inactive/reduced-motion; no new audio collector. All reading
surfaces remain opaque and colors follow Tok/Matugen.

Updated new-widget default footprints to fit controls. Existing media1 was expanded
with sea-desktop.py --set media1 --size medium, preserving its position and saving
the old arrangement to desktop.json.bak. No new desktop widgets were added over
user choices. Clock/weather/system designs appear when those widgets are added.
The hover-only › drawer trigger and Super+Alt+W remain intact.

Validation: 51 tests pass including Qt rendering all widget types with a mock MPRIS
player, actual play-button clicks, blocked unsupported next/seek, valid seeking,
and a square clock preview. Preview saved to /tmp/sea-material-widgets-preview.png
uses fixture data, not actual playback. QML critical/syntax lint passed. Installed
source copies match. Live media empty state rendered without new QML errors;
no actual playback was started or modified. Fullscreen game was active during a
live drawer capture, so that capture was not used as evidence of drawer appearance.
Existing Qt portal/accessibility/SVG warnings and transient PipeWire stale-node
warnings remain; not represented as fixed by this visual task.

References:
https://github.com/caelestia-dots/shell/tree/main/modules/dashboard/media
https://raw.githubusercontent.com/caelestia-dots/shell/main/modules/dashboard/media/CoverVisualiser.qml
https://github.com/end-4/dots-hyprland

## Horizontal tabbed media player — 30 October

User clarified layout: album artwork and track information stay on the LEFT;
Controls / Details / Lyrics tabs swap ONLY the RIGHT pane. Deployed one 740x420
(max, screen-clamped) card with a persistent art pane. Removed separate sidecars
and duplicate details artwork. Existing lyrics language/sync/seek features and
track metadata remain in their respective tabs; player switching, shuffle/repeat,
output status and volume remain in Controls. Added shell.mediaTab(index) IPC for
keyboard/verification use alongside openWidget.

Fixed the clipped/sandwiched play button by budgeting album size against media
card height, giving transport buttons explicit minimum dimensions, and grouping
controls at their implicit height. MaterialWidget now supports all/art/controls
presentations while drawer/desktop retain all. Live screenshots for all tabs
inspected, final controls screenshot /tmp/sea-player-horizontal-final.png.
Tests: 51 pass, including geometry checks at several card sizes, art-only hiding
transport and controls-only retaining it within bounds. QML critical/syntax lint
clear; shell loads. No playback action invoked by validation. Existing unrelated
Qt warnings remain. Prior tabs/sidecar checkpoint is superseded by this layout.

## Compact media proportions — 30 October

User rejected stretched 740x420 player and requested online inspiration again.
Consulted Caelestia dashboard media Details.qml and Android Media3 Material3 player
layout/compact controller documentation. Reduced popup to 640x320 (screen-clamped),
shifted pane ratio toward wider controls and narrowed album area. Album/track pane
stays on left; Controls/Details/Lyrics still replace only the right pane. Controls
presentation no longer enters the generic compact mode that would hide transport
at short heights; its controls are centered at implicit content height. Explicit
136px control region (108px with player switcher) fits the complete control stack.
Details content now scrolls instead of clipping at the shorter popup height.

Validation: 51 tests pass, including controls-only play button fit at 108px height.
QML critical/syntax lint clear; source installed; live compact player screenshot
inspected at /tmp/sea-player-compact-final.png. Existing unrelated Qt warnings
remain. Prior 740x420 checkpoint is superseded by these dimensions.
References:
https://github.com/caelestia-dots/shell/blob/main/modules/dashboard/media/Details.qml
https://developer.android.com/reference/kotlin/androidx/media3/ui/compose/material3/PlayerDefaults

## Player composition rebuilt; details scroll fix — 30 October

User requested a full design rebuild rather than further proportional patches.
Introduced MediaPlayerFrame.qml: fixed artwork/track column, quiet divider and
underlined tabs, unboxed controls/details/lyrics host slots. Metadata no longer
repeats artwork/title. Popup is 620x300 with regular 18–20px outer padding.
Removed large rounded tab buttons and nested panel borders. User wanted the
visualizer retained: restored it as a live 22-bar strip in the cover frame, using
existing viz data. Hidden/paused/reduced-motion state settles the strip.

Latest screenshot showed an unnecessary Details scroll. Removed a duplicate
separator and reduced row spacing so ordinary track metadata fits. Flickable is
interactive only for genuine overflow and clears stale offsets when content fits.

Validation: 52 tests passed after composition/visualizer work, including actual
tab clicks, exactly one pane visible, persistent title position and live spectrum
settling when inactive. QML critical/syntax lint passed again after the small
Details spacing/scroll patch. Live rebuilt screenshots inspected for all tabs and
spectrum. Installed updates; existing unrelated Qt warnings remain.

## Miku placement, rounded frame and balanced spacing — 30 October

Copied the user's Downloads/miku.gif unmodified to assets/media-miku.gif and the
flat installed config. Initial tiny placement in the control row was rejected.
User explicitly wants her visible on every tab, not a no-cover fallback. Final
placement is a dedicated always-visible mascot area beside the existing player:
112px animation, round clipped frame using QtQuick.Effects MultiEffect and a
solid circular border/backing. Miku heading and Playing/Paused status fill the
otherwise empty top of that area. Animation continues across tabs and pauses
for hidden player / reduced motion; cache=false and bounded sourceSize avoid
caching all original 374px frames. GIF contains 192 frames.

Player expanded only horizontally to 748x300 to retain existing artwork/control
space. Latest user requested balanced box padding: artwork/title inset is now
24px and mascot stage is 168px so its outer circular frame has matching 24px right
clearance. Lyrics header was rebuilt with right-anchored language controls and
Synced text, removing the magic spacer that pushed the label out of bounds.

Validation: 52 tests pass, including GIF decoding/frame count, mascot visible
across all tabs, stopping for reduced motion/closed state, and existing player
controls. QML critical/syntax lint passed for mascot/header changes. Rounded
frame and lyrics alignment inspected live; source installed. Existing Qt warnings
remain. These decisions supersede the transient control-row/fallback placements.

### SilentSDDM settings — 30 October
- Added Login screen section under Settings → Idle & lock, with 16 upstream presets, background image/video path, login position, clock, animations and blur. Preview is test mode; Apply uses pkexec and never restarts SDDM or the session.
- Staged upstream SilentSDDM 1.5.0 commit d477613b07ca13729af20cb4699b308ac7348d2f in ~/.local/share/sea-shell/silent-sddm. Active system theme remains Astronaut until Apply. Theme not vendored; Download button stages pinned upstream on future installations.
- sea-sddm.py writes a separate configs/sea-shell.conf and copies custom backgrounds for SDDM access. Explicit authenticated Apply installs sea-silent, preserves unrelated sddm.conf settings and makes a first-use backup at /etc/sddm.conf.before-sea-shell. Never invoke upstream install scripts.
- Backend config generation and invalid preset traversal tests added; full suite 54 passes. Offscreen greeter preview checked separately; no actual login authentication tested.
- Replaced mismatched stock SDDM controls with token-colored rounded selectors, matching popup delegates, readable switches, blur slider and primary/secondary actions. Compact solid card; live Settings screenshot checked in light mode. Backend behavior unchanged.
- Fixed duplicate bars after compositor session changes: supervisors inherited different stale/current Hyprland signatures but connected to the same Wayland display. Lock now keys on WAYLAND_DISPLAY; cleanup waits for its bar and removes only its own pidfile. Removed both conflicting supervisors and relaunched one using the current desktop environment. A second launch is rejected by the lock.

### Shared profile and session presentation —30 October
- Added Your profile page (tab23): picture picker, display name, font, color, optional glow, live profile card preview; name/clock sizes, 12/24h clock, date/media/avatar visibility. Save writes profile.json and patches existing hyprlock presentation, with original config backup. Never modifies password/authentication setup. No live lock/unlock validation performed.
- Shared ProfileCard now appears in System header and compact power menu; power actions retain two-step destructive confirmation. Profile editor sliders explicitly styled using shared tokens after user rejected stock Qt sliders.
- Fixed sea-lockwall.sh to update only background paths, preserving avatar image paths.
- Added backend tests for toggles restoring, idempotent avatar handling, credential-related config preservation and invalid profile rejection. Full suite56 passed before final visual-only slider styling. New default profile seeded from Pictures/icons/pfp.png; lock presentation changes take effect when user presses Save profile.
