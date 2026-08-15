-- sea-shell — Hyprland keybinds (Lua config, Hyprland 0.55+)
-- Migrated from keybinds.conf. Uses tools you already have: kitty · fish · wpctl · brightnessctl.
-- For screenshots install: grim slurp  ·  for clipboard: cliphist wl-clipboard.
-- NB: every bind carries a `description` so the cheat-sheet (SUPER+K) shows real names
--     AND `hyprctl binds` / the rebinder can read them. Keep descriptions comma-free.
--
-- This file is dofile()'d from hyprland.lua; `hl` is the global Hyprland config API.

local mod       = "SUPER"
local term      = "kitty"
local menu      = "qs -c sea-shell ipc call launcher toggle"   -- resident launcher (instant)
local browser   = "xdg-open https://"
local settings  = "qs -c sea-shell ipc call settings toggle"   -- resident in the bar process
local wallpick  = "~/.config/quickshell/sea-shell/sea-toggle.sh wallpaper"
local powermenu = "~/.config/quickshell/sea-shell/sea-toggle.sh power"
local keybinds  = "~/.config/quickshell/sea-shell/sea-toggle.sh keybinds"
local shotmenu  = "~/.config/quickshell/sea-shell/sea-toggle.sh screenshot"
local dac       = "qs -c sea-shell ipc call dac toggle"        -- Moondrop DAC EQ panel (resident)

-- ---------------- apps ----------------
hl.bind(mod .. " + T",         hl.dsp.exec_cmd(term),                                          { description = "Terminal" })
hl.bind(mod .. " + Q",         hl.dsp.window.close(),                                          { description = "Close window" })
hl.bind("CTRL + Space",        hl.dsp.exec_cmd(menu),                                          { description = "App launcher" })
hl.bind(mod .. " + Space",     hl.dsp.exec_cmd(menu),                                          { description = "App launcher" })
hl.bind(mod .. " + E",         hl.dsp.exec_cmd("nautilus"),                                    { description = "File manager" })
hl.bind(mod .. " + A",         hl.dsp.exec_cmd(browser),                                       { description = "Browser" })
hl.bind(mod .. " + S",         hl.dsp.exec_cmd(settings),                                      { description = "Control center" })
hl.bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd(dac),                                           { description = "Moondrop EQ" })
hl.bind(mod .. " + SHIFT + W", hl.dsp.exec_cmd(wallpick),                                      { description = "Wallpaper picker" })
-- Routed through the shell rather than straight at the script so the switch gets a dip-to-black
-- transition. Animated wallpapers run on mpvpaper, which cannot transition at all — the shell
-- draws the fade over the swap instead. Falls back to the bare script if the bar isn't running.
hl.bind(mod .. " + N",         hl.dsp.exec_cmd("qs -c sea-shell ipc call wallpaper next 2>/dev/null || ~/.config/quickshell/sea-shell/sea-wallpaper-cycle.sh next"), { description = "Next wallpaper" })
hl.bind(mod .. " + SHIFT + N", hl.dsp.exec_cmd("qs -c sea-shell ipc call wallpaper prev 2>/dev/null || ~/.config/quickshell/sea-shell/sea-wallpaper-cycle.sh prev"), { description = "Previous wallpaper" })
hl.bind(mod .. " + SHIFT + D", hl.dsp.exec_cmd("~/.config/quickshell/sea-shell/sea-toggle-theme.sh"),        { description = "Toggle light/dark" })
hl.bind(mod .. " + K",         hl.dsp.exec_cmd(keybinds),                                      { description = "Keybind cheat-sheet" })
hl.bind(mod .. " + Escape",    hl.dsp.exec_cmd(powermenu),                                     { description = "Power menu" })
hl.bind(mod .. " + ALT + L",   hl.dsp.exec_cmd("~/.config/quickshell/sea-shell/sea-lock.sh"),  { description = "Lock screen" })
hl.bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"),                              { description = "Reload Hyprland" })
hl.bind(mod .. " + SHIFT + B", hl.dsp.exec_cmd("sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh --restart"), { description = "Restart bar" })

-- ---------------- window switcher (alt-tab) ----------------
-- hold ALT, press Tab to cycle a visual switcher; release ALT to focus. Escape cancels.
hl.bind("ALT + Tab",         hl.dsp.exec_cmd("qs -c sea-shell ipc call switcher next"),   { description = "Window switcher" })
hl.bind("ALT + SHIFT + Tab", hl.dsp.exec_cmd("qs -c sea-shell ipc call switcher prev"),   { description = "Window switcher (back)" })
hl.bind("ALT + Escape",      hl.dsp.exec_cmd("qs -c sea-shell ipc call switcher cancel"))
hl.bind("ALT + Alt_L",       hl.dsp.exec_cmd("qs -c sea-shell ipc call switcher commit"), { release = true })

-- ---------------- window management ----------------
hl.bind(mod .. " + F",         hl.dsp.window.fullscreen({ mode = "maximized",  action = "toggle" }), { description = "Maximize" })
hl.bind(mod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }), { description = "True fullscreen" })
hl.bind(mod .. " + P",         hl.dsp.window.float({ action = "toggle" }),                            { description = "Toggle floating" })
hl.bind(mod .. " + C",         hl.dsp.window.center(),                                                { description = "Center window" })

-- focus (vim keys + arrows)
hl.bind(mod .. " + H",     hl.dsp.focus({ direction = "l" }), { description = "Focus left" })
hl.bind(mod .. " + L",     hl.dsp.focus({ direction = "r" }), { description = "Focus right" })
hl.bind(mod .. " + K",     hl.dsp.focus({ direction = "u" }), { description = "Focus up" })
hl.bind(mod .. " + J",     hl.dsp.focus({ direction = "d" }), { description = "Focus down" })
hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "l" }), { description = "Focus left" })
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "r" }), { description = "Focus right" })
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "u" }), { description = "Focus up" })
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "d" }), { description = "Focus down" })

-- move windows
hl.bind(mod .. " + SHIFT + H", hl.dsp.window.move({ direction = "l" }), { description = "Move window left" })
hl.bind(mod .. " + SHIFT + L", hl.dsp.window.move({ direction = "r" }), { description = "Move window right" })
hl.bind(mod .. " + SHIFT + K", hl.dsp.window.move({ direction = "u" }), { description = "Move window up" })
hl.bind(mod .. " + SHIFT + J", hl.dsp.window.move({ direction = "d" }), { description = "Move window down" })

-- resize (repeatable)
hl.bind(mod .. " + CTRL + H", hl.dsp.window.resize({ x = -40, y = 0, relative = true }), { repeating = true, description = "Shrink width" })
hl.bind(mod .. " + CTRL + L", hl.dsp.window.resize({ x = 40,  y = 0, relative = true }), { repeating = true, description = "Grow width" })
hl.bind(mod .. " + CTRL + K", hl.dsp.window.resize({ x = 0, y = -40, relative = true }), { repeating = true, description = "Shrink height" })
hl.bind(mod .. " + CTRL + J", hl.dsp.window.resize({ x = 0, y = 40,  relative = true }), { repeating = true, description = "Grow height" })

-- ---------------- workspaces (1–10) ----------------
for i = 1, 10 do
    local key = tostring(i % 10)   -- 10 -> "0"
    hl.bind(mod .. " + " .. key,           hl.dsp.focus({ workspace = i }),       { description = "Workspace " .. i })
    hl.bind(mod .. " + SHIFT + " .. key,   hl.dsp.window.move({ workspace = i }), { description = "Send to workspace " .. i })
end

-- cycle workspaces with the scroll wheel over the desktop
hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { description = "Next workspace" })
hl.bind(mod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }), { description = "Previous workspace" })

-- special / scratchpad
hl.bind(mod .. " + grave",         hl.dsp.workspace.toggle_special("scratch"),                 { description = "Scratchpad" })
hl.bind(mod .. " + SHIFT + grave", hl.dsp.window.move({ workspace = "special:scratch" }),      { description = "Send to scratchpad" })

-- ---------------- move/resize with the mouse ----------------
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, description = "Move window (mouse)" })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Resize window (mouse)" })

-- ---------------- media & hardware keys ----------------
hl.bind("XF86AudioRaiseVolume",   hl.dsp.exec_cmd("wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true, locked = true, description = "Volume up" })
hl.bind("XF86AudioLowerVolume",   hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),        { repeating = true, locked = true, description = "Volume down" })
hl.bind("XF86AudioMute",          hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),       { locked = true, description = "Mute" })
hl.bind("XF86AudioMicMute",       hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),     { locked = true, description = "Mic mute" })
hl.bind("XF86MonBrightnessUp",    hl.dsp.exec_cmd("brightnessctl set 5%+"),                            { repeating = true, locked = true, description = "Brightness up" })
hl.bind("XF86MonBrightnessDown",  hl.dsp.exec_cmd("brightnessctl set 5%-"),                            { repeating = true, locked = true, description = "Brightness down" })
hl.bind("XF86AudioPlay",          hl.dsp.exec_cmd("playerctl play-pause"),                             { locked = true, description = "Play / pause" })
hl.bind("XF86AudioNext",          hl.dsp.exec_cmd("playerctl next"),                                   { locked = true, description = "Next track" })
hl.bind("XF86AudioPrev",          hl.dsp.exec_cmd("playerctl previous"),                               { locked = true, description = "Previous track" })

-- ---------------- laptop lid switch ----------------
-- lid CLOSE is intentionally not bound (clamshell — logind is set to ignore the lid).
-- hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd("loginctl lock-session && systemctl suspend"), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.dpms({ action = "on" }), { locked = true })

-- ---------------- screenshots (needs grim + slurp + wl-clipboard) ----------------
hl.bind("Print",              hl.dsp.exec_cmd(shotmenu), { description = "Screenshot menu" })
hl.bind(mod .. " + Print",    hl.dsp.exec_cmd([[pgrep -x slurp >/dev/null || { quickshell -c sea-shell ipc call shell pin; grim -g "$(slurp)" /tmp/sea-capture.png && quickshell -p ~/.config/quickshell/sea-shell/screenshot-editor.qml; }]]), { description = "Screenshot region" })
hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd([[pgrep -x slurp >/dev/null || { quickshell -c sea-shell ipc call shell pin; grim -g "$(slurp)" /tmp/sea-capture.png && quickshell -p ~/.config/quickshell/sea-shell/screenshot-editor.qml; }]]), { description = "Screenshot region" })
-- OCR a region straight to the clipboard (needs tesseract). The slurp guard matches the
-- screenshot binds above: a second selection while one is already open just cancels both.
hl.bind(mod .. " + SHIFT + O", hl.dsp.exec_cmd([[pgrep -x slurp >/dev/null || ~/.config/quickshell/sea-shell/sea-ocr.sh eng]]), { description = "OCR region to clipboard" })

-- ---------------- clipboard history (needs cliphist + wl-clipboard) ----------------
hl.bind(mod .. " + V", hl.dsp.exec_cmd("qs -c sea-shell ipc call launcher clipboard"), { description = "Clipboard history" })

-- ---------------- sea-shell 2.0 ----------------
hl.bind(mod .. " + W", hl.dsp.exec_cmd("qs -c sea-shell ipc call shell toggleExpose"),           { description = "Mission Control" })
hl.bind(mod .. " + D", hl.dsp.exec_cmd("~/.config/quickshell/sea-shell/sea-toggle.sh Dashboard"), { description = "Dashboard" })

-- Game mode: strips blur/shadows/animations, kills the video wallpaper, performance profile,
-- silences notifications — and restores every one of them to its previous value on the way out.
hl.bind(mod .. " + SHIFT + G", hl.dsp.exec_cmd("~/.config/quickshell/sea-shell/sea-gamemode.sh toggle"), { description = "Game mode" })
hl.bind(mod .. " + R", hl.dsp.exec_cmd("qs -c sea-shell ipc call recorder toggle"),              { description = "Screen Recording" })

-- ---------------- screen magnifier (Hyprland cursor:zoom_factor) ----------------
-- SUPER +/- steps the zoom (hold to repeat), SUPER 0 resets. The level flashes in the OSD.
hl.bind(mod .. " + equal",       hl.dsp.exec_cmd("qs -c sea-shell ipc call zoom inc"),   { repeating = true, description = "Magnifier zoom in" })
hl.bind(mod .. " + minus",       hl.dsp.exec_cmd("qs -c sea-shell ipc call zoom dec"),   { repeating = true, description = "Magnifier zoom out" })
hl.bind(mod .. " + KP_Add",      hl.dsp.exec_cmd("qs -c sea-shell ipc call zoom inc"),   { repeating = true, description = "Magnifier zoom in" })
hl.bind(mod .. " + KP_Subtract", hl.dsp.exec_cmd("qs -c sea-shell ipc call zoom dec"),   { repeating = true, description = "Magnifier zoom out" })
hl.bind(mod .. " + 0",           hl.dsp.exec_cmd("qs -c sea-shell ipc call zoom reset"), { description = "Magnifier reset" })

-- NOTE: preserved from keybinds.conf — SUPER+C is bound twice (center window above, and Code here).
-- The last-registered wins in Hyprland; left as-is for a faithful migration. Remove one to resolve.
hl.bind(mod .. " + C", hl.dsp.exec_cmd("visual-studio-code-electron"), { description = "Code" })
