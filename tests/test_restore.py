import tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from test_archives import Engine,fm

class RestoreTests(unittest.TestCase):
    def test_restore_preserves_collision_and_records_undo(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);trashed=root/'trashed';trashed.write_text('restored')
            origin=root/'original.txt';origin.write_text('existing')
            info=root/'metadata';info.write_text('metadata')
            with patch.object(fm.FileManagerBackend,'_trash_home_of',return_value=(info,None)),patch.object(fm.FileManagerBackend,'_trash_origin',return_value=origin):
                worker=fm.RestoreWorker(Engine(),1,[str(trashed)]);worker.run()
            self.assertFalse(worker.failed)
            self.assertEqual(origin.read_text(),'existing')
            self.assertEqual((root/'original_2.txt').read_text(),'restored')
            self.assertFalse(info.exists())
            self.assertEqual(worker.records,[{'op':'create','path':str(root/'original_2.txt')}])
    def test_restore_broken_link(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);trashed=root/'trashed';trashed.symlink_to(root/'missing')
            origin=root/'original';info=root/'metadata';info.touch()
            with patch.object(fm.FileManagerBackend,'_trash_home_of',return_value=(info,None)),patch.object(fm.FileManagerBackend,'_trash_origin',return_value=origin):
                worker=fm.RestoreWorker(Engine(),1,[str(trashed)]);worker.run()
            self.assertFalse(worker.failed)
            self.assertTrue(origin.is_symlink())
            self.assertFalse(trashed.is_symlink())
if __name__=='__main__':unittest.main()
