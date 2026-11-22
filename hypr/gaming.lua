-- sea-shell — the gaming session (Hyprland 0.55+). Big picture mode and nothing else.
--
-- Started by sea-gaming-session.sh from the "sea-shell Gaming" entry on the login screen, in
-- place of hyprland.lua. Nothing of the desktop runs: no bar, no wallpaper, no idle daemon, no
-- blur or animations. Every setting a console needs is in big picture's own Settings, and Power →
-- Log out goes back to the login screen, where the desktop session is picked as usual.
--
-- Installed by install.sh to ~/.config/hypr/sea-shell/gaming.lua. Your own additions go in
-- ~/.config/hypr/sea-shell/gaming-user.lua, which is loaded last and never overwritten.

local home = os.getenv("HOME") or ""

hl.env("SEA_SESSION", "gaming")
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")

-- The same screens, modes and placement as the desktop (Settings → Displays writes monitors.lua).
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
pcall(dofile, home .. "/.config/hypr/sea-shell/monitors.lua")

-- Big picture → System → Keyboard layout overrides this at start.
hl.config({ input = { kb_layout = "us", numlock_by_default = true, follow_mouse = 1 } })

-- Nothing to look at but big picture and the game, so nothing to draw around them.
hl.config({
    general = { gaps_in = 0, gaps_out = 0, border_size = 0 },
    decoration = {
        rounding = 0,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        blur = { enabled = false },
        shadow = { enabled = false },
    },
    animations = { enabled = false },
    -- See sea.lua: direct scanout flashed purple in fullscreen XWayland games on NVIDIA.
    render = { direct_scanout = 0 },
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
    cursor = { inactive_timeout = 3 },
})
hl.layer_rule({ match = { namespace = "sea-bigpicture" }, no_anim = true })

-- ---------------- keys ----------------
-- Media keys work as on the desktop. The rest are ways out if something stops answering.
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true, locked = true, description = "Volume up" })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),        { repeating = true, locked = true, description = "Volume down" })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),       { locked = true, description = "Mute" })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),     { locked = true, description = "Mic mute" })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 5%+"),                            { repeating = true, locked = true, description = "Brightness up" })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"),                            { repeating = true, locked = true, description = "Brightness down" })
hl.bind("XF86AudioPlay",         hl.dsp.exec_cmd("playerctl play-pause"),                             { locked = true, description = "Play / pause" })
hl.bind("SUPER + Escape",        hl.dsp.exec_cmd("qs -p ~/.config/quickshell/sea-shell/gaming.qml ipc call bigpicture open"), { description = "Big picture" })
hl.bind("SUPER + Q",             hl.dsp.window.close(),                                               { description = "Close window" })
hl.bind("SUPER + F",             hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }), { description = "Fullscreen" })
hl.bind("SUPER + Return",        hl.dsp.exec_cmd("kitty"),                                            { description = "Terminal" })
hl.bind("SUPER + SHIFT + B",     hl.dsp.exec_cmd("sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh --restart"), { description = "Restart big picture" })
hl.bind("CTRL + ALT + Delete",   hl.dsp.exit(),                                                       { description = "Log out" })

-- Lid closed: the same as the desktop's, the screen goes off and comes back.
hl.bind("switch:on:Lid Switch",  hl.dsp.dpms({ action = "off" }), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.dpms({ action = "on" }),  { locked = true })

hl.on("hyprland.start", function()
    -- Only what portals and services need. Not --all: SEA_SESSION would stay in the user
    -- manager's environment and follow you into the desktop session afterwards.
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE")
    hl.exec_cmd("sh ~/.config/quickshell/sea-shell/sea-bar-supervisor.sh")
end)

pcall(dofile, home .. "/.config/hypr/sea-shell/gaming-user.lua")
