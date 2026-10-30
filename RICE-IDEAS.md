# Sea-shell polish ideas — 30 October 2026

Research sources:
- https://github.com/end-4/dots-hyprland — live overview previews, screen translation,
  anti-flashbang and wallpaper-derived Material themes.
- https://github.com/duxlabs-dev/dux-shell — searchable launcher including windows,
  grouped notifications, image clipboard previews and shared application theming.
- https://github.com/noctalia-dev/noctalia — cohesive configurable shell surfaces,
  shared palettes, script widgets and optional plugin functionality.

These are examples from maintained rice/shell projects, not a ranking or a claim
about all Linux users. Recommendations below are sea-shell proposals, not features
already shipped by this research pass.

## Priorities for sea-shell

1. Complete the shared visual identity: Papirus light/dark is now installed and
   selected, with Bibata Modern Ice at 24px. Next add an optional user-local folder
   accent overlay driven by Matugen, with correct cache invalidation and a reset.
   Papirus does not recolor itself with the wallpaper today.
2. Add running-window results to the existing launcher so searching an app can
   focus its current window. Keep keyboard selection stable until actual pointer
   movement; do not replace the existing overview or app ranking.
3. Improve notification history with app grouping, expand/collapse, keyboard
   navigation and per-app mute. Preserve existing actions and DND/game integration.
4. Add a small file shelf: temporarily collect files and screenshots, then drag
   them into an app. Build on Files and Capture rather than another resident daemon.
5. Finish motion controls: shared short transitions plus a reduced-motion option.
   Stop hidden animations and expensive live previews; retain the confirmed gaming
   graphics fixes. Measure frame timing before adding more blur or effects.

Existing features to refine rather than duplicate: live overview, OCR capture,
clipboard image previews, Matugen colors, wallpaper picker, game mode, dashboards
and the searchable Settings interface. Screen translation could follow later with
an explicit provider choice; the user should know when captured text leaves the PC.

## Installed assets

Papirus 20260801-1 from the configured Arch mirror, package signature verified.
User-local icons: ~/.local/share/icons/{Papirus,Papirus-Light,Papirus-Dark}.
Sea-shell stores iconTheme=Papirus and chooses the appropriate mode variant.
Qt and GTK both resolved Papirus-Light in the active light session; folder pixmap
rendered successfully. Bibata-Modern-Ice already existed, and was applied through
GSettings and Hyprland. Existing apps may need reopening to refresh their icons.
