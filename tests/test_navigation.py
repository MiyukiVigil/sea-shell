import os
os.environ['QT_QPA_PLATFORM']='offscreen'
os.environ['QT_QPA_PLATFORMTHEME']=''
os.environ['QT_STYLE_OVERRIDE']='Fusion'
import time,tempfile,unittest,zipfile
from pathlib import Path
from test_clipboard import APP,fm

class NavigationTests(unittest.TestCase):
    def wait(self,predicate,seconds=4):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            APP.processEvents()
            if predicate():return
            time.sleep(.001)
        self.fail('Timed out waiting for listing')
    def test_navigation_and_latest_search_own_the_results(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);a=root/'a';b=root/'b';a.mkdir();b.mkdir()
            for i in range(600):(a/f'old-{i}.txt').touch()
            (b/'new.txt').touch()
            backend=fm.FileManagerBackend(str(a),secondary=True)
            try:
                backend.setSearchQuery('old')
                backend.cd(str(b))
                backend.setSearchQuery('new')
                self.wait(lambda:backend.model.count==1 and backend.model.at(0)['name']=='new.txt')
                token=backend._scan_token
                backend._scan_finished(token-1,[('wrong',str(a/'wrong'),False,0,0)],'')
                self.assertEqual(backend.model.at(0)['name'],'new.txt')
                self.assertEqual(backend.currentPath,str(b))
            finally:
                backend._scan_cancel.set();backend._scan_pool.waitForDone()
    def test_navigation_clears_old_rows_immediately(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);a=root/'a';b=root/'b';a.mkdir();b.mkdir();(a/'file').touch()
            backend=fm.FileManagerBackend(str(a),secondary=True)
            try:
                self.wait(lambda:backend.model.count==1)
                backend.cd(str(b))
                self.assertEqual(backend.model.count,0)
            finally:
                backend._scan_cancel.set();backend._scan_pool.waitForDone()
    def test_old_archive_preview_result_is_ignored_after_navigation(self):
        with tempfile.TemporaryDirectory() as root:
            backend=fm.FileManagerBackend(root,secondary=True)
            try:
                old=backend._archive_token
                backend.selectFile('')
                snapshot=dict(backend._preview_data)
                backend._on_archive_extracted('old.zip/file',old,'/nonexistent','preview')
                self.assertEqual(backend._preview_data,snapshot)
            finally:
                backend._scan_cancel.set();backend._scan_pool.waitForDone()

    def test_archive_listing_and_navigation(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);archive=root/'files.zip'
            with zipfile.ZipFile(archive,'w') as z:
                z.writestr('folder/note.txt','data');z.writestr('root.txt','root')
            backend=fm.FileManagerBackend(str(root),secondary=True)
            try:
                backend.cd(str(archive))
                self.wait(lambda:backend.model.count==2 and not backend.listingBusy)
                self.assertEqual({row['name'] for row in backend.model._rows},{'folder','root.txt'})
                backend.cd(str(archive/'folder'))
                self.wait(lambda:backend.model.count==1 and not backend.listingBusy)
                self.assertEqual(backend.model.at(0)['name'],'note.txt')
            finally:
                backend._scan_cancel.set();backend._scan_pool.waitForDone()

    def test_media_listing_only_queues_requested_thumbnails(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            for i in range(200):(root/f'file-{i}.pdf').touch()
            backend=fm.FileManagerBackend(str(root),secondary=True)
            class Pool:
                def __init__(self):self.work=[]
                def start(self,worker):self.work.append(worker)
            pool=Pool();backend._thumb_pool=pool
            try:
                self.wait(lambda:backend.model.count==200 and not backend.listingBusy)
                self.assertEqual(len(pool.work),0)
                path=backend.model.at(0)['path']
                backend.requestListingThumbnail(path)
                backend.requestListingThumbnail(path)
                self.assertEqual(len(pool.work),1)
            finally:
                backend._scan_cancel.set();backend._scan_pool.waitForDone()

if __name__=='__main__':unittest.main()
