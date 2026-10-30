"""Run with python3 -m unittest discover -s tests -p test_file_operations.py."""
import importlib.util
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

spec = importlib.util.spec_from_file_location('sea_fm', Path(__file__).resolve().parents[1] / 'quickshell/scripts/system/sea-fm.py')
fm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fm)

class Engine:
    def is_cancelled(self, _): return False

class FileOperations(unittest.TestCase):
    def test_merge_undo_never_owns_existing_destination(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            src, dst = root / 'source', root / 'destination'
            src.mkdir(); dst.mkdir()
            (src / 'new').write_text('new')
            (dst / 'existing').write_text('keep')
            worker = fm.FileOpWorker(Engine(), 1, 'copy', [], root)
            worker._emit = lambda *args, **kwargs: None
            worker._place(src, dst)
            self.assertEqual((dst / 'new').read_text(), 'new')
            self.assertFalse(any(r.get('path') == str(dst) for r in worker.records))
            self.assertEqual((dst / 'existing').read_text(), 'keep')

    def test_created_directory_precedes_child_records(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            src, dst = root / 'source', root / 'destination'
            src.mkdir(); (src / 'new').write_text('new')
            worker = fm.FileOpWorker(Engine(), 1, 'copy', [], root)
            worker._emit = lambda *args, **kwargs: None
            worker._place(src, dst)
            self.assertEqual(worker.records[0], {'op': 'mkdir', 'path': str(dst)})
            self.assertEqual(worker.records[1]['path'], str(dst / 'new'))

    def test_cancelled_copy_leaves_no_partial_file(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); src, dst = root / 'src', root / 'dst'
            src.write_bytes(b'x' * 1024)
            worker = fm.FileOpWorker(Engine(), 1, 'copy', [], root)
            worker._check = lambda: (_ for _ in ()).throw(fm._Cancelled())
            with self.assertRaises(fm._Cancelled): worker._copy_file(src, dst)
            self.assertFalse(dst.exists())
            self.assertFalse(list(root.glob('.sea-copy-*')))
            self.assertEqual(src.stat().st_size, 1024)

    def test_copy_metadata_failure_leaves_no_partial_file(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); src, dst = root / 'src', root / 'dst'
            src.write_text('original')
            worker = fm.FileOpWorker(Engine(), 1, 'copy', [], root)
            worker._emit = lambda *args, **kwargs: None
            with patch.object(fm.shutil, 'copystat', side_effect=OSError('IO error')):
                with self.assertRaises(OSError): worker._copy_file(src, dst)
            self.assertFalse(dst.exists())
            self.assertFalse(list(root.glob('.sea-copy-*')))
            self.assertEqual(src.read_text(), 'original')

    @unittest.skipUnless(fm.native_core(), 'build Rust core first')
    def test_native_large_copy_contents_progress_and_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);src,dst=root/'source',root/'dest'
            data=bytes(range(256))*32768
            src.write_bytes(data);src.chmod(0o640)
            worker=fm.FileOpWorker(Engine(),1,'copy',[],root)
            worker._emit=lambda *a,**kw:None
            worker._copy_file(src,dst)
            self.assertEqual(dst.read_bytes(),data)
            self.assertEqual(worker.done_bytes,len(data))
            self.assertEqual(dst.stat().st_mode & 0o777,0o640)
            self.assertFalse(list(root.glob('.sea-copy-*')))

    @unittest.skipUnless(fm.native_core(), 'build Rust core first')
    def test_cancel_native_copy_removes_temporary_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);src,dst=root/'source',root/'dest'
            data=b'x'*(8*1024*1024);src.write_bytes(data)
            engine=Engine();engine.cancelled=False
            engine.is_cancelled=lambda _:engine.cancelled
            worker=fm.FileOpWorker(engine,1,'copy',[],root)
            worker._emit=lambda *a,**kw:setattr(engine,'cancelled',True)
            with self.assertRaises(fm._Cancelled):worker._copy_file(src,dst)
            self.assertFalse(dst.exists())
            self.assertFalse(list(root.glob('.sea-copy-*')))
            self.assertEqual(src.stat().st_size,len(data))

    def test_free_name_skips_broken_links(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root) / 'file.txt'
            p.with_name('file_2.txt').symlink_to('/nonexistent/sea-fm-test')
            self.assertEqual(fm._free_name(p).name, 'file_3.txt')

    def test_undo_directory_preserves_new_contents(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root) / 'folder'; p.mkdir()
            (p / 'later').write_text('keep')
            journal = fm.UndoJournal()
            with self.assertRaises(OSError):
                journal._reverse('mkdir', {'path': str(p)})
            self.assertEqual((p / 'later').read_text(), 'keep')

if __name__ == '__main__': unittest.main()
