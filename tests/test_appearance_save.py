import importlib.util,json,tempfile,threading,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('appearance_save',Path(__file__).resolve().parents[1]/'quickshell/scripts/theme/sea-save-appearance.py')
save_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(save_module)
class AppearanceSaveTests(unittest.TestCase):
    def test_merge_preserves_other_settings_and_unicode(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);(root/'appearance.json').write_text(json.dumps({'unrelated':'keep','mode':'dark'}))
            save_module.save({'mode':'light','font':'字体 🌙'},root)
            data=json.loads((root/'appearance.json').read_text())
            self.assertEqual(data,{'unrelated':'keep','mode':'light','font':'字体 🌙'})
            self.assertFalse(list(root.glob('.appearance-*.tmp')))
    def test_invalid_existing_data_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'appearance.json';p.write_text('invalid')
            with self.assertRaises(ValueError):save_module.save({'mode':'light'},root)
            self.assertEqual(p.read_text(),'invalid')
    def test_concurrent_writers_preserve_all_merged_fields(self):
        with tempfile.TemporaryDirectory() as root:
            threads=[threading.Thread(target=save_module.save,args=({str(i):i},root)) for i in range(8)]
            for thread in threads:thread.start()
            for thread in threads:thread.join()
            self.assertEqual(json.loads((Path(root)/'appearance.json').read_text()),{str(i):i for i in range(8)})
if __name__=='__main__':unittest.main()
