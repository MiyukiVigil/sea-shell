# File-manager rework validation — 2026-10-29

## Delivered architecture

The installed file manager uses the release Rust core for filesystem scans,
recursive searches and large-file byte transfer. Python/QML remains the desktop
UI and operation-policy layer. This is a hybrid backend rework, not a claim that
all application code has been rewritten in Rust.

## Requirement evidence

| Requirement | Evidence |
| --- | --- |
| Rust backend integrated with UI | `native_core`, `DirectoryScanWorker`, `_native_copy`; native integration/cancellation tests; installed binary checksum matches release build |
| Reliable copy/move and undo | atomic temporary-file commit, metadata preservation, merge-safe directory records, symlink collision handling; file-operation and asynchronous undo tests |
| Cut and Ctrl+V | MIME action survives panes/windows; real QML keyboard smoke test moves data and creates a folder |
| Responsive browsing/search | cancellable native workers, stale-result rejection, batched UI enrichment; navigation and scan-cancellation tests |
| Media-folder responsiveness | instantiated delegates request thumbnails; 200-PDF listing test queues none until requested |
| Archives/restore/permissions | staged conflict-aware extraction, background archive index/preview/restore/permission workers; tests for selection expansion, traversal rejection, failed-cache cleanup, restore collisions and symlink targets |
| Visual refresh/features | light/dark render inspection, animated selection actions, styled empty-state action, loading/search feedback, corrected dialog input height and semantic colors |
| Installation | deployed Python, QML and Rust executable hashes match verified workspace files; installer builds with locked Cargo dependencies and preserves compatibility fallback |

## Checks completed

- `python3 -m unittest discover -s tests`: 33 passing tests, including real QML keyboard events.
- Cargo unit tests: two passing.
- Cargo Clippy with warnings denied: passing.
- Python compilation, installer shell syntax, `git diff --check`: passing.
- Installed QML interface loaded without warnings in the render checks.
- Installed light and dark visuals inspected; selected-file action bar rendered correctly.
- Desktop rendering test after imports, with warm QML cache: first frame 547 ms;
  4,000 rows ready at 1,203 ms; largest sampled event-loop gap 127 ms.
- Earlier empty-folder first-frame test including backend module import: 680 ms.

These checks establish this rework's behavior on the tested desktop. They do not
promise zero bugs, entirely Rust code, or constant performance on network/offline
mounts. Existing search depth/result limits remain unchanged. No user files were
used in destructive tests; fixtures lived in temporary directories.
