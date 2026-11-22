import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sea_appimage', ROOT / 'quickshell/scripts/system/sea-appimage.py')
appimage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appimage)

PNG = b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' + struct.pack('>II', 256, 256) + b'rest'


def fake_image(path, kind=2, runtime=b''):
    header = bytearray(64)
    header[:4] = b'\x7fELF'
    header[8:11] = b'AI' + bytes([kind])
    section_table = 64 + len(runtime)
    header[40:48] = struct.pack('<Q', section_table)
    header[58:62] = struct.pack('<HH', 64, 0)
    path.write_bytes(bytes(header) + runtime + b'hsqs')
    return path


class AppImageTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.script = self.home / 'scripts with space/sea-appimage.py'
        env = patch.dict(os.environ, {'HOME': str(self.home),
                                      'XDG_DATA_HOME': str(self.home / 'data'),
                                      'XDG_CONFIG_HOME': str(self.home / 'config')})
        env.start()
        self.addCleanup(env.stop)
        for target, value in (('refresh_launcher', None), ('needs_extract_and_run', False)):
            stub = patch.object(appimage, target, return_value=value)
            stub.start()
            self.addCleanup(stub.stop)

    def unpacks(self, desktop=None, files=None):
        """Stand in for 7z: lay out the image's top level as given."""
        def extract(path, into):
            root = Path(into)
            if desktop is not None:
                (root / 'app.desktop').write_text(desktop)
            for name, data in (files or {}).items():
                (root / name).write_bytes(data)
            return root
        stub = patch.object(appimage, 'extract', extract)
        stub.start()
        self.addCleanup(stub.stop)

    def install(self, name='App-x86_64.AppImage'):
        source = fake_image(self.home / name)
        return source, appimage.install(source, script=self.script)

    def entry(self, slug):
        return appimage.applications() / f'sea-appimage-{slug}.desktop'

    def exec_line(self, slug):
        return appimage.parse_desktop(self.entry(slug).read_text())['Exec']

    def test_install_moves_file_and_writes_entry_with_icon(self):
        self.unpacks('[Desktop Entry]\nName=SCSKiller\nIcon=App\nExec=SCSKiller.Ui\nCategories=Game;\n'
                     'StartupWMClass=SCSKiller.Ui\n', {'App.png': PNG})
        source, result = self.install('SCSKiller-x86_64.AppImage')
        target = self.home / 'Applications/SCSKiller.AppImage'
        self.assertFalse(source.exists())
        self.assertTrue(os.access(target, os.X_OK))
        self.assertEqual(result['path'], target)
        fields = appimage.parse_desktop(self.entry('scskiller').read_text())
        self.assertEqual(fields['Exec'], f'"{target}"')
        self.assertEqual(fields['Categories'], 'Game;')
        self.assertEqual(fields['StartupWMClass'], 'SCSKiller.Ui')
        self.assertEqual(fields['Icon'], 'sea-appimage-scskiller')
        self.assertEqual((appimage.data_home() / 'icons/hicolor/256x256/apps/sea-appimage-scskiller.png').read_bytes(), PNG)

    def test_bundled_exec_only_contributes_flags(self):
        self.unpacks('[Desktop Entry]\nName=App\nExec=env FOO=1 rm -rf %U\n')
        _, result = self.install()
        self.assertEqual(self.exec_line('app'), f'"{result["path"]}" "-rf" %U')

    def test_unlisted_keys_are_not_copied(self):
        self.unpacks('[Desktop Entry]\nName=App\nDBusActivatable=true\nTryExec=/bin/sh\nActions=Evil;\n'
                     '[Desktop Action Evil]\nName=Bad\nExec=/bin/sh\n')
        _, result = self.install()
        fields = appimage.parse_desktop(self.entry('app').read_text())
        self.assertNotIn('DBusActivatable', fields)
        self.assertEqual(fields['TryExec'], str(result['path']))
        self.assertEqual(fields['Actions'], 'Uninstall;')
        self.assertNotIn('Evil', self.entry('app').read_text())

    def test_hostile_name_stays_in_applications_folder(self):
        self.unpacks('[Desktop Entry]\nName=../../evil name\n')
        _, result = self.install()
        self.assertEqual(result['path'].parent, self.home / 'Applications')
        self.assertEqual(self.entry('evil-name').parent, appimage.applications())

    def test_unreadable_image_still_installs_from_its_filename(self):
        with patch.object(appimage, 'extract', side_effect=OSError):
            _, result = self.install('Foo_Bar-1.2.3-x86_64.AppImage')
        self.assertEqual(result['name'], 'Foo_Bar')
        self.assertIsNone(result['icon'])

    def test_new_version_replaces_old_one(self):
        self.unpacks('[Desktop Entry]\nName=App\n')
        _, first = self.install('App-1.0.AppImage')
        _, second = self.install('App-2.0.AppImage')
        self.assertTrue(second['updated'])
        self.assertEqual(first['path'], second['path'])
        self.assertEqual(list((self.home / 'Applications').iterdir()), [second['path']])
        self.assertEqual(list(appimage.applications().glob('sea-appimage-*.desktop')), [self.entry('app')])

    def test_unmanaged_file_in_the_way_is_not_overwritten(self):
        self.unpacks('[Desktop Entry]\nName=App\n')
        mine = self.home / 'Applications/App.AppImage'
        mine.parent.mkdir()
        mine.write_text('mine')
        _, result = self.install()
        self.assertEqual(mine.read_text(), 'mine')
        self.assertEqual(result['path'].name, 'App-2.AppImage')

    def test_rejects_files_that_are_not_appimages(self):
        plain = self.home / 'plain.AppImage'
        plain.write_bytes(b'\x7fELF' + bytes(60))
        with self.assertRaises(appimage.AppImageError):
            appimage.install(plain)
        self.assertTrue(plain.exists())
        with self.assertRaises(appimage.AppImageError):
            appimage.install(fake_image(self.home / 'old.AppImage', kind=1))

    def test_links_leaving_the_image_are_ignored(self):
        outside = self.home / 'secret.png'
        outside.write_bytes(PNG)

        def extract(path, into):
            (Path(into) / '.DirIcon').symlink_to(outside)
            return Path(into)
        with patch.object(appimage, 'extract', extract):
            self.assertEqual(appimage.read_bundle(self.home), ({}, None))

    def test_remove_trashes_file_and_clears_entry_and_icon(self):
        self.unpacks('[Desktop Entry]\nName=My App\nIcon=x\n', {'x.png': PNG})
        _, result = self.install()
        with patch.object(appimage, 'trash') as trash:
            self.assertEqual(appimage.remove('my app'), 'My App')
        trash.assert_called_once_with(result['path'])
        self.assertFalse(self.entry('my-app').exists())
        self.assertEqual(list((appimage.data_home() / 'icons').rglob('*.png')), [])
        with self.assertRaises(appimage.AppImageError):
            appimage.remove('my app')

    def test_entries_we_did_not_write_are_not_listed(self):
        applications = appimage.applications()
        applications.mkdir(parents=True)
        (applications / 'sea-appimage-other.desktop').write_text('[Desktop Entry]\nName=Other\n')
        self.assertEqual(appimage.installed(), {})

    def test_double_click_on_installed_app_launches_it(self):
        self.unpacks('[Desktop Entry]\nName=App\n')
        _, result = self.install()
        with patch.object(appimage, 'launch') as launch, patch.object(appimage, 'install') as install:
            self.assertEqual(appimage.open_file(result['path']), 0)
        launch.assert_called_once_with('app')
        install.assert_not_called()

    def test_double_click_installs_and_open_button_launches(self):
        self.unpacks('[Desktop Entry]\nName=App\n')
        source = fake_image(self.home / 'App.AppImage')
        with patch.object(appimage, 'notify', return_value=True) as notify, patch.object(appimage, 'launch') as launch:
            self.assertEqual(appimage.open_file(source), 0)
        self.assertEqual(notify.call_args.args[0], 'App installed')
        launch.assert_called_once_with('app')

    def test_double_click_on_bad_file_says_so(self):
        plain = self.home / 'plain.AppImage'
        plain.write_text('nope')
        with patch.object(appimage, 'notify') as notify:
            self.assertEqual(appimage.open_file(plain), 1)
        self.assertEqual(notify.call_args.kwargs['urgency'], 'critical')

    def test_fuse2_runtime_falls_back_to_extract_and_run(self):
        self.unpacks('[Desktop Entry]\nName=App\n')
        with patch.object(appimage, 'needs_extract_and_run', return_value=True):
            _, result = self.install()
        self.assertEqual(self.exec_line('app'), f'env APPIMAGE_EXTRACT_AND_RUN=1 "{result["path"]}"')

    def test_register_respects_a_chosen_default(self):
        config = appimage.config_home()
        config.mkdir(parents=True)
        (config / 'mimeapps.list').write_text(f'[Default Applications]\n{appimage.MIME}=other.desktop;\n')
        with patch.object(appimage.subprocess, 'run') as run:
            path = appimage.register(self.script)
        run.assert_not_called()
        self.assertIn(f'MimeType={appimage.MIME};', path.read_text())
        self.assertIn(f'"{self.script}" open %f', path.read_text())

    def test_register_claims_unset_default_and_unregister_gives_it_back(self):
        config = appimage.config_home()
        config.mkdir(parents=True)
        listing = config / 'mimeapps.list'
        listing.write_text('[Default Applications]\ntext/plain=a.desktop;\n')
        with patch.object(appimage.subprocess, 'run') as run:
            appimage.register(self.script)
        self.assertEqual(run.call_args.args[0], ['xdg-mime', 'default', appimage.HANDLER, appimage.MIME])
        listing.write_text(listing.read_text() + f'{appimage.MIME}={appimage.HANDLER};\n')
        appimage.unregister()
        self.assertEqual(listing.read_text(), '[Default Applications]\ntext/plain=a.desktop;\n')
        self.assertFalse((appimage.applications() / appimage.HANDLER).exists())


class Fuse2DetectionTests(unittest.TestCase):
    def test_only_fuse2_runtime_without_the_library_needs_the_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            old = fake_image(Path(temp) / 'old', runtime=b'..libfuse.so.2..')
            new = fake_image(Path(temp) / 'new', runtime=b'static runtime')
            with patch.object(appimage.subprocess, 'run') as run:
                run.return_value.stdout = 'libc.so.6 (libc6,x86-64) => /usr/lib/libc.so.6\n'
                self.assertTrue(appimage.needs_extract_and_run(old))
                self.assertFalse(appimage.needs_extract_and_run(new))
                run.return_value.stdout = 'libfuse.so.2 (libc6,x86-64) => /usr/lib/libfuse.so.2\n'
                self.assertFalse(appimage.needs_extract_and_run(old))


if __name__ == '__main__':
    unittest.main()
