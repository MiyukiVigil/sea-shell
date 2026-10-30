import importlib.util,tempfile,unittest
from pathlib import Path

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).resolve().parents[1]/'quickshell/scripts/system'/file)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
register=module('register_files','sea-register-files.py')
defaults=module('defaults_files','sea-defaults.py')
class RegistrationTests(unittest.TestCase):
    def test_desktop_entry_quotes_paths_and_registers_folders(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);script=root/'folder with spaces'/'sea-fm.py';script.parent.mkdir();script.touch()
            entry=register.register(script,root/'data');text=entry.read_text()
            self.assertIn('MimeType=inode/directory;',text)
            line=next(line[5:] for line in text.splitlines() if line.startswith('Exec='))
            self.assertEqual(defaults._exec_words(line)[1],str(script))
            self.assertTrue(text.startswith(register.STAMP))
    def test_existing_entry_is_backed_up(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);script=root/'sea-fm.py';script.touch();applications=root/'data/applications';applications.mkdir(parents=True)
            entry=applications/'sea-fm.desktop';entry.write_text('old')
            register.register(script,root/'data');register.register(script,root/'data')
            self.assertEqual(entry.with_suffix('.desktop.before-sea-shell').read_text(),'old')
if __name__=='__main__':unittest.main()
