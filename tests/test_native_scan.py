"""Integration checks for the compiled Rust scanner (cargo build --release first)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CORE = Path(__file__).resolve().parents[1] / 'native/sea-fm-core/target/release/sea-fm-core'

@unittest.skipUnless(CORE.exists(), 'build sea-fm-core first')
class NativeScan(unittest.TestCase):
    def scan(self, path, query='', hidden=False):
        return json.loads(subprocess.check_output([str(CORE),'scan',str(path),query,'1' if hidden else '0']))

    def test_listing_metadata_hidden_unicode_and_links(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            (root/'hello 世界.txt').write_text('abc')
            (root/'.secret').touch()
            (root/'folder').mkdir()
            (root/'link').symlink_to(root/'folder',target_is_directory=True)
            (root/'broken').symlink_to(root/'gone')
            result=self.scan(root)
            self.assertFalse(result['error'])
            rows={r[0]:r for r in result['rows']}
            self.assertNotIn('.secret',rows)
            self.assertEqual(rows['hello 世界.txt'][3],3)
            self.assertTrue(rows['link'][2])
            self.assertFalse(rows['broken'][2])
            self.assertEqual(len(self.scan(root,hidden=True)['rows']),5)

    def test_search_cap_and_symlink_loop(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);(root/'sub').mkdir()
            (root/'sub'/'loop').symlink_to(root,target_is_directory=True)
            for i in range(200):(root/'sub'/f'hit-{i}').touch()
            rows=self.scan(root,'HIT')['rows']
            self.assertEqual(len(rows),150)
            self.assertEqual(len({r[1] for r in rows}),150)

    @unittest.skipUnless(os.name == 'posix', 'Unix filenames')
    def test_non_utf8_names_request_lossless_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            fd=os.open(os.fsencode(root)+b'/invalid-\xff',os.O_CREAT|os.O_WRONLY,0o600)
            os.close(fd)
            result=self.scan(root)
            self.assertTrue(result['fallback'])
            self.assertTrue(result['error'])

    def test_missing_directory_reports_error(self):
        self.assertTrue(self.scan('/nonexistent/sea-fm-test')['error'])

if __name__=='__main__':unittest.main()
