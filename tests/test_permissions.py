import os,stat,tempfile,unittest
from pathlib import Path
from test_archives import Engine,fm

class PermissionsTests(unittest.TestCase):
    def test_recursive_permissions_do_not_follow_links(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);folder=root/'folder';folder.mkdir();file=folder/'file';file.touch();file.chmod(0o600)
            outside=root/'outside';outside.touch();outside.chmod(0o600)
            (folder/'link').symlink_to(outside)
            worker=fm.PermissionWorker(Engine(),1,folder,0o644,True);worker.run()
            self.assertFalse(worker.failed)
            self.assertEqual(stat.S_IMODE(file.stat().st_mode),0o644)
            self.assertEqual(stat.S_IMODE(folder.stat().st_mode),0o755)
            self.assertEqual(stat.S_IMODE(outside.stat().st_mode),0o600)
            self.assertEqual(worker.skipped,1)
            self.assertTrue(all(r['op']=='chmod' for r in worker.records))
    def test_cancel_before_changes_preserves_permissions(self):
        with tempfile.TemporaryDirectory() as root:
            file=Path(root)/'file';file.touch();file.chmod(0o600)
            engine=Engine();engine.is_cancelled=lambda _:True
            worker=fm.PermissionWorker(engine,1,file,0o644,False);worker.run()
            self.assertEqual(stat.S_IMODE(file.stat().st_mode),0o600)
            self.assertFalse(worker.records)
if __name__=='__main__':unittest.main()
