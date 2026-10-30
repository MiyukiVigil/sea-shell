# sea-fm-core

Rust filesystem core for the Qt Quick file manager. The UI and operation coordinator
remain in Python/QML; directory IO, recursive search and large-file data transfer
use this executable. It is not a complete Rust UI or a completed migration.

Build and check:

```sh
cargo build --release --locked --manifest-path native/sea-fm-core/Cargo.toml
cargo test --locked --manifest-path native/sea-fm-core/Cargo.toml
cargo clippy --locked --manifest-path native/sea-fm-core/Cargo.toml -- -D warnings
python3 -m unittest discover -s tests
```

The installer builds and installs the executable when Cargo is available. Without
it, browsing and copies retain the compatible Python implementation. The Python
coordinator looks beside itself first, then in this crate's release target folder.

## Protocol

- `scan PATH QUERY HIDDEN`: one JSON object containing `rows`, `error`, and
  `fallback`. Each row is `[name,path,is_directory,size,mtime_seconds]`.
  A nonempty query searches through depth three, caps results at 150, and never
  follows directory symlinks. `HIDDEN` is `1` or `0`. Non-UTF8 paths request the
  lossless Python fallback rather than silently changing filenames.
- `copy-data SOURCE TEMPORARY`: streams regular-file contents into an existing
  caller-owned temporary file. Writes JSON progress lines with cumulative `bytes`.
  It does not publish the final destination, remove the source, resolve conflicts,
  save metadata, or create undo records. Those actions remain with the coordinator.

Cancellation terminates the helper. The coordinator waits for it to exit before
removing the temporary file. Successful copies receive metadata and are renamed
into place only after completion. Small files bypass process launch overhead.

## Validation

Run the commands above for the Rust unit/static checks and Python integration suite.
Coverage includes native listings and cancellation, large-file copy integrity and
cancellation, queued completion, cut/copy MIME data across panes, keyboard Cut/Paste
and folder creation through the QML interface, navigation races, archive browsing,
archive conflicts and selected-folder extraction, restore collisions, symlink-safe
permissions, thumbnail scheduling, and asynchronous undo.

Measured after Python/Qt imports on this desktop with the installed build and
warm QML cache: first rendered frame in a generated 4,000-file folder at 547 ms; all 4,000 rows ready at
1,203 ms. Largest sampled event-loop gap was 127 ms. These are individual measurements,
not guarantees for slow disks, network mounts, cold caches or every folder type.

This is a hybrid rework: Rust handles directory IO/search and large-file data
transfer; Python coordinates Qt models, filesystem policy and operation history;
QML renders the interface. A missing native executable uses the compatibility path.
Existing recursive search limits (depth three and 150 results) are preserved.

## Interface rework

The QML interface now has Matugen-derived light/dark semantic colors, animated
selection actions, actionable empty/search states, loading feedback, and subtle
color/dialog transitions. Thumbnails are requested by instantiated delegates
instead of every row in a folder. Filesystem undo runs on the serialized operation
pool; completion returns to the UI thread before changing journal state.
