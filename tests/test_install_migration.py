import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MigrationTests(unittest.TestCase):
    def test_install_twice_preserves_migration_and_original_fonts(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            cfg = home / '.config'
            (cfg / 'hypr').mkdir(parents=True)
            (cfg / 'hypr/hyprland.lua').write_text('-- existing user settings\n')
            (cfg / 'hypr/hypridle.conf').write_text('general {\n lock_cmd = pidof hyprlock || hyprlock\n}\n')
            definitions = home / 'definitions.sh'
            definitions.write_text((ROOT / 'install.sh').read_text().split('# ---- args (flags combine', 1)[0])
            script = '''source "$TEST_DEFINITIONS"
SCRIPT_DIR="$TEST_REPO"
NO_DEPS=1
NO_HUBMOON=1
check_deps() { :; }
fc-cache() { :; }
gsettings() { if [ "$1" = get ]; then printf "'Cantarell 11'\\n"; fi; }
unset HYPRLAND_INSTANCE_SIGNATURE
do_install
do_install
'''
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(cfg), TEST_DEFINITIONS=str(definitions), TEST_REPO=str(ROOT))
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('sea-lock.sh --now', (cfg / 'hypr/hypridle.conf').read_text())
            lua = (cfg / 'hypr/hyprland.lua').read_text()
            self.assertEqual(lua.count('-- >>> sea-shell >>>'), 1)
            self.assertNotIn('hyprpolkitagent', lua)
            self.assertIn('allow_session_lock_restore = true', (cfg / 'hypr/sea-shell/sea.lua').read_text())
            self.assertTrue((cfg / 'fontconfig/conf.d/60-sea-fonts.conf').is_file())
            self.assertEqual((cfg / 'sea-shell/before-fonts/font-name').read_text(), "'Cantarell 11'\n")
            dest = cfg / 'quickshell/sea-shell'
            for name in ['LockSurface.qml', 'PowerMenu.qml', 'PolkitDialog.qml', 'NotifGroup.qml', 'BatteryRing.qml', 'sea-whats-new.py']:
                self.assertTrue((dest / name).is_file(), name)
