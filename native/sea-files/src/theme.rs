//! Colours, font and corner size follow Settings → Appearance, live. appearance.json is the same
//! file the bar reads, so Files changes with the rest of the desktop rather than after a restart.
use gtk::{gdk, gio, glib, prelude::*};
use std::rc::Rc;

fn config_path() -> std::path::PathBuf {
    glib::user_config_dir().join("sea-shell/appearance.json")
}

fn hex(c: (f64, f64, f64)) -> String {
    format!("#{:02x}{:02x}{:02x}", (c.0 * 255.0).round() as u8, (c.1 * 255.0).round() as u8, (c.2 * 255.0).round() as u8)
}

fn hsl(h: f64, s: f64, l: f64) -> (f64, f64, f64) {
    let f = |n: f64| {
        let k = (n + h * 12.0) % 12.0;
        l - s * l.min(1.0 - l) * (k - 3.0).min(9.0 - k).clamp(-1.0, 1.0)
    };
    (f(0.0), f(8.0), f(4.0))
}

fn hue_sat(rgb: gdk::RGBA) -> (f64, f64) {
    let (r, g, b) = (rgb.red() as f64, rgb.green() as f64, rgb.blue() as f64);
    let (max, min) = (r.max(g).max(b), r.min(g).min(b));
    let d = max - min;
    if d < 1e-6 {
        return (0.0, 0.0);
    }
    let l = (max + min) / 2.0;
    let s = d / (1.0 - (2.0 * l - 1.0).abs());
    let h = if max == r { ((g - b) / d).rem_euclid(6.0) } else if max == g { (b - r) / d + 2.0 } else { (r - g) / d + 4.0 };
    (h / 6.0, s)
}

/// Tok.qml's palette and shape scale, formula for formula, so Files sits beside Settings as one
/// thing. If the shell's tokens change, this is the other place to change them.
pub fn css(json: &serde_json::Value) -> (String, bool) {
    let light = json["mode"].as_str() == Some("light");
    let accent = gdk::RGBA::parse(json["accent"].as_str().unwrap_or("#63c7dd")).unwrap_or(gdk::RGBA::BLUE);
    let font = json["font"].as_str().filter(|f| !f.is_empty()).unwrap_or("sans-serif");
    let cfg = json["radius"].as_f64().unwrap_or(14.0);
    let (h, s) = hue_sat(accent);
    let achromatic = s < 0.06;
    let sm = if achromatic { 0.0 } else { 1.0 };
    let pick = |l: (f64, f64), d: (f64, f64)| {
        let (sat, lum) = if light { l } else { d };
        hsl(h, sat * sm, lum)
    };
    let sat = if achromatic { 0.0 } else if light { s.clamp(0.35, 0.95) } else { s.clamp(0.42, 0.95) };
    let acc = hex(hsl(h, sat, if light { 0.34 } else { 0.62 }));
    let acc_ink = if light { "#ffffff".to_string() } else { hex(hsl(h, 0.55 * sm, 0.07)) };
    let wash = hex(pick((0.34, 0.915), (0.40, 0.155)));
    let surface = hex(pick((0.09, 0.972), (0.13, 0.104)));
    let raised = hex(pick((0.10, 1.0), (0.12, 0.136)));
    let sunken = hex(pick((0.08, 0.898), (0.16, 0.046)));
    let ink_rgb = pick((0.16, 0.09), (0.08, 0.912));
    let ink = hex(ink_rgb);
    let ink2 = hex(pick((0.12, 0.31), (0.08, 0.68)));
    let ink3 = hex(pick((0.10, 0.52), (0.08, 0.492)));
    let tint = |a: f64| format!("rgba({},{},{},{a})", (ink_rgb.0 * 255.0) as u8, (ink_rgb.1 * 255.0) as u8, (ink_rgb.2 * 255.0) as u8);
    let (group, rule, hover, chip) = (tint(if light { 0.04 } else { 0.05 }), tint(0.075), tint(0.07), tint(0.06));
    let acc_soft = {
        let a = gdk::RGBA::parse(&acc).unwrap_or(gdk::RGBA::BLUE);
        format!("rgba({},{},{},.16)", (a.red() * 255.0) as u8, (a.green() * 255.0) as u8, (a.blue() * 255.0) as u8)
    };
    // Tok's scale stops short of what this window wants: Files is round first. Everything still
    // scales from the Appearance slider, so a user who likes square corners gets square corners.
    let panel = cfg.clamp(2.0, 30.0);
    let pill = cfg.clamp(2.0, 99.0);
    let r = (cfg * 0.75).clamp(2.0, 22.0);
    let r_small = (cfg * 0.5).clamp(2.0, 14.0);
    let tile_r = (cfg * 0.5).clamp(2.0, 11.0);
    // Settings tints each sidebar group by turning the accent's hue.
    let tile = |turn: f64| hex(hsl((h + turn).rem_euclid(1.0), if achromatic { 0.0 } else { 0.46 }, if light { 0.55 } else { 0.5 }));
    let (t0, t1, t2) = (tile(0.0), tile(0.09), tile(-0.09));
    let warn_wash = if light { "#f6ebd3" } else { "#33270d" };
    let crit = if light { "#ad2020" } else { "#f0706a" };
    (format!(r#"
window.sea {{ background: {surface}; color: {ink}; font-family: "{font}"; font-size: 13px; }}
.sym {{ font-family: "Material Symbols Outlined"; font-size: 18px; font-weight: normal; }}

/* sidebar: floats like everything else */
.sidebar {{ background: {group}; border: 1px solid {rule}; border-radius: {panel}px; padding: 12px 0; margin: 12px 0 12px 12px; }}
.sidebar .search {{ margin: 0 12px 6px 12px; background: {chip}; border: 1px solid {rule}; border-radius: {pill}px; min-height: 36px; padding: 0 6px; box-shadow: none; outline: none; color: {ink}; }}
.sidebar .search:focus-within {{ border-color: {acc}; }}
.sidebar list {{ background: transparent; }}
.sidebar row {{ border-radius: {pill}px; margin: 1px 10px; padding: 5px 8px; color: {ink}; min-height: 24px; background: transparent; outline: none; transition: background-color 130ms ease-out; }}
.sidebar row:hover {{ background: {hover}; }}
.sidebar row.active {{ background: {acc}; color: {acc_ink}; font-weight: 600; }}
.side-title {{ color: {ink3}; font-size: 11px; font-weight: 600; margin: 14px 22px 4px 22px; }}
.tile {{ border-radius: {tile_r}px; min-width: 24px; min-height: 24px; color: #ffffff; }}
.tile .sym {{ font-size: 15px; }}
.tile-0 {{ background: {t0}; }} .tile-1 {{ background: {t1}; }} .tile-2 {{ background: {t2}; }}
row.active .tile {{ box-shadow: inset 0 0 0 1px rgba(255,255,255,.55); }}

/* toolbar: round buttons and one long pill for the address */
.toolbar {{ padding: 12px 12px 6px 12px; }}
.toolbar button, .chip {{ background: transparent; border: none; box-shadow: none; outline: none; border-radius: {pill}px; min-height: 36px; min-width: 36px; padding: 0; color: {ink}; transition: background-color 130ms ease-out; }}
.toolbar button:hover {{ background: {hover}; }}
.toolbar button:disabled {{ color: {ink3}; opacity: .45; }}
.toolbar button.on {{ background: {wash}; color: {acc}; }}
.address {{ background: {chip}; border: 1px solid {rule}; border-radius: {pill}px; min-height: 36px; padding: 0 6px; }}
.address button {{ min-height: 28px; min-width: 0; padding: 0 10px; font-weight: 500; }}
.crumb-sep {{ color: {ink3}; font-size: 14px; }}
.path-entry {{ background: {chip}; border: 1px solid {acc}; border-radius: {pill}px; min-height: 36px; padding: 0 10px; box-shadow: none; outline: none; color: {ink}; }}

/* command row: pills, with words */
.commandbar {{ padding: 2px 12px 10px 12px; }}
.chip {{ background: {chip}; border: 1px solid {rule}; padding: 0 16px; font-weight: 500; }}
.chip:hover {{ background: {acc_soft}; }}
.chip:active {{ background: {acc_soft}; }}
.chip:disabled {{ color: {ink3}; opacity: .5; }}
.chip .sym {{ font-size: 17px; }}

/* floating panels */
.panel {{ background: {group}; border: 1px solid {rule}; border-radius: {panel}px; }}
.files {{ margin: 0 12px 0 12px; }}
.preview {{ margin: 0 12px 0 0; }}
paned > separator {{ background: transparent; min-width: 1px; border: none; box-shadow: none; }}
columnview, gridview, columnview > listview {{ background: transparent; color: {ink}; }}
columnview > header {{ background: transparent; border: none; box-shadow: none; }}
columnview > header button {{ background: transparent; border: none; box-shadow: none; outline: none; color: {ink2}; font-size: 11px; font-weight: 600; padding: 10px 8px 6px 8px; min-height: 0; }}
columnview > header button:hover {{ color: {ink}; }}
columnview > listview > row {{ border-radius: {pill}px; margin: 1px 0; min-height: 34px; background: transparent; outline: none; transition: background-color 90ms ease-out; }}
columnview > listview > row > cell {{ padding: 0 10px; }}
columnview > listview > row:hover {{ background: {hover}; }}
columnview > listview > row:selected, gridview > child:selected {{ background: {wash}; color: {ink}; }}
columnview > listview:focus-within > row:selected, gridview:focus-within > child:selected {{ background: {acc}; color: {acc_ink}; }}
gridview {{ padding: 10px; }}
gridview > child {{ border-radius: {r}px; padding: 12px 8px; margin: 3px; background: transparent; outline: none; transition: background-color 90ms ease-out; }}
gridview > child:hover {{ background: {hover}; }}
gridview > child image {{ border-radius: {r_small}px; }}
.dim {{ color: {ink2}; }}
row:selected .dim, child:selected .dim {{ color: inherit; opacity: .8; }}
.preview-title {{ font-size: 15px; font-weight: 600; }}
.preview-text {{ font-family: "JetBrains Mono", monospace; font-size: 11px; color: {ink2}; }}
.preview-picture {{ border-radius: {r}px; }}
.statusbar {{ padding: 8px 22px 12px 22px; color: {ink3}; font-size: 11px; }}
.dialog {{ background: {raised}; }}
.dialog entry {{ background: {sunken}; border: 1px solid {rule}; border-radius: {pill}px; min-height: 36px; padding: 0 10px; box-shadow: none; outline: none; color: {ink}; }}
.dialog entry:focus-within {{ border-color: {acc}; }}
scrollbar {{ background: transparent; border: none; }}
scrollbar slider {{ background: {hover}; border-radius: 99px; min-width: 6px; min-height: 6px; margin: 2px; border: none; }}
scrollbar slider:hover {{ background: {ink3}; }}
tooltip, tooltip.background {{ background: {raised}; color: {ink}; border-radius: {r}px; border: 1px solid {rule}; }}
rubberband {{ background: {acc_soft}; border: 1px solid {acc}; border-radius: {r_small}px; }}

/* right-click menu: a floating rounded card of pills */
popover.menu > contents, popover > contents {{ background: {raised}; border: 1px solid {rule}; border-radius: {panel}px; padding: 0; box-shadow: 0 8px 28px rgba(0,0,0,.24); color: {ink}; }}
popover.menu box.inline-buttons, popover.menu stack {{ padding: 0; }}
popover.menu modelbutton {{ border-radius: {pill}px; min-height: 30px; padding: 0 14px; margin: 1px 8px; color: {ink}; outline: none; }}
popover.menu modelbutton:hover, popover.menu modelbutton:focus-visible {{ background: {acc}; color: {acc_ink}; }}
popover.menu modelbutton:disabled {{ color: {ink3}; }}
popover.menu modelbutton accelerator {{ color: {ink3}; margin-left: 24px; }}
popover.menu modelbutton:hover accelerator {{ color: {acc_ink}; }}
popover.menu separator {{ background: {rule}; margin: 5px 12px; min-height: 1px; }}

/* round things */
button.round {{ background: transparent; border: none; box-shadow: none; outline: none; border-radius: 99px; min-width: 34px; min-height: 34px; padding: 0; color: {ink}; }}
button.round:hover {{ background: {hover}; }}
button.play-big {{ background: {acc}; color: {acc_ink}; border: none; box-shadow: 0 4px 16px rgba(0,0,0,.3); border-radius: 99px; min-width: 60px; min-height: 60px; padding: 0; }}
button.play-big .sym {{ font-size: 32px; }}
.player {{ background: {chip}; border: 1px solid {rule}; border-radius: {pill}px; padding: 3px 12px 3px 4px; }}
scale trough {{ background: {hover}; border-radius: 99px; min-height: 6px; border: none; }}
scale highlight {{ background: {acc}; border-radius: 99px; border: none; }}
scale slider {{ background: {raised}; border: 2px solid {acc}; border-radius: 99px; min-width: 16px; min-height: 16px; margin: -6px; box-shadow: none; }}
.quicklook {{ background: {surface}; }}
.quicklook .preview-text {{ font-size: 14px; color: {ink}; }}
.quicklook .pdf-page {{ border-radius: {r_small}px; box-shadow: 0 1px 6px rgba(0,0,0,.18); background: #ffffff; }}

/* tabs: a row of pills, only there once there's a second tab */
.tabstrip {{ padding: 12px 12px 0 12px; }}
.tab {{ background: {chip}; border: 1px solid {rule}; border-radius: {pill}px; min-height: 30px; padding: 0 4px 0 14px; }}
.tab:hover {{ background: {hover}; }}
.tab.current {{ background: {acc}; color: {acc_ink}; border-color: {acc}; font-weight: 600; }}
.tab button.round {{ min-width: 24px; min-height: 24px; color: inherit; }}
.tab button.round .sym {{ font-size: 14px; }}
.tabstrip > button.round {{ min-width: 32px; min-height: 32px; }}
.pane-dim .toolbar, .pane-dim .commandbar {{ opacity: .5; }}
.drive-eject {{ min-width: 24px; min-height: 24px; }}
.drive-eject .sym {{ font-size: 15px; }}

/* copies in progress */
.jobs {{ margin: 8px 12px 0 12px; }}
.job {{ background: {group}; border: 1px solid {rule}; border-radius: {panel}px; padding: 8px 8px 8px 16px; }}
.job-title {{ font-weight: 600; }}
progressbar trough {{ background: {hover}; border-radius: 99px; min-height: 6px; border: none; }}
progressbar progress {{ background: {acc}; border-radius: 99px; min-height: 6px; border: none; }}

/* the note above the files */
.banner {{ background: {wash}; border: 1px solid {rule}; border-radius: {pill}px; margin: 0 12px 10px 12px; padding: 4px 4px 4px 16px; }}
.banner.admin {{ background: {warn_wash}; }}
.banner button {{ background: {acc}; color: {acc_ink}; border: none; box-shadow: none; border-radius: {pill}px; min-height: 30px; padding: 0 16px; font-weight: 600; }}

/* preferences and dialogs */
.pref-page {{ padding: 8px 18px 22px 18px; }}
.pref-head {{ font-weight: 700; margin: 14px 8px 2px 8px; }}
.pref-panel {{ padding: 4px 0; }}
.pref-row {{ padding: 10px 16px; min-height: 34px; }}
.small {{ font-size: 11px; }}
switch {{ background: {hover}; border: none; border-radius: 99px; min-width: 44px; min-height: 24px; box-shadow: none; outline: none; }}
switch:checked {{ background: {acc}; }}
switch slider {{ background: {raised}; border-radius: 99px; min-width: 18px; min-height: 18px; margin: 3px; border: none; box-shadow: 0 1px 3px rgba(0,0,0,.25); }}
button.pill-choice {{ background: {chip}; border: 1px solid {rule}; box-shadow: none; outline: none; border-radius: {pill}px; min-height: 30px; padding: 0 14px; color: {ink}; font-weight: 500; }}
button.pill-choice:hover {{ background: {acc_soft}; }}
button.pill-choice:checked {{ background: {acc}; color: {acc_ink}; border-color: {acc}; }}
button.swatch {{ border: 1px solid {rule}; box-shadow: none; outline: none; border-radius: 99px; min-width: 24px; min-height: 24px; padding: 0; }}
dropdown > button {{ background: {chip}; border: 1px solid {rule}; box-shadow: none; outline: none; border-radius: {pill}px; min-height: 30px; padding: 0 14px; color: {ink}; }}
.dialog-body {{ padding: 20px; }}
.dialog-title {{ font-size: 15px; font-weight: 600; }}
button.danger {{ background: {crit}; color: #ffffff; border: none; box-shadow: none; outline: none; border-radius: {pill}px; min-height: 34px; padding: 0 18px; font-weight: 600; }}
button.accent {{ background: {acc}; color: {acc_ink}; border: none; box-shadow: none; outline: none; border-radius: {pill}px; min-height: 34px; padding: 0 18px; font-weight: 600; }}
.dialog passwordentry {{ background: {sunken}; border: 1px solid {rule}; border-radius: {pill}px; min-height: 36px; padding: 0 12px; box-shadow: none; outline: none; color: {ink}; }}
.dialog passwordentry:focus-within {{ border-color: {acc}; }}
button.plain {{ background: {chip}; border: 1px solid {rule}; box-shadow: none; outline: none; border-radius: {pill}px; min-height: 34px; padding: 0 18px; color: {ink}; }}
"#), light)
}

thread_local! {
    static REAPPLY: std::cell::RefCell<Option<Rc<dyn Fn()>>> = const { std::cell::RefCell::new(None) };
}

/// Preferences changed. Files can have its own colours, set in Preferences as the old Files could.
pub fn reapply() {
    if let Some(f) = REAPPLY.with(|r| r.borrow().clone()) {
        f();
    }
}

pub fn install() {
    let Some(display) = gdk::Display::default() else { return };
    let provider = gtk::CssProvider::new();
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_USER);
    let apply: Rc<dyn Fn()> = Rc::new(move || {
        let mut json: serde_json::Value = std::fs::read_to_string(config_path())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(serde_json::Value::Null);
        if crate::prefs::str_of("themeSource", "shell") == "own" {
            json["mode"] = crate::prefs::str_of("ownMode", "light").into();
            json["accent"] = crate::prefs::str_of("ownAccent", "#535a92").into();
            json["radius"] = crate::prefs::int_of("ownRadius", 24).into();
        }
        let (text, light) = css(&json);
        provider.load_from_string(&text);
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_interface_color_scheme(if light { gtk::InterfaceColorScheme::Light } else { gtk::InterfaceColorScheme::Dark });
            let own = crate::prefs::str_of("iconTheme", "");
            let icons = if own.is_empty() { json["iconTheme"].as_str().unwrap_or("").to_string() } else { own };
            if !icons.is_empty() {
                settings.set_gtk_icon_theme_name(Some(&icons));
            }
        }
    });
    apply();
    REAPPLY.with(|r| *r.borrow_mut() = Some(apply.clone()));
    let file = gio::File::for_path(config_path());
    if let Ok(monitor) = file.monitor_file(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE) {
        monitor.connect_changed(move |_, _, _, _| apply());
        // Lives as long as the app: dropping the monitor would quietly stop the following.
        std::mem::forget(monitor);
    }
}
