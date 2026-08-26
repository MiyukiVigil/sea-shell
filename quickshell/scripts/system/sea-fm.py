#!/usr/bin/env python3
"""
sea-fm.py — Ultra-Fast, Zero-Lag Native File Manager for sea-shell.
Features:
- Instant native Qt Quick application with direct Wayland/X11 keyboard focus
- Instant live search (<2ms) across current directory and subdirectories
- Zero-lag file selection (<5ms) with asynchronous background media inspection & PDF rendering
- Multi-page 300 DPI ultra-HD PDF document rendering (PyMuPDF / fitz)
- Live in-app video & audio preview player with ffprobe metadata
- Python-docx word document extraction
- Pygments syntax-highlighted code viewer
- Zip / Unzip / Tar archive compression & extraction
- Robust clipboard (Ctrl+C, Ctrl+X, Ctrl+V) with native Wayland wl-copy/wl-paste sync and auto-naming
- Dynamic Light & Dark Mode switching synchronized with sea-shell appearance.json
"""

import sys
import os
import glob
import shutil
import subprocess
import json
import time
import hashlib
import stat
import re
import threading
import colorsys
import datetime
from urllib.parse import quote, unquote
import mimetypes
import zipfile
import tarfile
from pathlib import Path

# PySide6 Qt imports
from PySide6.QtCore import (
    QObject, Slot, Property, Signal, QUrl, QThread, QRunnable, QThreadPool,
    QAbstractListModel, QModelIndex, QByteArray, QMimeDatabase,
    Qt, QStandardPaths, QFileInfo, QDateTime, QFileSystemWatcher, QMimeData, QPoint,
    QTimer, QProcess, QSocketNotifier
)
from PySide6.QtGui import (
    QIcon, QKeySequence, QAction, QColor, QFont, QClipboard,
    QDrag, QPixmap, QPainter
)
from PySide6.QtWidgets import QApplication
from PySide6.QtQml import QQmlApplicationEngine, QQmlContext
from PySide6.QtQuick import QQuickWindow, QQuickImageProvider

# The window's menu bar, published over DBus for sea-shell's global menu strip.
# Optional on purpose: it needs python-gobject, and a file manager that refuses to
# start because a panel integration is missing would be a bad trade.
try:
    from sea_fm_menu import AppMenu
except Exception:
    AppMenu = None

# Lazy-loaded modules cache
_LAZY_MODULES = {}

def get_fitz():
    if "fitz" not in _LAZY_MODULES:
        try:
            import fitz
            _LAZY_MODULES["fitz"] = fitz
        except ImportError:
            _LAZY_MODULES["fitz"] = None
    return _LAZY_MODULES["fitz"]

def get_docx():
    if "docx" not in _LAZY_MODULES:
        try:
            import docx
            _LAZY_MODULES["docx"] = docx
        except ImportError:
            _LAZY_MODULES["docx"] = None
    return _LAZY_MODULES["docx"]

def get_pygments():
    if "pygments" not in _LAZY_MODULES:
        try:
            import pygments
            from pygments.lexers import get_lexer_for_filename, TextLexer
            from pygments.formatters import HtmlFormatter
            _LAZY_MODULES["pygments"] = (pygments, get_lexer_for_filename, TextLexer, HtmlFormatter)
        except ImportError:
            _LAZY_MODULES["pygments"] = None
    return _LAZY_MODULES["pygments"]

def get_pil():
    if "PIL" not in _LAZY_MODULES:
        try:
            from PIL import Image
            _LAZY_MODULES["PIL"] = Image
        except ImportError:
            _LAZY_MODULES["PIL"] = None
    return _LAZY_MODULES["PIL"]

CONFIG_DIR = Path.home() / ".config" / "sea-shell"
APPEARANCE_FILE = CONFIG_DIR / "appearance.json"
BOOKMARKS_FILE = CONFIG_DIR / "fm_bookmarks.json"
VIEWSTATE_FILE = CONFIG_DIR / "fm_viewstate.json"
TAGS_FILE = CONFIG_DIR / "fm_tags.json"
PREVIEW_CACHE_DIR = Path.home() / ".cache" / "sea-fm" / "thumbnails"
VIDEO_THUMB_PX = 640
PDF_THUMB_DPI = 110      # grid icon and the first inspector frame
PDF_PAGE_DPI = 300       # the page viewer, where you actually read it

# LibreOffice needs a profile of its own, or converting while the user has a
# document open either fails or hijacks their running instance.
LO_PROFILE_DIR = Path.home() / ".cache" / "sea-fm" / "lo-profile"

# freedesktop.org trash spec: the file goes in files/, and a sibling .trashinfo in
# info/ records where it came from. Without that second half nothing can be restored,
# which is the difference between a trash can and a slow delete.
TRASH_ROOT = Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share")) / "Trash"
TRASH_FILES = TRASH_ROOT / "files"
TRASH_INFO = TRASH_ROOT / "info"


# TRASH IS PER-VOLUME, AND PRETENDING OTHERWISE COSTS MORE THAN IT LOOKS.
#
# Everything used to go to the home trash. Deleting a 4 GB file from a USB stick
# therefore COPIED it across to the internal disk, slowly, and failed outright if
# home was full or read-only. Worse, `gio trash` gets this right, so a file
# trashed from a drive landed in that drive's own trash while _trash_record_for
# only ever searched the home one — it found nothing, the item was quietly left
# off the undo stack, and "Undo" restored everything except that file.
#
# The spec puts a volume's trash at the top of the volume: $topdir/.Trash/$uid
# when an administrator has made one with the sticky bit set, and $topdir/.Trash-$uid
# otherwise. Paths recorded there are RELATIVE to the volume, so the trash still
# resolves after the drive is mounted somewhere else — which is the point of the
# rule and the reason the absolute path this used to write everywhere was wrong.

def _topdir_for(path):
    """The mount point of the filesystem this path lives on."""
    p = Path(path)
    p = p if p.is_dir() else p.parent
    try:
        p = p.resolve()
    except OSError:
        pass
    while p != p.parent and not os.path.ismount(str(p)):
        p = p.parent
    return p


def _trash_home_top():
    return _topdir_for(Path.home())


def _trash_dirs_for(path):
    """(files, info, topdir) for the trash this path belongs in.

    topdir is None for the home trash, where absolute paths are recorded.
    """
    top = _topdir_for(path)
    if top == _trash_home_top():
        return TRASH_FILES, TRASH_INFO, None
    uid = os.getuid()
    admin = top / ".Trash"
    try:
        if admin.is_dir() and not admin.is_symlink():
            if admin.stat().st_mode & stat.S_ISVTX:
                base = admin / str(uid)
                return base / "files", base / "info", top
    except OSError:
        pass
    base = top / f".Trash-{uid}"
    return base / "files", base / "info", top


def _all_trash_dirs():
    """Every trash this user can see: home first, then one per mounted volume.

    Browsing "Trash" has to show all of them or the file you just deleted from a
    drive is simply missing from the place it says deleted files go.
    """
    out = [(TRASH_FILES, TRASH_INFO, None)]
    seen = {str(TRASH_FILES)}
    try:
        for dev in scan_block_devices():
            mount = dev.get("path") or ""
            if not mount or not os.path.isdir(mount):
                continue
            files, info, top = _trash_dirs_for(mount)
            if str(files) in seen or not files.is_dir():
                continue
            seen.add(str(files))
            out.append((files, info, top))
    except Exception:
        pass
    return out
DOC_PREVIEW_EXTS = (".docx", ".doc", ".odt", ".rtf",
                    ".pptx", ".ppt", ".odp",
                    ".xlsx", ".xls", ".ods")


def video_thumb_path(digest):
    return PREVIEW_CACHE_DIR / f"vid{VIDEO_THUMB_PX}_{digest}.png"


def pdf_thumb_path(digest):
    return PREVIEW_CACHE_DIR / f"pdfthumb{PDF_THUMB_DPI}_{digest}.png"


def pdf_page_path(digest, index):
    return PREVIEW_CACHE_DIR / f"pdfpg{PDF_PAGE_DPI}_{digest}_p{index}.png"

PREVIEW_CACHE_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_DIR.mkdir(parents=True, exist_ok=True)


class ThumbnailWorker(QRunnable):
    """Background task to generate video/pdf thumbnails without blocking the UI thread.

    CARRIES THE GENERATION IT WAS QUEUED IN. Opening a folder of four hundred
    videos queues four hundred ffmpegthumbnailer runs three at a time; walking
    straight through into another folder used to leave every one of them to run
    anyway, so navigating quickly buried the pool in work for folders nobody was
    looking at any more. A worker from a superseded generation now stops before
    it spends anything.
    """
    def __init__(self, file_path, category, backend, gen=None):
        super().__init__()
        self.file_path = Path(file_path)
        self.category = category
        self.backend = backend
        self.gen = backend._thumb_gen if gen is None else gen

    def _stale(self):
        return self.backend._thumb_gen != self.gen

    def run(self):
        try:
            if self._stale() or not self.file_path.exists():
                return
            h = hashlib.md5(f"{self.file_path.resolve()}_{self.file_path.stat().st_mtime}".encode()).hexdigest()

            if self.category == "video":
                thumb = video_thumb_path(h)
                if not thumb.exists():
                    res = subprocess.run(["ffmpegthumbnailer", "-i", str(self.file_path),
                                          "-o", str(thumb), "-s", str(VIDEO_THUMB_PX)],
                                         capture_output=True)
                    if res.returncode != 0:
                        subprocess.run(["ffmpeg", "-y", "-ss", "00:00:01", "-i", str(self.file_path),
                                        "-vframes", "1", "-q:v", "2",
                                        "-vf", f"scale='min({VIDEO_THUMB_PX},iw)':-2",
                                        str(thumb)], capture_output=True)
                if thumb.exists() and not self._stale():
                    self.backend.thumbnailReady.emit(str(self.file_path), str(thumb))

            elif self.category == "pdf":
                thumb = pdf_thumb_path(h)
                if not thumb.exists():
                    fitz = get_fitz()
                    if fitz:
                        doc = fitz.open(self.file_path)
                        if len(doc) > 0:
                            page = doc.load_page(0)
                            pix = page.get_pixmap(dpi=PDF_THUMB_DPI, alpha=False)
                            pix.save(str(thumb))
                        doc.close()
                if thumb.exists() and not self._stale():
                    self.backend.thumbnailReady.emit(str(self.file_path), str(thumb))
        except Exception:
            pass


class MediaInfoWorker(QRunnable):
    """Background task to extract ffprobe metadata without freezing UI."""
    def __init__(self, file_path, backend):
        super().__init__()
        self.file_path = Path(file_path)
        self.backend = backend

    def run(self):
        try:
            res = subprocess.run([
                "ffprobe", "-v", "error", "-show_entries",
                "format=duration,bit_rate:stream=width,height,codec_name,sample_rate",
                "-of", "json", str(self.file_path)
            ], capture_output=True, text=True)
            if res.returncode == 0:
                info = json.loads(res.stdout)
                self.backend.mediaInfoReady.emit(str(self.file_path), info)
        except Exception:
            pass


class PdfPagesWorker(QRunnable):
    """Background task to render multi-page PDFs at 300 DPI without freezing UI."""
    def __init__(self, file_path, max_pages, backend):
        super().__init__()
        self.file_path = Path(file_path)
        self.max_pages = max_pages
        self.backend = backend

    def run(self):
        try:
            fitz = get_fitz()
            if not fitz or not self.file_path.exists():
                return
            h = hashlib.md5(f"{self.file_path.resolve()}_{self.file_path.stat().st_mtime}".encode()).hexdigest()
            doc = fitz.open(self.file_path)
            page_count = len(doc)
            page_paths = []

            for page_idx in range(min(self.max_pages, page_count)):
                thumb = pdf_page_path(h, page_idx)
                if not thumb.exists():
                    page = doc.load_page(page_idx)
                    pix = page.get_pixmap(dpi=PDF_PAGE_DPI, alpha=False)
                    pix.save(str(thumb))
                if thumb.exists():
                    page_paths.append(str(thumb))
                # PUBLISHED AS THEY LAND. Rendering thirty pages at 300 DPI takes
                # seconds; holding them all back until the last one meant a long
                # document showed nothing for that whole time. The first page is
                # usually ready almost at once, and the viewer can open on it
                # while the rest continue behind.
                if page_idx == 0 or (page_idx + 1) % 4 == 0:
                    self.backend.pdfPagesReady.emit(str(self.file_path),
                                                    list(page_paths))

            doc.close()
            self.backend.pdfPagesReady.emit(str(self.file_path), page_paths)
        except Exception:
            pass


# OFFICE DOCUMENTS CARRY THEIR OWN PICTURE, AND IT IS FREE.
#
# Every OpenDocument file is required by the spec to contain
# Thumbnails/thumbnail.png, and OOXML files usually carry docProps/thumbnail.*
# because Word and PowerPoint write one on save. Both are just entries in a zip,
# so getting one costs a zip read — a few milliseconds — against the second or
# more it takes LibreOffice to start, convert to PDF and render a page.
#
# So the panel shows that first and converts afterwards. The conversion still
# happens, because the embedded thumbnail is one small image and the page viewer
# wants real pages, but nobody waits on it to see what the document is.
EMBEDDED_THUMB_NAMES = (
    "Thumbnails/thumbnail.png",          # OpenDocument, mandatory
    "docProps/thumbnail.jpeg",           # OOXML, when the app saved one
    "docProps/thumbnail.jpg",
    "docProps/thumbnail.png",
)


def embedded_thumbnail(path, digest):
    """The document's own preview image, pulled straight out of the container."""
    out = PREVIEW_CACHE_DIR / f"emb_{digest}.png"
    if out.exists():
        return str(out)
    try:
        with zipfile.ZipFile(path) as zf:
            names = set(zf.namelist())
            pick = next((n for n in EMBEDDED_THUMB_NAMES if n in names), None)
            if pick is None:
                # Some producers vary the case or the folder; look a little harder
                # before giving up, but only among things plainly named thumbnail.
                pick = next((n for n in sorted(names)
                             if "thumbnail" in n.lower()
                             and n.lower().endswith((".png", ".jpg", ".jpeg"))), None)
            if pick is None:
                return ""
            data = zf.read(pick)
    except Exception:
        return ""
    if not data:
        return ""
    # EMF is a vector format Qt will not load; anything it cannot decode simply
    # is not a thumbnail as far as we are concerned.
    img = QPixmap()
    if not img.loadFromData(data):
        return ""
    try:
        img.save(str(out), "PNG")
    except Exception:
        return ""
    return str(out)


class DocPreviewWorker(QRunnable):
    """Office documents rendered to page images by way of LibreOffice.

    On demand only. soffice costs a second or two and a whole process to start,
    so converting every document in a folder the moment it is listed would be a
    far worse trade than a preview that arrives shortly after you ask for it.
    Once rendered it is cached, and the listing picks the thumbnail up from there.
    """

    def __init__(self, file_path, max_pages, backend, token=None):
        super().__init__()
        self.file_path = Path(file_path)
        self.max_pages = max_pages
        self.backend = backend
        self.token = token

    def _gave_up(self):
        """Say so, rather than leaving the panel waiting for pages forever.

        Without this, a document LibreOffice cannot convert -- or a machine with
        no soffice on it at all -- left the preview showing "Rendering pages" and
        nothing else, because the only way out of that state was pages arriving.
        """
        if self.token is not None:
            self.backend.previewDetailReady.emit(
                str(self.file_path), self.token, {"renderPending": False})

    def _to_pdf(self, digest):
        pdf = PREVIEW_CACHE_DIR / f"doc_{digest}.pdf"
        if pdf.exists():
            return pdf
        outdir = PREVIEW_CACHE_DIR / f"doc_{digest}_out"
        try:
            outdir.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["soffice", f"-env:UserInstallation=file://{LO_PROFILE_DIR}",
                 "--headless", "--norestore", "--nolockcheck",
                 "--convert-to", "pdf", "--outdir", str(outdir), str(self.file_path)],
                capture_output=True, timeout=180)
            made = sorted(outdir.glob("*.pdf"))
            if made:
                made[0].replace(pdf)
        except Exception:
            pass
        finally:
            shutil.rmtree(outdir, ignore_errors=True)
        return pdf if pdf.exists() else None

    def run(self):
        try:
            if not self.file_path.exists():
                self._gave_up()
                return
            digest = hashlib.md5(
                f"{self.file_path.resolve()}_{self.file_path.stat().st_mtime}".encode()).hexdigest()

            thumb = pdf_thumb_path(digest)
            if not thumb.exists():
                pdf = self._to_pdf(digest)
                if pdf is None:
                    self._gave_up()
                    return
                fitz = get_fitz()
                if not fitz:
                    self._gave_up()
                    return
                doc = fitz.open(pdf)
                try:
                    if len(doc) == 0:
                        self._gave_up()
                        return
                    doc.load_page(0).get_pixmap(dpi=PDF_THUMB_DPI, alpha=False).save(str(thumb))
                    # The panel gets its picture here, before the remaining pages
                    # are rendered at full resolution.
                    self.backend.thumbnailReady.emit(str(self.file_path), str(thumb))
                    ready = []
                    for idx in range(min(self.max_pages, len(doc))):
                        out = pdf_page_path(digest, idx)
                        if not out.exists():
                            doc.load_page(idx).get_pixmap(
                                dpi=PDF_PAGE_DPI, alpha=False).save(str(out))
                        ready.append(str(out))
                        if idx == 0 or (idx + 1) % 4 == 0:
                            self.backend.pdfPagesReady.emit(str(self.file_path),
                                                            list(ready))
                finally:
                    doc.close()

            pages = []
            for idx in range(self.max_pages):
                q = pdf_page_path(digest, idx)
                if not q.exists():
                    break
                pages.append(str(q))

            if thumb.exists():
                self.backend.thumbnailReady.emit(str(self.file_path), str(thumb))
            if pages:
                self.backend.pdfPagesReady.emit(str(self.file_path), pages)
        except Exception:
            pass


# =====================================================================
# UNDO
# =====================================================================
#
# WHAT IS AND IS NOT UNDOABLE, AND WHY THE LINE IS THERE.
#
# Every operation that moves or creates a file records how to reverse itself.
# Permanent deletion does not, and must never appear to: an "Undo" that cannot
# actually undo is worse than no undo at all, because the offer is what stops
# you thinking twice. So Shift+Delete and Empty Trash clear nothing and record
# nothing — the stack keeps whatever was there before, and the label keeps
# describing that older operation rather than lying about this one.
#
# Reversing a COPY means trashing the copies, not deleting them. Undo is allowed
# to be wrong about what you wanted; it is not allowed to be the operation that
# loses the file. Everything undo destroys is itself recoverable.
#
# The stack is process-wide rather than per-pane. Two panes are two views of one
# file system, and an undo that only reached the half of the window you happened
# to be looking at would be a coin toss.

class UndoJournal(QObject):
    changed = Signal()

    LIMIT = 40

    def __init__(self, parent=None):
        super().__init__(parent)
        self._stack = []

    # ---- reading ----

    @Property(bool, notify=changed)
    def canUndo(self):
        return len(self._stack) > 0

    @Property(int, notify=changed)
    def depth(self):
        return len(self._stack)

    @Property(str, notify=changed)
    def label(self):
        """What the next undo would reverse, in the words the menu shows."""
        if not self._stack:
            return ""
        top = self._stack[-1]
        n = len(top["items"])
        return top["verb"] if n == 1 else f"{top['verb']} ({n} items)"

    # ---- writing ----

    def record(self, kind, verb, items):
        if not items:
            return
        self._stack.append({"kind": kind, "verb": verb, "items": items})
        del self._stack[:-self.LIMIT]
        self.changed.emit()

    @Slot()
    def clear(self):
        self._stack = []
        self.changed.emit()

    # ---- reversing ----

    @Slot(result=str)
    def undo(self):
        """Reverse the newest operation. Returns a line for the status bar.

        A partial failure still pops: the entry has been applied as far as it can
        be, and leaving it on the stack would offer to do the recoverable half a
        second time.
        """
        if not self._stack:
            return "Nothing to undo"
        top = self._stack.pop()
        self.changed.emit()
        done, failed = 0, []
        if top["kind"] == "rename":
            # Renames reverse as a SET, not one at a time — see _reverse_renames.
            try:
                done = self._reverse_renames(top["items"])
            except Exception as exc:
                failed.append(str(exc))
        elif top["kind"] == "batch":
            # A single file operation can have done several KINDS of thing — a
            # paste that replaced two files and created three retired the two to
            # the trash and then wrote the three. Each item carries its own "op",
            # and they reverse NEWEST FIRST: putting a replaced file back before
            # the file that replaced it has been taken away would just collide
            # with it and fail.
            for it in reversed(top["items"]):
                try:
                    if self._reverse(it.get("op", "create"), it):
                        done += 1
                except Exception as exc:
                    failed.append(str(exc))
        else:
            for it in top["items"]:
                try:
                    if self._reverse(top["kind"], it):
                        done += 1
                except Exception as exc:
                    failed.append(str(exc))
        verb = top["verb"].lower()
        if failed and done:
            return f"Undid {done} of {len(top['items'])} — {failed[0]}"
        if failed:
            return f"Could not undo {verb} — {failed[0]}"
        return f"Undid {verb}" + (f" ({done} items)" if done > 1 else "")

    def _reverse_renames(self, items):
        """Undo a rename set as a set, through temporary names.

        A batch rename can be a PERMUTATION — two files swapping names is the
        canonical case, and shifting a numbered series is the common one — and
        reversing it row by row collides with the rows that have not moved yet,
        for exactly the reason applying it row by row would. Undoing a swap was
        therefore refused outright ("a.txt exists again") and the batch stayed
        applied. So the reversal stages through temporaries the same way.
        """
        jobs = []
        for it in items:
            src, dest = Path(it["new"]), Path(it["old"])
            if not src.exists():
                raise RuntimeError(f"{src.name} is gone")
            jobs.append((src, dest))
        sources = {s for s, _ in jobs}
        for _src, dest in jobs:
            if dest.exists() and dest not in sources:
                raise RuntimeError(f"{dest.name} exists again")
        stamp = f".sea-fm-undo-{os.getpid()}-"
        staged = []
        for i, (src, dest) in enumerate(jobs):
            tmp = src.parent / f"{stamp}{i}"
            src.rename(tmp)
            staged.append((tmp, dest))
        for tmp, dest in staged:
            tmp.rename(dest)
        return len(staged)

    def _reverse(self, kind, it):
        if kind == "trash":
            # Back out of the trash the same way a restore does, including the
            # .trashinfo — a file put back with its record left behind shows up
            # in the trash listing as an entry pointing at nothing.
            src = Path(it["trash"])
            dest = Path(it["orig"])
            if not src.exists():
                raise RuntimeError(f"{dest.name} is no longer in the trash")
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists():
                dest = _free_name(dest)
            shutil.move(str(src), str(dest))
            info = Path(it.get("info", ""))
            if info and info.exists():
                info.unlink()
            return True

        if kind == "move":
            src = Path(it["dst"])
            dest = Path(it["src"])
            if not src.exists():
                raise RuntimeError(f"{src.name} has moved again")
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists():
                dest = _free_name(dest)
            shutil.move(str(src), str(dest))
            return True

        if kind == "create":
            # Includes pasted copies, duplicates and extractions. Trashed, never
            # deleted — see the note at the top.
            p = Path(it["path"])
            if not p.exists():
                return False
            _trash_to_spec(p)
            return True

        if kind == "chmod":
            p = Path(it["path"])
            if not p.exists():
                return False
            os.chmod(str(p), it["old"])
            return True

        if kind == "tag":
            TAGS().apply(it["path"], it.get("old", ""))
            return True

        return False


def _free_name(dest):
    """A sibling name that is not taken, keeping the extension where it is."""
    stem, suffix = dest.stem, dest.suffix
    i = 2
    cand = dest.with_name(f"{stem}_{i}{suffix}")
    while cand.exists():
        i += 1
        cand = dest.with_name(f"{stem}_{i}{suffix}")
    return cand


def _trash_to_spec(p):
    """Move one path into the trash per the freedesktop spec, by hand.

    Used where the exact destination has to be known — undo needs to be able to
    say which file in the trash is the one it just put there, and `gio trash`
    does not report where it landed.
    """
    files_dir, info_dir, top = _trash_dirs_for(p)
    files_dir.mkdir(parents=True, exist_ok=True)
    info_dir.mkdir(parents=True, exist_ok=True)
    name = p.name
    target = files_dir / name
    if target.exists():
        name = f"{p.stem}_{int(time.time())}{p.suffix}"
        target = files_dir / name
    info = info_dir / f"{name}.trashinfo"
    orig = p.resolve()
    # Relative to the volume for a volume trash, absolute for the home one. A
    # drive that records absolute paths restores to wherever it happened to be
    # mounted the day the file was deleted, which is not where it came from.
    recorded = str(orig.relative_to(top)) if top else str(orig)
    info.write_text(
        "[Trash Info]\nPath={}\nDeletionDate={}\n".format(
            quote(recorded),
            datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")))
    shutil.move(str(p), str(target))
    return {"orig": str(orig), "trash": str(target), "info": str(info)}


_UNDO = None


def UNDO():
    global _UNDO
    if _UNDO is None:
        _UNDO = UndoJournal()
    return _UNDO


# =====================================================================
# COLOUR TAGS
# =====================================================================
#
# Tags are deliberately a FIXED palette rather than anything derived from the
# wallpaper accent. The accent moves when the wallpaper does, and a label whose
# colour changes underneath it is not a label — the whole value of "the blue
# ones" is that it still means the same set next week.
#
# The store is keyed by absolute path and is process-wide, so both panes agree.
# A path that no longer exists is dropped on load rather than kept as a ghost:
# there is no way to un-tag something you can no longer see.

# Tags are browsed as a virtual folder rather than as a filter toggle, so history,
# tabs, the breadcrumb and "send the other pane here" all work on them with no
# special cases at all. It is only virtual when no real directory of that name
# exists — a machine with a real /Tags keeps its own.
ARCHIVE_EXTS = (".zip", ".jar", ".whl", ".apk", ".cbz", ".epub",
                ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz",
                ".tar.bz2", ".tbz2", ".tar.zst", ".tzst",
                # Read through an external tool — see _external_members. Without
                # these a .7z was handed to whatever the desktop had registered
                # for it, which meant double-clicking one opened File Roller
                # rather than looking inside it here like every other archive.
                ".7z", ".rar")

# Formats the standard library cannot read, listed and unpacked through 7z or
# bsdtar instead. libarchive (bsdtar) covers rar and zstd where 7z does not.
EXTERNAL_ARCHIVE_EXTS = (".7z", ".rar", ".tar.zst", ".tzst")
ARCHIVE_CACHE_DIR = Path.home() / ".cache" / "sea-fm" / "archive"


def _archive_stem(path):
    """'photos.tar.gz' -> 'photos'. Path.stem only strips ONE suffix, so the
    obvious version unpacks a .tar.gz into a folder called 'photos.tar'."""
    name = Path(path).name
    low = name.lower()
    for ext in sorted(ARCHIVE_EXTS, key=len, reverse=True):
        if low.endswith(ext):
            return name[:-len(ext)]
    return Path(name).stem

ARCHIVE_PREVIEW_MAX = 64 * 1024 * 1024
TAG_ROOT = "/Tags"
TAG_NAMES = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Grey"]
TAG_COLORS = {
    "Red": "#e5534b", "Orange": "#e08a33", "Yellow": "#d2a72f",
    "Green": "#43a866", "Blue": "#4a90d9", "Purple": "#9a6bd1",
    "Grey": "#8a8a99",
}


class TagStore(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._tags = {}
        self._load()

    def _load(self):
        try:
            with open(TAGS_FILE) as f:
                raw = json.load(f)
            self._tags = {k: v for k, v in raw.items()
                          if v in TAG_COLORS and os.path.exists(k)}
        except Exception:
            self._tags = {}

    def _save(self):
        try:
            with open(TAGS_FILE, "w") as f:
                json.dump(self._tags, f, indent=2)
        except Exception:
            pass

    def get(self, path):
        return self._tags.get(path, "")

    def apply(self, path, name):
        """Set or clear one tag with no undo record — the reversal path."""
        if name:
            self._tags[path] = name
        else:
            self._tags.pop(path, None)
        self._save()
        self.changed.emit()

    @Property("QVariantMap", constant=True)
    def palette(self):
        return dict(TAG_COLORS)

    @Property(list, constant=True)
    def names(self):
        return list(TAG_NAMES)

    @Property("QVariantMap", notify=changed)
    def counts(self):
        out = {n: 0 for n in TAG_NAMES}
        for name in self._tags.values():
            if name in out:
                out[name] += 1
        return out

    @Slot(str, result=str)
    def tagOf(self, path):
        return self._tags.get(path, "")

    @Slot(list, str)
    def setTag(self, paths, name):
        touched = []
        for p in paths:
            if not p:
                continue
            old = self._tags.get(p, "")
            if old == name:
                continue
            touched.append({"path": p, "old": old})
            if name:
                self._tags[p] = name
            else:
                self._tags.pop(p, None)
        if not touched:
            return
        self._save()
        UNDO().record("tag", "Tag" if name else "Remove Tag", touched)
        self.changed.emit()

    @Slot(str, result=list)
    def taggedPaths(self, name):
        """Paths carrying this tag — or every tagged path when name is empty.

        Pruned as it goes: a tag on a file that has since been deleted elsewhere
        would otherwise sit in the list for ever with nothing to click.
        """
        gone = [p for p in self._tags if not os.path.exists(p)]
        for p in gone:
            self._tags.pop(p, None)
        if gone:
            self._save()
        return sorted([p for p, v in self._tags.items() if not name or v == name],
                      key=lambda s: os.path.basename(s).lower())


_TAGS = None


def TAGS():
    global _TAGS
    if _TAGS is None:
        _TAGS = TagStore()
    return _TAGS


# =====================================================================
# FILE ICONS FROM THE ICON THEME
# =====================================================================
#
# The grid used to draw one Material Symbols glyph per broad category, so every
# text file, every source file and every config file were the same picture. An
# icon theme already knows the difference — Breeze ships a distinct icon for
# text/x-python, application/pdf, application/json and several hundred more — and
# it is the picture the rest of the desktop uses for those files, which is the
# stronger argument: the file manager should not have a private opinion about
# what a PDF looks like.
#
# HOW A NAME IS FOUND. shared-mime-info gives each type an icon name and a
# GENERIC one to fall back to (text/x-python -> text-x-python, then text-x-generic).
# Themes vary in how much they carry, so the chain is tried in order and the first
# name the theme actually has wins. A theme with nothing for any of them falls
# back to the glyph, which is why the old drawing code is still there.
#
# The lookup is cached per icon name because it is asked once per row per listing.

ICON_THEME_FALLBACK = "Papirus"

# FOLDERS THAT FOLLOW THE ACCENT.
#
# Papirus (and a few others) ship the same folder drawn in a couple of dozen
# colours — folder-blue, folder-teal, folder-red and so on, including the
# well-known variants like folder-blue-documents. sea-shell's accent moves with
# the wallpaper, so the folder colour can move with it: the folder in the file
# manager ends up the same colour as the bar, without anybody choosing it.
#
# The palette below is a CANDIDATE list, not an assumption. Which of these a theme
# actually has is discovered by asking it, so a theme with three colours works as
# well as one with twenty, and a theme with none falls straight back to plain
# "folder".
FOLDER_TINTS = {
    # name          hue    sat    light   (of the theme's own folder colour)
    "red":        (0.985, 0.72, 0.61),
    "deeporange": (0.035, 0.90, 0.63),
    "orange":     (0.075, 0.95, 0.57),
    "yellow":     (0.115, 0.90, 0.58),
    "palebrown":  (0.085, 0.30, 0.55),
    "brown":      (0.055, 0.22, 0.57),
    "green":      (0.250, 0.35, 0.52),
    "teal":       (0.465, 0.72, 0.36),
    "darkcyan":   (0.500, 0.85, 0.30),
    "cyan":       (0.520, 0.90, 0.45),
    "breeze":     (0.555, 0.80, 0.58),
    "blue":       (0.570, 0.68, 0.49),
    "nordic":     (0.590, 0.35, 0.65),
    "bluegrey":   (0.560, 0.15, 0.46),
    "indigo":     (0.650, 0.45, 0.55),
    "violet":     (0.700, 0.45, 0.55),
    "magenta":    (0.850, 0.60, 0.55),
    "pink":       (0.925, 0.75, 0.59),
    "grey":       (0.000, 0.00, 0.54),
    "black":      (0.000, 0.00, 0.18),
    "white":      (0.000, 0.00, 0.92),
}


def _hex_to_hls(text):
    raw = str(text or "").lstrip("#")
    if len(raw) != 6:
        return None
    try:
        r, g, b = (int(raw[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    except ValueError:
        return None
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return h, l, s


def nearest_folder_tint(accent, available):
    """The available folder colour closest to the accent.

    Hue dominates, because that is what the eye matches on; saturation and
    lightness only break ties. A near-grey accent is matched on lightness alone,
    since it has no meaningful hue to compare and would otherwise land on
    whichever colour happened to sit at hue zero.
    """
    got = _hex_to_hls(accent)
    if not got or not available:
        return ""
    h, l, s = got
    best, best_cost = "", None
    for name in available:
        th, ts, tl = FOLDER_TINTS[name]
        if s < 0.12:
            if ts > 0.2:
                continue                     # a grey accent wants a grey folder
            cost = abs(l - tl) * 2.0
        else:
            # GREY, BLACK AND WHITE ARE NOT CANDIDATES FOR A COLOURED ACCENT.
            # Their hue is recorded as 0 because they have none, and 0 is a real
            # hue on the circle — so a red accent at 0.99 came out 0.01 away from
            # "white" and matched it, which is how a rose accent produced a white
            # folder. An achromatic swatch is only ever the answer for an
            # achromatic accent, handled above.
            if ts < 0.08:
                continue
            dh = abs(h - th)
            dh = min(dh, 1.0 - dh)           # hue is a circle
            cost = dh * 4.0 + abs(s - ts) * 0.6 + abs(l - tl) * 0.5
        if best_cost is None or cost < best_cost:
            best, best_cost = name, cost
    return best

# The folders every desktop names specially, in freedesktop's vocabulary.
XDG_FOLDER_ICONS = {
    "home": "user-home",
    "desktop_windows": "user-desktop",
    "description": "folder-documents",
    "download": "folder-download",
    "music_note": "folder-music",
    "image": "folder-pictures",
    "movie": "folder-videos",
    "public": "folder-publicshare",
}

# Named folders worth a distinct icon where a theme has one.
NAMED_FOLDER_ICONS = {
    ".git": "folder-git", ".github": "folder-github",
    "node_modules": "folder-node", ".config": "folder-templates",
    ".cache": "folder-temp", "src": "folder-code", "source": "folder-code",
    "build": "folder-build", "dist": "folder-build", "bin": "folder-bin",
    "test": "folder-test", "tests": "folder-test",
    "docs": "folder-documents", "doc": "folder-documents",
    "screenshots": "folder-pictures", "wallpapers": "folder-images",
    "games": "folder-games", "backup": "folder-backup",
    "tmp": "folder-temp", "temp": "folder-temp",
    "fonts": "folder-font", ".fonts": "folder-font",
    ".ssh": "folder-locked", "projects": "folder-development",
}


class IconResolver:
    """Names an icon for a file, and answers whether the theme actually has it."""

    def __init__(self):
        self._db = QMimeDatabase()
        self._have = {}          # icon name -> bool
        self._for_mime = {}      # (mime, kind) -> resolved name or ""
        self._tint = ""          # accent-matched folder colour, "" for plain
        self._tints = None       # which colours this theme has, discovered once

    def set_theme(self, name):
        if name and name != QIcon.themeName():
            QIcon.setThemeName(name)
        self._have.clear()
        self._for_mime.clear()
        self._tint = ""
        self._tints = None

    def folder_tints(self):
        """Which of the candidate folder colours this theme actually carries."""
        if self._tints is None:
            self._tints = [n for n in FOLDER_TINTS if self._has("folder-" + n)]
        return self._tints

    def set_accent(self, accent):
        """Choose the folder colour for this accent. Returns True if it changed."""
        want = nearest_folder_tint(accent, self.folder_tints())
        if want == self._tint:
            return False
        self._tint = want
        self._for_mime = {k: v for k, v in self._for_mime.items() if k[0] != "dir"}
        return True

    def _has(self, name):
        if not name:
            return False
        got = self._have.get(name)
        if got is None:
            got = not QIcon.fromTheme(name).isNull()
            self._have[name] = got
        return got

    def _first(self, *names):
        for n in names:
            if self._has(n):
                return n
        return ""

    def for_folder(self, name, full_path, well_known):
        """well_known is the glyph name the existing vocabulary already chose."""
        key = ("dir", well_known, name.lower())
        got = self._for_mime.get(key)
        if got is not None:
            return got
        candidates = []
        xdg = XDG_FOLDER_ICONS.get(well_known)
        named = NAMED_FOLDER_ICONS.get(name.lower())
        # The tinted spelling of each candidate first — folder-blue-documents
        # before folder-documents — so a theme that has both uses the accent, and
        # one that has only the plain name still works.
        if self._tint:
            t = self._tint
            if xdg:
                candidates.append(xdg.replace("folder-", f"folder-{t}-", 1)
                                  if xdg.startswith("folder-") else xdg)
            if named and named.startswith("folder-"):
                candidates.append(named.replace("folder-", f"folder-{t}-", 1))
            candidates.append(f"folder-{t}")
        if xdg:
            candidates.append(xdg)
        if named:
            candidates.append(named)
        candidates.append("folder")
        candidates.append("inode-directory")
        got = self._first(*candidates)
        self._for_mime[key] = got
        return got

    def is_text(self, path, deep=False):
        """Whether this file is readable as text, according to shared-mime-info.

        THE EXTENSION LIST WAS NEVER GOING TO BE COMPLETE. Text formats the list
        had not heard of (.mjs, .jsonc, .bat) fell through to a placeholder icon,
        while .epub -- a zip -- was called a document and read as UTF-8, which
        showed the user a screen of replacement characters. The mime database
        already knows which types inherit text/plain; asking it is both shorter
        and right about formats nobody thought to enumerate.
        """
        # Matched on the NAME for a listing -- 0.02ms a file against 0.12ms for
        # opening each one to sniff it, which is a trade worth making several
        # hundred times over. A preview is one file, so it can afford to look.
        mode = (QMimeDatabase.MatchMode.MatchDefault if deep
                else QMimeDatabase.MatchMode.MatchExtension)
        mt = self._db.mimeTypeForFile(str(path), mode)
        name = mt.name()
        # THE TOP-LEVEL TYPE IS THE RELIABLE PART. text/x-shellscript does not
        # inherit text/plain in shared-mime-info at all -- its only parent is
        # application/x-executable, because a script is one -- so an inherits()
        # test alone called every shell script binary and refused to preview it.
        if name.startswith("text/") or mt.inherits("text/plain"):
            return True
        # And a few text formats live under application/ for historical reasons.
        return name in ("application/json", "application/xml",
                        "application/javascript", "application/x-shellscript",
                        "application/x-desktop", "application/toml",
                        "application/x-yaml", "application/yaml",
                        "application/x-perl", "application/x-ruby",
                        "application/sql", "application/x-yaml")

    def for_file(self, path, ext):
        """The theme's icon for this file, by content type where cheap.

        Matched on the NAME rather than by sniffing the file: a listing asks this
        once per row, and opening several hundred files to read their first bytes
        is not a trade worth making for an icon.
        """
        mt = self._db.mimeTypeForFile(path, QMimeDatabase.MatchMode.MatchExtension)
        key = ("file", mt.name())
        got = self._for_mime.get(key)
        if got is not None:
            return got
        chain = [mt.iconName(), mt.genericIconName()]
        # A last, broad guess from the top-level type, for themes that carry only
        # the families.
        top = mt.name().split("/")[0]
        chain.append({"text": "text-x-generic", "image": "image-x-generic",
                      "video": "video-x-generic", "audio": "audio-x-generic",
                      "font": "font-x-generic"}.get(top, "application-x-generic"))
        chain.append("text-x-generic")
        got = self._first(*[c for c in chain if c])
        self._for_mime[key] = got
        return got


_ICONS = None


def ICONS():
    global _ICONS
    if _ICONS is None:
        _ICONS = IconResolver()
    return _ICONS


class ThemeIconProvider(QQuickImageProvider):
    """Serves themed icons to QML as image://fileicon/<name>.

    Rendered at the size the view asks for rather than a fixed one, so a grid at
    256px does not scale up a 32px bitmap — which is what made the old icons look
    soft when zoomed.
    """

    def __init__(self):
        super().__init__(QQuickImageProvider.ImageType.Pixmap)

    def requestPixmap(self, image_id, size, requested_size):
        name = image_id.split("?")[0]
        want = max(requested_size.width(), requested_size.height())
        if want <= 0:
            want = 64
        want = max(16, min(512, want))
        icon = QIcon.fromTheme(name)
        if icon.isNull():
            pm = QPixmap(want, want)
            pm.fill(Qt.transparent)
            return pm
        pm = icon.pixmap(want, want)
        if pm.isNull():
            pm = QPixmap(want, want)
            pm.fill(Qt.transparent)
        return pm


# =====================================================================
# PREFERENCES
# =====================================================================
#
# TWO STORES, DELIBERATELY, because they have different owners.
#
# Anything about how the SHELL looks — dark or light, the accent, how round
# things are — belongs to ~/.config/sea-shell/appearance.json, which the bar, the
# dock, the dashboard and this window all read. Changing it here changes all of
# them, which is the point: a file manager with its own private idea of dark mode
# would be the odd one out again.
#
# That file is written through sea-set-appearance.py rather than by hand. It has
# around ninety keys and settings.qml rewrites it wholesale from its own state; a
# surface that knows about three of them must merge, or it silently resets the
# eighty-seven it has never heard of.
#
# Anything about how THIS WINDOW behaves — the view it opens in, whether one click
# opens a file — is nobody else's business and lives in fm_prefs.json.

PREFS_FILE = CONFIG_DIR / "fm_prefs.json"

PREF_DEFAULTS = {
    "defaultView": "grid",       # grid | list | compact
    "showHidden": False,
    "inspectorOnOpen": False,
    "singleClickOpen": False,
    "confirmTrash": False,
    "sortField": "name",
    "sortDescending": False,
    "gridIconSize": 120,
    "cacheBudgetMb": 512,
    "rememberPerFolder": True,
    # THE FILE MANAGER'S OWN LOOK, OR THE SHELL'S.
    #
    # "shell" reads ~/.config/sea-shell/appearance.json and follows the bar, the
    # dock and everything else — one desktop, one look. "own" keeps the three
    # values below for this window alone and touches nothing outside it.
    #
    # The distinction matters because the first version only had the shell-wide
    # path, so choosing dark mode in the file manager restyled the entire desktop.
    # That is a reasonable thing to WANT, but it is not a reasonable thing to
    # happen by default from a preference panel labelled Appearance inside one app.
    #
    # INDEPENDENT WRITES, NOT AN INDEPENDENT LOOK. A file manager's own appearance
    # panel must change the file manager and nothing else -- the first version
    # wrote appearance.json, so choosing dark mode here restyled the bar, the dock
    # and the dashboard too. The fix for that was to give the window its own
    # values, but defaulting to them meant the window then sat in dark mode while
    # the shell went light, and stayed on the accent it happened to be opened
    # with. Following the shell is the default again; choosing anything in the
    # Appearance menu switches this window to its own copy, and that copy is
    # still never written back to the shell.
    "themeSource": "shell",      # own | shell
    "themeChosen": False,        # did the user actually ask for their own look
    "ownMode": "dark",
    "ownAccent": "#63c7dd",
    "ownRadius": 14,
    "ownSeeded": False,          # has the first-run adoption happened yet
    "useThemeIcons": True,
    "tintFolders": True,         # folders follow the accent where the theme allows
    # Papirus by default where it is installed: it carries a distinct icon for
    # several hundred MIME types, where a theme like Adwaita collapses .py, .txt,
    # .c and .qml all onto the same generic page. A theme that is not installed is
    # ignored rather than leaving the grid blank — see _apply_icon_theme — so this
    # is safe to ship as a default on a machine that does not have it. Set it to
    # "" in the preferences to follow the desktop's own theme instead.
    "iconTheme": "Papirus",
}


class Prefs(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._v = dict(PREF_DEFAULTS)
        try:
            raw = json.loads(PREFS_FILE.read_text())
            for k, v in raw.items():
                # Only keys we know, and only if the type still matches — a stale
                # file from an older version must not inject a string where the
                # UI expects a bool.
                if k in PREF_DEFAULTS and isinstance(v, type(PREF_DEFAULTS[k])):
                    self._v[k] = v
        except Exception:
            pass
        # An earlier version defaulted to the window's own theme, so a file
        # written by it says "own" whether or not anyone chose that. Only a
        # deliberate choice sets themeChosen, so anything without it goes back to
        # following the shell -- which is what a setting nobody touched should do.
        if self._v.get("themeSource") == "own" and not self._v.get("themeChosen"):
            self._v["themeSource"] = "shell"

    def _save(self):
        try:
            PREFS_FILE.write_text(json.dumps(self._v, indent=2))
        except Exception:
            pass

    @Property("QVariantMap", notify=changed)
    def all(self):
        return dict(self._v)

    @Slot(str, result="QVariant")
    def get(self, key):
        return self._v.get(key, PREF_DEFAULTS.get(key))

    @Slot(str, "QVariant")
    def set(self, key, value):
        if key not in PREF_DEFAULTS:
            return
        want = PREF_DEFAULTS[key]
        try:
            if isinstance(want, bool):
                value = bool(value)
            elif isinstance(want, int):
                value = int(value)
            elif isinstance(want, str):
                value = str(value)
        except (TypeError, ValueError):
            return
        if self._v.get(key) == value:
            return
        self._v[key] = value
        self._save()
        self.changed.emit()

    @Slot()
    def reset(self):
        self._v = dict(PREF_DEFAULTS)
        self._save()
        self.changed.emit()


_PREFS = None


def PREFS():
    global _PREFS
    if _PREFS is None:
        _PREFS = Prefs()
    return _PREFS


def _appearance_script():
    here = Path(__file__).resolve().parent / "sea-set-appearance.py"
    if here.exists():
        return str(here)
    fallback = Path.home() / ".config" / "quickshell" / "sea-shell" / "sea-set-appearance.py"
    return str(fallback) if fallback.exists() else ""


# =====================================================================
# STARRED AND RECENT
# =====================================================================
#
# Both are VIRTUAL FOLDERS, the same trick the colour tags already use: /Starred
# and /Recent are real locations as far as this file manager is concerned, so the
# breadcrumb, tabs, history, back/forward, the filter box and "send the other pane
# here" all work on them with no special cases at all. Each is only virtual when
# no real directory of that name exists, so a machine with an actual /Recent keeps
# its own.
#
# Recent is not a store of ours. It is ~/.local/share/recently-used.xbel, the
# freedesktop recent-files list that GTK applications already write to — so what
# shows up here is what you actually opened, in any application, rather than a
# private history that only knows about this window.

STARRED_FILE = CONFIG_DIR / "fm_starred.json"
STAR_ROOT = "/Starred"
RECENT_ROOT = "/Recent"
RECENT_XBEL = Path.home() / ".local" / "share" / "recently-used.xbel"
RECENT_LIMIT = 100


class StarStore(QObject):
    """Individual files pinned by the user, as opposed to bookmarked folders."""

    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._paths = []
        self._load()

    def _load(self):
        try:
            raw = json.loads(STARRED_FILE.read_text())
            # A star on something that has since been deleted is not a star, it
            # is a dead row you cannot click.
            self._paths = [p for p in raw if isinstance(p, str) and os.path.exists(p)]
        except Exception:
            self._paths = []

    def _save(self):
        try:
            STARRED_FILE.write_text(json.dumps(self._paths, indent=2))
        except Exception:
            pass

    @Slot(str, result=bool)
    def isStarred(self, path):
        return path in self._paths

    @Property(int, notify=changed)
    def count(self):
        return len(self._paths)

    @Slot(list)
    def toggle(self, paths):
        wanted = [p for p in paths if p]
        if not wanted:
            return
        # All-or-nothing on a mixed selection: if anything in it is unstarred the
        # gesture means "star these", which is what people expect from one button
        # acting on many rows.
        add = any(p not in self._paths for p in wanted)
        for p in wanted:
            if add and p not in self._paths:
                self._paths.append(p)
            elif not add and p in self._paths:
                self._paths.remove(p)
        self._save()
        self.changed.emit()

    @Slot(result=list)
    def paths(self):
        gone = [p for p in self._paths if not os.path.exists(p)]
        if gone:
            self._paths = [p for p in self._paths if p not in gone]
            self._save()
        return list(self._paths)


_STARS = None


def STARS():
    global _STARS
    if _STARS is None:
        _STARS = StarStore()
    return _STARS


def recent_paths(limit=RECENT_LIMIT):
    """Recently used local files, newest first, from the freedesktop list."""
    if not RECENT_XBEL.exists():
        return []
    try:
        import xml.etree.ElementTree as ET
        root = ET.parse(RECENT_XBEL).getroot()
    except Exception:
        return []
    out = []
    for bm in root.findall("bookmark"):
        href = bm.get("href") or ""
        if not href.startswith("file://"):
            continue
        path = QUrl(href).toLocalFile()
        # The list is a history, so it is full of things that have since been
        # moved or deleted; showing those would make Recent mostly dead rows.
        if not path or not os.path.exists(path):
            continue
        out.append((bm.get("visited") or bm.get("modified") or "", path))
    out.sort(reverse=True)
    seen, paths = set(), []
    for _when, p in out:
        if p in seen:
            continue
        seen.add(p)
        paths.append(p)
        if len(paths) >= limit:
            break
    return paths


# =====================================================================
# BACKGROUND WALKERS  (properties, duplicates)
# =====================================================================

class DirSizeWorker(QRunnable):
    """Total size of a folder, off the UI thread.

    A properties dialog that blocks while it counts a home directory is a
    properties dialog nobody opens twice, so the number arrives late and the
    dialog says so until it does.
    """

    def __init__(self, backend, path, token):
        super().__init__()
        self.backend = backend
        self.path = str(path)
        self.token = token

    def run(self):
        total, files, dirs = 0, 0, 0
        try:
            for root, dirnames, filenames in os.walk(self.path, onerror=None):
                if self.backend._size_token != self.token:
                    return
                dirs += len(dirnames)
                for fn in filenames:
                    files += 1
                    try:
                        total += os.lstat(os.path.join(root, fn)).st_size
                    except OSError:
                        pass
        except Exception:
            pass
        if self.backend._size_token == self.token:
            self.backend.dirSizeReady.emit(
                self.path, {"bytes": total, "files": files, "dirs": dirs})


class DuplicateWorker(QRunnable):
    """Identical files under a folder, cheapest test first.

    Three passes, each one only over what survived the last: group by SIZE (a
    stat, already free from the walk), then by the hash of the first 64K, then
    by the whole file. Two files of a different length are never read at all,
    and for a tree of mostly-unique files that is nearly all of them.
    """

    HEAD = 64 * 1024

    def __init__(self, backend, root, token):
        super().__init__()
        self.backend = backend
        self.root = str(root)
        self.token = token

    def _alive(self):
        return self.backend._dupe_token == self.token

    def _digest(self, path, limit=None):
        h = hashlib.blake2b(digest_size=16)
        with open(path, "rb") as fh:
            if limit is None:
                for block in iter(lambda: fh.read(1 << 20), b""):
                    h.update(block)
            else:
                h.update(fh.read(limit))
        return h.hexdigest()

    def run(self):
        by_size = {}
        scanned = 0
        try:
            for root, dirnames, filenames in os.walk(self.root, onerror=None):
                if not self._alive():
                    return
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                for fn in filenames:
                    fp = os.path.join(root, fn)
                    try:
                        st = os.lstat(fp)
                    except OSError:
                        continue
                    # Symlinks are not copies of anything and an empty file is
                    # identical to every other empty file, which is true and
                    # useless.
                    if not stat.S_ISREG(st.st_mode) or st.st_size == 0:
                        continue
                    by_size.setdefault(st.st_size, []).append(fp)
                    scanned += 1
                    if scanned % 500 == 0:
                        self.backend.duplicateProgress.emit(scanned, root)
        except Exception:
            pass

        groups = []
        for size, paths in by_size.items():
            if len(paths) < 2 or not self._alive():
                continue
            heads = {}
            for fp in paths:
                try:
                    heads.setdefault(self._digest(fp, self.HEAD), []).append(fp)
                except OSError:
                    continue
            for head, same_head in heads.items():
                if len(same_head) < 2 or not self._alive():
                    continue
                # A file smaller than the head read is already fully hashed.
                if size <= self.HEAD:
                    full = {head: same_head}
                else:
                    full = {}
                    for fp in same_head:
                        try:
                            full.setdefault(self._digest(fp), []).append(fp)
                        except OSError:
                            continue
                for _, same in full.items():
                    if len(same) < 2:
                        continue
                    files = []
                    for fp in sorted(same):
                        try:
                            st = os.lstat(fp)
                        except OSError:
                            continue
                        files.append({
                            "path": fp,
                            "name": os.path.basename(fp),
                            "dir": os.path.dirname(fp),
                            "mtime": st.st_mtime,
                            "mtimeStr": QDateTime.fromSecsSinceEpoch(
                                int(st.st_mtime)).toString("yyyy-MM-dd hh:mm"),
                        })
                    if len(files) < 2:
                        continue
                    groups.append({
                        "size": size,
                        "sizeStr": _fmt_size(size),
                        "count": len(files),
                        "wasted": size * (len(files) - 1),
                        "files": files,
                    })

        if not self._alive():
            return
        # Biggest saving first — that is the order anyone reading this list cares
        # about, and it puts the one worth acting on at the top.
        groups.sort(key=lambda g: g["wasted"], reverse=True)
        self.backend.duplicatesReady.emit(groups)


def _fmt_size(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} TB"


# =====================================================================
# REMOVABLE DRIVES AND VOLUMES
# =====================================================================
#
# WHAT COUNTS AS A DEVICE. The old version read /proc/mounts, which can only
# ever show what is ALREADY MOUNTED — so a USB stick you had just plugged in was
# invisible, which is precisely the moment you go looking for it. lsblk sees
# every block device whether mounted or not, so an unmounted volume can be shown
# and offered.
#
# The filtering is about noise, not capability. Loop devices are container and
# snap plumbing, swap is not a place you can put a file, an unformatted partition
# has nothing to show, and the EFI partition is a boot detail nobody browses. A
# whole disk that has partitions is skipped in favour of the partitions, since
# the filesystems live there.
#
# HOW IT KEEPS UP. Polling lsblk on a timer is what this would normally cost, and
# this shell is already watched for idle CPU, so nothing is polled at all:
#   - plugging or unplugging is a udev event  -> `udevadm monitor`, a pipe we read
#   - mounting or unmounting is not a udev event, but the kernel marks
#     /proc/self/mounts as having exceptional data every time it changes, which is
#     exactly what a poll(POLLPRI) — a QSocketNotifier in Exception mode — waits on
# Both are edge-triggered and cost nothing while nothing happens.

DEV_SKIP_FS = {"swap", "squashfs", "linux_raid_member", "LVM2_member"}
DEV_SKIP_MOUNTS = ("/boot", "/efi", "/var/lib/waydroid", "/snap", "/proc",
                   "/sys", "/dev", "/run/credentials")


def _dev_icon(tran, dev_type, removable):
    if dev_type == "rom":
        return "album"
    if tran in ("usb",):
        return "usb"
    if tran in ("mmc",) or (tran is None and removable):
        return "sd_card"
    return "hard_drive"


def _human(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if n < 1024 or unit == "PB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return ""


def scan_block_devices():
    """Every volume worth showing, mounted or not, newest information each call."""
    try:
        out = subprocess.run(
            ["lsblk", "-b", "-J", "-o",
             "NAME,PATH,LABEL,FSTYPE,SIZE,MOUNTPOINT,RM,HOTPLUG,TYPE,TRAN,"
             "MODEL,VENDOR,RO,FSAVAIL,FSSIZE,UUID"],
            capture_output=True, text=True, timeout=5)
        tree = json.loads(out.stdout).get("blockdevices", [])
    except Exception:
        return []

    found = []

    def visit(node, parent=None):
        parent = parent or {}
        tran = node.get("tran") or parent.get("tran")
        model = node.get("model") or parent.get("model")
        vendor = node.get("vendor") or parent.get("vendor")
        removable = bool(node.get("rm") or node.get("hotplug")
                         or parent.get("removable"))
        kids = node.get("children") or []
        ctx = {"tran": tran, "model": model, "vendor": vendor,
               "removable": removable}

        dev_type = node.get("type")
        fstype = node.get("fstype")
        mount = node.get("mountpoint") or ""

        keep = True
        if dev_type == "loop" or (node.get("name") or "").startswith("zram"):
            keep = False
        elif fstype in DEV_SKIP_FS:
            keep = False
        elif kids:
            # The partitions carry the filesystems; the disk itself is a header.
            keep = False
        elif dev_type == "disk" and not fstype and dev_type != "rom":
            keep = False
        elif dev_type != "rom" and not fstype:
            keep = False
        elif mount and any(mount == m or mount.startswith(m + "/")
                           for m in DEV_SKIP_MOUNTS):
            keep = False
        elif mount in ("[SWAP]",):
            keep = False

        if keep:
            # An unlabelled volume is named the way the desktop names it: the
            # device's own identity when it is something you plugged in, and
            # "132.3 GB Volume" when it is a partition of the disk already in
            # the machine — repeating the disk model for each of its partitions
            # just lists the same name three times.
            label = node.get("label")
            if not label and removable:
                label = f"{vendor or ''} {model or ''}".strip()
            if not label and mount:
                label = Path(mount).name
            if not label:
                label = f"{_human(node.get('size'))} Volume"
            label = label[:34]
            if mount == "/":
                label = "Root Filesystem"
            size = node.get("size")
            total = node.get("fssize") or size
            avail = node.get("fsavail")
            used_pct = -1
            if mount and total and avail:
                try:
                    used_pct = int(round(
                        (1.0 - float(avail) / float(total)) * 100))
                except (TypeError, ValueError, ZeroDivisionError):
                    used_pct = -1
            found.append({
                "name": label,
                "path": mount,
                "dev": node.get("path") or "",
                "fstype": fstype or "",
                "icon": _dev_icon(tran, dev_type, removable),
                "removable": removable,
                # The root filesystem is not something to offer to unmount.
                "system": mount == "/",
                "mounted": bool(mount),
                "readOnly": bool(node.get("ro")),
                "sizeStr": _human(size),
                "usedPct": used_pct,
                "freeStr": _human(avail) if avail else "",
            })

        for kid in kids:
            visit(kid, ctx)

    for node in tree:
        visit(node)

    # Mounted first, then removable (the ones you came looking for), then name.
    found.sort(key=lambda d: (not d["system"], not d["mounted"],
                              not d["removable"], d["name"].lower()))
    return found


class DirModel(QAbstractListModel):
    """The rows of one pane, updated in place rather than replaced.

    WHY THIS IS NO LONGER A JAVASCRIPT ARRAY. Both file views used
    `model: pane.items`, a plain JS array that the QML reassigned wholesale on
    every refresh. QML cannot diff an array it has just been handed a new copy
    of, so a change of any size destroyed and rebuilt EVERY delegate in the view:
    one file appearing in a folder of four thousand rebuilt four thousand
    delegates. That is why the grid jumped back to the top whenever anything
    happened, and why a folder that was being written into was unusable.

    A model reports what actually changed. One file arriving is one inserted row;
    a thumbnail landing is one dataChanged on one row; everything else in the view
    keeps its delegate, and the view keeps its scroll position and its selection.

    ONE ROLE ON PURPOSE. With a single role QML binds `modelData` to it, so every
    existing delegate — all of which already read modelData.name, modelData.path
    and so on — went on working untouched.
    """

    ENTRY = Qt.UserRole + 1
    countChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._rows = []

    # ---- the QAbstractListModel contract ----

    def rowCount(self, parent=QModelIndex()):
        return 0 if parent.isValid() else len(self._rows)

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid() or not (0 <= index.row() < len(self._rows)):
            return None
        if role == self.ENTRY:
            return self._rows[index.row()]
        return None

    def roleNames(self):
        return {self.ENTRY: QByteArray(b"entry")}

    # ---- what QML asks of it ----

    @Property(int, notify=countChanged)
    def count(self):
        return len(self._rows)

    @Slot(int, result="QVariant")
    def at(self, i):
        return self._rows[i] if 0 <= i < len(self._rows) else {}

    @Slot(result=list)
    def paths(self):
        return [r["path"] for r in self._rows]

    @Slot(str, result=int)
    def indexOfPath(self, path):
        for i, r in enumerate(self._rows):
            if r["path"] == path:
                return i
        return -1

    # ---- the diff ----

    def setEntries(self, entries):
        """Move the view to this listing with the smallest set of signals.

        Both lists are sorted the same way, so anything present in both keeps its
        relative order — which is what lets removals and insertions be found by
        walking the two in step instead of computing a general edit script.
        """
        new = list(entries)
        before = len(self._rows)
        keep = {e["path"] for e in new}

        # WALKING THE TWO LISTS IN STEP ONLY WORKS IF NOTHING HAS MOVED PAST
        # ANYTHING ELSE. Removals and insertions preserve the relative order of
        # everything that survives, so they can be found this way — but changing
        # the sort order reorders every row at once, and the same walk then reads
        # a moved row as "missing here, new there" and inserts a second copy of
        # it. Checking first that the survivors are still a SUBSEQUENCE of the new
        # listing separates the two cases; a genuine reorder is a reset, which is
        # honest about the fact that every row really did move.
        survivors = [r["path"] for r in self._rows if r["path"] in keep]
        probe = iter(e["path"] for e in new)
        if not all(p in probe for p in survivors):
            self.beginResetModel()
            self._rows = new
            self.endResetModel()
            if len(self._rows) != before:
                self.countChanged.emit()
            return

        # Removals, back to front so the indices ahead of the cursor stay valid,
        # batched into runs so deleting a folder's worth of files is a handful of
        # signals rather than one per file.
        i = len(self._rows) - 1
        while i >= 0:
            if self._rows[i]["path"] in keep:
                i -= 1
                continue
            j = i
            while j >= 0 and self._rows[j]["path"] not in keep:
                j -= 1
            self.beginRemoveRows(QModelIndex(), j + 1, i)
            del self._rows[j + 1:i + 1]
            self.endRemoveRows()
            i = j

        # Insertions, front to back, likewise in runs.
        k = 0
        while k < len(new):
            if k < len(self._rows) and self._rows[k]["path"] == new[k]["path"]:
                k += 1
                continue
            here = self._rows[k]["path"] if k < len(self._rows) else None
            j = k
            while j < len(new) and new[j]["path"] != here:
                j += 1
            self.beginInsertRows(QModelIndex(), k, j - 1)
            self._rows[k:k] = new[k:j]
            self.endInsertRows()
            k = j

        # The two should agree exactly by now. If they ever do not, a reset is
        # wrong-looking but correct, where walking off the end of the shorter list
        # would raise and leave the model holding a listing that never happened.
        if len(self._rows) != len(new):
            self.beginResetModel()
            self._rows = new
            self.endResetModel()
            self.countChanged.emit()
            return

        # Anything left over is a row that stayed put but changed — a rename that
        # kept its place in the sort, a new mtime, a thumbnail that has arrived.
        run_start = None
        for idx in range(len(self._rows)):
            if self._rows[idx] != new[idx]:
                self._rows[idx] = new[idx]
                if run_start is None:
                    run_start = idx
            elif run_start is not None:
                self.dataChanged.emit(self.index(run_start), self.index(idx - 1),
                                      [self.ENTRY])
                run_start = None
        if run_start is not None:
            self.dataChanged.emit(self.index(run_start),
                                  self.index(len(self._rows) - 1), [self.ENTRY])

        if len(self._rows) != before:
            self.countChanged.emit()

    def patch_thumb(self, path, thumb):
        """A thumbnail landing touches ONE row, not the whole listing.

        This is the case the old code handled worst: every thumbnail that finished
        rendering triggered a full re-list and a full delegate rebuild, so opening
        a folder of videos rebuilt the grid once per video.
        """
        for i, r in enumerate(self._rows):
            if r["path"] == path:
                if r.get("thumbnailPath") == thumb:
                    return
                r["thumbnailPath"] = thumb
                self.dataChanged.emit(self.index(i), self.index(i), [self.ENTRY])
                return


# =====================================================================
# PREVIEW, OFF THE UI THREAD
# =====================================================================
#
# generatePreview used to do all of its work inline, on the UI thread, in the
# handler for "the selection changed". Opening a PDF, counting its pages and
# rendering the first one at 110 DPI; opening an image with PIL; reading and
# decoding 250 lines of a text file; parsing a .docx — every one of those blocked
# the window, and the block landed on the ARROW KEYS, so holding down Down through
# a folder of documents stuttered on each one.
#
# What is cheap (the name, the size, the icon, the category) is still computed
# inline, because a preview panel that flickers through an empty state on every
# keypress is worse than one that fills in a moment later. Everything expensive
# moved here, and lands as an update to the panel already on screen.
#
# A TOKEN, because the answer often arrives after the question stopped mattering:
# arrow down five times and four of those previews are already stale. The token is
# bumped on every selection, and a worker whose token no longer matches drops what
# it computed instead of overwriting the panel with an older file's contents.

PREVIEW_TEXT_LINES = 250
PREVIEW_CACHE_BUDGET = 512 * 1024 * 1024      # bytes of rendered pages to keep


class PreviewWorker(QRunnable):
    """The expensive half of one file's preview."""

    def __init__(self, backend, path, category, ext, size_str, token):
        super().__init__()
        self.backend = backend
        self.path = Path(path)
        self.category = category
        self.ext = ext
        self.size_str = size_str
        self.token = token

    def _stale(self):
        return self.backend._preview_token != self.token

    def run(self):
        try:
            frag = self._build()
        except Exception:
            frag = None
        if frag and not self._stale():
            self.backend.previewDetailReady.emit(str(self.path), self.token, frag)

    def _build(self):
        cat, p, ext = self.category, self.path, self.ext
        if not p.exists():
            return None

        if cat == "pdf":
            fitz = get_fitz()
            if not fitz:
                return {"meta": {"Format": "PDF Document", "Size": self.size_str}}
            digest = hashlib.md5(
                f"{p.resolve()}_{p.stat().st_mtime}".encode()).hexdigest()
            first = pdf_thumb_path(digest)
            doc = fitz.open(p)
            try:
                pages = len(doc)
                info = doc.metadata or {}
                if not first.exists() and pages:
                    doc.load_page(0).get_pixmap(
                        dpi=PDF_THUMB_DPI, alpha=False).save(str(first))
            finally:
                doc.close()
            if self._stale():
                return None
            if pages > 1:
                self.backend._thread_pool.start(PdfPagesWorker(p, 30, self.backend))
            title = info.get("title") or p.name
            author = info.get("author") or ""
            return {
                "pageCount": pages,
                "thumbnailPath": str(first) if first.exists() else "",
                "pdfPages": [str(first)] if first.exists() else [],
                "meta": {"Pages": f"{pages} pages",
                         "Author": author or "--",
                         "Title": title[:40],
                         "Format": "PDF Document",
                         "Size": self.size_str},
            }

        if cat == "image":
            meta = {"Size": self.size_str, "Format": ext.upper().lstrip(".")}
            pil = get_pil()
            if pil:
                try:
                    with pil.open(p) as img:
                        meta = {"Format": img.format,
                                "Dimensions": f"{img.width} × {img.height} px",
                                "Color Mode": img.mode,
                                "Size": self.size_str}
                except Exception:
                    pass
            return {"thumbnailPath": str(p), "meta": meta}

        if cat in ("video", "audio"):
            # ffprobe already runs on a worker; nothing expensive is left here.
            return None

        if cat == "document" and ext in DOC_PREVIEW_EXTS:
            digest = hashlib.md5(
                f"{p.resolve()}_{p.stat().st_mtime}".encode()).hexdigest()
            rendered = pdf_thumb_path(digest)
            frag = {}
            # The document's own thumbnail, if it has one, goes out immediately —
            # a zip read rather than a LibreOffice run. The conversion below still
            # happens for the page viewer; it just no longer gates seeing anything.
            if not rendered.exists():
                quick = embedded_thumbnail(p, digest)
                if quick and not self._stale():
                    # Sent as a page as well as a thumbnail, because the viewer
                    # only draws pdfPages; a thumbnail on its own shows nothing.
                    self.backend.previewDetailReady.emit(
                        str(self.path), self.token,
                        {"thumbnailPath": quick, "pdfPages": [quick]})
            if rendered.exists():
                pages = []
                for idx in range(30):
                    q = pdf_page_path(digest, idx)
                    if not q.exists():
                        break
                    pages.append(str(q))
                frag["thumbnailPath"] = str(rendered)
                frag["pdfPages"] = pages or [str(rendered)]
            else:
                # THE EXTRACTED TEXT IS NOT THE PREVIEW, it is what there is until
                # the pages arrive. Showing it as the main view made a Word file
                # look like a plain text file for the couple of seconds soffice
                # takes -- and forever, on a document it could not convert. The
                # panel waits on this flag instead, and falls back to the text if
                # the render reports that it failed.
                frag["renderPending"] = True
                self.backend._thread_pool.start(
                    DocPreviewWorker(p, 30, self.backend, self.token))
            docx = get_docx()
            if docx and ext == ".docx":
                try:
                    d = docx.Document(str(p))
                    pars = [x.text for x in d.paragraphs if x.text.strip()]
                    frag["text"] = "\n\n".join(pars[:20])
                    frag["meta"] = {
                        "Format": "Word (.docx)",
                        "Paragraphs": f"{len(pars)} paragraphs",
                        "Word Count": f"~{sum(len(x.split()) for x in pars)} words"}
                except Exception:
                    frag["meta"] = {"Format": "Word Document"}
            else:
                frag.setdefault("meta", {"Format": "Office Document",
                                         "Size": self.size_str})
            return frag

        if cat in ("code", "document", "file"):
            # AN EPUB IS A ZIP, and reading one as UTF-8 filled the panel with
            # replacement characters under the heading "document". Anything the
            # mime database does not call text is not text, whatever the category
            # vocabulary decided to file it under. Sniffed rather than guessed
            # from the name, so a text file with an extension nobody has heard of
            # still previews -- which is why "file" is in the list at all.
            if not ICONS().is_text(p, deep=True):
                return None
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as fh:
                    lines = []
                    for _ in range(PREVIEW_TEXT_LINES):
                        line = fh.readline()
                        if not line:
                            break
                        lines.append(line)
                    # readline() past the end returns "", so a fixed-size list
                    # comprehension made EVERY text file report "250 lines".
                    truncated = bool(fh.readline())
                return {
                    "text": "".join(lines),
                    "meta": {"Lines": f"{len(lines)} lines"
                                      + (f" (first {PREVIEW_TEXT_LINES})" if truncated else ""),
                             "Encoding": "UTF-8",
                             "File Type": ext.upper().lstrip(".") or "TEXT",
                             "Size": self.size_str},
                }
            except Exception as exc:
                return {"text": f"Could not read text: {exc}"}

        return None


class CachePruneWorker(QRunnable):
    """Keep the render cache from growing without bound.

    Nothing ever removed anything from ~/.cache/sea-fm. Every PDF ever opened left
    up to thirty 300-DPI page images behind for good, so the cache grew forever on
    a machine that reads documents. Oldest-first to a budget, once at startup,
    on a thread — the point is that the user never has to think about it.
    """

    def run(self):
        try:
            entries = []
            total = 0
            for base in (PREVIEW_CACHE_DIR, ARCHIVE_CACHE_DIR, SHARE_CACHE_DIR):
                if not base.is_dir():
                    continue
                for f in base.iterdir():
                    try:
                        st = f.stat()
                    except OSError:
                        continue
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    entries.append((st.st_mtime, st.st_size, f))
                    total += st.st_size
            budget = max(64, int(PREFS().get("cacheBudgetMb") or 512)) * 1024 * 1024
            if total <= budget:
                return
            entries.sort()                      # oldest first
            for _mtime, size, f in entries:
                if total <= budget:
                    break
                try:
                    f.unlink()
                    total -= size
                except OSError:
                    pass
        except Exception:
            pass


# =====================================================================
# SHARING
# =====================================================================
#
# Sending files to a phone is a thing this shell could already do — sea-kdeconnect.py
# talks to the KDE Connect daemon over D-Bus and exposes --list and --send-file.
# There is no reason for the file manager to reimplement any of that, so it does
# not: it asks that script for the device list and hands it the paths.
#
# FOLDERS ARE ZIPPED FIRST, because the KDE Connect share plugin takes files and
# nothing else. Handing it a directory silently sends nothing at all, which is the
# worst possible outcome for a share button — it looks like it worked. Zipping is
# the same thing every other file manager's KDE Connect integration does, and it
# is why sharing runs on the operations engine: a 2 GB folder has to be packed
# before it can go, and that is not something to do on the UI thread.

SHARE_CACHE_DIR = Path.home() / ".cache" / "sea-fm" / "share"


def _kdeconnect_script():
    """sea-kdeconnect.py, whether we are running from the repo or the flat deploy.

    The installer flattens quickshell/**/ into one directory, so in a deployed
    shell the script is a sibling; in the repo it is a sibling too, both being
    under scripts/system/. One lookup covers both.
    """
    here = Path(__file__).resolve().parent / "sea-kdeconnect.py"
    if here.exists():
        return str(here)
    fallback = Path.home() / ".config" / "quickshell" / "sea-shell" / "sea-kdeconnect.py"
    return str(fallback) if fallback.exists() else ""


# =====================================================================
# DESKTOP ENTRIES
# =====================================================================
#
# "Open With" used to read a .desktop file as one undifferentiated blob and split
# its Exec value on whitespace. Three separate things were wrong with that and
# each of them broke real applications:
#
#   - Exec="/opt/Sublime Text/sublime_text" %F split into "/opt/Sublime and
#     Text/sublime_text", so anything installed under a path with a space in it
#     simply failed to launch;
#   - Exec was truncated at the first "%", which also ate the "%%" that means a
#     LITERAL percent sign;
#   - key lookups were not group-aware, so a [Desktop Action] block's Icon= and
#     Exec= overrode the application's own, and 'NoDisplay=true' matched anywhere
#     in the file — including inside an action that merely mentioned it.
#
# The parser below follows the specification instead: groups are groups, quoting
# is the spec's quoting, and field codes are expanded rather than deleted.

_EXEC_DROP = set("icCkdDnNvm")          # field codes with nothing useful to pass


def _desktop_unquote(value):
    """Split an Exec value into arguments, per the Desktop Entry spec.

    Inside double quotes, a backslash escapes ", `, $ and \\ ; outside them,
    whitespace separates arguments.
    """
    args, cur, in_q, esc, started = [], [], False, False, False
    for ch in value:
        if esc:
            cur.append(ch)
            esc = False
            continue
        if in_q:
            if ch == "\\":
                esc = True
            elif ch == '"':
                in_q = False
            else:
                cur.append(ch)
            continue
        if ch == '"':
            in_q, started = True, True
        elif ch.isspace():
            if cur or started:
                args.append("".join(cur))
            cur, started = [], False
        else:
            cur.append(ch)
    if cur or started or in_q:
        args.append("".join(cur))
    return args


def _exec_argv(exec_value, files):
    """A runnable argv from an Exec value and the files it is being given.

    %F and %U stand for the whole list and expand in place; %f and %u stand for
    one file. An entry with no field code at all still gets the files appended,
    because refusing to open them would be a worse answer than a spec-pure one.
    """
    files = [str(f) for f in files]
    argv, saw_field = [], False
    for token in _desktop_unquote(exec_value):
        if token in ("%F", "%U"):
            argv.extend(files)
            saw_field = True
            continue
        if token in ("%f", "%u"):
            if files:
                argv.append(files[0])
            saw_field = True
            continue
        if len(token) == 2 and token[0] == "%" and token[1] in _EXEC_DROP:
            continue
        out = []
        i = 0
        while i < len(token):
            if token[i] == "%" and i + 1 < len(token):
                nxt = token[i + 1]
                if nxt == "%":
                    out.append("%")
                    i += 2
                    continue
                if nxt in "fu":
                    out.append(files[0] if files else "")
                    saw_field = True
                    i += 2
                    continue
                if nxt in "FU":
                    out.append(" ".join(files))
                    saw_field = True
                    i += 2
                    continue
                if nxt in _EXEC_DROP:
                    i += 2
                    continue
            out.append(token[i])
            i += 1
        argv.append("".join(out))
    argv = [a for a in argv if a != ""]
    if not saw_field:
        argv.extend(files)
    return argv


def _read_desktop_entry(path):
    """The [Desktop Entry] group of a .desktop file, as a plain dict.

    Group-aware, and it stops at the next group — everything after
    [Desktop Action Foo] belongs to that action, not to the application.
    """
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            in_entry = False
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    if in_entry:
                        break
                    in_entry = line == "[Desktop Entry]"
                    continue
                if not in_entry or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                # Localised keys (Name[de]) are skipped: this is a lookup by
                # canonical key, and the untranslated value is the one wanted.
                if key.endswith("]"):
                    continue
                data.setdefault(key, val.strip())
    except OSError:
        return {}
    return data


def _desktop_is_visible(entry):
    """Whether this entry should be offered to a user at all."""
    if entry.get("Type") != "Application":
        return False
    if entry.get("NoDisplay", "").lower() == "true":
        return False
    if entry.get("Hidden", "").lower() == "true":
        return False
    if not entry.get("Exec"):
        return False
    # TryExec names the binary that must exist for the entry to be usable — the
    # standard way a package advertises an application it may not have installed.
    try_exec = entry.get("TryExec", "")
    if try_exec:
        if os.path.isabs(try_exec):
            if not os.access(try_exec, os.X_OK):
                return False
        elif shutil.which(try_exec) is None:
            return False
    return True


TERMINALS = ("kitty", "alacritty", "foot", "wezterm", "ghostty",
             "konsole", "gnome-terminal", "xfce4-terminal", "xterm")


def _desktop_dirs():
    """Everywhere a .desktop file can live, in the order the spec searches."""
    roots = [os.path.expanduser("~/.local/share")]
    roots += (os.environ.get("XDG_DATA_DIRS")
              or "/usr/local/share:/usr/share").split(":")
    out, seen = [], set()
    for r in roots:
        d = os.path.join(r.strip(), "applications")
        if d and d not in seen and os.path.isdir(d):
            seen.add(d)
            out.append(d)
    return out


def _desktop_exe(entry_id):
    """The program a desktop id runs, for matching against what is installed."""
    if not entry_id:
        return ""
    for base in _desktop_dirs():
        cand = Path(base) / entry_id
        if cand.exists():
            data = _read_desktop_entry(cand)
            argv = _exec_argv(data.get("Exec", ""), []) if data else []
            if argv:
                return argv[0]
    return ""


def _terminal_argv(cwd=None, inner=None):
    """A terminal to run something in, whichever of them is installed.

    kitty used to be hardcoded, so on a machine without it "Open in Terminal"
    raised FileNotFoundError and did nothing at all.
    """
    # THE ONE THE USER CHOSE COMES FIRST. Settings writes it to defaults.json --
    # a terminal is not a MIME type, so there is no standard place to ask -- and
    # without this the list below would keep opening whichever happened to be
    # installed first, whatever the preferences page said.
    order = list(TERMINALS)
    try:
        chosen = json.loads((Path.home() / ".config" / "sea-shell"
                             / "defaults.json").read_text()).get("terminal") or ""
        exe = Path(_desktop_exe(chosen)).name if chosen else ""
        if exe:
            order = [exe] + [t for t in order if t != exe]
    except Exception:
        pass

    for term in order:
        if shutil.which(term) is None:
            continue
        if inner:
            if term == "gnome-terminal":
                return [term, "--"] + inner
            return [term, "-e"] + inner
        if term in ("kitty", "wezterm"):
            return [term, "--directory", str(cwd)] if term == "kitty" else [term, "start", "--cwd", str(cwd)]
        if term == "gnome-terminal":
            return [term, f"--working-directory={cwd}"]
        if term in ("alacritty", "foot", "ghostty"):
            return [term, "--working-directory", str(cwd)]
        if term in ("konsole", "xfce4-terminal"):
            return [term, "--workdir", str(cwd)]
        return [term]
    return []


# =====================================================================
# FILE OPERATIONS
# =====================================================================
#
# WHY THERE IS AN ENGINE HERE AT ALL, AND NOT JUST shutil CALLS.
#
# Copying used to happen inline, on the UI thread, with shutil.copy2 in a for
# loop. Three things follow from that and all three were true:
#   - the window froze for the whole copy, with no progress and no way out;
#   - a destination that already existed was overwritten WITHOUT ASKING, which
#     is silent, permanent data loss and the worst bug this file manager had;
#   - "undo" then offered to reverse a paste that had eaten someone's file, and
#     reversing it took the survivor too.
#
# So the work moved to a worker thread, and the collision became a QUESTION.
#
# HOW THE QUESTION IS ASKED ACROSS A THREAD. The worker cannot open a dialog and
# the UI thread cannot block on the copy, so the worker emits `conflict` and then
# waits on an Event. The UI answers by calling resolve(), which stores the choice
# and sets the Event. That is the entire handshake; there is no polling and no
# nested event loop. "Apply to all" simply records the answer on the operation so
# the next collision never reaches the UI.
#
# REPLACE TRASHES, IT DOES NOT UNLINK. This is the one place this file manager is
# deliberately more careful than most. Choosing Replace moves the file being
# replaced to the trash first, so the operation stays reversible and the undo
# entry is honest — the same rule the undo journal already holds itself to.
# Replacing a folder with a folder MERGES instead, asking per file inside, so
# "replace" can never mean "delete a directory tree you did not look at".

FILEOP_CHUNK = 4 * 1024 * 1024
FILEOP_TICK = 0.08          # seconds between progress emissions

CONFLICT_REPLACE = "replace"
CONFLICT_KEEP_BOTH = "keepboth"
CONFLICT_SKIP = "skip"
CONFLICT_CANCEL = "cancel"


class _Cancelled(Exception):
    """Raised inside a worker when the user cancels; unwinds to run()."""


# Every operation reports itself the same way, so the UI has one thing to draw and
# one thing to cancel regardless of what is running. The verbs live here rather
# than in the QML because the status line, the notification and the undo label all
# need the same words and they must not drift apart.
# HOW LONG IS LEFT, AND WHEN IT IS HONEST TO SAY SO.
#
# An estimate made from the first fraction of a second of a copy is worthless --
# the rate has not settled, and a number that reads "4 hours" and then "12
# seconds" is worse than no number. Nautilus waits for the transfer rate to
# become reliable before it commits to one (its own constant for that is eight
# seconds) and shows the plain counts until then.
#
# The same idea here, with a shorter fuse: nothing is claimed for the first
# second and a half, or before a fiftieth of the work is done. After that the
# rate is an exponential moving average rather than a running total, so a copy
# that speeds up when it reaches a run of small files is reflected instead of
# being averaged away by its own slow start.
ETA_MIN_ELAPSED = 1.5       # seconds before any estimate is offered
ETA_MIN_FRACTION = 0.02     # ...and not before this much is done
ETA_SMOOTHING = 0.25        # weight of the newest sample in the moving average


def _fmt_duration(secs):
    """A rounded, readable length of time. Minutes are not shown beside hours
    unless the hours are few enough for the minutes to matter."""
    secs = int(secs)
    if secs < 60:
        return f"{max(1, secs)} second{'' if secs == 1 else 's'}"
    if secs < 3600:
        m = secs // 60
        return f"{m} minute{'' if m == 1 else 's'}"
    h, m = secs // 3600, (secs % 3600) // 60
    if h >= 4 or m == 0:
        return f"{h} hour{'' if h == 1 else 's'}"
    return f"{h} hour{'' if h == 1 else 's'}, {m} minute{'' if m == 1 else 's'}"


def _fmt_rate(per_sec, unit):
    if per_sec <= 0:
        return ""
    if unit == "bytes":
        return f"{_fmt_size(per_sec)}/s"
    return f"{per_sec:.0f} files/s" if per_sec >= 1 else ""


OP_VERBS = {
    "copy":     ("Copying",          "Copied"),
    "move":     ("Moving",           "Moved"),
    "trash":    ("Moving to Trash",  "Moved to Trash"),
    "delete":   ("Deleting",         "Deleted"),
    "compress": ("Compressing",      "Compressed"),
    "extract":  ("Extracting",       "Extracted"),
    "share":    ("Sharing",           "Shared"),
}


class _OpBase(QRunnable):
    """The shared half of every background operation.

    Progress, cancellation and the closing report are identical whether the work
    is a copy, a zip or an emptying of the trash — only the middle differs. Before
    this, only copy and move ran off the UI thread at all: zipping a folder,
    extracting an archive and deleting a large tree all froze the window with no
    indication that anything was happening and no way to stop it.
    """

    def __init__(self, engine, op_id, kind):
        super().__init__()
        self.e = engine
        self.op_id = op_id
        self.kind = kind
        self.total_files = 0
        self.total_bytes = 0
        self.done_files = 0
        self.done_bytes = 0
        self.records = []          # undo items, in the order applied
        self.skipped = 0
        self.failed = []
        self._tick = 0.0
        self._t0 = time.monotonic()
        self._rate = 0.0            # smoothed units per second
        self._last_t = self._t0
        self._last_done = 0
        self.phase = "measuring"    # measuring -> working
        self._in_measure = False    # true only while a tree is being counted

    def _check(self):
        if self.e.is_cancelled(self.op_id):
            raise _Cancelled()

    def _emit(self, current="", force=False):
        now = time.monotonic()
        if not force and now - self._tick < FILEOP_TICK:
            return
        self._tick = now
        # Byte progress where the work is measured in bytes, file counts where it
        # is not — extracting 900 tiny files is better described by "412 of 900"
        # than by a byte figure that jumps to 99% on the first large member.
        if self.total_bytes:
            unit, done, total = "bytes", self.done_bytes, self.total_bytes
        else:
            unit, done, total = "files", self.done_files, self.total_files
        pct = int(done * 100 / total) if total else 0
        # Counting is over the moment the walk says so. Deriving it from "is there
        # a denominator yet" instead left an operation with nothing to count --
        # copying an empty folder, or a tree of folders with no files in it --
        # saying "Preparing" from beginning to end, because the denominator it
        # was waiting for never arrived.
        if self.phase == "measuring" and total and not self._in_measure:
            self._begin_work(now)

        # The rate, as an average that leans on the recent past.
        dt = now - self._last_t
        if dt >= 0.25:
            inst = max(0.0, (done - self._last_done) / dt)
            self._rate = (inst if self._rate <= 0
                          else ETA_SMOOTHING * inst + (1 - ETA_SMOOTHING) * self._rate)
            self._last_t, self._last_done = now, done

        elapsed = now - self._t0
        eta_str = ""
        if (self.phase == "working" and total and self._rate > 0
                and elapsed >= ETA_MIN_ELAPSED
                and done >= total * ETA_MIN_FRACTION):
            left = (total - done) / self._rate
            if left >= 1:
                eta_str = _fmt_duration(left)

        self.e.progress.emit(self.op_id, {
            "kind": self.kind,
            "verb": OP_VERBS.get(self.kind, ("Working", "Done"))[0],
            "phase": self.phase,
            "doneFiles": self.done_files,
            "totalFiles": self.total_files,
            "doneBytes": self.done_bytes,
            "totalBytes": self.total_bytes,
            "doneStr": _fmt_size(self.done_bytes),
            "totalStr": _fmt_size(self.total_bytes),
            "percent": max(0, min(100, pct)),
            "current": current,
            "unit": unit,
            "etaStr": eta_str,
            "rateStr": _fmt_rate(self._rate, unit) if self.phase == "working" else "",
            "elapsed": round(elapsed, 1),
        })

    def _walk_measure(self, paths):
        """Count what is about to be processed, so progress has a denominator.

        Announced, because it is not instant on a large tree and the window used
        to show nothing at all until the first file was actually copied -- so the
        operation looked like it had not started.
        """
        self.phase = "measuring"
        self._in_measure = True
        self._emit(force=True)
        for src in [Path(p) for p in paths]:
            try:
                if src.is_dir() and not src.is_symlink():
                    for root, _dirs, files in os.walk(src, onerror=None):
                        self._check()
                        for fn in files:
                            self.total_files += 1
                            try:
                                self.total_bytes += os.lstat(
                                    os.path.join(root, fn)).st_size
                            except OSError:
                                pass
                        # Counting a large tree is not instant, and a window that
                        # says only "Preparing" for thirty seconds is indistinguishable
                        # from one that has hung. The running total goes out as it
                        # grows -- throttled by _emit, so this costs nothing.
                        self._emit()
                else:
                    self.total_files += 1
                    self.total_bytes += src.lstat().st_size
            except OSError:
                pass
        self._in_measure = False
        self._begin_work()

    def _begin_work(self, now=None):
        """Counting is done; from here the clock and the rate mean something.

        Called from _emit the moment a denominator exists, rather than from each
        worker's run(), because not every worker counts the same way -- extract
        takes its total from the archive's member list and never walks a tree at
        all. Deriving the moment from the numbers covers all of them, and cannot
        be forgotten in a new one.
        """
        self.phase = "working"
        self._t0 = now or time.monotonic()
        self._last_t = self._t0
        self._last_done = 0
        self._rate = 0.0

    def _report(self, cancelled):
        self.e.finish(self.op_id, self.kind, self.records, self.done_files,
                      self.skipped, self.failed, cancelled)


class TrashWorker(_OpBase):
    """Moving things to the trash, off the UI thread.

    Trashing is not free: it is a rename when the trash is on the same filesystem
    and a full copy when it is not, so a folder of holiday video trashed from a
    USB stick is minutes of work. It used to happen inline.
    """

    def __init__(self, engine, op_id, paths, trash_one):
        super().__init__(engine, op_id, "trash")
        self.paths = [Path(p) for p in paths]
        self._trash_one = trash_one

    def run(self):
        cancelled = False
        try:
            self.total_files = len(self.paths)
            self._emit(force=True)
            for p in self.paths:
                self._check()
                if not (p.exists() or p.is_symlink()):
                    continue
                try:
                    rec = self._trash_one(p)
                    # Only items whose destination in the trash is known can be
                    # reversed, and only those go on the undo stack — a label that
                    # overstates what it can undo is the one thing undo must never be.
                    if rec and rec.get("trash"):
                        rec = dict(rec, op="trash")
                        self.records.append(rec)
                except Exception as exc:
                    self.failed.append(f"{p.name}: {exc}")
                self.done_files += 1
                self._emit(p.name)
        except _Cancelled:
            cancelled = True
        self._emit(force=True)
        self._report(cancelled)


class DeleteWorker(_OpBase):
    """Permanent deletion, off the UI thread and with a way out of it.

    Records NO undo, and deliberately does not clear the stack either: there is no
    way to reverse this, and an Undo entry that cannot undo is worse than none.
    """

    def __init__(self, engine, op_id, paths, forget_record):
        super().__init__(engine, op_id, "delete")
        self.paths = [Path(p) for p in paths]
        self._forget = forget_record

    def _rm_tree(self, p):
        """Remove a tree file by file so progress moves and cancel is possible.

        shutil.rmtree is one opaque call: on a large tree it neither reports nor
        stops, which is precisely the case a progress bar exists for.
        """
        for root, dirs, files in os.walk(str(p), topdown=False, onerror=None):
            for fn in files:
                self._check()
                try:
                    os.unlink(os.path.join(root, fn))
                except OSError as exc:
                    self.failed.append(f"{fn}: {exc.strerror or exc}")
                self.done_files += 1
                self._emit(fn)
            for dn in dirs:
                try:
                    os.rmdir(os.path.join(root, dn))
                except OSError:
                    pass
        p.rmdir()

    def run(self):
        cancelled = False
        try:
            self._walk_measure(self.paths)
            self._emit(force=True)
            for p in self.paths:
                self._check()
                if not (p.exists() or p.is_symlink()):
                    continue
                try:
                    if p.is_dir() and not p.is_symlink():
                        self._rm_tree(p)
                    else:
                        p.unlink()
                        self.done_files += 1
                    # A file deleted straight out of a trash leaves its record
                    # behind, pointing at something that is no longer there.
                    self._forget(p)
                except _Cancelled:
                    raise
                except Exception as exc:
                    self.failed.append(f"{p.name}: {exc}")
                self._emit(p.name)
        except _Cancelled:
            cancelled = True
        self._emit(force=True)
        self._report(cancelled)


class CompressWorker(_OpBase):
    """Building an archive, member by member so it can be watched and stopped."""

    def __init__(self, engine, op_id, paths, out_path, fmt):
        super().__init__(engine, op_id, "compress")
        self.paths = [Path(p) for p in paths]
        self.out = Path(out_path)
        self.fmt = fmt

    def _members(self):
        """(path on disk, name inside the archive) for everything going in."""
        for p in self.paths:
            if not p.exists():
                continue
            if p.is_dir() and not p.is_symlink():
                yield p, p.name
                for root, dirs, files in os.walk(p):
                    base = Path(root)
                    for d in dirs:
                        full = base / d
                        yield full, str(full.relative_to(p.parent))
                    for f in files:
                        full = base / f
                        yield full, str(full.relative_to(p.parent))
            else:
                yield p, p.name

    def run(self):
        cancelled = False
        wrote = False
        try:
            self._walk_measure(self.paths)
            self._emit(force=True)
            if self.fmt == "zip":
                with zipfile.ZipFile(self.out, "w", zipfile.ZIP_DEFLATED) as zf:
                    for full, arc in self._members():
                        self._check()
                        try:
                            zf.write(full, arc)
                        except OSError as exc:
                            self.failed.append(f"{full.name}: {exc.strerror or exc}")
                            continue
                        if full.is_file():
                            self.done_files += 1
                            try:
                                self.done_bytes += full.lstat().st_size
                            except OSError:
                                pass
                        self._emit(full.name)
                wrote = True
            else:
                mode = {"tar.gz": "w:gz", "tar.xz": "w:xz",
                        "tar.bz2": "w:bz2", "tar": "w"}.get(self.fmt, "w:gz")
                with tarfile.open(self.out, mode) as tf:
                    for full, arc in self._members():
                        self._check()
                        try:
                            tf.add(str(full), arcname=arc, recursive=False)
                        except OSError as exc:
                            self.failed.append(f"{full.name}: {exc.strerror or exc}")
                            continue
                        if full.is_file():
                            self.done_files += 1
                            try:
                                self.done_bytes += full.lstat().st_size
                            except OSError:
                                pass
                        self._emit(full.name)
                wrote = True
        except _Cancelled:
            cancelled = True
        except Exception as exc:
            self.failed.append(str(exc))

        # A cancelled archive is a corrupt archive. Take the half-written file
        # away rather than leave something that looks like a finished one.
        if cancelled or (self.failed and not wrote):
            try:
                if self.out.exists():
                    self.out.unlink()
            except OSError:
                pass
        elif self.out.exists():
            self.records.append({"op": "create", "path": str(self.out)})
        self._emit(force=True)
        self._report(cancelled)


class ExtractWorker(_OpBase):
    """Unpacking an archive, member by member.

    Formats the standard library cannot open are handed to bsdtar or 7z when one
    of them is installed, so .7z, .rar and .tar.zst stop being a silent failure.
    """

    def __init__(self, engine, op_id, archive, target, members=None):
        super().__init__(engine, op_id, "extract")
        self.archive = Path(archive)
        self.target = Path(target)
        self.members = members          # None = the whole archive

    def _external(self):
        low = self.archive.name.lower()
        needs = low.endswith((".7z", ".rar", ".tar.zst", ".tzst", ".zst"))
        if not needs:
            return None
        if shutil.which("7z"):
            return ["7z", "x", "-y", f"-o{self.target}", str(self.archive)]
        if shutil.which("bsdtar"):
            return ["bsdtar", "-x", "-f", str(self.archive), "-C", str(self.target)]
        return []

    def run(self):
        cancelled = False
        before = set()
        try:
            self.target.mkdir(parents=True, exist_ok=True)
            before = set(os.listdir(self.target))

            ext_cmd = self._external()
            if ext_cmd is not None:
                if not ext_cmd:
                    self.failed.append(
                        f"{self.archive.suffix} needs 7z or bsdtar installed")
                else:
                    self.total_files = 1
                    self._emit(self.archive.name, force=True)
                    res = subprocess.run(ext_cmd, capture_output=True, text=True)
                    if res.returncode != 0:
                        self.failed.append(
                            (res.stderr or res.stdout or "extraction failed"
                             ).strip().splitlines()[0])
                    else:
                        self.done_files = 1
            else:
                low = self.archive.name.lower()
                if low.endswith((".zip", ".jar", ".whl", ".apk", ".cbz", ".epub")):
                    with zipfile.ZipFile(self.archive) as zf:
                        names = self.members or zf.namelist()
                        self.total_files = len(names)
                        self.total_bytes = sum(
                            i.file_size for i in zf.infolist()
                            if not self.members or i.filename in set(names))
                        self._emit(force=True)
                        for n in names:
                            self._check()
                            try:
                                zf.extract(n, self.target)
                                info = zf.getinfo(n)
                                self.done_bytes += info.file_size
                            except (KeyError, OSError) as exc:
                                self.failed.append(f"{n}: {exc}")
                            self.done_files += 1
                            self._emit(os.path.basename(n.rstrip("/")))
                else:
                    with tarfile.open(self.archive) as tf:
                        infos = (tf.getmembers() if not self.members
                                 else [tf.getmember(n) for n in self.members])
                        self.total_files = len(infos)
                        self.total_bytes = sum(i.size for i in infos)
                        self._emit(force=True)
                        for info in infos:
                            self._check()
                            try:
                                # Python 3.14 filters to the "data" profile by
                                # default, which refuses members that would land
                                # outside the destination.
                                tf.extract(info, self.target)
                                self.done_bytes += info.size
                            except Exception as exc:
                                self.failed.append(f"{info.name}: {exc}")
                            self.done_files += 1
                            self._emit(os.path.basename(info.name.rstrip("/")))
        except _Cancelled:
            cancelled = True
        except Exception as exc:
            self.failed.append(str(exc))

        # What the archive ADDED is whatever is there now that was not before.
        # Reading the member list instead would name files that already existed
        # and were overwritten, and trashing one of those on undo would take the
        # user's own file with it.
        try:
            added = sorted(set(os.listdir(self.target)) - before)
        except OSError:
            added = []
        for n in added:
            self.records.append({"op": "create", "path": str(self.target / n)})
        self._emit(force=True)
        self._report(cancelled)


class FileOpWorker(_OpBase):
    """One copy or move, start to finish, on a pool thread."""

    def __init__(self, engine, op_id, kind, sources, dest_dir):
        super().__init__(engine, op_id, kind)   # kind is "copy" or "move"
        self.sources = [Path(s) for s in sources]
        self.dest = Path(dest_dir)

    def _measure(self):
        self._walk_measure(self.sources)

    # ---- conflict ----

    def _ask(self, src, dst):
        """Replace / keep both / skip for one collision. Blocks this thread."""
        standing = self.e.standing_choice(self.op_id)
        if standing:
            return standing
        try:
            s_st, d_st = src.lstat(), dst.lstat()
        except OSError:
            return CONFLICT_REPLACE
        payload = {
            "opId": self.op_id,
            "name": src.name,
            "srcPath": str(src),
            "dstPath": str(dst),
            "srcIsDir": src.is_dir(),
            "dstIsDir": dst.is_dir(),
            "srcSizeStr": _fmt_size(s_st.st_size) if not src.is_dir() else "—",
            "dstSizeStr": _fmt_size(d_st.st_size) if not dst.is_dir() else "—",
            "srcWhen": QDateTime.fromSecsSinceEpoch(
                int(s_st.st_mtime)).toString("d MMM yyyy, hh:mm"),
            "dstWhen": QDateTime.fromSecsSinceEpoch(
                int(d_st.st_mtime)).toString("d MMM yyyy, hh:mm"),
            "srcNewer": s_st.st_mtime > d_st.st_mtime,
        }
        return self.e.raise_conflict(self.op_id, payload)

    # ---- the actual placing ----

    def _copy_file(self, src, dst):
        """Chunked so a big file still reports progress and can still be stopped."""
        with open(src, "rb") as fh, open(dst, "wb") as out:
            while True:
                self._check()
                block = fh.read(FILEOP_CHUNK)
                if not block:
                    break
                out.write(block)
                self.done_bytes += len(block)
                self._emit(src.name)
        shutil.copystat(str(src), str(dst), follow_symlinks=False)

    def _retire(self, victim):
        """Move what is being replaced to the trash, and say where it went."""
        rec = _trash_to_spec(victim)
        rec["op"] = "trash"
        self.records.append(rec)

    def _place(self, src, dst):
        self._check()

        # A symlink is copied as a symlink; following it would silently turn a
        # 40-byte link into a copy of whatever it points at.
        if src.is_symlink():
            return self._place_leaf(src, dst, link=True)

        if src.is_dir():
            if dst.exists() and not dst.is_dir():
                choice = self._ask(src, dst)
                if choice == CONFLICT_CANCEL:
                    raise _Cancelled()
                if choice == CONFLICT_SKIP:
                    self.skipped += 1
                    return
                if choice == CONFLICT_KEEP_BOTH:
                    dst = _free_name(dst)
                else:
                    self._retire(dst)
            elif dst.exists():
                # Folder onto folder is a MERGE, not a replacement. Nothing is
                # removed for being in the way; each file inside gets its own
                # question, or none if the answer already applies to all.
                pass

            if self.kind == "move" and not dst.exists():
                # Same filesystem: one rename moves the whole tree instantly.
                try:
                    os.rename(str(src), str(dst))
                except OSError:
                    pass
                else:
                    moved = sum(len(f) for _r, _d, f in os.walk(dst))
                    self.done_files += moved
                    try:
                        for root, _d, files in os.walk(dst):
                            for fn in files:
                                self.done_bytes += os.lstat(
                                    os.path.join(root, fn)).st_size
                    except OSError:
                        pass
                    self.records.append({"op": "move", "src": str(src),
                                         "dst": str(dst)})
                    self._emit(src.name, force=True)
                    return

            dst.mkdir(parents=True, exist_ok=True)
            created_here = not any(r.get("path") == str(dst) for r in self.records)
            for child in sorted(src.iterdir(), key=lambda c: c.name):
                self._place(child, dst / child.name)
            shutil.copystat(str(src), str(dst))
            if self.kind == "move":
                try:
                    src.rmdir()
                except OSError:
                    pass          # something inside was skipped; leave it be
            if created_here and self.kind == "copy":
                self.records.append({"op": "create", "path": str(dst)})
            return

        self._place_leaf(src, dst)

    def _place_leaf(self, src, dst, link=False):
        if dst.exists() or dst.is_symlink():
            choice = self._ask(src, dst)
            if choice == CONFLICT_CANCEL:
                raise _Cancelled()
            if choice == CONFLICT_SKIP:
                self.skipped += 1
                self.done_files += 1
                try:
                    self.done_bytes += src.lstat().st_size
                except OSError:
                    pass
                self._emit(src.name)
                return
            if choice == CONFLICT_KEEP_BOTH:
                dst = _free_name(dst)
            else:
                self._retire(dst)

        try:
            if link:
                target = os.readlink(str(src))
                os.symlink(target, str(dst))
                if self.kind == "move":
                    src.unlink()
                self.done_files += 1
            elif self.kind == "move":
                try:
                    os.rename(str(src), str(dst))
                except OSError:
                    self._copy_file(src, dst)
                    src.unlink()
                else:
                    try:
                        self.done_bytes += dst.lstat().st_size
                    except OSError:
                        pass
                self.done_files += 1
            else:
                self._copy_file(src, dst)
                self.done_files += 1
        except _Cancelled:
            # A half-written file is not a file. Take it back out before unwinding.
            try:
                if dst.exists():
                    dst.unlink()
            except OSError:
                pass
            raise
        except OSError as exc:
            self.failed.append(f"{src.name}: {exc.strerror or exc}")
            self.done_files += 1
            return

        self.records.append({"op": "move", "src": str(src), "dst": str(dst)}
                            if self.kind == "move"
                            else {"op": "create", "path": str(dst)})
        self._emit(src.name)

    # ---- entry point ----

    def run(self):
        cancelled = False
        try:
            self._measure()
            self._emit(force=True)
            for src in self.sources:
                self._check()
                if not (src.exists() or src.is_symlink()):
                    continue
                # Pasting a folder into itself, or into its own descendant, is a
                # loop that fills the disk. Refuse it rather than start it.
                if src.is_dir() and (src == self.dest
                                     or self.dest.is_relative_to(src)):
                    self.failed.append(f"{src.name}: cannot be placed inside itself")
                    continue
                dst = self.dest / src.name
                if self.kind == "move" and src == dst:
                    continue
                # Copying a file onto itself means "make a copy", not "ask".
                if self.kind == "copy" and src == dst:
                    dst = _free_name(dst)
                self._place(src, dst)
        except _Cancelled:
            cancelled = True
        except Exception as exc:
            self.failed.append(str(exc))

        self._emit(force=True)
        self.e.finish(self.op_id, self.kind, self.records, self.done_files,
                      self.skipped, self.failed, cancelled)


class ShareWorker(_OpBase):
    """Pack what needs packing, then hand everything to KDE Connect."""

    def __init__(self, engine, op_id, dev_id, dev_name, paths):
        super().__init__(engine, op_id, "share")
        self.dev_id = dev_id
        self.dev_name = dev_name or "device"
        self.paths = [Path(p) for p in paths]

    def _pack(self, folder):
        SHARE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        out = SHARE_CACHE_DIR / f"{folder.name}.zip"
        if out.exists():
            out = _free_name(out)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(folder, folder.name)
            for root, dirs, files in os.walk(folder):
                base = Path(root)
                for d in dirs:
                    full = base / d
                    zf.write(full, str(full.relative_to(folder.parent)))
                for f in files:
                    self._check()
                    full = base / f
                    try:
                        zf.write(full, str(full.relative_to(folder.parent)))
                    except OSError as exc:
                        self.failed.append(f"{f}: {exc.strerror or exc}")
                        continue
                    self.done_files += 1
                    try:
                        self.done_bytes += full.lstat().st_size
                    except OSError:
                        pass
                    self._emit(f"packing {f}")
        return out

    def run(self):
        cancelled = False
        outgoing = []
        try:
            self._walk_measure(self.paths)
            self._emit(force=True)
            for p in self.paths:
                self._check()
                if not p.exists():
                    continue
                if p.is_dir() and not p.is_symlink():
                    outgoing.append(str(self._pack(p)))
                else:
                    outgoing.append(str(p))
                    self.done_files += 1
                    try:
                        self.done_bytes += p.lstat().st_size
                    except OSError:
                        pass
                    self._emit(p.name)

            if outgoing and not self.failed:
                script = _kdeconnect_script()
                if not script:
                    self.failed.append("sea-kdeconnect.py not found")
                else:
                    self._emit(f"sending to {self.dev_name}", force=True)
                    res = subprocess.run(
                        [sys.executable, script, "--send-file", self.dev_id]
                        + outgoing,
                        capture_output=True, text=True, timeout=120)
                    if res.returncode != 0:
                        self.failed.append(
                            (res.stderr or "the device did not accept the files"
                             ).strip().splitlines()[0])
        except _Cancelled:
            cancelled = True
        except Exception as exc:
            self.failed.append(str(exc))

        self._emit(force=True)
        # Sharing creates nothing on this machine worth undoing — the zips are
        # cache, and the files themselves never moved.
        self.records = []
        self.e.finish(self.op_id, self.kind, [], len(outgoing),
                      self.skipped, self.failed, cancelled)


class FileOpEngine(QObject):
    """The process-wide owner of running copies and moves.

    Process-wide for the same reason the undo journal is: two panes are two views
    of one file system, and a copy started in one of them is not a fact about that
    half of the window.
    """

    progress = Signal(str, "QVariant")
    conflict = Signal("QVariant")
    resolved = Signal(str)
    finished = Signal(str, "QVariant")
    activeChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._pool = QThreadPool()
        # One at a time. Two concurrent copies to the same disk are slower than
        # the same two in sequence, and two conflict dialogs at once is not a
        # question anyone can answer.
        self._pool.setMaxThreadCount(1)
        self._seq = 0
        self._live = {}           # op_id -> {"cancel": bool, "all": str, "gate": Event, "choice": str}

    # ---- starting ----

    def _launch(self, kind, make_worker):
        """Register an operation and hand its worker to the pool.

        Every kind of work goes through here, so there is exactly one place that
        knows how an operation is born, cancelled and listed.
        """
        self._seq += 1
        op_id = f"op{self._seq}"
        self._live[op_id] = {"cancel": False, "all": "",
                             "gate": threading.Event(), "choice": "",
                             "kind": kind, "started": time.time()}
        self.activeChanged.emit()
        self._pool.start(make_worker(op_id))
        return op_id

    def _start(self, kind, sources, dest_dir):
        clean = [str(s) for s in sources if s]
        if not clean:
            return ""
        return self._launch(
            kind, lambda oid: FileOpWorker(self, oid, kind, clean, dest_dir))

    @Slot(list, str, result=str)
    def copyTo(self, sources, dest_dir):
        return self._start("copy", sources, dest_dir)

    @Slot(list, str, result=str)
    def moveTo(self, sources, dest_dir):
        return self._start("move", sources, dest_dir)

    def trashPaths(self, paths, trash_one):
        clean = [str(p) for p in paths if p]
        if not clean:
            return ""
        return self._launch(
            "trash", lambda oid: TrashWorker(self, oid, clean, trash_one))

    def deletePaths(self, paths, forget_record):
        clean = [str(p) for p in paths if p]
        if not clean:
            return ""
        return self._launch(
            "delete", lambda oid: DeleteWorker(self, oid, clean, forget_record))

    def compressPaths(self, paths, out_path, fmt):
        clean = [str(p) for p in paths if p]
        if not clean:
            return ""
        return self._launch(
            "compress", lambda oid: CompressWorker(self, oid, clean, out_path, fmt))

    def shareTo(self, dev_id, dev_name, paths):
        clean = [str(p) for p in paths if p]
        if not clean:
            return ""
        return self._launch(
            "share", lambda oid: ShareWorker(self, oid, dev_id, dev_name, clean))

    def extractArchiveTo(self, archive, target, members=None):
        return self._launch(
            "extract",
            lambda oid: ExtractWorker(self, oid, archive, target, members))

    @Property(bool, notify=activeChanged)
    def busy(self):
        return bool(self._live)

    # ---- the conflict handshake ----

    def raise_conflict(self, op_id, payload):
        """Called ON THE WORKER THREAD. Asks, then blocks until answered."""
        state = self._live.get(op_id)
        if state is None:
            return CONFLICT_CANCEL
        state["gate"].clear()
        state["choice"] = ""
        self.conflict.emit(payload)
        # The timeout is a deadlock guard, not a policy: if the dialog never
        # appears at all, the copy stops instead of hanging the pool for ever.
        if not state["gate"].wait(timeout=3600):
            return CONFLICT_CANCEL
        return state["choice"] or CONFLICT_CANCEL

    @Slot(str, str, bool)
    def resolve(self, op_id, choice, apply_to_all):
        """Called ON THE UI THREAD when the user answers the dialog."""
        state = self._live.get(op_id)
        if state is None:
            return
        if choice not in (CONFLICT_REPLACE, CONFLICT_KEEP_BOTH,
                          CONFLICT_SKIP, CONFLICT_CANCEL):
            choice = CONFLICT_CANCEL
        if apply_to_all and choice != CONFLICT_CANCEL:
            state["all"] = choice
        state["choice"] = choice
        if choice == CONFLICT_CANCEL:
            state["cancel"] = True
        state["gate"].set()
        self.resolved.emit(op_id)

    def standing_choice(self, op_id):
        state = self._live.get(op_id)
        return state["all"] if state else ""

    # ---- cancelling ----

    @Slot(str)
    def cancel(self, op_id):
        state = self._live.get(op_id)
        if state is None:
            return
        state["cancel"] = True
        state["choice"] = CONFLICT_CANCEL
        state["gate"].set()      # release a worker parked on a conflict

    @Slot()
    def cancelAll(self):
        for op_id in list(self._live):
            self.cancel(op_id)

    def is_cancelled(self, op_id):
        state = self._live.get(op_id)
        return state["cancel"] if state else True

    # ---- finishing ----

    UNDO_VERBS = {"copy": "Paste", "move": "Move", "trash": "Move to Trash",
                  "compress": "Compress", "extract": "Extract"}

    def finish(self, op_id, kind, records, done, skipped, failed, cancelled):
        self._live.pop(op_id, None)
        if records:
            # One entry for the whole operation, reversed newest-first. A paste
            # that replaced three files and created two is a single Undo, and
            # undoing it puts all five back. Permanent deletion records nothing,
            # so it never reaches here with items.
            UNDO().record("batch", self.UNDO_VERBS.get(kind, "Change"), records)
        _present, past = OP_VERBS.get(kind, ("Working", "Done"))
        bits = []
        if cancelled:
            bits.append(f"Cancelled — {done} item(s) already handled")
        else:
            bits.append(f"{past} {done} item(s)")
        if skipped:
            bits.append(f"{skipped} skipped")
        if failed:
            bits.append(f"{len(failed)} failed — {failed[0]}")
        summary = ", ".join(bits)
        self.finished.emit(op_id, {"kind": kind, "done": done,
                                   "skipped": skipped, "failed": failed,
                                   "cancelled": cancelled, "summary": summary})
        self.activeChanged.emit()


_OPS = None


def OPS():
    global _OPS
    if _OPS is None:
        _OPS = FileOpEngine()
    return _OPS


class FileManagerBackend(QObject):
    currentPathChanged = Signal(str)
    directoryChanged = Signal()
    showHiddenChanged = Signal(bool)
    viewModeChanged = Signal(str)
    gridIconSizeChanged = Signal(int)
    sortFieldChanged = Signal(str)
    sortDescendingChanged = Signal(bool)
    searchQueryChanged = Signal(str)
    filterTextChanged = Signal(str)
    selectedFileChanged = Signal(str)
    previewDataChanged = Signal(dict)
    bookmarksChanged = Signal(list)
    storageDevicesChanged = Signal(list)
    storageStatsChanged = Signal(dict)
    clipboardChanged = Signal(list, str)
    statusMessageChanged = Signal(str)
    themeChanged = Signal(dict)
    iconGenerationChanged = Signal()
    thumbnailReady = Signal(str, str)
    mediaInfoReady = Signal(str, dict)
    pdfPagesReady = Signal(str, list)
    dirSizeReady = Signal(str, dict)
    previewDetailReady = Signal(str, int, dict)
    shareDevicesChanged = Signal(list)
    duplicatesReady = Signal(list)
    duplicateProgress = Signal(int, str)

    def __init__(self, initial_path=None, parent=None, secondary=False):
        super().__init__(parent)
        self._secondary = secondary
        self._current_path = str(Path(initial_path).resolve()) if (initial_path and Path(initial_path).exists() and Path(initial_path).is_dir()) else str(Path.home())
        p = PREFS()
        self._show_hidden = bool(p.get("showHidden"))
        self._view_mode = str(p.get("defaultView") or "grid")
        self._grid_icon_size = max(64, min(256, int(p.get("gridIconSize") or 120)))
        self._sort_field = str(p.get("sortField") or "name")
        self._sort_descending = bool(p.get("sortDescending"))
        self._search_query = ""
        self._selected_file = ""
        self._preview_data = {}
        self._history = [self._current_path]
        self._history_idx = 0
        self._clipboard_paths = []
        self._clipboard_mode = "copy"
        self._status_message = "Ready"
        self._storage_stats = {}
        self._storage_devices = []
        self._udisks_procs = []     # kept alive until each call reports back
        self._thread_pool = QThreadPool.globalInstance()
        self._queued_thumbs = set()
        self._thumb_gen = 0
        self._icon_gen = 0          # bumped when themed icons change beneath their names
        self._icon_sig = None       # (theme name, folder tint) currently in force
        self._media_cache = {}
        self._thumb_cache = {}
        self._wk_dirs = None
        self._cat_palette = None
        self._thumb_pool = QThreadPool()
        self._thumb_pool.setMaxThreadCount(3)
        self._view_state = {}
        self._view_state_dirty = False
        # Cancellation for the two background walkers: a token bumped on every
        # new request, so a walk whose answer nobody is waiting for stops itself
        # instead of racing the one that replaced it.
        self._size_token = 0
        self._dupe_token = 0
        self._model = DirModel(self)
        self._refresh_pending = False
        # Bumped on every selection, so a preview that finishes after you have
        # already moved on is discarded instead of overwriting the current one.
        self._preview_token = 0
        self._preview_source = ""    # what the pending preview is being read from
        self._dragging = False
        self._share_devices = []
        self._share_proc = None
        self._tag_view = None
        self._place = None          # "starred" | "recent" when in one of those
        self._filter_text = ""      # the inline name filter, not the search box
        # The rest of the filter: kind, size, age and colour tag. Every desktop's
        # filter offers roughly these four — Finder and Explorer both do — because
        # they are the questions you can answer about a file without opening it.
        self._filter_kind = "any"
        self._filter_size = "any"
        self._filter_date = "any"
        self._filter_tag = ""
        self._archive = None        # (archive path, path inside it)
        self._arc_cache = {}        # one archive's index, keyed on its mtime
        self._theme = {
            "accent": "#63c7dd",
            "isDark": True,
            "isLight": False,
            "fontSans": "Adwaita Sans",
            "fontMono": "Roboto Mono",
            "radius": 8
        }

        self._apply_icon_theme()
        PREFS().changed.connect(self._apply_icon_theme)
        # Its own colours are a preference, so they repaint when one changes.
        PREFS().changed.connect(self._load_theme)
        self._load_theme()
        self._load_view_state()
        self._apply_view_state(self._current_path)  # startup: nothing is bound yet
        self._load_bookmarks()
        self._scan_storage_devices()
        self._update_storage_stats()
        self._update_default_dir_preview()

        # NOTHING USED TO NOTICE A FILE APPEARING. The only watcher in this file
        # was the one on appearance.json below, so a download finishing, a build
        # writing its output, or the other pane moving something in left the
        # listing showing a folder as it was when you arrived at it. Every refresh
        # had to be provoked by the user doing something themselves.
        self._dir_watcher = QFileSystemWatcher(self)
        self._dir_watcher.directoryChanged.connect(self._on_dir_changed)
        # Writing a file is many events — create, write, write, close — and a
        # rebuild per event would make an active folder unusable. One rebuild
        # shortly after the last of them is what people actually want to see.
        self._dir_settle = QTimer(self)
        self._dir_settle.setInterval(180)
        self._dir_settle.setSingleShot(True)
        self._dir_settle.timeout.connect(self._flush_dir_change)
        self._watch_current_dir()

        # Watch appearance.json for dynamic Matugen palette changes
        self._theme_watcher = QFileSystemWatcher(self)
        if APPEARANCE_FILE.exists():
            self._theme_watcher.addPath(str(APPEARANCE_FILE))
            self._theme_watcher.fileChanged.connect(self._on_appearance_file_changed)

        # The second pane would duplicate every scan and every signal for a list
        # that is identical in both.
        if not secondary:
            self._watch_devices()
            # Once per launch is enough, and it must not be on the way to the
            # first frame — see CachePruneWorker.
            QTimer.singleShot(4000, lambda: self._thread_pool.start(CachePruneWorker()))

        self.thumbnailReady.connect(self._on_thumbnail_ready)
        self.mediaInfoReady.connect(self._on_media_info_ready)
        self.pdfPagesReady.connect(self._on_pdf_pages_ready)
        self.previewDetailReady.connect(self._on_preview_detail)

        # Copies and moves run on a pool thread now, so the listing no longer
        # refreshes as a side effect of the call returning — it refreshes when
        # the work actually reports itself done.
        OPS().progress.connect(self._on_op_progress)
        OPS().finished.connect(self._on_op_finished)

        # THE MODEL KEEPS ITSELF CURRENT. Every signal that invalidates a listing
        # is wired to the same coalesced refresh, so no caller anywhere has to
        # remember to re-list after changing something — which is what the QML
        # used to do, unevenly, and is why some operations updated the view and
        # others quietly did not until you navigated away and back.
        for sig in (self.currentPathChanged, self.directoryChanged,
                    self.showHiddenChanged, self.sortFieldChanged,
                    self.sortDescendingChanged, self.searchQueryChanged,
                    self.filterTextChanged, self.themeChanged):
            sig.connect(lambda *_a: self.refresh())
        TAGS().changed.connect(self.refresh)
        STARS().changed.connect(self.refresh)
        self.refresh()

    def _on_op_progress(self, _op_id, info):
        verb = "Moving" if info.get("kind") == "move" else "Copying"
        name = info.get("current") or ""
        self.setStatus(f"{verb} {name} — {info.get('percent', 0)}% "
                       f"({info.get('doneStr')} of {info.get('totalStr')})")

    def _on_op_finished(self, _op_id, info):
        self.setStatus(info.get("summary", "Done"))
        self.directoryChanged.emit()

    def _on_thumbnail_ready(self, file_path, thumb_path):
        self._thumb_cache[file_path] = thumb_path
        self._model.patch_thumb(file_path, thumb_path)
        # Matched against the path the preview was GENERATED FROM: a file inside
        # an archive is rendered from its cache copy while the panel is labelled
        # with its location in the archive, so comparing to the displayed path
        # threw the thumbnail away. Same reason as _on_preview_detail.
        if self._preview_source == file_path and self._preview_data:
            if not self._preview_data.get("thumbnailPath"):
                self._preview_data["thumbnailPath"] = thumb_path
                # AND IT HAS TO BE VIEWABLE, not merely recorded. The page viewer
                # draws pdfPages and the placeholder only shows when there is no
                # thumbnail at all, so a document that had one picture and no pages
                # yet matched neither and the panel went blank until LibreOffice
                # finished converting. One page of one image is the honest state.
                if not self._preview_data.get("pdfPages"):
                    self._preview_data["pdfPages"] = [thumb_path]
                self._preview_data["renderPending"] = False
                self.previewDataChanged.emit(self._preview_data)

    def _on_media_info_ready(self, file_path, info):
        self._media_cache[file_path] = info
        if self._selected_file == file_path and self._preview_data:
            meta = self._preview_data.get("meta", {})
            fmt = info.get("format", {})
            if "duration" in fmt:
                d = float(fmt["duration"])
                mins = int(d // 60)
                secs = int(d % 60)
                meta["Duration"] = f"{mins:02d}:{secs:02d}"
            streams = info.get("streams", [])
            for s in streams:
                if "width" in s and "height" in s:
                    meta["Resolution"] = f"{s['width']} × {s['height']}"
                    break
            self._preview_data["meta"] = meta
            self.previewDataChanged.emit(self._preview_data)

    def _on_pdf_pages_ready(self, file_path, pages):
        if self._preview_source == file_path and self._preview_data and pages:
            self._preview_data["pdfPages"] = pages
            # An office document has no page count until it has been converted,
            # and the viewer's header reads "PDF" when it finds none. Pages arrive
            # in batches, so this tracks the batch rather than being set once --
            # otherwise the header said "1 Page" above a three page document.
            # A PDF is left alone: its count came from the file itself and is the
            # true total, which the thirty rendered pages are only a prefix of.
            if self._preview_data.get("category") != "pdf":
                self._preview_data["pageCount"] = len(pages)
            self._preview_data["renderPending"] = False
            self.previewDataChanged.emit(self._preview_data)

    def _on_appearance_file_changed(self, path):
        # The pause is for the writer to finish, but time.sleep() here ran ON THE
        # UI THREAD and froze the window every time the wallpaper changed. A timer
        # waits the same 50ms without stopping anything.
        QTimer.singleShot(50, self._reload_theme_file)

    def _reload_theme_file(self):
        self._load_theme()
        # An editor that replaces the file rather than writing into it leaves the
        # watcher pointed at an inode nobody will touch again, so the path is
        # re-added whenever it has fallen off.
        if APPEARANCE_FILE.exists() and str(APPEARANCE_FILE) not in self._theme_watcher.files():
            self._theme_watcher.addPath(str(APPEARANCE_FILE))

    @staticmethod
    def _theme_stem(name):
        for suffix in ("-Dark", "-Light", "-dark", "-light"):
            if name.endswith(suffix):
                return name[:-len(suffix)]
        return name

    def _variant_for_mode(self, base, installed):
        """Papirus / Papirus-Dark / Papirus-Light — whichever suits the mode.

        Several themes ship a light and a dark cut, differing in the shade the
        symbolic icons are drawn in. Picking the wrong one gives dark glyphs on a
        dark window, so the choice follows the window rather than being pinned.
        """
        stem = self._theme_stem(base)
        dark = self._theme.get("isDark", True)
        order = ([stem + "-Dark", stem + "-dark", stem]
                 if dark else [stem + "-Light", stem + "-light", stem])
        for cand in order:
            if cand in installed:
                return cand
        return base

    @Property(int, notify=iconGenerationChanged)
    def iconGeneration(self):
        """Bumped whenever the icons a name resolves to have changed underneath.

        QML CACHES PROVIDER PIXMAPS BY URL, and an icon's NAME does not change
        when the theme does -- a folder is "folder" in every theme there is. So
        image://fileicon/folder kept serving the bitmap it fetched the first
        time, and the new theme only appeared after a restart, which emptied the
        cache along with everything else. Delegates append this to the URL, so a
        theme change makes a URL QML has never seen and it fetches again.
        """
        return self._icon_gen

    def _apply_icon_theme(self):
        want = str(PREFS().get("iconTheme") or "")
        installed = set(self.iconThemes())
        if want and self._theme_stem(want) not in {self._theme_stem(i) for i in installed}:
            want = ""          # asked for a theme this machine does not have
        if want:
            want = self._variant_for_mode(want, installed)
        if not want:
            # Nothing chosen, or the choice is gone: keep whatever the desktop is
            # set to, and only invent one if that left us with nothing at all.
            want = QIcon.themeName() or ICON_THEME_FALLBACK
        ICONS().set_theme(want)
        # Whether the folder tint moved matters as much as whether the theme did.
        # Turning the tint off leaves every name resolving somewhere new while the
        # theme name stays put, and gating the re-list on the theme name alone
        # meant that switch changed nothing on screen until the window restarted.
        ICONS().set_accent(self._theme.get("accent", "#63c7dd")
                           if PREFS().get("tintFolders") else "")
        # Compared as a pair, and AFTER the fact, because set_theme resets the
        # tint as part of its own bookkeeping -- so asking set_accent whether it
        # changed anything answers "yes" every time and would re-list the folder
        # on every unrelated preference the user touches.
        sig = (want, ICONS()._tint)
        if sig != self._icon_sig:
            self._icon_sig = sig
            self._icon_gen += 1
            self.iconGenerationChanged.emit()
            self.refresh()

    @Slot(result=str)
    def folderTint(self):
        """The folder colour currently in use, for the preferences panel to show."""
        return ICONS()._tint or ""

    @Slot(result=int)
    def folderTintCount(self):
        return len(ICONS().folder_tints())

    @Slot(result=list)
    def iconThemes(self):
        """Icon themes installed on this machine, by directory name."""
        found = set()
        for base in QIcon.themeSearchPaths():
            try:
                for d in Path(base).iterdir():
                    if (d / "index.theme").exists():
                        found.add(d.name)
            except OSError:
                continue
        return sorted(found, key=str.lower)

    def _load_theme(self):
        accent = "#63c7dd"
        is_dark = True
        font_sans = "Adwaita Sans"
        font_mono = "Roboto Mono"
        radius = 8

        if APPEARANCE_FILE.exists():
            try:
                with open(APPEARANCE_FILE, "r") as f:
                    data = json.load(f)
                    accent = data.get("accent", "#63c7dd")
                    mode = data.get("mode", "dark")
                    is_dark = (mode != "light")
                    font_sans = data.get("font", "Adwaita Sans")
                    radius = data.get("radius", 8)
            except Exception:
                pass

        # A window with its own look overrides what it just read. The FONT still
        # comes from the shell either way — a file manager in a different typeface
        # from the rest of the desktop reads as broken rather than as customised.
        p = PREFS()
        if p.get("themeSource") == "own":
            # First run: adopt whatever the shell looks like right now, so an
            # independent theme starts out matching the desktop rather than
            # announcing itself with unrelated defaults. After that these are the
            # window's own and the shell can move without it.
            if not p.get("ownSeeded"):
                p.set("ownMode", "light" if not is_dark else "dark")
                p.set("ownAccent", accent)
                p.set("ownRadius", int(radius))
                p.set("ownSeeded", True)
            is_dark = str(p.get("ownMode") or "dark") != "light"
            accent = str(p.get("ownAccent") or accent)
            radius = int(p.get("ownRadius") or radius)

        self._theme = {
            "accent": accent,
            "isDark": is_dark,
            "isLight": not is_dark,
            "fontSans": font_sans,
            "fontMono": font_mono,
            "radius": radius
        }
        self._cat_palette = None
        # The accent decides the folder colour, so it is re-chosen whenever the
        # accent moves — including when matugen changes it from the wallpaper.
        # The light/dark cut of the icon theme follows the mode for the same reason.
        self._apply_icon_theme()
        self._sync_folder_tint()
        self.themeChanged.emit(self._theme)

    # ---- Properties ----
    @Property(str, notify=currentPathChanged)
    def currentPath(self):
        return self._current_path

    @Property(bool, notify=showHiddenChanged)
    def showHidden(self):
        return self._show_hidden

    @Property(str, notify=viewModeChanged)
    def viewMode(self):
        return self._view_mode

    @Property(int, notify=gridIconSizeChanged)
    def gridIconSize(self):
        return self._grid_icon_size

    @Property(str, notify=sortFieldChanged)
    def sortField(self):
        return self._sort_field

    @Property(bool, notify=sortDescendingChanged)
    def sortDescending(self):
        return self._sort_descending

    @Property(str, notify=searchQueryChanged)
    def searchQuery(self):
        return self._search_query

    @Property(str, notify=selectedFileChanged)
    def selectedFile(self):
        return self._selected_file

    @Property(dict, notify=previewDataChanged)
    def previewData(self):
        return self._preview_data

    @Property(list, notify=bookmarksChanged)
    def bookmarks(self):
        return self._bookmarks

    @Property(list, notify=shareDevicesChanged)
    def shareDevices(self):
        """Devices this selection could be sent to, newest answer each ask."""
        return self._share_devices

    @Slot()
    def refreshShareDevices(self):
        """Ask sea-kdeconnect for the device list, off the UI thread.

        ASYNCHRONOUS because the daemon may not be running: the script starts it
        and waits, and a subprocess.run() here would freeze the window for as
        long as that takes — while the user is holding a menu open.
        """
        script = _kdeconnect_script()
        if not script:
            self._share_devices = []
            self.shareDevicesChanged.emit([])
            return
        if self._share_proc is not None:
            return
        proc = QProcess(self)
        self._share_proc = proc

        def done(_code, _status):
            out = bytes(proc.readAllStandardOutput()).decode("utf-8", "replace")
            self._share_proc = None
            proc.deleteLater()
            try:
                devices = json.loads(out) if out.strip() else []
            except Exception:
                devices = []
            # Only devices that are actually PAIRED, REACHABLE and carry the
            # share plugin can receive a file. Listing the rest gives you a menu
            # entry that silently does nothing.
            usable = [d for d in devices
                      if d.get("isPaired") and d.get("isReachable")
                      and d.get("canShare")]
            if usable != self._share_devices:
                self._share_devices = usable
                self.shareDevicesChanged.emit(usable)

        proc.finished.connect(done)
        proc.errorOccurred.connect(lambda *_a: done(1, 0))
        proc.start(sys.executable, [script, "--list"])

    @Slot(int, int, result=list)
    def pathRange(self, a, b):
        """Every path between two rows, for shift-click range selection.

        Answered here because the listing lives in a QAbstractListModel and QML
        cannot index one directly.
        """
        rows = self._model._rows
        if not rows:
            return []
        a = max(0, min(len(rows) - 1, int(a)))
        b = max(0, min(len(rows) - 1, int(b)))
        lo, hi = (a, b) if a <= b else (b, a)
        return [r["path"] for r in rows[lo:hi + 1]]

    @Slot(str, result=int)
    def rowOf(self, path):
        for i, r in enumerate(self._model._rows):
            if r["path"] == path:
                return i
        return -1

    @Slot(str)
    def setThemeScope(self, scope):
        """Switch between following the shell and having our own look.

        Turning "own" on SEEDS the local values from whatever is on screen right
        now, so the switch itself changes nothing. Without that, choosing "just
        this window" would snap the accent and the roundness to whatever the
        defaults happened to be — which looks like a bug, not a choice.
        """
        p = PREFS()
        if scope == "own" and p.get("themeSource") != "own":
            p.set("ownMode", "dark" if self._theme.get("isDark", True) else "light")
            p.set("ownAccent", str(self._theme.get("accent", "#63c7dd")))
            p.set("ownRadius", int(self._theme.get("radius", 14)))
        p.set("themeSource", "own" if scope == "own" else "shell")
        p.set("themeChosen", True)      # this was asked for, not inherited

    @Slot(str, "QVariant")
    def setAppearance(self, key, value):
        """Change one shell-wide appearance key, for the whole shell.

        Written through sea-set-appearance.py, which merges — see the note on the
        preferences store. Writing appearance.json from here directly would reset
        every key this window does not know about, which is most of them.
        """
        script = _appearance_script()
        if not script:
            self.setStatus("sea-set-appearance.py not found")
            return
        if isinstance(value, bool):
            text = "true" if value else "false"
        else:
            text = str(value)
        try:
            subprocess.Popen([sys.executable, script, f"{key}={text}"],
                             start_new_session=True)
            self.setStatus(f"Appearance: {key} = {text}")
        except Exception as exc:
            self.setStatus(f"Could not change appearance: {exc}")

    @Slot(result=str)
    def cacheSize(self):
        total = 0
        for base in (PREVIEW_CACHE_DIR, ARCHIVE_CACHE_DIR, SHARE_CACHE_DIR):
            if not base.is_dir():
                continue
            for f in base.iterdir():
                try:
                    if f.is_file():
                        total += f.stat().st_size
                except OSError:
                    pass
        return _fmt_size(total)

    @Slot()
    def clearCache(self):
        removed = 0
        for base in (PREVIEW_CACHE_DIR, ARCHIVE_CACHE_DIR, SHARE_CACHE_DIR):
            if not base.is_dir():
                continue
            for f in list(base.iterdir()):
                try:
                    if f.is_file():
                        f.unlink()
                        removed += 1
                except OSError:
                    pass
        self._thumb_cache.clear()
        self._queued_thumbs.clear()
        self.setStatus(f"Cleared {removed} cached preview(s)")
        self.refresh()

    @Slot(str, str, list)
    def shareWith(self, dev_id, dev_name, paths):
        wanted = [p for p in paths if p and os.path.exists(p)]
        if not wanted:
            self.setStatus("Nothing selected to share")
            return
        if self._virtual(*wanted):
            self._refuse_virtual()
            return
        OPS().shareTo(dev_id, dev_name, wanted)

    @Property(list, notify=storageDevicesChanged)
    def storageDevices(self):
        return self._storage_devices

    @Property(dict, notify=storageStatsChanged)
    def storageStats(self):
        return self._storage_stats

    @Property(str, notify=statusMessageChanged)
    def statusMessage(self):
        return self._status_message

    @Property(dict, notify=themeChanged)
    def theme(self):
        return self._theme

    @Property(QObject, constant=True)
    def model(self):
        """The pane's rows. Constant because the OBJECT never changes — only its
        contents do, which is the entire point of it being a model."""
        return self._model

    @Slot()
    def refresh(self):
        """Re-read the folder and move the model to it, at most once per turn.

        COALESCED, because one navigation raises several of the signals that
        invalidate a listing — the path changes, then the saved view state
        restores a sort order, then the directory reports itself changed. The QML
        used to answer each of those with its own re-list, and separately had both
        a `backend` connection and a `be1` connection firing on the same path
        change, so a single click into a folder listed it twice over. Setting a
        flag and doing the work once the current batch of signals has been
        delivered collapses all of that into one pass.
        """
        if self._refresh_pending:
            return
        self._refresh_pending = True
        QTimer.singleShot(0, self._do_refresh)

    def _do_refresh(self):
        self._refresh_pending = False
        self._model.setEntries(self.getDirectoryContents())

    @Property("QVariantMap", notify=themeChanged)
    def categoryColors(self):
        """The derived per-category palette, so QML chrome can colour an
        archive action the same way it colours an archive file."""
        return self._category_palette()

    # ---- Navigation ----
    @staticmethod
    def _tag_view_for(path_str):
        """The tag a path names, "" for all tagged files, or None if not a tag view."""
        raw = str(path_str or "").rstrip("/") or "/"
        if raw != TAG_ROOT and not raw.startswith(TAG_ROOT + "/"):
            return None
        if os.path.isdir(TAG_ROOT):
            return None
        rest = raw[len(TAG_ROOT):].strip("/")
        if not rest:
            return ""
        return rest if rest in TAG_COLORS else None

    @staticmethod
    def _place_for(path_str):
        """"starred" / "recent" for those virtual roots, else None."""
        raw = str(path_str or "").rstrip("/") or "/"
        for root, name in ((STAR_ROOT, "starred"), (RECENT_ROOT, "recent")):
            if raw == root and not os.path.isdir(root):
                return name
        return None

    @Slot(str)
    def cd(self, path_str):
        if not path_str:
            return
        place = self._place_for(path_str)
        if place is not None:
            self._place = place
            self._tag_view = None
            self._archive = None
            self._land(STAR_ROOT if place == "starred" else RECENT_ROOT,
                       "Switched to")
            return
        tag = self._tag_view_for(path_str)
        if tag is not None:
            self._tag_view = tag
            self._place = None
            self._archive = None
            self._land(TAG_ROOT + ("/" + tag if tag else ""), "Switched to")
            return
        arc = self._archive_split(path_str)
        if arc is not None:
            self._tag_view = None
            self._place = None
            self._archive = arc
            self._land(str(Path(arc[0]) / arc[1]) if arc[1] else arc[0], "Opened")
            return
        target = Path(os.path.expanduser(path_str)).resolve()
        if target.exists() and target.is_dir():
            self._tag_view = None
            self._place = None
            self._archive = None
            if self._history_idx == len(self._history) - 1:
                self._history.append(str(target))
                self._history_idx += 1
            else:
                self._history = self._history[:self._history_idx + 1]
                self._history.append(str(target))
                self._history_idx += 1
            self._land(str(target), "Switched to", push=False)

    def _land(self, new_path, verb, push=True):
        """Everything that happens once a new location has been decided on.

        Shared by cd and the history buttons so a tag view arrived at by going Back
        is the same thing as one arrived at by clicking the tag.
        """
        self._current_path = new_path
        if push:
            if self._history_idx == len(self._history) - 1:
                self._history.append(new_path)
                self._history_idx += 1
            else:
                self._history = self._history[:self._history_idx + 1]
                self._history.append(new_path)
                self._history_idx += 1
        pending = self._apply_view_state(self._current_path)
        # A new folder is a new generation: thumbnails still queued for the one
        # being left are abandoned rather than rendered for nobody.
        self._thumb_gen += 1
        self._queued_thumbs.clear()
        self._watch_current_dir()
        self.currentPathChanged.emit(self._current_path)
        self._flush_pending(pending)
        self._selected_file = ""
        self.selectedFileChanged.emit("")
        # A virtual folder has no device behind it and nothing to preview, and
        # asking the filesystem about /Tags would just raise.
        if self._tag_view is None and self._archive is None and self._place is None:
            self._update_storage_stats()
            self._update_default_dir_preview()
        self.setStatus(f"{verb} {self._current_path}")

    def _watch_current_dir(self):
        """Follow the pane. A tag view and the inside of an archive have no
        directory behind them to watch, so neither is offered to inotify."""
        try:
            old = self._dir_watcher.directories()
            if old:
                self._dir_watcher.removePaths(old)
            if (self._tag_view is None and self._archive is None
                    and self._place is None):
                if os.path.isdir(self._current_path):
                    self._dir_watcher.addPath(self._current_path)
        except Exception:
            pass

    def _on_dir_changed(self, _path):
        self._dir_settle.start()

    def _flush_dir_change(self):
        # A directory that was deleted or unmounted is dropped by the watcher and
        # cannot simply be re-added. Step up to the nearest parent that still
        # exists rather than sit on a listing of somewhere that is gone.
        if not os.path.isdir(self._current_path):
            p = Path(self._current_path)
            while p != p.parent and not p.is_dir():
                p = p.parent
            self.cd(str(p))
            return
        if self._current_path not in self._dir_watcher.directories():
            try:
                self._dir_watcher.addPath(self._current_path)
            except Exception:
                pass
        self._update_storage_stats()
        self.directoryChanged.emit()

    @Slot()
    def goUp(self):
        parent = Path(self._current_path).parent
        if parent and parent.exists() and str(parent) != self._current_path:
            self.cd(str(parent))

    @Slot()
    def goBack(self):
        if self._history_idx > 0:
            self._history_idx -= 1
            dest = self._history[self._history_idx]
            self._place = self._place_for(dest)
            self._tag_view = None if self._place else self._tag_view_for(dest)
            self._archive = (None if (self._place or self._tag_view is not None)
                             else self._archive_split(dest))
            self._land(dest, "Back to", push=False)

    @Slot()
    def goForward(self):
        if self._history_idx < len(self._history) - 1:
            self._history_idx += 1
            dest = self._history[self._history_idx]
            self._place = self._place_for(dest)
            self._tag_view = None if self._place else self._tag_view_for(dest)
            self._archive = (None if (self._place or self._tag_view is not None)
                             else self._archive_split(dest))
            self._land(dest, "Forward to", push=False)

    @Slot(bool)
    def setShowHidden(self, val):
        self._show_hidden = val
        self.showHiddenChanged.emit(val)

    @Slot(str)
    def setViewMode(self, mode):
        # "compact" is Dolphin's third mode: names in narrow columns that flow
        # downwards then across, which fits far more of a large folder on screen
        # than the grid and reads faster than the detail list when all you want
        # is to find a name.
        if mode in ["grid", "list", "compact"]:
            self._view_mode = mode
            self.viewModeChanged.emit(mode)
            self._remember_view_state()

    @Slot(int)
    def setGridIconSize(self, size):
        size = max(64, min(256, size))
        if size == self._grid_icon_size:
            return
        self._grid_icon_size = size
        self.gridIconSizeChanged.emit(self._grid_icon_size)
        self._remember_view_state()

    @Slot(str)
    def setSortField(self, field):
        self._sort_field = field
        self.sortFieldChanged.emit(field)
        self._remember_view_state()

    @Slot(bool)
    def setSortDescending(self, desc):
        self._sort_descending = desc
        self.sortDescendingChanged.emit(desc)
        self._remember_view_state()

    @Property(str, notify=filterTextChanged)
    def filterText(self):
        return self._filter_text

    @Slot(str)
    def setFilterText(self, text):
        text = (text or "").strip().lower()
        if text == self._filter_text:
            return
        self._filter_text = text
        self.filterTextChanged.emit(text)

    @Property(str, notify=currentPathChanged)
    def placeView(self):
        """"starred", "recent" or "" — the chrome needs to know which it is in."""
        return self._place or ""

    @Slot(str)
    def setSearchQuery(self, query):
        self._search_query = query.strip()
        self.searchQueryChanged.emit(self._search_query)

    @Slot(str)
    def setStatus(self, msg):
        self._status_message = msg
        self.statusMessageChanged.emit(msg)

    # ---- Fast Directory Listing & Live Recursive Search ----
    @Slot(result=list)
    def getDirectoryContents(self):
        path = Path(self._current_path)
        if (self._tag_view is None and self._archive is None
                and self._place is None
                and (not path.exists() or not path.is_dir())):
            return []

        entries = []
        q = self._search_query.lower()

        if self._archive is not None:
            entries = self._archive_entries(self._archive[0], self._archive[1], q)
        elif self._place == "starred":
            entries = self._paths_as_entries(STARS().paths(), q)
        elif self._place == "recent":
            # Newest first, and NOT re-sorted below — the order is the whole
            # meaning of "recent", so a Recent view sorted by name is useless.
            entries = self._paths_as_entries(recent_paths(), q)
            return self._apply_filter(entries)
        elif self.inTrash:
            entries = self._trash_entries(q)
        elif self._tag_view is not None:
            entries = self._tagged_entries(self._tag_view, q)
        elif q:
            def scan_recursive(dir_path, depth=0):
                if depth > 3 or len(entries) >= 150:
                    return
                try:
                    with os.scandir(dir_path) as it:
                        for entry in it:
                            if len(entries) >= 150:
                                break
                            name = entry.name
                            if not self._show_hidden and name.startswith("."):
                                continue
                            try:
                                is_dir = entry.is_dir(follow_symlinks=False)
                                if q in name.lower():
                                    stat = entry.stat(follow_symlinks=False)
                                    size = stat.st_size if not is_dir else 0
                                    mtime = stat.st_mtime
                                    ext = Path(name).suffix.lower()
                                    icon_name, category, color, badge = self._categorize_file(name, is_dir, ext, entry.path)

                                    # Search stays instant: recursive hits show a
                                    # thumbnail only if one is already cached.
                                    thumb_path = self._resolve_thumb(entry.path, category, mtime, queue=False)

                                    entries.append({
                                        "name": name,
                                        "path": entry.path,
                                        "isDir": is_dir,
                                        "size": size,
                                        "sizeStr": self._format_size(size) if not is_dir else "--",
                                        "mtime": mtime,
                                        "mtimeStr": QDateTime.fromSecsSinceEpoch(int(mtime)).toString("yyyy-MM-dd hh:mm"),
                                        "extension": ext,
                                        "extBadge": badge,
                                        "mimeType": mimetypes.guess_type(name)[0] or ("folder" if is_dir else "file"),
                                        "iconName": icon_name,
                                        "category": category,
                                        "accentColor": color,
                                        "themeIcon": self.theme_icon(name, is_dir, entry.path),
                                        "thumbnailPath": thumb_path,
                                        "tag": TAGS().get(entry.path)
                                    })

                                if is_dir:
                                    scan_recursive(entry.path, depth + 1)
                            except OSError:
                                continue
                except OSError:
                    pass

            scan_recursive(path, 0)
        else:
            try:
                with os.scandir(path) as it:
                    for entry in it:
                        name = entry.name
                        if not self._show_hidden and name.startswith("."):
                            continue

                        try:
                            stat = entry.stat(follow_symlinks=False)
                            is_dir = entry.is_dir(follow_symlinks=True)
                            size = stat.st_size if not is_dir else 0
                            mtime = stat.st_mtime
                            ext = Path(name).suffix.lower()

                            icon_name, category, color, badge = self._categorize_file(name, is_dir, ext, entry.path)

                            thumb_path = self._resolve_thumb(entry.path, category, mtime)

                            entries.append({
                                "name": name,
                                "path": entry.path,
                                "isDir": is_dir,
                                "size": size,
                                "sizeStr": self._format_size(size) if not is_dir else "--",
                                "mtime": mtime,
                                "mtimeStr": QDateTime.fromSecsSinceEpoch(int(mtime)).toString("yyyy-MM-dd hh:mm"),
                                "extension": ext,
                                "extBadge": badge,
                                "mimeType": mimetypes.guess_type(name)[0] or ("folder" if is_dir else "file"),
                                "iconName": icon_name,
                                "category": category,
                                "accentColor": color,
                                "themeIcon": self.theme_icon(name, is_dir, entry.path),
                                "thumbnailPath": thumb_path,
                                "tag": TAGS().get(entry.path)
                            })
                        except OSError:
                            continue
            except OSError as e:
                self.setStatus(f"Error reading directory: {e}")
                return []

        def sort_key(item):
            val = item.get(self._sort_field, "")
            if self._sort_field == "name":
                val = str(val).lower()
            return val

        # TWO PASSES, AND THE ORDER OF THEM IS THE POINT. Folding "is it a folder"
        # into the sort key put it under the same `reverse` as the field being
        # sorted, so choosing Z-A did not just reverse the names — it moved every
        # folder to the BOTTOM. Sorting by the field first and then stably
        # partitioning folders to the top keeps the grouping fixed while the
        # direction toggle only ever means what it says.
        entries.sort(key=sort_key, reverse=self._sort_descending)
        entries.sort(key=lambda it: not it["isDir"])
        return self._apply_filter(entries)

    # What each size band means, in bytes. Folders are never size-filtered: the
    # size of a directory entry says nothing about what is in it.
    SIZE_BANDS = {
        "small":  (0, 1024 * 1024),
        "medium": (1024 * 1024, 100 * 1024 * 1024),
        "large":  (100 * 1024 * 1024, None),
    }

    # And each age band, in seconds.
    DATE_BANDS = {
        "today": 86400,
        "week": 7 * 86400,
        "month": 30 * 86400,
        "year": 365 * 86400,
    }

    # A "kind" is a group of the categories the listing already assigns, so the
    # filter and the icon colours can never disagree about what a file is.
    KIND_CATEGORIES = {
        "folder":   {"directory"},
        "image":    {"image"},
        "video":    {"video"},
        "audio":    {"audio"},
        "document": {"document", "pdf"},
        "code":     {"code"},
        "archive":  {"archive"},
    }

    def _apply_filter(self, entries):
        """The filter: name, kind, size, age and tag, all at once.

        DISTINCT FROM THE SEARCH BOX on purpose, which is the distinction Dolphin
        draws too: search walks subdirectories and can take a moment, while the
        filter only ever hides rows already listed and is therefore instant. They
        are different questions — "where is this file" and "show me less".
        """
        f = self._filter_text
        kind = self._filter_kind
        size = self._filter_size
        date = self._filter_date
        tag = self._filter_tag
        if not f and kind == "any" and size == "any" and date == "any" and not tag:
            return entries

        cats = self.KIND_CATEGORIES.get(kind)
        lo = hi = None
        if size in self.SIZE_BANDS:
            lo, hi = self.SIZE_BANDS[size]
        cutoff = None
        if date in self.DATE_BANDS:
            cutoff = time.time() - self.DATE_BANDS[date]

        out = []
        for e in entries:
            if f and f not in e["name"].lower():
                continue
            if cats is not None and e.get("category") not in cats:
                continue
            if tag and e.get("tag") != tag:
                continue
            # A folder has no meaningful length, so a size band would hide every
            # one of them for no reason anybody would expect.
            if lo is not None and not e.get("isDir"):
                n = e.get("size") or 0
                if n < lo or (hi is not None and n >= hi):
                    continue
            elif lo is not None and e.get("isDir"):
                continue
            if cutoff is not None and (e.get("mtime") or 0) < cutoff:
                continue
            out.append(e)
        return out

    @Property(str, notify=filterTextChanged)
    def filterKind(self):
        return self._filter_kind

    @Property(str, notify=filterTextChanged)
    def filterSize(self):
        return self._filter_size

    @Property(str, notify=filterTextChanged)
    def filterDate(self):
        return self._filter_date

    @Property(str, notify=filterTextChanged)
    def filterTag(self):
        return self._filter_tag

    @Property(int, notify=filterTextChanged)
    def activeFilterCount(self):
        """How many conditions are narrowing the listing, for the badge."""
        n = 0
        if self._filter_text:
            n += 1
        if self._filter_kind != "any":
            n += 1
        if self._filter_size != "any":
            n += 1
        if self._filter_date != "any":
            n += 1
        if self._filter_tag:
            n += 1
        return n

    @Slot(str, str)
    def setFilterFacet(self, facet, value):
        """One entry point for all four dropdowns, so they cannot drift apart."""
        attr = {"kind": "_filter_kind", "size": "_filter_size",
                "date": "_filter_date", "tag": "_filter_tag"}.get(facet)
        if not attr:
            return
        value = str(value or ("" if facet == "tag" else "any"))
        if getattr(self, attr) == value:
            return
        setattr(self, attr, value)
        self.filterTextChanged.emit(self._filter_text)

    @Slot()
    def clearFilters(self):
        if not self.activeFilterCount:
            return
        self._filter_text = ""
        self._filter_kind = "any"
        self._filter_size = "any"
        self._filter_date = "any"
        self._filter_tag = ""
        self.filterTextChanged.emit("")

    def _paths_as_entries(self, paths, q=""):
        out = []
        for p in paths:
            if q and q not in os.path.basename(p).lower():
                continue
            entry = self._entry_for(p)
            if entry:
                out.append(entry)
        return out

    # ---- Fast Zero-Lag Inspector & File Preview ----
    @Slot(str)
    def selectFile(self, file_path):
        self._selected_file = file_path
        self.selectedFileChanged.emit(file_path)
        if file_path:
            # A member has no path on disk to read, so it is unpacked into the
            # cache once and previewed from there. The panel still shows the name
            # and the location inside the archive, not the cache file's.
            arc = self._archive_split(file_path) if self._archive else None
            if arc and arc[1]:
                real = self._extract_member(arc[0], arc[1])
                if real:
                    self.generatePreview(real)
                    if self._preview_data:
                        self._preview_data["name"] = Path(file_path).name
                        self._preview_data["path"] = file_path
                        self.previewDataChanged.emit(self._preview_data)
                else:
                    self._preview_data = {
                        "name": Path(file_path).name, "path": file_path,
                        "isDir": False, "category": "archive",
                        "iconName": "folder_zip", "sizeStr": "--",
                        "text": "", "html": "", "thumbnailPath": "",
                        "pdfPages": [], "pageCount": 0,
                        "meta": {"In archive": Path(arc[0]).name,
                                 "Note": "Too large to preview — extract it first"},
                    }
                    self.previewDataChanged.emit(self._preview_data)
                return
            self.generatePreview(file_path)
        else:
            self._update_default_dir_preview()

    def _update_default_dir_preview(self):
        p = Path(self._current_path)
        if not p.exists():
            return

        try:
            stat = p.stat()
            self._preview_data = {
                "name": p.name or "Root Directory",
                "path": str(p),
                "isDir": True,
                "mime": "inode/directory",
                "sizeStr": "--",
                "mtimeStr": QDateTime.fromSecsSinceEpoch(int(stat.st_mtime)).toString("yyyy-MM-dd hh:mm:ss"),
                "category": "directory",
                "iconName": "folder",
                "color": self._theme.get("accent", "#63c7dd"),
                "text": "",
                "html": "",
                "thumbnailPath": "",
                "pdfPages": [],
                "pageCount": 0,
                "meta": {
                    "Storage Free": self._storage_stats.get("freeStr", "--"),
                    "Total Capacity": self._storage_stats.get("totalStr", "--")
                }
            }
        except Exception:
            self._preview_data = {
                "name": p.name or "Root Directory",
                "path": str(p),
                "isDir": True,
                "mime": "inode/directory",
                "sizeStr": "--",
                "mtimeStr": "--",
                "category": "directory",
                "iconName": "folder",
                "color": self._theme.get("accent", "#63c7dd"),
                "text": "",
                "html": "",
                "thumbnailPath": "",
                "pdfPages": [],
                "pageCount": 0,
                "meta": {}
            }
        self.previewDataChanged.emit(self._preview_data)

    @Slot(str)
    def generatePreview(self, file_path):
        """Everything cheap, now; everything expensive, shortly.

        The panel is filled from a stat and the file's name — which costs
        nothing — and dispatched to a worker for the parts that used to freeze
        the window. See the note above PreviewWorker for why the split is here.
        """
        p = Path(file_path)
        if not p.exists():
            self._update_default_dir_preview()
            return

        is_dir = p.is_dir()
        st = None
        try:
            st = p.stat()
            mtime_str = QDateTime.fromSecsSinceEpoch(
                int(st.st_mtime)).toString("yyyy-MM-dd hh:mm:ss")
            size_str = self._format_size(st.st_size) if not is_dir else "--"
        except OSError:
            mtime_str, size_str = "--", "--"

        mime, _ = mimetypes.guess_type(file_path)
        mime = mime or ("folder" if is_dir else "application/octet-stream")
        ext = p.suffix.lower()
        icon_name, category, color, badge = self._categorize_file(
            p.name, is_dir, ext, str(p))

        self._preview_token += 1
        token = self._preview_token
        self._preview_source = str(p)

        preview = {
            "name": p.name, "path": str(p), "isDir": is_dir, "mime": mime,
            "sizeStr": size_str, "mtimeStr": mtime_str, "category": category,
            "iconName": icon_name, "color": color, "badge": badge,
            "text": "", "html": "", "thumbnailPath": "", "pdfPages": [],
            "pageCount": 0, "loading": False,
            "meta": {"Type": badge or ext.lstrip(".").upper() or "File",
                     "Size": size_str},
        }

        if is_dir:
            preview["meta"] = {"Type": "Directory Folder",
                               "Storage Free": self._storage_stats.get("freeStr", "--")}
        elif category == "archive":
            preview["meta"] = {"Archive Type": badge or "Archive",
                               "Compressed Size": size_str}
        elif category in ("video", "audio"):
            # A cached thumbnail is a dictionary lookup, so it goes in now; the
            # ffprobe metadata was already asynchronous.
            digest = (hashlib.md5(f"{p.resolve()}_{st.st_mtime}".encode()).hexdigest()
                      if st is not None else "")
            if category == "video" and digest:
                thumb = video_thumb_path(digest)
                if thumb.exists():
                    preview["thumbnailPath"] = str(thumb)
                else:
                    self._thumb_pool.start(ThumbnailWorker(p, "video", self))
            cached = self._media_cache.get(str(p))
            if cached:
                preview["meta"] = self._media_meta(cached, ext, size_str)
            else:
                preview["meta"] = {"Container" if category == "video" else "Format":
                                   ext.upper().lstrip("."), "Size": size_str}
                self._thread_pool.start(MediaInfoWorker(p, self))

        # "file" is here so a text file with an unrecognised extension still gets
        # looked at; PreviewWorker sniffs it and returns nothing if it is binary.
        if category in ("pdf", "image", "code", "document", "file"):
            # The panel says so rather than looking finished-but-empty.
            preview["loading"] = True
            self._thread_pool.start(
                PreviewWorker(self, p, category, ext, size_str, token))

        self._preview_data = preview
        self.previewDataChanged.emit(preview)

    @staticmethod
    def _media_meta(info, ext, size_str):
        fmt = info.get("format", {})
        meta = {"Container": ext.upper().lstrip("."), "Size": size_str}
        if "duration" in fmt:
            try:
                d = float(fmt["duration"])
                meta["Duration"] = f"{int(d // 60):02d}:{int(d % 60):02d}"
            except (TypeError, ValueError):
                pass
        for s in info.get("streams", []):
            if "width" in s and "height" in s:
                meta["Resolution"] = f"{s['width']} × {s['height']}"
                break
        return meta

    def _on_preview_detail(self, path, token, frag):
        """Merge a worker's findings into the panel, if it is still the one shown.

        Matched against the path the preview was GENERATED FROM, not the one the
        panel displays. For a file inside an archive those differ: the member is
        unpacked to a cache file and read from there, while the panel is relabelled
        with its location inside the archive. Comparing against the displayed path
        meant every archive member's text and thumbnail was computed and then
        thrown away for not matching.
        """
        if token != self._preview_token:
            return
        if not self._preview_data or self._preview_source != path:
            return
        merged = dict(self._preview_data)
        for k, v in frag.items():
            if k == "meta":
                m = dict(merged.get("meta", {}))
                m.update(v)
                merged["meta"] = m
            else:
                merged[k] = v
        merged["loading"] = False
        self._preview_data = merged
        self.previewDataChanged.emit(merged)

    # ---- Storage Statistics ----
    def _update_storage_stats(self):
        try:
            usage = shutil.disk_usage(self._current_path)
            total = usage.total
            used = usage.used
            free = usage.free
            percent = int((used / total) * 100) if total else 0

            self._storage_stats = {
                "total": total,
                "used": used,
                "free": free,
                "percent": percent,
                "freeStr": self._format_size(free),
                "totalStr": self._format_size(total),
                "usedStr": self._format_size(used)
            }
            self.storageStatsChanged.emit(self._storage_stats)
        except Exception:
            pass

    # ---- Archive Operations (Zip / Unzip / Tar) ----
    @Slot(list)
    @Slot(list, str)
    @Slot(list, str, str)
    def compressFiles(self, file_paths, archive_name="", format_type="zip"):
        if not file_paths:
            return
        if self._virtual(self._current_path):
            self._refuse_virtual(); return
        parent_dir = Path(self._current_path)
        first = Path(file_paths[0])
        base = archive_name.strip() if archive_name else (
            first.stem if len(file_paths) == 1 else "archive")

        fmt = format_type if format_type in (
            "zip", "tar.gz", "tar.xz", "tar.bz2", "tar") else "zip"
        suffix = "." + fmt
        if not base.lower().endswith(suffix):
            base += suffix
        out_path = parent_dir / base
        # Never write over an archive that is already there. The old version did,
        # so compressing twice in a row destroyed the first archive silently.
        if out_path.exists():
            out_path = _free_name(out_path)
        OPS().compressPaths(list(file_paths), str(out_path), fmt)

    @Slot(str)
    @Slot(str, bool)
    def extractArchive(self, archive_path, extract_to_subfolder=False):
        p = Path(archive_path)
        if not p.is_file():
            return
        # _archive_stem, not Path.stem: the latter strips ONE suffix, so
        # photos.tar.gz unpacked into a folder named "photos.tar".
        target = (p.parent / _archive_stem(p)) if extract_to_subfolder else p.parent
        OPS().extractArchiveTo(str(p), str(target))

    # ---- File Operations & Open With ----
    @Slot(str, result=str)
    def urlToPath(self, url_str):
        if not url_str:
            return ""
        if url_str.startswith("file://"):
            return QUrl(url_str).toLocalFile()
        return url_str

    @Slot(list)
    def startNativeDrag(self, file_paths):
        """Begin a drag of the current selection.

        WHY THERE IS A GUARD, AND WHY IT IS NOT OPTIONAL. QDrag.exec() BLOCKS in a
        nested event loop until the drop happens. The QML that calls this does so
        from onPositionChanged, which keeps firing for the whole gesture — so
        every mouse move inside the drag re-entered this function and started
        ANOTHER nested loop with another QDrag, nesting without bound until the
        process died. That is the drag crash, and it needs stopping on both ends:
        the flag here, and a one-shot in the delegate that calls it.

        The exec is also deferred by a turn of the event loop. Starting a nested
        loop from inside QML's own mouse-event delivery unwinds the stack the
        scene graph is still standing on, which is its own class of crash on
        Wayland.
        """
        if self._dragging:
            return
        clean_paths = [str(p) for p in file_paths if p and Path(p).exists()]
        if not clean_paths and self._selected_file and Path(self._selected_file).exists():
            clean_paths = [self._selected_file]
        if not clean_paths:
            return
        self._dragging = True
        QTimer.singleShot(0, lambda: self._run_drag(clean_paths))

    def _run_drag(self, clean_paths):
        try:
            drag = QDrag(QApplication.instance())
            mime = QMimeData()
            mime.setUrls([QUrl.fromLocalFile(p) for p in clean_paths])
            mime.setText("\n".join(clean_paths))
            # Other file managers read this to tell a copy from a cut; without it
            # a drop into Nautilus or Dolphin arrives with no stated intent.
            mime.setData("x-special/gnome-copied-files",
                         ("copy\n" + "\n".join(
                             QUrl.fromLocalFile(p).toString()
                             for p in clean_paths)).encode())
            drag.setMimeData(mime)
            pix = self._drag_pixmap(clean_paths)
            drag.setPixmap(pix)
            drag.setHotSpot(QPoint(pix.width() // 2, pix.height() - 6))
            drag.exec(Qt.CopyAction | Qt.MoveAction)
        except Exception as exc:
            self.setStatus(f"Drag failed: {exc}")
        finally:
            self._dragging = False

    def _drag_pixmap(self, paths):
        """What follows the cursor: the file's own icon, and its name.

        It used to be a dark navy bar with text in it, which matched nothing on
        screen and told you nothing about what you had hold of. An image drags as
        its thumbnail, everything else as the same glyph and category colour the
        grid draws, so the thing under the cursor looks like the thing you picked
        up.
        """
        first = Path(paths[0])
        count = len(paths)
        name = first.name
        if len(name) > 26:
            name = name[:23] + "…"
        if count > 1:
            name = f"{name}  +{count - 1}"

        scale = 2                      # drawn at 2x so it stays crisp on HiDPI
        icon_px = 44
        pad = 8
        font = QFont(self._theme.get("fontSans", "Adwaita Sans"), 9)
        metrics_pm = QPixmap(1, 1)
        probe = QPainter(metrics_pm)
        probe.setFont(font)
        text_w = probe.fontMetrics().horizontalAdvance(name)
        text_h = probe.fontMetrics().height()
        probe.end()

        w = max(icon_px, text_w) + pad * 2
        h = icon_px + 4 + text_h + pad * 2

        pm = QPixmap(w * scale, h * scale)
        pm.setDevicePixelRatio(scale)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)

        is_dir = first.is_dir()
        ext = first.suffix.lower()
        icon_name, category, colour, _badge = self._categorize_file(
            first.name, is_dir, ext, str(first))

        cx = w / 2
        drawn = False
        if category == "image" and count == 1:
            src = QPixmap(str(first))
            if not src.isNull():
                thumb = src.scaled(icon_px, icon_px, Qt.KeepAspectRatio,
                                   Qt.SmoothTransformation)
                p.drawPixmap(int(cx - thumb.width() / 2), pad, thumb)
                drawn = True
        if not drawn:
            glyph = QFont("Material Symbols Rounded")
            glyph.setPixelSize(34)
            glyph.setStyleStrategy(QFont.PreferAntialias)
            # FILL is a VARIABLE AXIS, not a weight. Without setting it the face
            # falls back to its default of 0 and the drag preview showed hollow
            # outline glyphs while the grid behind it showed solid ones.
            try:
                glyph.setVariableAxis(QFont.Tag("FILL"), 1.0)
                glyph.setVariableAxis(QFont.Tag("wght"), 400.0)
            except Exception:
                pass
            p.setFont(glyph)
            p.setPen(QColor(colour))
            p.drawText(0, pad, w, icon_px, Qt.AlignCenter, icon_name)

        # The name sits on a plate only as wide as the name, so short names do
        # not drag a wide empty bar behind them.
        dark = self._theme.get("isDark", True)
        plate = QColor(18, 18, 24, 225) if dark else QColor(255, 255, 255, 235)
        ink = QColor(240, 240, 245) if dark else QColor(20, 20, 26)
        ty = pad + icon_px + 2
        p.setPen(Qt.NoPen)
        p.setBrush(plate)
        p.drawRoundedRect(int(cx - text_w / 2) - 6, ty,
                          text_w + 12, text_h + 2, 4, 4)
        p.setPen(ink)
        p.setFont(font)
        p.drawText(0, ty, w, text_h + 2, Qt.AlignCenter, name)
        p.end()
        return pm

    @Slot(str, result=dict)
    def getAvailableApps(self, path_str):
        p = Path(path_str)
        ext = p.suffix.lower()
        mime = self._mime_for(path_str, ext)

        default_desktop = ""
        try:
            res = subprocess.run(["xdg-mime", "query", "default", mime],
                                 capture_output=True, text=True, check=False,
                                 timeout=3)
            default_desktop = res.stdout.strip()
        except Exception:
            pass

        # XDG_DATA_DIRS, not two hardcoded paths: Flatpak and Nix put their
        # entries elsewhere entirely, and neither showed up in "Open With".
        roots = [os.path.expanduser("~/.local/share")]
        roots += (os.environ.get("XDG_DATA_DIRS")
                  or "/usr/local/share:/usr/share").split(":")
        dirs, seen_dir = [], set()
        for r in roots:
            d = os.path.join(r.strip(), "applications")
            if d and d not in seen_dir and os.path.isdir(d):
                seen_dir.add(d)
                dirs.append(d)

        matched, others, seen = [], [], set()
        family = mime.split("/")[0] + "/"
        for d in dirs:
            for f in glob.glob(os.path.join(d, "**", "*.desktop"), recursive=True):
                dname = os.path.relpath(f, d).replace(os.sep, "-")
                if dname in seen:
                    continue
                seen.add(dname)
                entry = _read_desktop_entry(f)
                if not _desktop_is_visible(entry):
                    continue
                mimes = [m.strip() for m in entry.get("MimeType", "").split(";")
                         if m.strip()]
                info = {
                    "name": entry.get("Name") or dname[:-8],
                    "exec": entry.get("Exec", ""),
                    "desktop": dname,
                    "icon": entry.get("Icon", "application-x-executable"),
                    "terminal": entry.get("Terminal", "").lower() == "true",
                    "isDefault": dname == default_desktop,
                    "mime": mime,
                }
                # An exact MimeType match is a real recommendation. A match on the
                # family alone ("this handles some kind of image") is a weaker one
                # and sorts below it, rather than being mixed in as an equal.
                if info["isDefault"] or mime in mimes:
                    info["rank"] = 0 if info["isDefault"] else 1
                    matched.append(info)
                elif any(m.startswith(family) for m in mimes):
                    info["rank"] = 2
                    matched.append(info)
                else:
                    others.append(info)

        matched.sort(key=lambda x: (x["rank"], x["name"].lower()))
        others.sort(key=lambda x: x["name"].lower())
        return {"mime": mime, "default": default_desktop,
                "recommended": matched, "all": matched + others}

    @staticmethod
    def _mime_for(path_str, ext):
        """The MIME type of a file, asked of the system before being guessed.

        `xdg-mime query filetype` consults shared-mime-info, which knows the
        content of a file as well as its name — so an extensionless script or a
        .ts that is video rather than TypeScript is identified correctly instead
        of falling through to application/octet-stream.
        """
        try:
            res = subprocess.run(["xdg-mime", "query", "filetype", str(path_str)],
                                 capture_output=True, text=True, timeout=3)
            got = res.stdout.strip()
            if got and "/" in got:
                return got
        except Exception:
            pass
        guessed, _ = mimetypes.guess_type(str(path_str))
        if guessed:
            return guessed
        fallback = {
            ".md": "text/markdown", ".py": "text/x-python", ".sh": "text/x-shellscript",
            ".qml": "text/plain", ".log": "text/plain", ".conf": "text/plain",
            ".ini": "text/plain", ".toml": "text/plain", ".yml": "text/yaml",
            ".yaml": "text/yaml", ".rs": "text/plain", ".go": "text/plain",
            ".zst": "application/zstd", ".7z": "application/x-7z-compressed",
        }
        return fallback.get(ext, "application/octet-stream")

    @Slot(str, str)
    def openWithApp(self, path_str, exec_cmd):
        p = Path(path_str)
        if not p.exists():
            return
        argv = _exec_argv(exec_cmd, [str(p)])
        if not argv:
            self.setStatus("That application has no command to run")
            return
        try:
            subprocess.Popen(argv, start_new_session=True)
            self.setStatus(f"Opened {p.name} with {Path(argv[0]).name}")
        except FileNotFoundError:
            self.setStatus(f"{Path(argv[0]).name} is not installed")
        except Exception as e:
            self.setStatus(f"Failed to open with {Path(argv[0]).name}: {e}")

    @Slot(str, str, str)
    def setAsDefaultApp(self, path_str, desktop_id, exec_cmd):
        p = Path(path_str)
        if not p.exists():
            return
        mime = self._mime_for(path_str, p.suffix.lower())
        try:
            subprocess.run(["xdg-mime", "default", desktop_id, mime], check=False)
            self.setStatus(f"Set {desktop_id} as default for {mime}")
        except Exception as e:
            self.setStatus(f"Could not set default: {e}")
        self.openWithApp(path_str, exec_cmd)

    @Slot(str)
    def openFile(self, path_str):
        # Double-clicking an archive looks inside it rather than handing it to
        # another application — that is the point of being able to browse one.
        if str(path_str).lower().endswith(ARCHIVE_EXTS) and os.path.isfile(path_str):
            self.cd(path_str)
            return
        arc = self._archive_split(path_str) if self._archive else None
        if arc and arc[1]:
            tree = self._archive_index(arc[0])
            if arc[1] in tree:
                self.cd(path_str)
                return
            real = self._extract_member(arc[0], arc[1])
            if not real:
                self.setStatus("Too large to open from inside the archive — extract it first")
                return
            path_str = real

        p = Path(path_str)
        if not p.exists():
            return
        if p.is_dir():
            self.cd(path_str)
        else:
            try:
                subprocess.Popen(["xdg-open", str(p)], start_new_session=True)
                self.setStatus(f"Opened {p.name}")
            except Exception as e:
                self.setStatus(f"Could not open {p.name}: {e}")

    @Slot()
    @Slot(str)
    def openTerminal(self, path_str=""):
        target = path_str or self._current_path
        p = Path(target)
        if p.is_file():
            p = p.parent
        if self._virtual(str(p)) or not p.is_dir():
            self.setStatus("There is no real folder here to open a terminal in")
            return
        argv = _terminal_argv(cwd=p)
        if not argv:
            self.setStatus("No terminal emulator found")
            return
        try:
            subprocess.Popen(argv, cwd=str(p), start_new_session=True)
            self.setStatus(f"Terminal launched at {p}")
        except Exception as e:
            self.setStatus(f"Could not launch a terminal: {e}")

    @Slot()
    @Slot(str)
    def copyPath(self, path_str=""):
        target = path_str or self._selected_file or self._current_path
        if target:
            cb = QApplication.clipboard()
            cb.setText(target)
            try:
                subprocess.run(["wl-copy", target], check=False)
            except Exception:
                pass
            self.setStatus(f"Copied path: {target}")

    @Slot(list)
    @Slot(list, str)
    def setClipboard(self, file_paths, mode="copy"):
        clean_paths = [str(p) for p in file_paths if p and Path(p).exists()]
        if not clean_paths and self._selected_file and Path(self._selected_file).exists():
            clean_paths = [self._selected_file]
        if not clean_paths:
            return

        self._clipboard_paths = clean_paths
        self._clipboard_mode = mode
        self.clipboardChanged.emit(clean_paths, mode)

        # 1. Qt Clipboard
        try:
            cb = QApplication.clipboard()
            mime = QMimeData()
            urls = [QUrl.fromLocalFile(p) for p in clean_paths]
            mime.setUrls(urls)
            mime.setText("\n".join(clean_paths))
            cb.setMimeData(mime)
        except Exception:
            pass

        # 2. Wayland Native Clipboard
        try:
            subprocess.run(["wl-copy", "\n".join(clean_paths)], check=False)
        except Exception:
            pass

        self.setStatus(f"Copied {len(clean_paths)} item(s) to clipboard")

    @Slot()
    @Slot(str)
    def openNewWindow(self, path_str=""):
        target = path_str or self._current_path
        script_path = str(Path(__file__).resolve())
        # sys.executable, not "python3": launched from a virtualenv or a different
        # interpreter, the new window otherwise starts under whichever python3 is
        # first on PATH and may not have PySide6 at all.
        subprocess.Popen([sys.executable, script_path, str(target)],
                         start_new_session=True)
        self.setStatus(f"Opened new window at {Path(target).name}")

    @Slot()
    @Slot(str)
    def pasteFiles(self, target_dir=""):
        if self._virtual(target_dir or self._current_path):
            self._refuse_virtual(); return
        dest_dir = Path(target_dir or self._current_path).resolve()
        if not dest_dir.exists() or not dest_dir.is_dir():
            return

        paths_to_paste = [p for p in self._clipboard_paths if Path(p).exists()]

        # Nothing of our own on the clipboard means it came from another
        # application, so read it back out — Wayland first, Qt second.
        if not paths_to_paste:
            for line in self._foreign_clipboard():
                if line and Path(line).exists():
                    paths_to_paste.append(line)

        if not paths_to_paste:
            self.setStatus("Clipboard is empty")
            return

        mode = self._clipboard_mode
        if mode == "cut":
            OPS().moveTo(paths_to_paste, str(dest_dir))
            self._clipboard_paths = []
            self.clipboardChanged.emit([], "copy")
        else:
            OPS().copyTo(paths_to_paste, str(dest_dir))

    @staticmethod
    def _uri_to_path(line):
        """One clipboard line as a local path.

        Percent-escapes are UNDONE. The old version did a bare
        replace("file://", "") and left them, so a URI for "my file.txt" stayed
        "my%20file.txt", failed its exists() check, and was dropped — which is
        why pasting anything with a space in its name from another application
        silently did nothing at all.
        """
        line = (line or "").strip()
        if not line:
            return ""
        if line.startswith("file://"):
            return QUrl(line).toLocalFile()
        return line

    def _foreign_clipboard(self):
        """Paths another application put on the clipboard, best source first."""
        out = []
        try:
            res = subprocess.run(["wl-paste", "--no-newline", "--type",
                                  "text/uri-list"],
                                 capture_output=True, text=True, timeout=2)
            if res.returncode == 0:
                out = [self._uri_to_path(l) for l in res.stdout.splitlines()]
        except Exception:
            pass
        if not any(out):
            try:
                cb = QApplication.clipboard()
                mime = cb.mimeData()
                if mime and mime.hasUrls():
                    out = [u.toLocalFile() for u in mime.urls() if u.isLocalFile()]
                elif mime and mime.hasText():
                    out = [self._uri_to_path(l) for l in mime.text().splitlines()]
            except Exception:
                pass
        return [p for p in out if p]

    @Slot(list, str)
    def moveFiles(self, file_paths, target_dir):
        if self._virtual(*file_paths):
            self._refuse_virtual(); return
        dest_dir = Path(target_dir or self._current_path).resolve()
        if not dest_dir.exists() or not dest_dir.is_dir():
            return
        wanted = [str(p) for p in file_paths
                  if p and Path(p).exists() and Path(p).resolve().parent != dest_dir]
        if wanted:
            OPS().moveTo(wanted, str(dest_dir))

    @Slot(list, str)
    def copyFiles(self, file_paths, target_dir):
        if self._virtual(*file_paths):
            self._refuse_virtual(); return
        dest_dir = Path(target_dir or self._current_path).resolve()
        if not dest_dir.exists() or not dest_dir.is_dir():
            return
        wanted = [str(p) for p in file_paths if p and Path(p).exists()]
        if wanted:
            OPS().copyTo(wanted, str(dest_dir))

    @Property(str, constant=True)
    def trashPath(self):
        TRASH_FILES.mkdir(parents=True, exist_ok=True)
        return str(TRASH_FILES)

    @Property(bool, notify=currentPathChanged)
    def inTrash(self):
        try:
            return Path(self._current_path).resolve() == TRASH_FILES.resolve()
        except Exception:
            return False

    @staticmethod
    def _trash_home_of(item):
        """(info file, topdir) for something currently sitting in a trash.

        Which trash an item is in decides where its record lives and how that
        record's Path= is to be read, so every operation on a trashed file has to
        establish this first rather than assume the home trash.
        """
        item = Path(item)
        for files_dir, info_dir, top in _all_trash_dirs():
            try:
                if item.parent.resolve() == files_dir.resolve():
                    return info_dir / f"{item.name}.trashinfo", top
            except OSError:
                continue
        return None, None

    @staticmethod
    def _trash_origin(info_path, topdir):
        """The path a .trashinfo says its file came from, made absolute.

        A volume trash records the location RELATIVE to the volume, so resolving
        it needs to know which volume — an entry reading "Photos/a.jpg" means that
        path under the drive's mount point, not under the root of the filesystem.
        """
        try:
            for line in Path(info_path).read_text().splitlines():
                if line.startswith("Path="):
                    raw = unquote(line[5:].strip())
                    if not raw:
                        return None
                    p = Path(raw)
                    if p.is_absolute():
                        return p
                    return Path(topdir) / p if topdir else Path.home() / p
        except OSError:
            return None
        return None

    @staticmethod
    def _trash_record_for(orig):
        """Where in the trash a path just landed, read back out of the spec.

        `gio trash` does not report where it put anything, and undo has to be able
        to name the exact file. Every .trashinfo records the original path, so the
        answer is already written down — the newest record pointing at us wins,
        which matters when the same name has been trashed more than once.

        SEARCHED ACROSS EVERY TRASH, not just the home one. gio puts a file
        deleted from a drive into that drive's trash; looking only in ~ found
        nothing, returned None, and the item was silently dropped from the undo
        stack — so "Undo" put back everything except the file on the USB stick.
        """
        want = Path(orig).resolve()
        best, best_mtime, best_files = None, -1.0, None
        for files_dir, info_dir, top in _all_trash_dirs():
            try:
                if not info_dir.is_dir():
                    continue
                for info in info_dir.glob("*.trashinfo"):
                    if FileManagerBackend._trash_origin(info, top) != want:
                        continue
                    try:
                        m = info.stat().st_mtime
                    except OSError:
                        continue
                    if m > best_mtime:
                        best_mtime, best, best_files = m, info, files_dir
            except Exception:
                continue
        if best is None:
            return None
        return {"orig": str(want),
                "trash": str(best_files / best.name[:-len(".trashinfo")]),
                "info": str(best)}

    def _trash_one(self, p):
        """Move one path into the trash, reporting where it came from and went.

        Never falls back to deleting. The previous version did, so a failure to
        trash quietly became a permanent removal of the thing you were trying to
        keep — the one outcome "move to trash" must never produce.
        """
        res = subprocess.run(["gio", "trash", str(p)], capture_output=True)
        if res.returncode == 0:
            return self._trash_record_for(p)
        return _trash_to_spec(p)

    @Slot(list)
    def trashFiles(self, file_paths):
        if self._virtual(*file_paths):
            self._refuse_virtual(); return
        live = [p for p in file_paths if p and (os.path.exists(p)
                                                or os.path.islink(p))]
        if not live:
            return
        # Trashing is a rename within a filesystem and a full COPY across one, so
        # emptying a folder onto a different volume is real work. It runs on the
        # engine like everything else now, with the same progress and the same
        # cancel button.
        OPS().trashPaths(live, self._trash_one)
        self._selected_file = ""
        self.selectedFileChanged.emit("")

    @Slot(list)
    def deleteFilesPermanently(self, file_paths):
        """Shift+Delete. Nothing here is recoverable afterwards.

        Records NO undo, and deliberately does not clear the stack either. There
        is no way to reverse this, and an Undo entry that cannot undo is worse
        than none — the offer is what stops you thinking twice. Leaving the older
        entry in place keeps the menu describing something it can still do.
        """
        if self._virtual(*file_paths):
            self._refuse_virtual()
            return
        live = [p for p in file_paths if p and (os.path.exists(p)
                                                or os.path.islink(p))]
        if not live:
            return
        OPS().deletePaths(live, self._forget_trash_record)
        self._selected_file = ""
        self.selectedFileChanged.emit("")

    @staticmethod
    def _forget_trash_record(p):
        """Drop the .trashinfo beside something deleted straight out of a trash."""
        try:
            info, _top = FileManagerBackend._trash_home_of(p)
            if info and info.exists():
                info.unlink()
        except OSError:
            pass

    @Slot(list)
    def restoreFromTrash(self, file_paths):
        restored, failed, records = 0, [], []
        for path_str in file_paths:
            p = Path(path_str)
            if not p.exists():
                continue
            info, top = self._trash_home_of(p)
            origin = self._trash_origin(info, top) if info and info.exists() else None

            if origin is None:
                failed.append(f"{p.name}: no record of where it came from")
                continue
            try:
                origin.parent.mkdir(parents=True, exist_ok=True)
                dest = origin
                if dest.exists():
                    dest = origin.with_name(
                        f"{origin.stem}_restored_{int(time.time())}{origin.suffix}")
                shutil.move(str(p), str(dest))
                if info.exists():
                    info.unlink()
                # Reversed by trashing it again, which writes a fresh .trashinfo
                # pointing back at the origin — so undoing a restore leaves the
                # trash in the state it was in before, not an orphan entry.
                records.append({"path": str(dest)})
                restored += 1
            except Exception as e:
                failed.append(f"{p.name}: {e}")

        if records:
            UNDO().record("create", "Restore", records)
        if failed:
            self.setStatus(f"Restored {restored}, {len(failed)} failed — {failed[0]}")
        else:
            self.setStatus(f"Restored {restored} item(s)")
        self.directoryChanged.emit()

    @Slot()
    def emptyTrash(self):
        victims = []
        for files_dir, _info_dir, _top in _all_trash_dirs():
            if not files_dir.is_dir():
                continue
            try:
                victims.extend(str(e) for e in files_dir.iterdir())
            except OSError:
                continue
        if not victims:
            self.setStatus("The trash is already empty")
            return
        OPS().deletePaths(victims, self._forget_trash_record)

    @Slot(str, str)
    def renameFile(self, old_path_str, new_name):
        if self._virtual(old_path_str):
            self._refuse_virtual(); return
        old_p = Path(old_path_str)
        clean = (new_name or "").strip()
        if not old_p.exists() or not clean:
            return
        # A name is a NAME. Letting a separator through turns "rename" into
        # "move somewhere else", which is not what the field said it would do.
        if "/" in clean or clean in (".", ".."):
            self.setStatus("A file name cannot contain '/'")
            return
        new_p = old_p.parent / clean
        if new_p == old_p:
            return
        # Path.rename() on POSIX REPLACES the destination without a word. The old
        # code called it straight, so renaming a.txt onto an existing b.txt
        # destroyed b.txt permanently, with no prompt and nothing on the undo
        # stack that could bring it back. Nothing is overwritten by a rename now;
        # collisions are refused and the user picks another name.
        if new_p.exists() or new_p.is_symlink():
            self.setStatus(f"'{clean}' already exists here")
            return
        try:
            old_p.rename(new_p)
            UNDO().record("rename", "Rename",
                          [{"old": str(old_p), "new": str(new_p)}])
            self.setStatus(f"Renamed to '{new_p.name}'")
            self.directoryChanged.emit()
            self.selectFile(str(new_p))
        except Exception as e:
            self.setStatus(f"Rename failed: {e}")

    @Slot(str)
    def duplicateFile(self, path_str):
        if self._virtual(path_str):
            self._refuse_virtual(); return
        p = Path(path_str)
        if not p.exists():
            return
        stem = p.stem
        suffix = p.suffix
        new_name = f"{stem}_copy{suffix}"
        target = p.parent / new_name
        i = 2
        while target.exists():
            target = p.parent / f"{stem}_copy{i}{suffix}"
            i += 1
        try:
            if p.is_dir():
                shutil.copytree(str(p), str(target))
            else:
                shutil.copy2(str(p), str(target))
            UNDO().record("create", "Duplicate", [{"path": str(target)}])
            self.setStatus(f"Duplicated {p.name} → {target.name}")
            self.directoryChanged.emit()
            self.selectFile(str(target))
        except Exception as e:
            self.setStatus(f"Duplicate failed: {e}")

    @Slot(str, str)
    def createDirectory(self, parent_dir, name):
        if self._virtual(parent_dir or self._current_path):
            self._refuse_virtual(); return
        clean_name = name.strip() if name else "New Folder"
        target = Path(parent_dir or self._current_path) / clean_name
        try:
            target.mkdir(parents=True, exist_ok=False)
            UNDO().record("create", "New Folder", [{"path": str(target)}])
            self.setStatus(f"Created folder '{clean_name}'")
            self.directoryChanged.emit()
            self.selectFile(str(target))
        except FileExistsError:
            self.setStatus(f"Folder '{clean_name}' already exists")
        except Exception as e:
            self.setStatus(f"Could not create folder: {e}")

    @Slot(str, str)
    def createFile(self, parent_dir, name):
        if self._virtual(parent_dir or self._current_path):
            self._refuse_virtual(); return
        clean_name = name.strip() if name else "new_file.txt"
        target = Path(parent_dir or self._current_path) / clean_name
        try:
            target.touch(exist_ok=False)
            UNDO().record("create", "New File", [{"path": str(target)}])
            self.setStatus(f"Created file '{clean_name}'")
            self.directoryChanged.emit()
            self.selectFile(str(target))
        except FileExistsError:
            self.setStatus(f"File '{clean_name}' already exists")
        except Exception as e:
            self.setStatus(f"Could not create file: {e}")


    # ---- Looking inside archives ----
    #
    # An archive is browsed AT ITS OWN PATH: /home/u/photos.zip/holiday is a real
    # location as far as this file manager is concerned. That is the whole trick —
    # it means the breadcrumb, tabs, history, back/forward, the other pane and the
    # search box all work on the inside of a zip with no special cases anywhere,
    # and it reads correctly too: home › u › photos.zip › holiday.
    #
    # Everything in here is READ-ONLY. Rewriting a member in place means rebuilding
    # the archive, and a file manager that silently repacks a 2 GB zip because you
    # pressed F2 is not a trade worth making. Extraction is the way out.

    @staticmethod
    def _archive_split(path_str):
        """(archive path, path inside it) for a location within an archive."""
        low = str(path_str).lower()
        # Cheap guard first: cd runs on every navigation and this must not become
        # a walk up the tree stat-ing each ancestor for ordinary folders.
        if not any(e in low for e in ARCHIVE_EXTS):
            return None
        p = Path(path_str)
        inner = []
        while True:
            if p.is_file() and str(p).lower().endswith(ARCHIVE_EXTS):
                return str(p), "/".join(reversed(inner))
            if p.parent == p:
                return None
            inner.append(p.name)
            p = p.parent

    def _archive_index(self, archive_path):
        """{directory -> [member dicts]} for one archive, cached on its mtime."""
        try:
            mtime = os.path.getmtime(archive_path)
        except OSError:
            return {}
        key = (archive_path, mtime)
        if self._arc_cache.get("key") == key:
            return self._arc_cache["tree"]

        members = []
        try:
            low = archive_path.lower()
            if low.endswith(EXTERNAL_ARCHIVE_EXTS):
                members = self._external_members(archive_path)
            elif low.endswith((".zip", ".jar", ".whl", ".apk", ".cbz", ".epub")):
                with zipfile.ZipFile(archive_path) as zf:
                    for info in zf.infolist():
                        members.append((info.filename, info.file_size,
                                        time.mktime(info.date_time + (0, 0, -1))
                                        if info.date_time else mtime,
                                        info.is_dir()))
            else:
                with tarfile.open(archive_path) as tf:
                    for info in tf.getmembers():
                        members.append((info.name, info.size, info.mtime,
                                        info.isdir()))
        except Exception:
            self._arc_cache = {"key": key, "tree": {}}
            return {}

        tree = {}

        def ensure(d):
            return tree.setdefault(d, {})

        ensure("")
        for name, size, mtime_m, is_dir in members:
            clean = name.strip("/")
            while clean.startswith("./"):
                clean = clean[2:]
            if not clean or clean == ".":
                continue
            parts = clean.split("/")
            # Directories are often implied rather than listed, so each level is
            # created on the way past whether the archive mentions it or not.
            for depth in range(len(parts) - 1):
                parent = "/".join(parts[:depth])
                here = "/".join(parts[:depth + 1])
                ensure(parent).setdefault(parts[depth], {
                    "name": parts[depth], "inner": here, "isDir": True,
                    "size": 0, "mtime": mtime_m, "member": here})
                ensure(here)
            if is_dir:
                ensure("/".join(parts[:-1]))[parts[-1]] = {
                    "name": parts[-1], "inner": clean, "isDir": True,
                    "size": 0, "mtime": mtime_m, "member": name}
                ensure(clean)
            else:
                ensure("/".join(parts[:-1]))[parts[-1]] = {
                    "name": parts[-1], "inner": clean, "isDir": False,
                    "size": size, "mtime": mtime_m, "member": name}

        self._arc_cache = {"key": key, "tree": tree}
        return tree

    @staticmethod
    def _external_members(archive_path):
        """(name, size, mtime, isdir) for an archive only 7z or bsdtar can read.

        `7z l -slt` is used in preference to bsdtar's table because it emits one
        key per line: a member called "name with space.md" survives it, where the
        column-aligned listing has to be guessed at.
        """
        out = []
        if shutil.which("7z"):
            try:
                res = subprocess.run(["7z", "l", "-slt", "-ba", archive_path],
                                     capture_output=True, text=True, timeout=30)
            except Exception:
                res = None
            if res is not None and res.returncode == 0:
                name, size, mtime, is_dir = None, 0, 0.0, False
                for line in res.stdout.splitlines() + [""]:
                    if not line.strip():
                        if name:
                            out.append((name, size, mtime, is_dir))
                        name, size, mtime, is_dir = None, 0, 0.0, False
                        continue
                    key, _, val = line.partition("=")
                    key, val = key.strip(), val.strip()
                    if key == "Path":
                        name = val.replace("\\", "/")
                    elif key == "Size":
                        try:
                            size = int(val)
                        except ValueError:
                            size = 0
                    elif key == "Attributes":
                        is_dir = val.startswith("D")
                    elif key == "Modified" and val:
                        try:
                            mtime = QDateTime.fromString(
                                val[:19], "yyyy-MM-dd hh:mm:ss").toSecsSinceEpoch()
                            mtime = float(max(0, mtime))
                        except Exception:
                            mtime = 0.0
                if out:
                    return out
        if shutil.which("bsdtar"):
            try:
                res = subprocess.run(["bsdtar", "-tf", archive_path],
                                     capture_output=True, text=True, timeout=30)
                if res.returncode == 0:
                    for raw in res.stdout.splitlines():
                        nm = raw.rstrip("\n")
                        if not nm:
                            continue
                        out.append((nm.rstrip("/"), 0, 0.0, nm.endswith("/")))
            except Exception:
                pass
        return out

    def _virtual(self, *paths):
        """True if any of these live somewhere that cannot be written to.

        Guarding here rather than in the UI is deliberate: an archive member and
        a tag view both LOOK like ordinary paths to every call site, and the
        failure without a guard is not a refusal but a confusing one — rename
        would report "no such file" for something plainly on screen.
        """
        for path_str in paths:
            if not path_str:
                continue
            raw = str(path_str)
            if raw == TAG_ROOT or raw.startswith(TAG_ROOT + "/"):
                return True
            if raw in (STAR_ROOT, RECENT_ROOT):
                return True
            arc = self._archive_split(raw)
            if arc and arc[1]:
                return True
        return False

    def _refuse_virtual(self):
        self.setStatus("This is a read-only view — extract the files first"
                       if self._archive else "Not something that can be changed here")
        return True

    @staticmethod
    def _member_name(tree, inner):
        """The archive's own spelling of a member, which may carry a ./ prefix."""
        parent = "/".join(inner.split("/")[:-1])
        leaf = inner.split("/")[-1]
        entry = (tree.get(parent) or {}).get(leaf)
        return (entry or {}).get("member") or inner

    def _archive_entries(self, archive_path, inner, q=""):
        tree = self._archive_index(archive_path)
        here = tree.get(inner.strip("/"), {})
        out = []
        for entry in here.values():
            if q and q not in entry["name"].lower():
                continue
            name = entry["name"]
            is_dir = entry["isDir"]
            ext = Path(name).suffix.lower()
            full = str(Path(archive_path) / entry["inner"])
            icon_name, category, color, badge = self._categorize_file(
                name, is_dir, ext, full)
            out.append({
                "name": name,
                "path": full,
                "isDir": is_dir,
                "size": entry["size"],
                "sizeStr": self._format_size(entry["size"]) if not is_dir else "--",
                "mtime": entry["mtime"],
                "mtimeStr": QDateTime.fromSecsSinceEpoch(
                    int(entry["mtime"])).toString("yyyy-MM-dd hh:mm"),
                "extension": ext,
                "extBadge": badge,
                "mimeType": mimetypes.guess_type(name)[0] or (
                    "folder" if is_dir else "file"),
                "iconName": icon_name,
                "category": category,
                "accentColor": color,
                "themeIcon": self.theme_icon(name, is_dir, full),
                # No thumbnail: producing one means extracting the member, and
                # doing that for every row of a listing is a lot of work for a
                # folder you may only be passing through.
                "thumbnailPath": "",
                "tag": "",
            })
        return out

    @Property(bool, notify=currentPathChanged)
    def inArchive(self):
        return self._archive is not None

    @Property(str, notify=currentPathChanged)
    def archivePath(self):
        return self._archive[0] if self._archive else ""

    def _extract_member(self, archive_path, inner):
        """One member, unpacked into the preview cache so it can be previewed.

        Capped, because "look inside this zip" should never turn into unpacking a
        4 GB disk image onto a disk that may not have room for it.
        """
        digest = hashlib.md5(f"{archive_path}:{inner}:{os.path.getmtime(archive_path)}"
                             .encode()).hexdigest()
        out = ARCHIVE_CACHE_DIR / f"{digest}_{Path(inner).name}"
        if out.exists():
            return str(out)
        try:
            low = archive_path.lower()
            ARCHIVE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
            tree = self._archive_index(archive_path)
            inner = self._member_name(tree, inner)
            if low.endswith(EXTERNAL_ARCHIVE_EXTS):
                # Straight to stdout, so nothing is written anywhere but the cache
                # file we actually want.
                if shutil.which("7z"):
                    cmd = ["7z", "x", "-so", archive_path, inner]
                elif shutil.which("bsdtar"):
                    cmd = ["bsdtar", "-xOf", archive_path, inner]
                else:
                    return ""
                res = subprocess.run(cmd, capture_output=True, timeout=60)
                if res.returncode != 0 or not res.stdout:
                    return ""
                if len(res.stdout) > ARCHIVE_PREVIEW_MAX:
                    return ""
                with open(out, "wb") as dst:
                    dst.write(res.stdout)
                return str(out)
            if low.endswith((".zip", ".jar", ".whl", ".apk", ".cbz", ".epub")):
                with zipfile.ZipFile(archive_path) as zf:
                    info = zf.getinfo(inner)
                    if info.file_size > ARCHIVE_PREVIEW_MAX:
                        return ""
                    with zf.open(info) as src, open(out, "wb") as dst:
                        shutil.copyfileobj(src, dst)
            else:
                with tarfile.open(archive_path) as tf:
                    info = tf.getmember(inner)
                    if info.size > ARCHIVE_PREVIEW_MAX:
                        return ""
                    src = tf.extractfile(info)
                    if src is None:
                        return ""
                    with open(out, "wb") as dst:
                        shutil.copyfileobj(src, dst)
        except Exception:
            return ""
        return str(out)

    @Slot(list)
    @Slot(list, str)
    def extractSelection(self, paths, dest_dir=""):
        """Pull the chosen members out, keeping the folders they sit in.

        The destination defaults to a folder beside the archive named after it,
        rather than the archive's own parent — unpacking forty loose files into
        the folder you were browsing is the thing everyone has done once.
        """
        if not self._archive:
            return
        archive_path, _inner = self._archive
        wanted = []
        for path_str in paths:
            split = self._archive_split(path_str)
            if split and split[0] == archive_path and split[1]:
                wanted.append(split[1])
        if not wanted:
            # Nothing chosen means the whole archive — the natural reading of
            # "Extract" with no selection.
            wanted = [""]

        target = Path(dest_dir) if dest_dir else (
            Path(archive_path).parent / _archive_stem(archive_path))
        try:
            target.mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            self.setStatus(f"Could not create {target.name}: {exc}")
            return

        tree = self._archive_index(archive_path)

        def expand(inner):
            """A chosen folder means everything under it."""
            if inner in tree:
                out = []
                for entry in tree[inner].values():
                    out.extend(expand(entry["inner"]) if entry["isDir"]
                               else [entry.get("member") or entry["inner"]])
                return out
            return [self._member_name(tree, inner)]

        members = []
        for inner in wanted:
            members.extend(expand(inner))

        before = set(os.listdir(target))
        count = 0
        try:
            low = archive_path.lower()
            if low.endswith((".zip", ".jar", ".whl", ".apk", ".cbz", ".epub")):
                with zipfile.ZipFile(archive_path) as zf:
                    for m in members:
                        zf.extract(m, target)
                        count += 1
            else:
                with tarfile.open(archive_path) as tf:
                    for m in members:
                        tf.extract(m, target)
                        count += 1
        except Exception as exc:
            self.setStatus(f"Extraction failed after {count}: {exc}")
            return

        added = [{"path": str(target / n)}
                 for n in sorted(set(os.listdir(target)) - before)]
        if added:
            UNDO().record("create", "Extract", added)
        self.setStatus(f"Extracted {count} item(s) into '{target.name}'")
        self.directoryChanged.emit()

    # ---- Colour tag views ----

    def _entry_for(self, path_str):
        """One listing entry for an arbitrary path, in the shape the grid expects.

        The scan loops build this inline from a scandir entry, which they have and
        this does not — a tag view collects paths from all over the filesystem, so
        there is no directory being walked to borrow the stat from.
        """
        p = Path(path_str)
        try:
            st = p.lstat()
            is_dir = p.is_dir()
        except OSError:
            return None
        name = p.name
        ext = p.suffix.lower()
        size = 0 if is_dir else st.st_size
        mtime = st.st_mtime
        icon_name, category, color, badge = self._categorize_file(
            name, is_dir, ext, str(p))
        return {
            "name": name,
            "path": str(p),
            "isDir": is_dir,
            "size": size,
            "sizeStr": self._format_size(size) if not is_dir else "--",
            "mtime": mtime,
            "mtimeStr": QDateTime.fromSecsSinceEpoch(int(mtime)).toString(
                "yyyy-MM-dd hh:mm"),
            "extension": ext,
            "extBadge": badge,
            "mimeType": mimetypes.guess_type(name)[0] or (
                "folder" if is_dir else "file"),
            "iconName": icon_name,
            "category": category,
            "accentColor": color,
            "themeIcon": self.theme_icon(name, is_dir, str(p)),
            "thumbnailPath": self._resolve_thumb(str(p), category, mtime),
            "tag": TAGS().get(str(p)),
        }

    def _trash_entries(self, q=""):
        """Everything in every trash, as one listing.

        The trash is shown at the home trash's path, but a file deleted from a
        drive is in that drive's own trash — listing only the folder being pointed
        at meant the thing you had just deleted was simply absent from the place
        that says it keeps deleted files.
        """
        out = []
        for files_dir, _info_dir, _top in _all_trash_dirs():
            if not files_dir.is_dir():
                continue
            try:
                for item in files_dir.iterdir():
                    if q and q not in item.name.lower():
                        continue
                    entry = self._entry_for(str(item))
                    if entry:
                        out.append(entry)
            except OSError:
                continue
        return out

    def _tagged_entries(self, tag, q=""):
        out = []
        for path_str in TAGS().taggedPaths(tag):
            if q and q not in os.path.basename(path_str).lower():
                continue
            entry = self._entry_for(path_str)
            if entry:
                out.append(entry)
        return out

    @Property(str, notify=currentPathChanged)
    def tagView(self):
        """The tag being browsed, "" for all tagged files, or "-" for no tag view.

        A plain empty string cannot say the difference between "every tag" and "not
        a tag view at all", and the chrome needs both.
        """
        return "-" if self._tag_view is None else self._tag_view

    # ---- Properties ----

    @Slot(list, result="QVariant")
    def fileProperties(self, paths):
        paths = [p for p in paths if p]
        if not paths:
            return {}

        if len(paths) > 1:
            total, dirs, files = 0, 0, 0
            for path_str in paths:
                p = Path(path_str)
                try:
                    st = p.lstat()
                except OSError:
                    continue
                if p.is_dir():
                    dirs += 1
                else:
                    files += 1
                    total += st.st_size
            return {"multi": True, "count": len(paths), "dirs": dirs,
                    "files": files, "bytes": total, "sizeStr": _fmt_size(total),
                    "name": f"{len(paths)} items",
                    "where": str(Path(paths[0]).parent)}

        p = Path(paths[0])
        try:
            st = p.lstat()
        except OSError:
            return {}
        is_link = p.is_symlink()
        is_dir = p.is_dir()
        mode = stat.S_IMODE(st.st_mode)
        ext = p.suffix.lower()
        _icon, category, _color, badge = self._categorize_file(
            p.name, is_dir, ext, str(p))

        def when(ts):
            return QDateTime.fromSecsSinceEpoch(int(ts)).toString(
                "d MMM yyyy, hh:mm")

        try:
            import pwd
            owner = pwd.getpwuid(st.st_uid).pw_name
        except Exception:
            owner = str(st.st_uid)
        try:
            import grp
            group = grp.getgrgid(st.st_gid).gr_name
        except Exception:
            group = str(st.st_gid)

        items = -1
        if is_dir:
            try:
                items = len(os.listdir(str(p)))
            except OSError:
                items = -1

        return {
            "multi": False,
            "name": p.name or str(p),
            "path": str(p),
            "where": str(p.parent),
            "isDir": is_dir,
            "isLink": is_link,
            "linkTarget": os.readlink(str(p)) if is_link else "",
            "kind": "Folder" if is_dir else (badge or ext.lstrip(".").upper()
                                             or "Document"),
            "category": category,
            "mimeType": mimetypes.guess_type(p.name)[0] or (
                "inode/directory" if is_dir else "application/octet-stream"),
            "bytes": 0 if is_dir else st.st_size,
            "sizeStr": "—" if is_dir else _fmt_size(st.st_size),
            # st_blocks is in 512-byte units regardless of the filesystem's own
            # block size, so this is the space actually taken rather than the
            # length — the two differ a lot for sparse files and small ones.
            "onDisk": _fmt_size(st.st_blocks * 512),
            "items": items,
            # Linux has no creation time in stat, and st_ctime is the INODE change
            # time — labelling it "Created" would be a plain lie, so it is not.
            "modified": when(st.st_mtime),
            "changed": when(st.st_ctime),
            "accessed": when(st.st_atime),
            "owner": owner,
            "group": group,
            "mode": mode,
            "modeOctal": format(mode, "04o"),
            "modeStr": stat.filemode(st.st_mode),
            "writable": os.access(str(p), os.W_OK),
        }

    @Slot(str)
    def requestDirSize(self, path_str):
        """Kick off the recursive size for a folder; answered by dirSizeReady."""
        self._size_token += 1
        self._thread_pool.start(DirSizeWorker(self, path_str, self._size_token))

    @Slot(str, int)
    @Slot(str, int, bool)
    def setPermissions(self, path_str, mode, recursive=False):
        p = Path(path_str)
        if not p.exists():
            return
        mode &= 0o7777
        targets = [p]
        if recursive and p.is_dir():
            for root, dirnames, filenames in os.walk(str(p)):
                targets.extend(Path(root) / n for n in dirnames)
                targets.extend(Path(root) / n for n in filenames)

        records, failed = [], []
        for t in targets:
            try:
                old = stat.S_IMODE(t.lstat().st_mode)
                want = mode
                # A directory without its execute bit cannot be entered — not even
                # by its owner, and not even to read a file inside it whose own
                # permissions are fine. Applying a file's mode recursively would
                # otherwise seal the whole tree shut, so on directories execute
                # follows read.
                if t.is_dir():
                    want = mode | ((mode & 0o444) >> 2)
                if old == want:
                    continue
                os.chmod(str(t), want)
                records.append({"path": str(t), "old": old})
            except OSError as exc:
                failed.append(str(exc))

        if records:
            UNDO().record("chmod", "Change Permissions", records)
        if failed:
            self.setStatus(f"Changed {len(records)}, {len(failed)} failed — {failed[0]}")
        else:
            self.setStatus(f"Permissions set to {format(mode, '04o')}"
                           + (f" on {len(records)} items" if len(records) > 1 else ""))
        self.directoryChanged.emit()

    # ---- Batch rename ----

    @Slot(list, list, result=int)
    def batchRename(self, paths, new_names):
        """Rename many files at once, through temporary names.

        The obvious implementation breaks on the case batch rename exists for:
        shifting a numbered series down by one, or swapping two names, has every
        step colliding with a file that has not been moved out of the way yet.
        Going via temporaries costs one extra rename each and makes any
        permutation legal, including ones that pass through themselves.
        """
        if self._virtual(*paths):
            self._refuse_virtual()
            return 0
        if len(paths) != len(new_names):
            self.setStatus("Batch rename: mismatched lists")
            return 0

        jobs = []
        for src_str, raw in zip(paths, new_names):
            src = Path(src_str)
            name = (raw or "").strip()
            if not src.exists() or not name or "/" in name or name in (".", ".."):
                continue
            dest = src.parent / name
            if dest == src:
                continue
            jobs.append((src, dest))

        if not jobs:
            self.setStatus("Nothing to rename")
            return 0

        # THE WHOLE BATCH OR NONE OF IT. A half-applied rename leaves a set of
        # files in a state nobody asked for and nobody can describe, so both ways
        # of colliding are checked before anything moves.
        targets = [d for _, d in jobs]
        if len(set(targets)) != len(targets):
            self.setStatus("Cancelled — two files would end up with the same name")
            return 0
        sources = {s for s, _ in jobs}
        for dest in targets:
            if dest.exists() and dest not in sources:
                self.setStatus(f"Cancelled — '{dest.name}' already exists")
                return 0

        stamp = f".sea-fm-rn-{os.getpid()}-"
        staged = []
        try:
            for i, (src, dest) in enumerate(jobs):
                tmp = src.parent / f"{stamp}{i}"
                src.rename(tmp)
                staged.append((tmp, dest, src))
            for tmp, dest, _src in staged:
                tmp.rename(dest)
        except Exception as exc:
            for tmp, dest, src in staged:
                try:
                    if tmp.exists():
                        tmp.rename(src)
                    elif dest.exists() and not src.exists():
                        dest.rename(src)
                except OSError:
                    pass
            self.setStatus(f"Batch rename failed, nothing changed: {exc}")
            return 0

        UNDO().record("rename", "Batch Rename",
                      [{"old": str(src), "new": str(dest)}
                       for _tmp, dest, src in staged])
        self.setStatus(f"Renamed {len(staged)} item(s)")
        self.directoryChanged.emit()
        return len(staged)

    # ---- Duplicate finder ----

    @Slot()
    @Slot(str)
    def findDuplicates(self, root=""):
        target = root or self._current_path
        if self._tag_view is not None or not os.path.isdir(target):
            self.setStatus("Duplicate scan needs a real folder")
            self.duplicatesReady.emit([])
            return
        self._dupe_token += 1
        self.setStatus(f"Scanning {Path(target).name} for duplicates…")
        self._thread_pool.start(DuplicateWorker(self, target, self._dupe_token))

    @Slot()
    def cancelDuplicates(self):
        # Bumping the token is the whole cancellation: the worker checks it between
        # every file and returns without emitting.
        self._dupe_token += 1

    # ---- Bookmarks Management ----
    # ---- Per-folder view memory ----
    # A photo folder wants big icons, a source tree wants the list. Remembering
    # that per directory is the single most-asked-for view behaviour.
    def _load_view_state(self):
        try:
            if VIEWSTATE_FILE.exists():
                with open(VIEWSTATE_FILE, "r") as f:
                    loaded = json.load(f)
                if isinstance(loaded, dict):
                    self._view_state = loaded
        except Exception:
            self._view_state = {}

    def _save_view_state(self):
        try:
            # Keep the file from growing without bound; the oldest entries are
            # the least likely to be revisited.
            if len(self._view_state) > 400:
                trimmed = sorted(self._view_state.items(),
                                 key=lambda kv: kv[1].get("seen", 0), reverse=True)[:300]
                self._view_state = dict(trimmed)
            with open(VIEWSTATE_FILE, "w") as f:
                json.dump(self._view_state, f)
        except Exception:
            pass

    def _apply_view_state(self, path):
        if not PREFS().get("rememberPerFolder"):
            return []
        """Adopt the saved view for `path`. Returns the signals to fire, so the
        caller can announce them after the new path rather than during it —
        emitting mid-navigation made QML re-list the directory two or three
        times for a single move."""
        saved = self._view_state.get(path)
        if not saved:
            return []

        pending = []
        mode = saved.get("view")
        if mode in ("grid", "list") and mode != self._view_mode:
            self._view_mode = mode
            pending.append((self.viewModeChanged, mode))
        size = saved.get("iconSize")
        if isinstance(size, int):
            size = max(64, min(256, size))
            if size != self._grid_icon_size:
                self._grid_icon_size = size
                pending.append((self.gridIconSizeChanged, size))
        field = saved.get("sortField")
        if field and field != self._sort_field:
            self._sort_field = field
            pending.append((self.sortFieldChanged, field))
        desc = saved.get("sortDesc")
        if isinstance(desc, bool) and desc != self._sort_descending:
            self._sort_descending = desc
            pending.append((self.sortDescendingChanged, desc))
        return pending

    @staticmethod
    def _flush_pending(pending):
        for signal, value in pending or []:
            signal.emit(value)

    def _remember_view_state(self):
        if self._secondary or not PREFS().get("rememberPerFolder"):
            return
        self._view_state[self._current_path] = {
            "view": self._view_mode,
            "iconSize": self._grid_icon_size,
            "sortField": self._sort_field,
            "sortDesc": self._sort_descending,
            "seen": int(time.time()),
        }
        self._save_view_state()

    def _load_bookmarks(self):
        home = Path.home()
        default_bookmarks = [
            {"name": "Home", "path": str(home)},
            {"name": "Desktop", "path": str(home / "Desktop")},
            {"name": "Documents", "path": str(home / "Documents")},
            {"name": "Downloads", "path": str(home / "Downloads")},
            {"name": "Music", "path": str(home / "Music")},
            {"name": "Pictures", "path": str(home / "Pictures")},
            {"name": "Videos", "path": str(home / "Videos")},
        ]

        if BOOKMARKS_FILE.exists():
            try:
                with open(BOOKMARKS_FILE, "r") as f:
                    self._bookmarks = json.load(f)
            except Exception:
                self._bookmarks = default_bookmarks
        else:
            self._bookmarks = default_bookmarks
            self._save_bookmarks()

        # Icons always come from the shared folder vocabulary, so the sidebar and
        # the grid can never name the same directory two different ways.
        for bm in self._bookmarks:
            bm["icon"] = self._folder_icon(bm.get("name", ""), bm.get("path", ""))

    def _save_bookmarks(self):
        if getattr(self, "_secondary", False):
            return
        try:
            with open(BOOKMARKS_FILE, "w") as f:
                json.dump(self._bookmarks, f, indent=2)
        except Exception:
            pass

    @Slot(str)
    @Slot(str, str)
    def addBookmark(self, path_str, name=""):
        p = Path(path_str)
        if not p.exists():
            return
        b_name = name or p.name
        if not any(b["path"] == str(p) for b in self._bookmarks):
            self._bookmarks.append({"name": b_name, "path": str(p), "icon": self._folder_icon(b_name, str(p))})
            self._save_bookmarks()
            self.bookmarksChanged.emit(self._bookmarks)
            self.setStatus(f"Bookmarked {b_name}")

    @Slot(str)
    def removeBookmark(self, path_str):
        self._bookmarks = [b for b in self._bookmarks if b["path"] != path_str]
        self._save_bookmarks()
        self.bookmarksChanged.emit(self._bookmarks)
        self.setStatus("Bookmark removed")

    # ---- Storage Devices ----
    def _scan_storage_devices(self):
        devices = scan_block_devices()
        if not devices:
            devices = [{"name": "Root Filesystem", "path": "/", "dev": "",
                        "icon": "hard_drive", "mounted": True, "system": True,
                        "removable": False, "readOnly": False, "fstype": "",
                        "sizeStr": "", "freeStr": "", "usedPct": -1}]
        if devices != self._storage_devices:
            self._storage_devices = devices
            self.storageDevicesChanged.emit(devices)

    # ---- Mounting ----

    def _udisks(self, args, done):
        """udisksctl, asynchronously, WITH interaction allowed.

        Two things had to be true here and the obvious version got both wrong.

        Interaction is REQUIRED, not optional: mounting a removable drive is
        usually permitted outright, but mounting an internal volume — the NTFS
        half of a dual-boot machine, say — is an administrative action, and
        udisks asks polkit, which asks you. Passing --no-user-interaction
        suppresses that question and turns "type your password" into a flat
        "Not authorized" with nothing the user can do about it.

        And once a password can be asked for, the call CANNOT be synchronous: a
        subprocess.run() would sit on the UI thread for as long as the prompt is
        on screen, so the window behind the dialog would be frozen while you type
        into it.
        """
        proc = QProcess(self)
        self._udisks_procs.append(proc)

        def finished(code, _status):
            out = bytes(proc.readAllStandardOutput()).decode("utf-8", "replace")
            err = bytes(proc.readAllStandardError()).decode("utf-8", "replace")
            try:
                self._udisks_procs.remove(proc)
            except ValueError:
                pass
            proc.deleteLater()
            done(code == 0, (out or err).strip())

        proc.finished.connect(finished)
        proc.errorOccurred.connect(
            lambda *_a: self.setStatus("udisksctl is not installed"))
        proc.start("udisksctl", list(args))

    @staticmethod
    def _refused(msg):
        low = (msg or "").lower()
        return ("not authorized" in low or "dismissed" in low
                or "cancelled" in low or "canceled" in low)

    @Slot(str)
    def mountDevice(self, dev):
        if not dev:
            return
        self.setStatus(f"Mounting {Path(dev).name}…")

        def done(ok, msg):
            self._scan_storage_devices()
            if not ok:
                self.setStatus("Mount cancelled" if self._refused(msg)
                               else f"Could not mount {Path(dev).name}: "
                                    f"{msg.splitlines()[0] if msg else ''}")
                return
            # "Mounted /dev/sda1 at /run/media/user/LABEL" — go there, because
            # mounting a drive and then having to find it is two steps for one
            # intent.
            target = msg.rsplit(" at ", 1)[1].rstrip(".").strip() if " at " in msg else ""
            self.setStatus(f"Mounted {Path(dev).name}")
            if target and os.path.isdir(target):
                self.cd(target)

        self._udisks(["mount", "-b", dev], done)

    @Slot(str)
    def unmountDevice(self, dev):
        if not dev:
            return
        self._leave_device(dev)
        self.setStatus(f"Unmounting {Path(dev).name}…")

        def done(ok, msg):
            self._scan_storage_devices()
            self.setStatus(f"Unmounted {Path(dev).name}" if ok
                           else ("Unmount cancelled" if self._refused(msg)
                                 else f"Could not unmount: {msg.splitlines()[0] if msg else ''}"))

        self._udisks(["unmount", "-b", dev], done)

    @Slot(str)
    def ejectDevice(self, dev):
        """Unmount, then power the drive down so it is safe to pull out."""
        if not dev:
            return
        self._leave_device(dev)
        self.setStatus(f"Ejecting {Path(dev).name}…")

        def unmounted(ok, msg):
            if not ok and "not mounted" not in (msg or "").lower():
                self._scan_storage_devices()
                self.setStatus("Eject cancelled" if self._refused(msg)
                               else f"Could not eject: {msg.splitlines()[0] if msg else ''}")
                return
            # POWER-OFF ONLY WHAT CAN BE UNPLUGGED. It applies to the whole drive,
            # not one partition of it — so ejecting the NTFS half of a dual-boot
            # machine would ask the kernel to power down the disk the system is
            # running from. A fixed volume stops at the unmount.
            if not any(d.get("dev") == dev and d.get("removable")
                       for d in self._storage_devices):
                self._scan_storage_devices()
                self.setStatus(f"Unmounted {Path(dev).name}")
                return
            whole = re.sub(r"(p?\d+)$", "", dev)

            def powered(_ok2, _msg2):
                self._scan_storage_devices()
                self.setStatus(f"Safe to remove {Path(dev).name}")

            self._udisks(["power-off", "-b", whole], powered)

        self._udisks(["unmount", "-b", dev], unmounted)

    def _leave_device(self, dev):
        """Step off a volume before unmounting it.

        Staying in a directory that is about to disappear leaves the listing
        showing files that are no longer there, and the unmount itself fails
        because the process holds the mount point as its own cwd.
        """
        mount = ""
        for d in self._storage_devices:
            if d.get("dev") == dev:
                mount = d.get("path") or ""
                break
        if not mount:
            return
        here = self._current_path
        if here == mount or here.startswith(mount.rstrip("/") + "/"):
            self.cd(str(Path.home()))

    def _stop_watchers(self):
        try:
            if self._udev is not None:
                self._udev.kill()
                self._udev.waitForFinished(500)
        except Exception:
            pass

    def _on_udev_line(self):
        try:
            self._udev.readAllStandardOutput()
            self._dev_debounce.start()
        except RuntimeError:
            # Shutting down: the C++ side is already gone.
            pass

    # ---- Staying current without polling ----

    def _watch_devices(self):
        """Two edge-triggered sources, no timer between them.

        Plugging a drive in is a udev event; MOUNTING one is not — it is a change
        to the kernel's mount table, which reports itself through poll(POLLPRI)
        on /proc/self/mounts. Watching only one of the two makes half of what
        happens invisible, which is how a drive you just mounted fails to appear.
        """
        self._dev_debounce = QTimer(self)
        self._dev_debounce.setInterval(350)
        self._dev_debounce.setSingleShot(True)
        self._dev_debounce.timeout.connect(self._scan_storage_devices)

        try:
            self._udev = QProcess(self)
            self._udev.setProgram("udevadm")
            self._udev.setArguments(["monitor", "--udev", "--subsystem-match=block"])
            self._udev.readyReadStandardOutput.connect(self._on_udev_line)
            self._udev.start()
        except Exception:
            self._udev = None

        # Qt tears the QProcess down at exit while udevadm is still running and
        # complains about it. It is a long-lived monitor, so it gets stopped on
        # purpose rather than collected.
        QApplication.instance().aboutToQuit.connect(self._stop_watchers)

        try:
            self._mounts_fd = os.open("/proc/self/mounts", os.O_RDONLY)
            self._mounts_notifier = QSocketNotifier(
                self._mounts_fd, QSocketNotifier.Type.Exception, self)
            self._mounts_notifier.activated.connect(
                lambda *_a: self._dev_debounce.start())
        except Exception:
            self._mounts_notifier = None

    # ---- Helpers ----
    def _resolve_thumb(self, path, category, mtime, queue=True):
        """Thumbnail for a listing row: the file itself for images, a cached
        render for video/pdf, queued in the background the first time."""
        if category == "image":
            return path
        if category not in ("video", "pdf"):
            return ""

        cached = self._thumb_cache.get(path)
        if cached and Path(cached).exists():
            return cached

        digest = hashlib.md5(f"{path}_{mtime}".encode()).hexdigest()
        on_disk = PREVIEW_CACHE_DIR / (
            f"vid{VIDEO_THUMB_PX}_{digest}.png" if category == "video"
            else f"pdfthumb{PDF_THUMB_DPI}_{digest}.png")
        if on_disk.exists():
            self._thumb_cache[path] = str(on_disk)
            return str(on_disk)

        if queue and path not in self._queued_thumbs:
            self._queued_thumbs.add(path)
            self._thumb_pool.start(ThumbnailWorker(path, category, self))
        return ""

    def _format_size(self, size_bytes):
        if size_bytes < 1024:
            return f"{size_bytes} B"
        elif size_bytes < 1024 * 1024:
            return f"{size_bytes / 1024:.1f} KB"
        elif size_bytes < 1024 * 1024 * 1024:
            return f"{size_bytes / (1024 * 1024):.1f} MB"
        else:
            return f"{size_bytes / (1024 * 1024 * 1024):.1f} GB"

    # ---- Icon & colour vocabulary ----
    WELL_KNOWN_LOCATIONS = (
        (QStandardPaths.DesktopLocation, "desktop_windows"),
        (QStandardPaths.DocumentsLocation, "description"),
        (QStandardPaths.DownloadLocation, "download"),
        (QStandardPaths.MusicLocation, "music_note"),
        (QStandardPaths.PicturesLocation, "image"),
        (QStandardPaths.MoviesLocation, "movie"),
        (QStandardPaths.PublicShareLocation, "public"),
    )

    NAMED_FOLDERS = {
        ".git": "commit", ".github": "commit", "node_modules": "deployed_code",
        ".config": "tune", ".cache": "cached", ".local": "folder_special",
        ".ssh": "key", ".fonts": "font_download", "fonts": "font_download",
        "src": "code_blocks", "source": "code_blocks", "lib": "code_blocks",
        "build": "construction", "dist": "inventory_2", "target": "inventory_2",
        "bin": "terminal", "scripts": "terminal",
        "test": "science", "tests": "science",
        "docs": "menu_book", "doc": "menu_book",
        "screenshots": "screenshot", "wallpapers": "wallpaper",
        "projects": "workspaces", "repos": "workspaces",
        "games": "sports_esports", "backup": "backup", "backups": "backup",
        "trash": "delete", "tmp": "schedule", "temp": "schedule",
    }

    # A fixed hue per category keeps the classes distinguishable at a glance;
    # saturation and lightness come from the live accent so the set still reads
    # as one palette instead of eight unrelated stickers.
    CATEGORY_HUES = {
        "archive": 0.09, "pdf": 0.99, "image": 0.78, "audio": 0.90,
        "video": 0.66, "code": 0.42, "document": 0.55, "file": None,
    }

    def _well_known_dirs(self):
        if self._wk_dirs is None:
            home = os.path.normpath(str(Path.home()))
            found = {home: "home"}
            for loc, icon in self.WELL_KNOWN_LOCATIONS:
                try:
                    target = QStandardPaths.writableLocation(loc)
                except Exception:
                    target = ""
                if target:
                    found.setdefault(os.path.normpath(target), icon)
            self._wk_dirs = found
        return self._wk_dirs

    def _sync_folder_tint(self):
        """Point the folder colour at the current accent, and re-list if it moved."""
        if not PREFS().get("tintFolders"):
            if ICONS()._tint:
                ICONS()._tint = ""
                ICONS()._for_mime = {k: v for k, v in ICONS()._for_mime.items()
                                     if k[0] != "dir"}
                self.refresh()
            return
        if ICONS().set_accent(self._theme.get("accent", "#63c7dd")):
            self.refresh()

    def theme_icon(self, name, is_dir, full_path):
        """The icon theme's name for this entry, or "" when the theme has none."""
        if not PREFS().get("useThemeIcons"):
            return ""
        try:
            if is_dir:
                return ICONS().for_folder(name, full_path,
                                          self._folder_icon(name, full_path))
            return ICONS().for_file(full_path or name, Path(name).suffix.lower())
        except Exception:
            return ""

    def _folder_icon(self, name, full_path=None):
        if full_path:
            known = self._well_known_dirs().get(os.path.normpath(str(full_path)))
            if known:
                return known
        return self.NAMED_FOLDERS.get(name.lower(), "folder")

    def _category_palette(self):
        """Category colours rebuilt from the current accent and light/dark mode."""
        if self._cat_palette is not None:
            return self._cat_palette

        accent = self._theme.get("accent", "#63c7dd")
        is_dark = self._theme.get("isDark", True)
        try:
            raw = accent.lstrip("#")
            ar, ag, ab = (int(raw[k:k + 2], 16) / 255.0 for k in (0, 2, 4))
        except Exception:
            ar, ag, ab = (0.388, 0.780, 0.867)

        _, _, accent_sat = colorsys.rgb_to_hls(ar, ag, ab)
        sat = min(0.82, max(0.40, accent_sat))
        light = 0.66 if is_dark else 0.44

        def hexof(h, l, sa):
            r, g, b = colorsys.hls_to_rgb(h, l, sa)
            return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))

        palette = {}
        for cat, hue in self.CATEGORY_HUES.items():
            if hue is None:
                continue
            palette[cat] = hexof(hue, light, sat)
        palette["file"] = hexof(0.0, 0.62 if is_dark else 0.48, 0.0)
        palette["directory"] = accent
        self._cat_palette = palette
        return palette

    def _categorize_file(self, name, is_dir, ext, full_path=None):
        palette = self._category_palette()
        if is_dir:
            return self._folder_icon(name, full_path), "directory", palette["directory"], "DIR"

        badge = ext.replace(".", "").upper() if ext else "FILE"
        if ext in [".zip", ".tar", ".gz", ".tgz", ".xz", ".7z", ".bz2", ".rar", ".zst"]:
            return "folder_zip", "archive", palette["archive"], badge
        if ext == ".pdf":
            return "picture_as_pdf", "pdf", palette["pdf"], "PDF"
        if ext in [".png", ".jpg", ".jpeg", ".webp", ".svg", ".gif", ".bmp", ".ico", ".avif", ".tiff"]:
            return "image", "image", palette["image"], badge
        if ext in [".mp3", ".flac", ".wav", ".ogg", ".m4a", ".aac", ".opus"]:
            return "audiotrack", "audio", palette["audio"], badge
        if ext in [".mp4", ".mkv", ".webm", ".avi", ".mov", ".flv", ".m4v"]:
            return "movie", "video", palette["video"], badge
        if ext in [".py", ".qml", ".js", ".ts", ".jsx", ".tsx", ".rs", ".go", ".java", ".rb",
                   ".cpp", ".c", ".h", ".hpp", ".html", ".css", ".scss", ".sh", ".fish",
                   ".lua", ".vim", ".json", ".toml", ".yaml", ".yml", ".conf", ".ini",
                   ".csv", ".log", ".sql", ".nix", ".desktop", ".service"]:
            return "code", "code", palette["code"], badge
        if ext in [".doc", ".docx", ".txt", ".md", ".rtf", ".odt", ".epub",
                   ".xlsx", ".xls", ".ods", ".pptx", ".ppt", ".odp"]:
            return "description", "document", palette["document"], badge
        # Anything else the mime database calls text is a code preview rather than
        # a shrug -- see IconResolver.is_text.
        if full_path and ICONS().is_text(full_path):
            return "code", "code", palette["code"], badge
        return "draft", "file", palette["file"], badge


def main():
    # Qt Quick defaults to distance-field text, which smears the interior detail of
    # filled icon glyphs at UI sizes and leaves a pale rim that reads as a fake bevel.
    # Nothing here scales or rotates text, so the native rasteriser is strictly better.
    QQuickWindow.setTextRenderType(QQuickWindow.TextRenderType.NativeTextRendering)

    app = QApplication(sys.argv)
    app.setApplicationName("Files")
    app.setDesktopFileName("sea-fm")

    init_path = sys.argv[1] if len(sys.argv) > 1 and Path(sys.argv[1]).exists() else None
    backend = FileManagerBackend(initial_path=init_path)
    # The split pane's own backend. It starts at home rather than mirroring the
    # first, so opening the split shows you somewhere else — the entire point.
    backend_b = FileManagerBackend(initial_path=str(Path.home()), secondary=True)

    script_dir = Path(__file__).resolve().parent
    candidates = [
        script_dir.parent.parent / "ui" / "FileManager.qml",
        script_dir / "FileManager.qml",
        Path.home() / ".config" / "quickshell" / "sea-shell" / "FileManager.qml"
    ]

    qml_path = None
    for cand in candidates:
        if cand.exists():
            qml_path = cand
            break

    if not qml_path:
        print(f"Error: FileManager.qml not found.", file=sys.stderr)
        sys.exit(1)

    engine = QQmlApplicationEngine()
    # image://fileicon/<name> — see ThemeIconProvider.
    engine.addImageProvider("fileicon", ThemeIconProvider())
    # "be1"/"be2" are the two panes. FileManager.qml declares its own `backend`
    # property that resolves to whichever pane is active, and a root property
    # shadows a context property — so every existing `backend.foo` in that file
    # follows the focused pane with no rewriting.
    engine.rootContext().setContextProperty("be1", backend)
    engine.rootContext().setContextProperty("be2", backend_b)
    engine.rootContext().setContextProperty("backend", backend)
    # Undo and tags are properties of the APPLICATION, not of a pane. Two panes are
    # two views of one filesystem, and an undo that only reached the half of the
    # window you happened to be looking at would be a coin toss.
    engine.rootContext().setContextProperty("undo", UNDO())
    engine.rootContext().setContextProperty("tagstore", TAGS())
    # Copies and moves belong to the application too, for the same reason: a
    # transfer started in one pane is not a fact about that half of the window,
    # and there is exactly one progress bar and one conflict dialog for both.
    engine.rootContext().setContextProperty("ops", OPS())
    engine.rootContext().setContextProperty("stars", STARS())
    engine.rootContext().setContextProperty("prefs", PREFS())
    app.aboutToQuit.connect(OPS().cancelAll)

    # THE MENU BAR AS DATA. sea-fm has no QMenuBar for the accessibility walk to
    # find — it is Qt Quick all the way down — so the global menu would never see
    # it. Exporting com.canonical.dbusmenu is the path sea-appmenu tries FIRST,
    # and it is strictly better than the fallback: the whole tree arrives in one
    # call, nothing is opened on screen, and states are always current.
    #
    # The tree itself is built in QML, where the enabled conditions already exist
    # as bindings; this side only owns the wire format. `appmenu` is always set,
    # even when the export could not start, so the QML has one thing to talk to
    # and no branch of its own.
    appmenu = AppMenu() if AppMenu is not None else None
    if appmenu is not None and not appmenu.start():
        appmenu = None
    engine.rootContext().setContextProperty("appmenu", appmenu)
    if appmenu is not None:
        app.aboutToQuit.connect(appmenu.stop)

    ui_dir = str(Path(__file__).parent.parent / "ui")
    if os.path.exists(ui_dir):
        engine.addImportPath(ui_dir)

    engine.load(QUrl.fromLocalFile(str(qml_path)))
    if not engine.rootObjects():
        print("Failed to load QML interface", file=sys.stderr)
        sys.exit(1)

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
