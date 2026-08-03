-- sea-shell — Hyprland look, themed after miyukivigil.tech (Lua config, Hyprland 0.55+).
-- Migrated from sea.conf. dofile()'d from hyprland.lua; `hl` is the global config API.

-- Qt apps follow the shell's light/dark via the gtk3 platform theme (adw-gtk3 tracks the
-- gsettings color-scheme sea-apply-mode.sh flips) — Qt widgets switch live alongside GTK + the bar.
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")

hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 12,
        border_size = 2,
        resize_on_border = true,
        -- frost → iris gradient, 45° — the same gradient as the site logo/borders
        col = {
            active_border = { colors = { "rgba(a2e2e8ee)", "rgba(63c7ddee)" }, angle = 45 },
            inactive_border = "rgba(24304aaa)",
        },
    },
})

-- matugen-accent.sh rewrites matugen.lua with the wallpaper accent when "match colours" is on
-- (and applies it live via hyprctl). dofile'd AFTER the block above so it overrides those defaults;
-- absent/empty = the sea-cyan borders above stand. pcall so a missing file never breaks the config.
do
    local home = os.getenv("HOME") or ""
    pcall(dofile, home .. "/.config/hypr/sea-shell/matugen.lua")
end

hl.config({
    decoration = {
        rounding = 10,                 -- = --tile-radius: 10px
        active_opacity = 1.0,
        inactive_opacity = 0.96,
        blur = {
            enabled = true,            -- = CSS backdrop-filter: blur()
            size = 9,
            passes = 4,
            new_optimizations = true,
            vibrancy = 0.17,
            popups = true,             -- frost the bar dropdowns so low opacity stays readable
            popups_ignorealpha = 0.2,
            -- xray → blur samples the WALLPAPER, not the windows behind. Keeps the glassy
            -- bar/dropdowns readable over bright app windows. Only sea-shell layers are blurred.
            xray = true,
        },
        shadow = {
            enabled = true,            -- = the tile box-shadow glow
            range = 24,
            render_power = 3,
            color = "rgba(63c7dd44)",
            color_inactive = "rgba(0a141e66)",
        },
    },
})

-- animations: the site's "tile-in" spring + page-enter ease
hl.config({ animations = { enabled = true } })
hl.curve("seatile", { type = "bezier", points = { { 0.34, 1.5 }, { 0.58, 1.0 } } })  -- cubic-bezier(.34,1.5,.58,1)
hl.curve("seaease", { type = "bezier", points = { { 0.22, 1.0 }, { 0.36, 1.0 } } })  -- cubic-bezier(.22,1,.36,1)
hl.animation({ leaf = "windows",     enabled = true, speed = 4,  bezier = "seatile", style = "popin 84%" })
hl.animation({ leaf = "windowsOut",  enabled = true, speed = 4,  bezier = "seaease", style = "popin 84%" })
hl.animation({ leaf = "border",      enabled = true, speed = 8,  bezier = "seaease" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 30, bezier = "seaease", style = "loop" })
hl.animation({ leaf = "fade",        enabled = true, speed = 5,  bezier = "seaease" })
hl.animation({ leaf = "workspaces",  enabled = true, speed = 5,  bezier = "seatile", style = "slide" })

-- ---------------- layer rules ----------------
-- frost the sea-shell bar + its popups / overlays (matches the bar's backdrop blur).
-- ignore_alpha 0.2 keeps blur off the fully-transparent parts of the layer surface.
for _, ns in ipairs({ "sea-shell:bar", "sea-shell:drop", "sea-shell:notif", "sea-shell:osd" }) do
    hl.layer_rule({ match = { namespace = ns }, blur = true, ignore_alpha = 0.2 })
end
-- launcher: frost the glass card but NOT the dim scrim (ignore_alpha 0.42 > scrim alpha 0.35).
hl.layer_rule({ match = { namespace = "sea-shell:launcher" }, blur = true, ignore_alpha = 0.42 })
-- kill Hyprland's open/close animation on dropdowns + launcher — the QML fades the card itself,
-- and the layer close-animation was snapshotting the card and smearing it as it faded out.
hl.layer_rule({ match = { namespace = "sea-shell:drop" },     no_anim = true })
hl.layer_rule({ match = { namespace = "sea-shell:launcher" }, no_anim = true })

-- float the little wifi-password terminal in the centre
hl.window_rule({ match = { class = "^(sea-wifi)$" }, float = true, size = { 560, 240 }, center = true })
