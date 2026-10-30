import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sea_sddm', Path(__file__).parents[1] / 'quickshell/scripts/sddm/sea-sddm.py')
sddm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sddm)

class SddmTests(unittest.TestCase):
    def test_prepare_preserves_preset_and_sets_supported_options(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            (base/'configs').mkdir()
            (base/'backgrounds').mkdir()
            (base/'configs/default.conf').write_text('[General]\nscale=1.0\n[LoginScreen]\nbrightness=0.1\n')
            (base/'metadata.desktop').write_text('[SddmGreeterTheme]\nConfigFile=configs/default.conf\n')
            image = base/'example.png'
            image.write_bytes(b'fixture')
            sddm.prepare(dict(background=str(image), position='left', animations=False, blur=12), base)
            c=sddm.config(); c.read(base/'configs/sea-shell.conf')
            self.assertEqual(c.get('General','scale'),'1.0')
            self.assertEqual(c.get('General','enable-animations'),'false')
            self.assertEqual(c.get('LoginScreen.LoginArea','position'),'"left"')
            self.assertEqual(c.get('LoginScreen','background'),'"sea-custom.png"')
            self.assertEqual(c.get('General','animated-background-placeholder'),'"sea-custom.png"')
            self.assertEqual((base/'backgrounds/sea-custom.png').read_bytes(),b'fixture')
            self.assertIn('ConfigFile=configs/sea-shell.conf',(base/'metadata.desktop').read_text())
    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError): sddm.prepare(dict(preset='../escape'))
