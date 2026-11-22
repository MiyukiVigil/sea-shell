import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from PySide6.QtQml import QJSEngine
from test_clipboard import APP

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'quickshell/scripts/system/sea-disk.py'
SETTINGS = (ROOT / 'quickshell/ui/settings.qml').read_text()


def load_with_home(home):
    os.environ['HOME'] = home
    spec = importlib.util.spec_from_file_location('sea_disk_under_test', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DiskMountsTests(unittest.TestCase):
    def test_btrfs_subvolumes_report_root_first(self):
        body = SETTINGS.split('    function diskMounts(n) {', 1)[1].split('\n    Process {', 1)[0]
        engine = QJSEngine()
        engine.evaluate('function diskMounts(n) {' + body)
        result = engine.evaluate('diskMounts({mountpoint:"/var/tmp",mountpoints:["/var/tmp","/var/log","/home","/"]}).join()')
        self.assertEqual(result.toString(), '/,/home,/var/log,/var/tmp')
        self.assertEqual(engine.evaluate('diskMounts({mountpoint:null,mountpoints:[null]}).length').toInt(), 0)


class CleanTests(unittest.TestCase):
    def setUp(self):
        self.saved_home = os.environ['HOME']
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.disk = load_with_home(self.home)

    def tearDown(self):
        os.environ['HOME'] = self.saved_home
        self.tmp.cleanup()

    def write(self, rel, size=4096):
        path = Path(self.home) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'x' * size)
        return path

    def test_hard_link_shared_outside_the_tree_frees_nothing(self):
        cached = self.write('.cache/uv/file', 1 << 20)
        outside = Path(self.home) / 'env-file'
        os.link(cached, outside)
        self.assertEqual(self.disk.measure(self.home + '/.cache/uv'), 0)
        outside.unlink()
        self.assertGreater(self.disk.measure(self.home + '/.cache/uv'), 0)

    def test_ids_are_the_only_way_to_a_path(self):
        self.write('precious/thesis.docx')
        for bad in ['/home', '../..', 'precious', 'cache:../precious', 'cache:cliphist',
                    'build:' + self.home + '/precious', 'build:/etc']:
            self.assertIsNone(self.disk.resolve_user_item(bad), bad)
        self.assertTrue((Path(self.home) / 'precious/thesis.docx').exists())

    def test_clearing_keeps_the_folder_and_does_not_follow_symlinks(self):
        keep = self.write('precious/thesis.docx')
        self.write('.cache/thumbnails/a/b.png')
        (Path(self.home) / '.cache/thumbnails/link').symlink_to(keep.parent)
        self.assertEqual(self.disk.clean_user_item('thumbnails', set())[0], 'done')
        self.assertEqual(os.listdir(self.home + '/.cache/thumbnails'), [])
        self.assertTrue(keep.exists())

    def test_build_folder_needs_the_file_that_rebuilds_it(self):
        self.write('work/app/target/release/bin')
        self.assertIsNone(self.disk.build_output_item(self.home + '/work/app/target'))
        self.write('work/app/Cargo.toml')
        self.assertIsNotNone(self.disk.build_output_item(self.home + '/work/app/target'))
        self.write('.app/thing/Cargo.toml')
        self.write('.app/thing/target/x')
        self.assertIsNone(self.disk.build_output_item(self.home + '/.app/thing/target'))

    def test_open_app_is_skipped(self):
        self.write('.cache/mozilla/firefox/x')
        self.assertEqual(self.disk.clean_user_item('firefox', {'firefox'})[0], 'skipped')
        self.assertTrue((Path(self.home) / '.cache/mozilla/firefox/x').exists())

    def test_root_never_runs_anything_off_the_list(self):
        self.assertEqual(self.disk.root_commands('journal'), [['journalctl', '--vacuum-time=14d']])
        self.assertIsNone(self.disk.root_commands('rm -rf /'))
        self.disk.orphan_names = lambda: ['go', 'pnpm']
        self.assertEqual(self.disk.root_commands('orphans:go,pnpm'),
                         [['pacman', '-Rns', '--noconfirm', 'go', 'pnpm']])
        self.assertIsNone(self.disk.root_commands('orphans:go,linux'))
        self.assertIsNone(self.disk.root_commands('orphans:--help'))

    def test_trash_refuses_anything_outside_home(self):
        out = subprocess.run([sys.executable, str(SCRIPT), 'trash', '/etc/hostname'], text=True,
                             capture_output=True, env={**os.environ, 'HOME': self.home}).stdout
        self.assertFalse(json.loads(out)['ok'])

    def test_biggest_files_leave_out_app_game_and_dependency_files(self):
        size = self.disk.MIN_BIG_FILE + 4096
        self.write('Downloads/big.iso', size)
        self.write('.local/share/app/big.db', size)
        self.write('Games/wuwa/drive_c/big.dll', size)
        self.write('work/node_modules/x/big.node', size)
        _, _, biggest, _ = self.disk.walk_home()
        self.assertEqual([os.path.basename(path) for _, path, _ in biggest], ['big.iso'])


class DriveHealthTests(unittest.TestCase):
    def test_docker_sizes(self):
        disk = load_with_home(os.environ['HOME'])
        self.assertEqual(disk.docker_size('4.096kB'), 4096)
        self.assertEqual(disk.docker_size('2.509GB'), 2509000000)
        self.assertEqual(disk.docker_size('0B'), 0)
        self.assertEqual(disk.docker_size(None), 0)


if __name__ == '__main__':
    unittest.main()
