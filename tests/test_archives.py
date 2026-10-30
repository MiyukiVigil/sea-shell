import tempfile
import unittest
import zipfile
from unittest.mock import patch
from pathlib import Path
from test_file_operations import fm

class Progress:
    def emit(self,*args):pass
class Engine:
    progress=Progress()
    def __init__(self,choice=None):self.choice=choice;self.result=None
    def is_cancelled(self,_):return False
    def standing_choice(self,_):return self.choice
    def finish(self,*args):self.result=args

class ArchiveTests(unittest.TestCase):
    def test_extract_merge_keeps_existing_files_and_tracks_only_new_entries(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);dest=root/'dest';dest.mkdir();(dest/'folder').mkdir()
            (dest/'folder'/'existing').write_text('keep')
            archive=root/'test.zip'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('folder/new','new')
            e=Engine();worker=fm.ExtractWorker(e,1,archive,dest);worker.run()
            self.assertFalse(worker.failed)
            self.assertEqual((dest/'folder'/'existing').read_text(),'keep')
            self.assertEqual((dest/'folder'/'new').read_text(),'new')
            self.assertFalse(any(r.get('path')==str(dest/'folder') for r in worker.records))
            self.assertFalse(list(root.glob('.sea-extract-*')))
    def test_failed_archive_preview_does_not_cache_partial_file(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);archive=root/'preview.zip';cache=root/'cache'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('note.txt','data')
            class Reader:
                def _archive_index(self,path):return {}
                def _member_name(self,tree,inner):return inner
            def broken(source,destination):
                destination.write(b'partial')
                raise OSError('read failed')
            with patch.object(fm,'ARCHIVE_CACHE_DIR',cache),patch.object(fm.shutil,'copyfileobj',broken):
                result=fm.FileManagerBackend._extract_member(Reader(),str(archive),'note.txt')
            self.assertEqual(result,'')
            self.assertEqual(list(cache.iterdir()),[])

    def test_selected_folder_includes_children_and_empty_folders(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);dest=root/'dest';archive=root/'test.zip'
            with zipfile.ZipFile(archive,'w') as z:
                z.writestr('selected/empty/','');z.writestr('selected/child','data');z.writestr('other','no')
            worker=fm.ExtractWorker(Engine(),1,archive,dest,['selected']);worker.run()
            self.assertFalse(worker.failed)
            self.assertEqual((dest/'selected'/'child').read_text(),'data')
            self.assertTrue((dest/'selected'/'empty').is_dir())
            self.assertFalse((dest/'other').exists())

    def test_skip_conflict_does_not_overwrite(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);dest=root/'dest';dest.mkdir();(dest/'file').write_text('original')
            archive=root/'test.zip'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('file','replacement')
            worker=fm.ExtractWorker(Engine(fm.CONFLICT_SKIP),1,archive,dest);worker.run()
            self.assertEqual((dest/'file').read_text(),'original')
            self.assertFalse(worker.records)
    def test_invalid_member_commits_nothing(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);dest=root/'dest';archive=root/'test.zip'
            with zipfile.ZipFile(archive,'w') as z:
                z.writestr('good','data');z.writestr('../escape','bad')
            worker=fm.ExtractWorker(Engine(),1,archive,dest);worker.run()
            self.assertTrue(worker.failed)
            self.assertFalse((root/'escape').exists())
            self.assertFalse((dest/'good').exists())
    def test_keep_both_preserves_original(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);dest=root/'dest';dest.mkdir();(dest/'file.txt').write_text('original')
            archive=root/'test.zip'
            with zipfile.ZipFile(archive,'w') as z:z.writestr('file.txt','new')
            worker=fm.ExtractWorker(Engine(fm.CONFLICT_KEEP_BOTH),1,archive,dest);worker.run()
            self.assertEqual((dest/'file.txt').read_text(),'original')
            self.assertEqual((dest/'file_2.txt').read_text(),'new')
if __name__=='__main__':unittest.main()
