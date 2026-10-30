"""Clipboard action tests; uses Qt's offscreen platform, no user clipboard."""
import os
os.environ['QT_QPA_PLATFORM']='offscreen'
os.environ['QT_QPA_PLATFORMTHEME']=''
os.environ['QT_STYLE_OVERRIDE']='Fusion'
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PySide6.QtWidgets import QApplication

spec=importlib.util.spec_from_file_location('clipboard_fm',Path(__file__).resolve().parents[1]/'quickshell/scripts/system/sea-fm.py')
fm=importlib.util.module_from_spec(spec);spec.loader.exec_module(fm)
APP=QApplication.instance() or QApplication([])
class Signal:
    def emit(self,*args):pass
class Pane:
    _selected_file=''
    clipboardChanged=Signal()
    _uri_to_path=staticmethod(fm.FileManagerBackend._uri_to_path)
    def setStatus(self,msg):self.status=msg
    def _virtual(self,*args):return False
    def _foreign_clipboard(self):return []

class ClipboardTests(unittest.TestCase):
    def tearDown(self):APP.clipboard().clear()
    def test_cut_and_copy_survive_pane_change(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);src=root/'file with spaces 世界.txt';src.write_text('data')
            dest=root/'dest';dest.mkdir();first,second=Pane(),Pane();second._current_path=str(dest)
            with patch.object(fm,'OPS') as ops:
                fm.FileManagerBackend.setClipboard(first,[str(src)],'cut')
                fm.FileManagerBackend.pasteFiles(second)
                ops.return_value.moveTo.assert_called_once_with([str(src)],str(dest))
                fm.FileManagerBackend.setClipboard(first,[str(src)],'copy')
                fm.FileManagerBackend.pasteFiles(second)
                ops.return_value.copyTo.assert_called_once_with([str(src)],str(dest))
    def test_replaced_clipboard_does_not_reuse_old_files(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'file';p.touch();pane=Pane();pane._current_path=root
            fm.FileManagerBackend.setClipboard(pane,[str(p)],'cut')
            APP.clipboard().setText('some text')
            with patch.object(fm,'OPS') as ops:
                fm.FileManagerBackend.pasteFiles(pane)
                ops.assert_not_called()
            self.assertEqual(pane.status,'Clipboard is empty')
    def test_broken_link_can_be_cut(self):
        with tempfile.TemporaryDirectory() as root:
            link=Path(root)/'link';link.symlink_to(Path(root)/'missing')
            pane=Pane();pane._current_path=root
            fm.FileManagerBackend.setClipboard(pane,[str(link)],'cut')
            with patch.object(fm,'OPS') as ops:
                fm.FileManagerBackend.pasteFiles(pane)
                ops.return_value.moveTo.assert_called_once_with([str(link)],root)

if __name__=='__main__':unittest.main()
