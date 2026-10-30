import importlib.util
import tempfile
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[1] / 'quickshell/scripts/system/sea-whats-new.py'
spec = importlib.util.spec_from_file_location('whats_new', PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WhatsNewTests(unittest.TestCase):
    def test_upgrade_is_claimed_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            (cfg / 'appearance.json').write_text('{"welcomed":true}')
            self.assertFalse(module.claim(cfg, '6.6.0'))
            self.assertTrue(module.claim(cfg, '7.0.0'))
            self.assertFalse(module.claim(cfg, '7.0.0'))
            self.assertEqual((cfg / 'whats-new-7.0').read_text(), '7.0.0\n')

    def test_first_run_and_unreadable_config_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            self.assertFalse(module.claim(cfg, '7.0.0'))
            (cfg / 'appearance.json').write_text('{"welcomed":false}')
            self.assertFalse(module.claim(cfg, '7.0.0'))

    def test_new_install_does_not_get_an_upgrade_page_on_reload(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            self.assertFalse(module.claim(cfg, '7.0.0', first_run=True))
            (cfg / 'appearance.json').write_text('{"welcomed":true}')
            self.assertFalse(module.claim(cfg, '7.0.0'))
