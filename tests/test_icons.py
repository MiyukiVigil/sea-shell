import importlib.util,tempfile,unittest
from pathlib import Path
s=importlib.util.spec_from_file_location('icons',Path(__file__).resolve().parents[1]/'quickshell/scripts/theme/sea-icons.py');icons=importlib.util.module_from_spec(s);s.loader.exec_module(icons)
class IconTests(unittest.TestCase):
    def test_variants_and_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            for name in ('breeze','breeze-dark','Adwaita'):
                (root/name).mkdir();(root/name/'index.theme').touch()
            self.assertEqual(icons.choose('breeze','dark',[root]),'breeze-dark')
            self.assertEqual(icons.choose('breeze','light',[root]),'breeze')
            self.assertEqual(icons.choose('missing','light',[root]),'breeze')
    def test_ini_preserves_existing_settings(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'settings.ini';p.write_text('[Settings]\ngtk-theme-name=adw-gtk3\n')
            icons.write_ini(p,'Settings','gtk-icon-theme-name','breeze')
            self.assertIn('gtk-theme-name=adw-gtk3',p.read_text())
            self.assertIn('gtk-icon-theme-name=breeze',p.read_text())
if __name__=='__main__':unittest.main()
