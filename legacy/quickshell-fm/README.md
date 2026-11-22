# Legacy PySide6 file manager (retired)

`sea-fm.py` and `FileManager.qml` were the original Super+E file manager. **sea-files** (Rust/GTK4 in `native/sea-files`) replaces them.

These files are kept for reference and for running old tests against the Python backend if needed. They are not installed or launched by sea-shell anymore.

To run the old stack manually (not supported):

```sh
cd legacy/quickshell-fm
python3 sea-fm.py   # expects FileManager.qml beside it
```
