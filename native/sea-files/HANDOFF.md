# sea-files handoff

Last updated 3 Nov 2026 (final pass). **Agent note:** work in this chat uses the main Cursor model only — no paid third-party/subagent models unless you explicitly enable them in Cursor settings.

## Current state

**sea-files** is the only supported file manager for sea-shell. Super+E, the global menu, and `sea-files-launch.sh` require a built binary at `~/.config/quickshell/sea-shell/sea-files` (from `./install.sh`).

Legacy PySide6 `sea-fm.py` + `FileManager.qml` live under `legacy/quickshell-fm/` for reference only.

```sh
cd native/sea-files && cargo build --release && cargo test --release
install -m 755 target/release/sea-files ~/.config/quickshell/sea-shell/sea-files
install -m 755 ../../quickshell/scripts/system/sea-files-launch.sh ~/.config/quickshell/sea-shell/
# Optional hardened pkexec target (run once with sudo):
# sudo install -m 755 target/release/sea-files /usr/libexec/sea-shell/sea-files
```

## Checklist

### Done

- [x] Core FM, archives, trash, undo/redo, Quick Look, split, tabs, root helper, DBus menu + FileManager1
- [x] Subfolder search, thumbnails, session tabs/size, favourites/recent/starred/tags, duplicates, batch rename, KDE Connect
- [x] `raise_or_open` + **Unix socket handover** (`$XDG_RUNTIME_DIR/sea-files.sock`)
- [x] Permission editing, tag undo, history menus, column visibility toggles
- [x] Inline list rename, tab reorder, sidebar drops, group-by
- [x] **Keep warm** — hide on close, reopen, 20 min idle quit, File → Quit
- [x] **Columns picker** — toolbar / View menu / background “Choose Columns…” popover (+ quick toggles)
- [x] **Retired Python FM** — moved to `legacy/quickshell-fm/`; launch via `sea-files-launch.sh`
- [x] `resident.rs`, CHANGELOG/install/keybinds/GlobalMenu/register-files updated

### Still open

- [ ] **Split `window.rs`** (~5k lines) — attempted; reverted to monolith until module boundaries are cleaned up
- [ ] Git commit of sea-shell WIP (you only — agents must not commit)

## Testing rules (do not skip)

1. **Never test on the real desktop** without nested compositor check:
   ```sh
   hyprctl monitors -j | python3 -c "import json,sys;m=json.load(sys.stdin);sys.exit(0 if len(m)==1 and m[0]['name'].startswith('WAYLAND-') else 1)" || exit 1
   ```
2. **No full-screen grabs** of the real desktop.
3. **No cancelling real pkexec** in tests — use `SEA_FILES_NO_PKEXEC=1`.
4. **No audible sound** in bench tests.
5. Point `HOME`, `XDG_*` at scratch; copy `appearance.json` + `fm_prefs.json` as needed.
6. Kill bench by env marker, not `qs kill`.
7. `SEA_FILES_BENCH=1` / `SEA_FILES_TRACE=1` for perf logs.

## Code map

| Module | Role |
|--------|------|
| `handover.rs` | Pre-GTK socket delegate + listener |
| `resident.rs` | Hide-on-close, idle quit, File → Quit |
| `window.rs` | UI monolith (split deferred) |
| `tags.rs`, `duplicates.rs`, `stars.rs`, … | Features |
| `root.rs` | pkexec helper |

## User rules

No git commits from agents. No AI attribution in commits. sea-shell visual language (rounded, Material Symbols).
