import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class UninstallRestoreTests(unittest.TestCase):
    def test_kept_idle_and_original_fonts_restore_without_touching_session(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            cfg = home / '.config'
            (cfg / 'hypr').mkdir(parents=True)
            idle = cfg / 'hypr/hypridle.conf'
            idle.write_text('general {\n    lock_cmd = ~/.config/quickshell/sea-shell/sea-lock.sh --now\n}\n')
            fonts = cfg / 'sea-shell/before-fonts'
            fonts.mkdir(parents=True)
            (fonts / 'font-name').write_text("'Cantarell 11'\n")
            aliases = cfg / 'fontconfig/conf.d'
            aliases.mkdir(parents=True)
            (aliases / '60-sea-fonts.conf').write_bytes((ROOT / 'fontconfig/60-sea-fonts.conf').read_bytes())
            # Only definitions are sourced. Session commands and service integrations are stubbed.
            source = (ROOT / 'install.sh').read_text().split('# ---- args (flags combine', 1)[0]
            script = home / 'installer-definitions.sh'
            script.write_text(source)
            command = '''source "$TEST_DEFINITIONS"
SCRIPT_DIR="$TEST_REPO"
pkill() { :; }
kill() { :; }
fc-cache() { :; }
gsettings() { printf '%s\\n' "$*" >> "$HOME/font-calls"; }
python3() { :; }
do_uninstall
do_uninstall
'''
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(cfg),
                       XDG_RUNTIME_DIR=str(home), TEST_DEFINITIONS=str(script), TEST_REPO=str(ROOT))
            result = subprocess.run(['bash', '-c', command], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('lock_cmd = pidof hyprlock || hyprlock', idle.read_text())
            self.assertFalse((aliases / '60-sea-fonts.conf').exists())
            self.assertIn("font-name 'Cantarell 11'", (home / 'font-calls').read_text())

    def test_filemanager_restoration_preserves_later_user_choice(self):
        spec = importlib.util.spec_from_file_location('restore', ROOT / 'quickshell/scripts/system/sea-restore-defaults.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, XDG_CONFIG_HOME=temp, XDG_DATA_HOME=temp):
            state = Path(temp) / 'sea-shell'
            state.mkdir()
            (state / 'before-filemanager').write_text('old.desktop\n')
            with patch.object(module.subprocess, 'run') as run:
                run.return_value.stdout = 'user-choice.desktop\n'
                module.main()
                self.assertEqual(run.call_count, 1)
            with patch.object(module.subprocess, 'run') as run:
                run.return_value.stdout = 'sea-fm.desktop\n'
                module.main()
                self.assertEqual(run.call_args.args[0], ['xdg-mime', 'default', 'old.desktop', 'inode/directory'])
