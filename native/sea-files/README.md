# sea-files

The rebuild of Files in Rust and GTK4. It runs alongside the old Python and QML Files, which stays the default until this one replaces it.

```sh
cargo build --release
./target/release/sea-files ~/Documents
cargo test --release
```

Layout follows Finder and Windows 11; colours and corners come from `~/.config/sea-shell/appearance.json` using the formulas in `Tok.qml`. Its menu is exported over `com.canonical.dbusmenu`, so the shell's global menu picks it up.

- `SEA_FILES_TRACE=1` prints listing and preview timings.
- `SEA_FILES_BENCH=1` scrolls the list top to bottom, prints frame times, then quits.
- `tests/virtual_pointer.py` drives a real mouse inside a nested Hyprland, for testing clicks and drags: `python3 tests/virtual_pointer.py move:400:155 click`.
