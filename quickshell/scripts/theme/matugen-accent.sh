#!/bin/sh
# sea-shell — recolour the shell accent + kitty from a wallpaper via matugen, or
# reset both to the default sea-cyan when called with --reset.
#
#   matugen-accent.sh [wallpaper]   apply: accent → appearance.json, palette → kitty
#   matugen-accent.sh --reset       revert accent to #63c7dd, clear the kitty overrides
#
# Writes ~/.config/sea-shell/appearance.json (accent, other fields preserved) and
# ~/.config/sea-shell/kitty-matugen.conf (kitty overrides; sea-cyan.conf includes it).
here="$(dirname "$0")"
DEFAULT="#63c7dd"
cfg="$HOME/.config/sea-shell/appearance.json"
kitty="$HOME/.config/sea-shell/kitty-matugen.conf"
mkdir -p "$HOME/.config/sea-shell"
reload_kitty() { pkill -USR1 -x kitty 2>/dev/null || true; }
overrides="$HOME/.config/sea-shell/matugen-overrides.json"

# Read per-target overrides from JSON config.
# Outputs: HYPRLAND=1 KITTY=1 FASTFETCH=1 STARSHIP=1 HYPR_CUSTOM_ACTIVE='' HYPR_CUSTOM_INACTIVE=''
# All targets default to enabled if the file is missing or unreadable.
read_overrides() {
    python3 - "$overrides" <<'OVPY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
def flag(key):
    sec = d.get(key, {})
    return '1' if sec.get('enabled', True) else '0'
def val(key, prop):
    sec = d.get(key, {})
    if sec.get('enabled', True): return ''
    return sec.get(prop, '') or ''
print('HYPRLAND=%s KITTY=%s FASTFETCH=%s STARSHIP=%s HYPR_CUSTOM_ACTIVE=%s HYPR_CUSTOM_INACTIVE=%s KITTY_CUSTOM_ACCENT=%s KITTY_CUSTOM_BG=%s FASTFETCH_CUSTOM_ACCENT=%s STARSHIP_CUSTOM_ACCENT=%s HYPR_GLOW=%s HYPR_CUSTOM_GLOW=%s' % (
    flag('hyprland'), flag('kitty'), flag('fastfetch'), flag('starship'),
    repr(val('hyprland', 'customActive')),
    repr(val('hyprland', 'customInactive')),
    repr(val('kitty', 'customAccent')),
    repr(val('kitty', 'customBg')),
    repr(val('fastfetch', 'customAccent')),
    repr(val('starship', 'customAccent')),
    # The window glow is its own target: some people want matugen borders but a fixed glow.
    # Defaults to enabled, like every other target.
    '1' if d.get('hyprGlow', {}).get('enabled', True) else '0',
    repr(val('hyprGlow', 'customColor')),
))
OVPY
}

# Apply Hyprland border colours.
# $1 = accent (#hex), $2 = frost (#hex)
# Honours HYPR_CUSTOM_ACTIVE / HYPR_CUSTOM_INACTIVE overrides if set.
apply_hyprland() {
    local a="$1" f="$2" aa ff
    [ -z "$a" ] && return
    aa=${a#\#}; ff=${f#\#}; [ -z "$ff" ] && ff="$aa"
    # custom border colours from overrides JSON take priority
    local cust_a_hex="${HYPR_CUSTOM_ACTIVE:-}" cust_i_hex="${HYPR_CUSTOM_INACTIVE:-}"
    local active_val inactive_val
    if [ -n "$cust_a_hex" ]; then
        local ca=${cust_a_hex#\#}
        active_val="rgba(${ca}ee)"
    else
        active_val="rgba(${ff}ee) rgba(${aa}ee) 45deg"
    fi
    if [ -n "$cust_i_hex" ]; then
        local ci=${cust_i_hex#\#}
        inactive_val="rgba(${ci}55)"
    else
        inactive_val="rgba(${aa}55)"
    fi
    # ---- window glow (decoration:shadow) ----
    # This is the "glow" around a focused tile. It was hardcoded to sea-cyan in sea.lua and so
    # stayed cyan on every wallpaper while the borders recoloured around it. Active glow is the
    # accent at the same 0x44 alpha the default used; the inactive shadow is a heavily darkened
    # accent at 0x66, which keeps it reading as depth rather than a second glow.
    # `enabled: false` on a target does NOT mean "leave it alone" in this overrides file — it
    # means "stop auto-matching and use my colour", which is why read_overrides only hands back
    # a custom value when the target is disabled. Gating the custom branch on enabled=1 (as this
    # first did) makes it unreachable and silently falls back to the accent.
    local glow_src="$a"
    [ "${HYPR_GLOW:-1}" != "1" ] && [ -n "${HYPR_CUSTOM_GLOW:-}" ] && glow_src="$HYPR_CUSTOM_GLOW"
    local gs=${glow_src#\#}
    local glow_a="rgba(${gs}44)"
    local glow_i="rgba($(darken_hex "$glow_src")66)"

    local hd="$HOME/.config/hypr/sea-shell"; mkdir -p "$hd"
    # sea-shell 5.0+ is Lua-only: emit matugen.lua (dofile'd from hyprland.lua's sea.lua).
    # A plain colour becomes a string; the frost→accent gradient becomes { colors = {...}, angle = N }.
    local lua_active lua_inactive="\"$inactive_val\""
    case "$active_val" in
        *deg)
            local _ga="${active_val%% *}" _rest="${active_val#* }" _gang="${active_val##* }"
            local _gb="${_rest%% *}"; _gang="${_gang%deg}"
            lua_active="{ colors = { \"$_ga\", \"$_gb\" }, angle = $_gang }" ;;
        *)  lua_active="\"$active_val\"" ;;
    esac
    printf 'hl.config({ general = { col = { active_border = %s, inactive_border = %s } } })\n' \
        "$lua_active" "$lua_inactive" > "$hd/matugen.lua"
    printf 'hl.config({ decoration = { shadow = { color = "%s", color_inactive = "%s" } } })\n' \
        "$glow_a" "$glow_i" >> "$hd/matugen.lua"
    # Live apply. `hyprctl keyword` is LEGACY-parser only — under a Lua config it refuses with
    # "keyword can't work with non-legacy parsers", so the borders kept the old accent until the
    # next reload. Fall back to `hyprctl eval` with the same Lua we just wrote to matugen.lua.
    hyprctl keyword general:col.active_border "$active_val" 2>/dev/null | grep -q '^ok' || \
        hyprctl eval "hl.config({ general = { col = { active_border = $lua_active } } })" >/dev/null 2>&1
    hyprctl keyword general:col.inactive_border "$inactive_val" 2>/dev/null | grep -q '^ok' || \
        hyprctl eval "hl.config({ general = { col = { inactive_border = $lua_inactive } } })" >/dev/null 2>&1
    # Live-apply the glow the same way. Verified against Hyprland 0.56: this eval really does
    # move decoration:shadow:color (checked with `hyprctl getoption`), which is why it is safe
    # to rely on rather than waiting for a reload.
    hyprctl eval \
        "hl.config({ decoration = { shadow = { color = \"$glow_a\", color_inactive = \"$glow_i\" } } })" >/dev/null 2>&1
}

# A very dark, slightly desaturated shade of the accent — the depth shadow behind unfocused
# windows. Mirrors what the hand-picked sea-cyan default (#0a141e for #63c7dd) was doing.
darken_hex() {
    python3 -c "
import sys, colorsys
h = sys.argv[1].lstrip('#')
r, g, b = (int(h[i:i+2], 16) / 255 for i in (0, 2, 4))
hh, l, s = colorsys.rgb_to_hls(r, g, b)
r, g, b = colorsys.hls_to_rgb(hh, 0.085, min(s, 0.55))
print('%02x%02x%02x' % tuple(round(c * 255) for c in (r, g, b)))
" "$1" 2>/dev/null || printf '0a141e'
}

# Apply hyprlock colours.
# $1 = accent (#hex), $2 = frost (#hex)
apply_hyprlock() {
    local a="$1" f="$2" aa ff
    [ -z "$a" ] && return
    aa=${a#\#}; ff=${f#\#}; [ -z "$ff" ] && ff="$aa"
    local hl_conf="$HOME/.config/hypr/sea-shell/hyprlock-colors.conf"
    mkdir -p "$(dirname "$hl_conf")"
    cat <<EOF > "$hl_conf"
# sea-shell matugen lockscreen colors
\$accent = rgba(${aa}cc)
\$accentAlpha = ${aa}
\$frost = rgba(${ff}ff)
\$frostAlpha = ${ff}
EOF
}

# Patch fastfetch config with the accent colour.
# $1 = accent (#hex)
apply_fastfetch() {
    local a="$1"
    [ -z "$a" ] && return
    local ffc="$HOME/.config/fastfetch/config.jsonc"
    [ -f "$ffc" ] && python3 - "$ffc" "$a" <<'PY'
import json, sys
p, acc = sys.argv[1], sys.argv[2]
r, g, b = int(acc[1:3],16), int(acc[3:5],16), int(acc[5:7],16)
sgr = f"38;2;{r};{g};{b}"                       # truecolor SGR fastfetch understands
def strip_jsonc(s):                             # drop // and /* */ comments but NOT inside strings
    o=[]; i=0; n=len(s); instr=False; esc=False
    while i<n:
        c=s[i]
        if instr:
            o.append(c)
            if esc: esc=False
            elif c=='\\': esc=True
            elif c=='"': instr=False
            i+=1; continue
        if c=='"': instr=True; o.append(c); i+=1; continue
        if c=='/' and i+1<n and s[i+1]=='/':
            while i<n and s[i]!='\n': i+=1
            continue
        if c=='/' and i+1<n and s[i+1]=='*':
            i+=2
            while i+1<n and not (s[i]=='*' and s[i+1]=='/'): i+=1
            i+=2; continue
        o.append(c); i+=1
    return ''.join(o)
try:
    d = json.loads(strip_jsonc(open(p, encoding="utf-8").read()))
except Exception:
    sys.exit(0)
disp = d.setdefault("display", {})
disp.pop("keyColor", None)                      # remove the wrong property earlier builds wrote
disp["color"] = sgr                             # a string colours the keys (labels) + title
d.setdefault("logo", {})["color"] = {"1": sgr}  # single-colour ascii logo → the accent
json.dump(d, open(p, "w", encoding="utf-8"), indent=4, ensure_ascii=False)
PY
}

set_accent() {   # $1 = hex, preserving every other appearance.json field
    python3 - "$cfg" "$1" <<'PY'
import json, os, sys
cfg, col = sys.argv[1], sys.argv[2]
try: d = json.load(open(cfg))
except Exception: d = {"radius": 14, "opacity": 0.82, "height": 42, "font": "monospace"}
d["accent"] = col
_t = cfg + ".tmp"
with open(_t, "w") as _fh: json.dump(d, _fh)
os.replace(_t, cfg)   # atomic: the bar watches this file and a torn read is a lost theme change
PY
}

star="$HOME/.config/starship.toml"
sdef="$HOME/.config/sea-shell/starship-default.toml"

if [ "$1" = "--reset" ]; then
    eval "$(read_overrides)"
    set_accent "$DEFAULT"
    if [ "$KITTY" = 1 ]; then
        : > "$kitty"                       # empty → kitty falls back to sea-cyan.conf defaults
        : > "$HOME/.config/sea-shell/kitty-matugen-light.conf"   # clear the light variant too
    fi
    [ "$STARSHIP" = 1 ] && [ -f "$sdef" ] && cp "$sdef" "$star" 2>/dev/null
    [ "$HYPRLAND" = 1 ] && apply_hyprland "$DEFAULT" "#a2e2e8"
    apply_hyprlock "$DEFAULT" "#a2e2e8"
    [ "$FASTFETCH" = 1 ] && apply_fastfetch "$DEFAULT"
    [ "$KITTY" = 1 ] && reload_kitty
    notify-send 'sea-shell' 'Colours reset to sea cyan' 2>/dev/null
    exit 0
fi

matugen_enabled=$(python3 -c "import json,sys; print(str(json.load(open(sys.argv[1])).get('matugen', False)))" "$cfg" 2>/dev/null)

if [ "$matugen_enabled" = "True" ]; then
    wp=$(printf '%s' "$1" | tr -d '\n\r')
    [ -z "$wp" ] && wp=$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null | tr -d '\n\r')
    [ -z "$wp" ] && exit 1
    # A moving wallpaper has to be reduced to one frame before matugen can look at it —
    # but the wallpaper indexer has ALREADY cut that frame and cached it, so this used to
    # re-decode the source clip on every single switch. Timed at 0.42s per cycle against a
    # JPEG that was sitting in ~/.cache/sea-shell/wallthumbs the whole time.
    #
    # And it took frame ZERO, which is the frame the poster deliberately avoids: a great
    # many wallpaper clips open on black, and a black frame hands the entire desktop a
    # palette derived from black. The poster seeks a second in for exactly that reason.
    case "$wp" in
        *.mp4|*.webm|*.mkv|*.mov|*.gif)
            ix=""
            for c in "$here/sea-wallpaper-index.py" "$here/../wallpaper/sea-wallpaper-index.py"; do
                [ -f "$c" ] && { ix="$c"; break; }
            done
            poster=""
            [ -n "$ix" ] && poster=$(python3 "$ix" --poster "$wp" 2>/dev/null)
            if [ -n "$poster" ] && [ -f "$poster" ]; then
                wp="$poster"
            else
                # No indexer reachable, or it could not extract — fall back to what this
                # did before, seeking a second in the way the poster would have.
                f=/tmp/sea-matugen-frame.png
                ffmpeg -y -ss 1 -i "$wp" -vframes 1 "$f" >/dev/null 2>&1 \
                    || ffmpeg -y -i "$wp" -vframes 1 "$f" >/dev/null 2>&1
                [ -f "$f" ] && wp="$f"
            fi ;;
    esac
fi

# ---------- the shell's light/dark can follow the PICTURE (modeSource = "wallpaper") ----------
# $wp is a still by now — the indexer's cached poster for a clip, the file itself for an image —
# so this costs one 1x1 resize of a JPEG that is already on disk, not a decode.
#
# WHY A DEAD ZONE AND NOT A THRESHOLD.  Measured across a real eleven-wallpaper library, the mean
# luminances were .28 .31 .41 .45 .45 .49 .51 .51 .52 .74 .94 — six of the eleven sit inside a
# tenth of 0.5. A plain midpoint would call .488 dark and .512 light, which is a coin toss between
# two pictures nobody would describe differently, and auto-rotate through that folder would flip
# the entire desktop every half hour on noise. So: commit only when the picture is not ambiguous,
# and otherwise leave the mode exactly where it is. Most wallpapers change nothing, which is the
# point — the ones that do are the ones you would have switched by hand anyway.
if [ -n "$wp" ] && [ -f "$wp" ] && command -v magick >/dev/null 2>&1; then
    src=$(python3 -c "import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(d.get('modeSource') or ('clock' if d.get('autoDark') else 'manual'))" "$cfg" 2>/dev/null)
    if [ "$src" = "wallpaper" ]; then
        lum=$(magick "$wp" -colorspace gray -resize 1x1! -format "%[fx:mean]" info: 2>/dev/null)
        case "$lum" in
            ''|*[!0-9.]*) : ;;                      # unreadable — leave the mode alone
            *) python3 - "$cfg" "$lum" <<'PY'
import json, os, sys
cfg = sys.argv[1]
try: lum = float(sys.argv[2])
except ValueError: raise SystemExit(0)
try: d = json.load(open(cfg))
except Exception: raise SystemExit(0)
cur = d.get("mode", "dark")
if   lum < 0.42: want = "dark"
elif lum > 0.60: want = "light"
else:            want = cur          # the dead zone: not bright enough or dark enough to say
if want != cur:
    d["mode"] = want
    t = cfg + ".tmp"
    with open(t, "w") as fh: json.dump(d, fh)
    os.replace(t, cfg)               # the bar watches this and pushes the mode out to GTK + kitty
PY
            ;;
        esac
    fi
fi

# check if auto colours from wallpaper (matugen) is enabled globally
jf=$(mktemp) || exit 1

if [ "$matugen_enabled" = "True" ]; then
    scheme=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('scheme','scheme-tonal-spot'))" "$cfg" 2>/dev/null)
    case "$scheme" in scheme-*) ;; *) scheme="scheme-tonal-spot" ;; esac
    json=$(matugen --json hex --type "$scheme" --prefer saturation image "$wp" 2>/dev/null)
    if [ -n "$json" ]; then
        printf '%s' "$json" > "$jf"
    else
        manual_accent=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('accent','#63c7dd'))" "$cfg" 2>/dev/null)
        printf '{"colors":{"primary":{"default":{"color":"%s"}}}}' "$manual_accent" > "$jf"
    fi
else
    manual_accent=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('accent','#63c7dd'))" "$cfg" 2>/dev/null)
    printf '{"colors":{"primary":{"default":{"color":"%s"}}}}' "$manual_accent" > "$jf"
fi

# accent = Material `primary`; kitty ANSI palette = the base16 scheme (dark variant).
# prints "<accent> <frost>" on stdout so the shell can also recolour starship.
# ── per-target overrides ─────────────────────────────────────────────────────
eval "$(read_overrides)"

pal=$(WRITE_KITTY="$KITTY" KITTY_CUSTOM_ACCENT="$KITTY_CUSTOM_ACCENT" KITTY_CUSTOM_BG="$KITTY_CUSTOM_BG" python3 - "$cfg" "$kitty" "$DEFAULT" "$jf" <<'PY'
import json, sys, os
cfg, kitty, default, jf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(jf))
def pick(node):
    if not node: return None
    return (node.get('dark') or node.get('default') or node.get('light') or {}).get('color')
def lighten(hx, amt=0.30):
    h = hx.lstrip('#'); r, g, b_ = int(h[0:2],16), int(h[2:4],16), int(h[4:6],16)
    return '#%02x%02x%02x' % (int(r+(255-r)*amt), int(g+(255-g)*amt), int(b_+(255-b_)*amt))
colors = data.get('colors', {}); b = data.get('base16', {})
def bb(k, fb): return pick(b.get(k)) or fb

custom_acc = os.environ.get('KITTY_CUSTOM_ACCENT', '').strip()
custom_bg = os.environ.get('KITTY_CUSTOM_BG', '').strip()

global_accent = pick(colors.get('primary')) or default
kitty_accent = custom_acc if custom_acc else global_accent

try: d = json.load(open(cfg))
except Exception: d = {"radius": 14, "opacity": 0.82, "height": 42, "font": "monospace"}
d["accent"] = global_accent
_t = cfg + ".tmp"
with open(_t, "w") as _fh: json.dump(d, _fh)
os.replace(_t, cfg)   # atomic: the bar watches this file and a torn read is a lost theme change

# Terminal palettes are built with a CONTRAST-AWARE, hue-preserving algorithm rather than
# matugen's raw base16 — that base16 is unreadable on saturated wallpapers (a hot-pink image
# gives a maroon bg with maroon text). Instead: a DESATURATED surface for the background (only
# a faint accent tint), standard distinct ANSI hues (red stays red, not "wallpaper red"), each
# bumped in lightness until it clears a WCAG contrast floor against that bg — the same idea as
# dank16 (Delta Phi Star). The "blue" slot borrows the accent hue so the terminal still reads
# as wallpaper-matched. Readable on ANY wallpaper; the accent stays vivid for the bar.
import colorsys
def _rgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16)/255.0 for i in (0,2,4))
def _hx(r,g,b): return '#%02x%02x%02x' % tuple(round(max(0.0,min(1.0,c))*255) for c in (r,g,b))
def _hsl(h): r,g,b=_rgb(h); hh,l,s=colorsys.rgb_to_hls(r,g,b); return hh,s,l
def H(hh,s,l): r,g,b=colorsys.hls_to_rgb(hh%1.0, max(0.0,min(1.0,l)), max(0.0,min(1.0,s))); return _hx(r,g,b)
def _lin(c): return c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
def _lum(h): r,g,b=_rgb(h); return 0.2126*_lin(r)+0.7152*_lin(g)+0.0722*_lin(b)
def _con(a,b): la,lb=_lum(a),_lum(b); hi,lo=max(la,lb),min(la,lb); return (hi+0.05)/(lo+0.05)
def readable(col, bg, target, up):        # nudge lightness until it clears the contrast floor
    hh,s,l=_hsl(col)
    for _ in range(90):
        if _con(H(hh,s,l), bg) >= target: return H(hh,s,l)
        l = l + 0.012 if up else l - 0.012
        if l>=1.0 or l<=0.0: break
    return H(hh, s, max(0.0,min(1.0,l)))
AH, ASAT, _AL = _hsl(kitty_accent)              # wallpaper accent HUE drives every tint

def kitty_rows(dark, opacity):
    # Background carries the wallpaper HUE at real saturation + enough lightness to actually
    # SEE the colour (a near-black bg reads the same for every wallpaper). Readability is kept
    # by a near-white/near-black foreground whose contrast is *enforced*, plus contrast-checked
    # ANSI — so a saturated bg is fine (white-on-teal, white-on-plum … all read clean).
    if dark:
        bg=custom_bg if custom_bg else H(AH, min(max(ASAT,0.28),0.55), 0.125)
        fg=readable(H(AH,0.08,0.94), bg, 9.0, True)
        c0=H(AH,0.32,0.24); c8=H(AH,0.22,0.44); c7=H(AH,0.09,0.83); c15=H(AH,0.05,0.98)
        nL,bL,S,up = 0.66, 0.76, 0.62, True
    else:
        bg=custom_bg if custom_bg else H(AH, min(max(ASAT,0.14),0.28), 0.955)
        fg=readable(H(AH,0.45,0.12), bg, 8.0, False)
        c0=H(AH,0.30,0.40); c8=H(AH,0.22,0.54); c7=H(AH,0.24,0.28); c15=H(AH,0.55,0.09)
        nL,bL,S,up = 0.44, 0.52, 0.70, False
    # ANSI hues nudged toward the accent (short-arc blend) so they carry the theme too, but not
    # so far they stop reading as red/green/blue. The "blue" slot IS the accent hue.
    def tint(h, amt=0.18):
        d=(AH-h+0.5)%1.0-0.5; return (h+d*amt)%1.0
    R,Y,G,Cy,Bl,M = tint(0.00), tint(0.12), tint(0.34), tint(0.50), AH, tint(0.83)
    def C(hue,l): return readable(H(hue,S,l), bg, 4.2, up)
    acc = readable(kitty_accent, bg, 3.0, up)                  # accent kept readable for cursor/borders
    return [
      ('foreground',fg),('background',bg),
      ('selection_foreground',bg),('selection_background',acc),
      ('cursor',acc),('cursor_text_color',bg),
      ('url_color',C(Cy,nL)),
      ('active_border_color',acc),('inactive_border_color',c8),
      ('active_tab_background',acc),('active_tab_foreground',bg),
      ('inactive_tab_foreground',c7),('inactive_tab_background',c0),
      ('background_opacity',opacity),
      ('color0',c0),('color8',c8),
      ('color1',C(R,nL)),('color9',C(R,bL)),
      ('color2',C(G,nL)),('color10',C(G,bL)),
      ('color3',C(Y,nL)),('color11',C(Y,bL)),
      ('color4',C(Bl,nL)),('color12',C(Bl,bL)),
      ('color5',C(M,nL)),('color13',C(M,bL)),
      ('color6',C(Cy,nL)),('color14',C(Cy,bL)),
      ('color7',c7),('color15',c15),
    ]
def write_kitty(path, dark, opacity):
    with open(path,'w') as f:
        f.write('# sea-shell matugen — contrast-aware %s variant (readable on any wallpaper)\n' % ('dark' if dark else 'light'))
        for k, v in kitty_rows(dark, opacity): f.write('%-22s %s\n' % (k, v))
import os
write_kitty(kitty, True, '0.92')
write_kitty((kitty[:-5] if kitty.endswith('.conf') else kitty) + '-light.conf', False, '0.94')
print(global_accent, lighten(global_accent))
PY
)
rm -f "$jf"

# starship — swap the sea accents (#63c7dd / #a2e2e8) for the wallpaper palette.
# Seed a pristine default once (deref the symlink), then always generate from it.
set -- $pal; accent="$1"; frost="$2"
apply_hyprlock "$accent" "$frost"
if [ "$STARSHIP" = 1 ]; then
    [ -f "$sdef" ] || { [ -e "$star" ] && cp -L "$star" "$sdef" 2>/dev/null; }
    if [ -f "$sdef" ] && [ -n "$accent" ] && [ -n "$frost" ]; then
        sed -e "s/#63c7dd/$accent/g" -e "s/#a2e2e8/$frost/g" "$sdef" > "$star.tmp" 2>/dev/null && mv "$star.tmp" "$star"
    fi
else
    [ -f "$sdef" ] || { [ -e "$star" ] && cp -L "$star" "$sdef" 2>/dev/null; }
    target_starship_acc="${STARSHIP_CUSTOM_ACCENT:-$accent}"
    custom_light=$(python3 -c "import sys; h=sys.argv[1].lstrip('#'); r,g,b=int(h[0:2],16),int(h[2:4],16),int(h[4:6],16); print('#%02x%02x%02x' % (int(r+(255-r)*0.3), int(g+(255-g)*0.3), int(b+(255-b)*0.3)))" "$target_starship_acc" 2>/dev/null)
    sed -e "s/#63c7dd/$target_starship_acc/g" -e "s/#a2e2e8/$custom_light/g" "$sdef" > "$star.tmp" 2>/dev/null && mv "$star.tmp" "$star"
fi

# Hyprland borders + fastfetch follow the accent too (per-target gated)
if [ "$HYPRLAND" = 1 ]; then
    apply_hyprland "$accent" "$frost"
else
    active_col="${HYPR_CUSTOM_ACTIVE:-$accent}"
    inactive_col="${HYPR_CUSTOM_INACTIVE:-$accent}"
    # derive active border second gradient stop if no custom inactive is set
    active_frost=$(python3 -c "import sys; h=sys.argv[1].lstrip('#'); r,g,b=int(h[0:2],16),int(h[2:4],16),int(h[4:6],16); print('#%02x%02x%02x' % (int(r+(255-r)*0.3), int(g+(255-g)*0.3), int(b+(255-b)*0.3)))" "$active_col" 2>/dev/null)
    apply_hyprland "$active_col" "$active_frost"
fi

if [ "$FASTFETCH" = 1 ]; then
    apply_fastfetch "$accent"
else
    apply_fastfetch "${FASTFETCH_CUSTOM_ACCENT:-$accent}"
fi

# if the shell is currently in light mode, refresh the live override too (kitty-mode.conf is a
# copy of the light palette that sea-apply-mode.sh makes on toggle — keep it current so a
# running light-mode kitty picks up the new colours without a re-toggle)
mode=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('mode','dark'))" "$cfg" 2>/dev/null)
[ "$mode" = "light" ] && cp "$HOME/.config/sea-shell/kitty-matugen-light.conf" "$HOME/.config/sea-shell/kitty-mode.conf" 2>/dev/null
reload_kitty
notify-send 'sea-shell' 'Colours matched to wallpaper 🎨' 2>/dev/null
