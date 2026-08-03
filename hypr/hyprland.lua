-- ~/.config/hypr/hyprland.lua — a sensible Hyprland (0.55+) starter that drives sea-shell.
--
-- Everything sea-shell needs lives in the marker-wrapped block at the bottom, which install.sh
-- manages (re-run ./install.sh to refresh it). Put YOUR own tweaks — monitors, keyboard layout,
-- extra window rules — above that block; they won't be touched.
--
-- sea-shell owns the *look* (gaps, borders, blur, shadow, animations, layer rules) in sea.lua,
-- so this file only sets the machine-specific essentials. See hypr/README-lua.md.

-- ================== MONITORS ==================
-- Fallback rule: every display uses its own preferred mode from EDID, auto-placed. Works anywhere.
-- To pin a specific display (follows it across ports), match by description —
-- get the string from `hyprctl monitors | grep description`:
--   hl.monitor({ output = "desc:<vendor model serial>", mode = "1920x1080@144", position = "0x0", scale = 1 })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- ================== INPUT ==================
hl.config({ input = { kb_layout = "us", numlock_by_default = true, follow_mouse = 1 } })

-- ================== MISC ==================
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true } })

-- ================== WINDOW RULES ==================
-- a few broadly-useful floats — sea-shell's own look + rules live in sea.lua
hl.window_rule({ match = { class = "^(pavucontrol)$" },               float = true })
hl.window_rule({ match = { class = "^(blueman-manager)$" },           float = true })
hl.window_rule({ match = { class = "^(nm-connection-editor)$" },      float = true })
hl.window_rule({ match = { class = "^(org\\.gnome\\.Calculator)$" },  float = true })
hl.window_rule({ match = { class = "^(firefox)$", title = "^(Picture-in-Picture)$" }, float = true })

-- ================== STARTUP (yours) ==================
hl.on("hyprland.start", function()
    -- makes systemd/dbus user services see the Wayland env (portals, etc.)
    hl.exec_cmd("dbus-update-activation-environment --systemd --all")
end)

-- >>> sea-shell >>>
-- Managed by install.sh — the sea-shell look, keybinds, bar, idle daemon, polkit agent and
-- wallpaper. Don't hand-edit; re-run ./install.sh to refresh.
dofile(os.getenv("HOME") .. "/.config/hypr/sea-shell/sea.lua")
dofile(os.getenv("HOME") .. "/.config/hypr/sea-shell/keybinds.lua")
hl.on("hyprland.start", function()
    hl.exec_cmd("qs -c sea-shell")
    hl.exec_cmd("command -v hypridle >/dev/null && exec hypridle")
    hl.exec_cmd("[ -x /usr/lib/hyprpolkitagent/hyprpolkitagent ] && exec /usr/lib/hyprpolkitagent/hyprpolkitagent")
    hl.exec_cmd("sleep 0.5; exec ~/.config/quickshell/sea-shell/sea-wallpaper-restore.sh")
end)
-- <<< sea-shell <<<
