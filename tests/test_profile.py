import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('profile_settings',Path(__file__).parents[1]/'quickshell/scripts/system/sea-profile.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class ProfileTests(unittest.TestCase):
    def test_lock_preserves_auth_and_round_trips_optional_labels(self):
        original=(Path(__file__).parents[1]/'hypr/hyprlock.conf').read_text()
        v=p.DEFAULTS|dict(name='Miyuki',avatar='/tmp/avatar.png',showDate=False,showMedia=False)
        first=p.patch_lock(original,v)
        self.assertIn('input-field {',first)
        self.assertIn('fail_text =',first)
        self.assertIn('path = /tmp/avatar.png',first)
        self.assertIn('text = Miyuki # sea-profile-name',first)
        second=p.patch_lock(first,v|dict(showDate=True,showMedia=True))
        self.assertIn("date +'%A, %-d %B %Y'",second)
        self.assertIn('sea-nowplaying.sh',second)
        self.assertEqual(second.count('image {'),1)
    def test_invalid_profile_rejected(self):
        for change in [dict(name='cmd[update:1] evil'),dict(name='$USER'),dict(font='bad\nline'),dict(color='red'),dict(clockSize=999)]:
            with self.assertRaises(ValueError): p.validate(p.DEFAULTS|dict(avatar='')|change)
