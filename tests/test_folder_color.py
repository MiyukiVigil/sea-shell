import importlib.util
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('folder_color', ROOT / 'quickshell/scripts/theme/sea-folder-color.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FolderColorTests(unittest.TestCase):
    def test_stock_palette_maps_to_itself(self):
        for name, color in module.COLORS.items():
            self.assertEqual(module.nearest('#' + color), name)

    def test_invalid_accents_are_rejected(self):
        for value in ('', '#fff', 'ffffff; touch /tmp/no', 'zzzzzz'):
            with self.assertRaises(ValueError):
                module.nearest(value)

    def test_root_helper_rejects_paths_options_and_extra_arguments(self):
        helper = ROOT / 'quickshell/scripts/system/sea-folder-color.sh'
        for args in ([], ['--theme'], ['/tmp/theme'], ['blue', 'extra'], ['$(id)']):
            result = subprocess.run(['/bin/sh', str(helper), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)
