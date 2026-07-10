#!/bin/sh
# sea-shell — recolour the shell accent + kitty from a wallpaper via matugen, or
# reset both to the default sea-cyan when called with --reset.
#
#   matugen-accent.sh [wallpaper]   apply: accent → appearance.json, palette → kitty
#   matugen-accent.sh --reset       revert accent to #63c7dd, clear the kitty overrides
#
# Writes ~/.config/sea-shell/appearance.json (accent, other fields preserved) and
# ~/.config/sea-shell/kitty-matugen.conf (kitty overrides; sea-cyan.conf includes it).
DEFAULT="#63c7dd"
cfg="$HOME/.config/sea-shell/appearance.json"
kitty="$HOME/.config/sea-shell/kitty-matugen.conf"
mkdir -p "$HOME/.config/sea-shell"
reload_kitty() { pkill -USR1 -x kitty 2>/dev/null || true; }

# recolour the two things outside quickshell that also want the accent:
#   • Hyprland window borders — written to a file Hyprland sources (persists across reload/login)
#     AND applied live via hyprctl.  active = frost→accent gradient, inactive = muted accent.
#   • fastfetch key + logo colour — patched to the exact accent (truecolor) in the user's config.
# $1 = accent (#hex), $2 = frost (#hex)
apply_extras() {
    local a="$1" f="$2" aa ff
    [ -z "$a" ] && return
    aa=${a#\#}; ff=${f#\#}; [ -z "$ff" ] && ff="$aa"
    local hd="$HOME/.config/hypr/sea-shell"; mkdir -p "$hd"
    printf 'general {\n    col.active_border = rgba(%see) rgba(%see) 45deg\n    col.inactive_border = rgba(%s55)\n}\n' "$ff" "$aa" "$aa" > "$hd/matugen.conf"
    hyprctl keyword general:col.active_border "rgba(${ff}ee) rgba(${aa}ee) 45deg" >/dev/null 2>&1
    hyprctl keyword general:col.inactive_border "rgba(${aa}55)" >/dev/null 2>&1
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
import json, sys
cfg, col = sys.argv[1], sys.argv[2]
try: d = json.load(open(cfg))
except Exception: d = {"radius": 14, "opacity": 0.82, "height": 42, "font": "monospace"}
d["accent"] = col
json.dump(d, open(cfg, "w"))
PY
}

star="$HOME/.config/starship.toml"
sdef="$HOME/.config/sea-shell/starship-default.toml"

if [ "$1" = "--reset" ]; then
    set_accent "$DEFAULT"
    : > "$kitty"                       # empty → kitty falls back to sea-cyan.conf defaults
    : > "$HOME/.config/sea-shell/kitty-matugen-light.conf"   # clear the light variant too
    [ -f "$sdef" ] && cp "$sdef" "$star" 2>/dev/null   # restore the default sea prompt
    apply_extras "$DEFAULT" "#a2e2e8"                  # borders + fastfetch back to sea cyan
    reload_kitty
    notify-send 'sea-shell' 'Colours reset to sea cyan' 2>/dev/null
    exit 0
fi

wp="$1"
[ -z "$wp" ] && wp=$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null)
[ -z "$wp" ] && exit 1
case "$wp" in
    *.mp4|*.webm|*.mkv|*.mov|*.gif)
        f=/tmp/sea-matugen-frame.png
        ffmpeg -y -i "$wp" -vframes 1 "$f" >/dev/null 2>&1 && wp="$f" ;;
esac

# colour-scheme algorithm (picked in the control center) — default tonal-spot
scheme=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('scheme','scheme-tonal-spot'))" "$cfg" 2>/dev/null)
case "$scheme" in scheme-*) ;; *) scheme="scheme-tonal-spot" ;; esac
json=$(matugen --json hex --type "$scheme" --prefer saturation image "$wp" 2>/dev/null)
[ -z "$json" ] && exit 1
# stash the JSON in a temp file — stdin is taken by the heredoc program below
jf=$(mktemp) || exit 1
printf '%s' "$json" > "$jf"

# accent = Material `primary`; kitty ANSI palette = the base16 scheme (dark variant).
# prints "<accent> <frost>" on stdout so the shell can also recolour starship.
pal=$(python3 - "$cfg" "$kitty" "$DEFAULT" "$jf" <<'PY'
import json, sys
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
accent = pick(colors.get('primary')) or default

try: d = json.load(open(cfg))
except Exception: d = {"radius": 14, "opacity": 0.82, "height": 42, "font": "monospace"}
d["accent"] = accent
json.dump(d, open(cfg, "w"))

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
AH, ASAT, _AL = _hsl(accent)              # wallpaper accent HUE drives every tint

def kitty_rows(dark, opacity):
    # Background carries the wallpaper HUE at real saturation + enough lightness to actually
    # SEE the colour (a near-black bg reads the same for every wallpaper). Readability is kept
    # by a near-white/near-black foreground whose contrast is *enforced*, plus contrast-checked
    # ANSI — so a saturated bg is fine (white-on-teal, white-on-plum … all read clean).
    if dark:
        bg=H(AH, min(max(ASAT,0.28),0.55), 0.125); fg=readable(H(AH,0.08,0.94), bg, 9.0, True)
        c0=H(AH,0.32,0.24); c8=H(AH,0.22,0.44); c7=H(AH,0.09,0.83); c15=H(AH,0.05,0.98)
        nL,bL,S,up = 0.66, 0.76, 0.62, True
    else:
        bg=H(AH, min(max(ASAT,0.14),0.28), 0.955); fg=readable(H(AH,0.45,0.12), bg, 8.0, False)
        c0=H(AH,0.30,0.40); c8=H(AH,0.22,0.54); c7=H(AH,0.24,0.28); c15=H(AH,0.55,0.09)
        nL,bL,S,up = 0.44, 0.52, 0.70, False
    # ANSI hues nudged toward the accent (short-arc blend) so they carry the theme too, but not
    # so far they stop reading as red/green/blue. The "blue" slot IS the accent hue.
    def tint(h, amt=0.18):
        d=(AH-h+0.5)%1.0-0.5; return (h+d*amt)%1.0
    R,Y,G,Cy,Bl,M = tint(0.00), tint(0.12), tint(0.34), tint(0.50), AH, tint(0.83)
    def C(hue,l): return readable(H(hue,S,l), bg, 4.2, up)
    acc = readable(accent, bg, 3.0, up)                  # accent kept readable for cursor/borders
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
write_kitty(kitty, True, '0.92')
write_kitty((kitty[:-5] if kitty.endswith('.conf') else kitty) + '-light.conf', False, '0.94')
print(accent, lighten(accent))
PY
)
rm -f "$jf"

# starship — swap the sea accents (#63c7dd / #a2e2e8) for the wallpaper palette.
# Seed a pristine default once (deref the symlink), then always generate from it.
set -- $pal; accent="$1"; frost="$2"
[ -f "$sdef" ] || { [ -e "$star" ] && cp -L "$star" "$sdef" 2>/dev/null; }
if [ -f "$sdef" ] && [ -n "$accent" ] && [ -n "$frost" ]; then
    sed -e "s/#63c7dd/$accent/g" -e "s/#a2e2e8/$frost/g" "$sdef" > "$star.tmp" 2>/dev/null && mv "$star.tmp" "$star"
fi

# Hyprland borders + fastfetch follow the accent too
apply_extras "$accent" "$frost"

# if the shell is currently in light mode, refresh the live override too (kitty-mode.conf is a
# copy of the light palette that sea-apply-mode.sh makes on toggle — keep it current so a
# running light-mode kitty picks up the new colours without a re-toggle)
mode=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('mode','dark'))" "$cfg" 2>/dev/null)
[ "$mode" = "light" ] && cp "$HOME/.config/sea-shell/kitty-matugen-light.conf" "$HOME/.config/sea-shell/kitty-mode.conf" 2>/dev/null

reload_kitty
notify-send 'sea-shell' 'Colours matched to wallpaper 🎨' 2>/dev/null
