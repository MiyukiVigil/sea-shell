"""Video wallpaper: the play/pause/freeze rules, the player itself on a generated clip, and the
cached re-encode. Offscreen Qt and a temporary cache; no desktop processes are touched."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from PySide6.QtCore import QUrl
from PySide6.QtQml import QJSEngine, QQmlApplicationEngine
from PySide6.QtQuick import QQuickItem
from PySide6.QtTest import QTest
from test_clipboard import APP

REPO = Path(__file__).resolve().parents[1]
UI = REPO / 'quickshell/ui'
OPT = REPO / 'quickshell/scripts/wallpaper/sea-wallpaper-optimize.py'
HAVE_FFMPEG = bool(shutil.which('ffmpeg') and shutil.which('ffprobe'))

spec = importlib.util.spec_from_file_location('sea_wall_opt', OPT)
opt = importlib.util.module_from_spec(spec); spec.loader.exec_module(opt)


def make_clip(path, size='320x180', rate=60, seconds=1, audio=False):
    cmd = ['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
           f'testsrc2=size={size}:rate={rate}:duration={seconds}']
    if audio:
        cmd += ['-f', 'lavfi', '-i', f'sine=duration={seconds}', '-c:a', 'aac']
    cmd += ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'ultrafast', str(path)]
    subprocess.run(cmd, check=True, timeout=60)


class Decide(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.js = QJSEngine()
        src = (UI / 'WallpaperState.js').read_text().replace('.pragma library', '')
        r = cls.js.evaluate(src)
        assert not r.isError(), r.toString()

    def decide(self, **s):
        obj = self.js.newObject()
        for k, v in s.items():
            obj.setProperty(k, v)
        return self.js.globalObject().property('decide').call([obj]).toString()

    def test_still_is_off(self):
        self.assertEqual(self.decide(motion=False, gameOn=True), 'off')

    def test_plays_by_default(self):
        self.assertEqual(self.decide(motion=True), 'play')

    def test_game_mode_and_battery_free_the_decoder(self):
        self.assertEqual(self.decide(motion=True, gameOn=True), 'freeze')
        self.assertEqual(self.decide(motion=True, onBattery=True, batteryStill=True), 'freeze')
        self.assertEqual(self.decide(motion=True, onBattery=True, batteryStill=False), 'play')

    def test_occluded_frees_the_decoder(self):
        self.assertEqual(self.decide(motion=True, occluded=True), 'freeze')
        self.assertEqual(self.decide(motion=True, occluded=False), 'play')

    def test_fullscreen_frees_unless_cover_still_is_off(self):
        self.assertEqual(self.decide(motion=True, coveredAll=True, coverStill=True), 'freeze')
        self.assertEqual(self.decide(motion=True, coveredAll=True, coverStill=False), 'pause')

    def test_is_motion(self):
        f = self.js.globalObject().property('isMotion')
        for p, want in [('/a/b.MP4', True), ('x.webm', True), ('x.gif', True),
                        ('x.png', False), ('', False)]:
            self.assertEqual(f.call([p]).toBool(), want, p)


@unittest.skipUnless(HAVE_FFMPEG, 'ffmpeg not installed')
class Player(unittest.TestCase):
    def test_first_frame_then_freeze_unloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / 'clip.mp4'
            make_clip(clip, seconds=2)
            engine = QQmlApplicationEngine(); errors = []
            engine.warnings.connect(lambda ws: errors.extend(str(w) for w in ws))
            code = '''import QtQuick
import QtQuick.Window
import "''' + UI.as_uri() + '''" as Sea
Window { id: win; width: 320; height: 180; visible: true
 property int readies: 0
 Sea.VideoWallpaperPlayer { objectName: "player"; anchors.fill: parent
  source: "''' + str(clip) + '''"; mode: "play"; onReady: win.readies++ }
}'''
            engine.loadData(code.encode(), QUrl('file:///tmp/sea-video-wallpaper-test.qml'))
            self.assertTrue(engine.rootObjects(), errors)
            w = engine.rootObjects()[0]; p = w.findChild(QQuickItem, 'player')
            try:
                deadline = time.time() + 10
                while w.property('readies') < 1 and time.time() < deadline:
                    QTest.qWait(50)
                self.assertEqual(w.property('readies'), 1, errors)
                QTest.qWait(400)
                self.assertTrue(p.property('frameShown'))

                p.setProperty('mode', 'freeze'); APP.processEvents()
                self.assertFalse(p.property('loaded'))

                p.setProperty('mode', 'play')
                deadline = time.time() + 10
                while w.property('readies') < 2 and time.time() < deadline:
                    QTest.qWait(50)
                self.assertEqual(w.property('readies'), 2)
                self.assertFalse([e for e in errors if 'sea-shell wallpaper' in e], errors)
            finally:
                w.close(); APP.processEvents()


class OptimizeRules(unittest.TestCase):
    def info(self, **kw):
        base = {'w': 1920, 'h': 1080, 'fps': 30.0, 'codec': 'h264', 'streams': 1}
        base.update(kw); return base

    def test_already_fitting_clip_plays_as_is(self):
        self.assertFalse(opt.needs_encode(self.info(), 1920, 1080, 30))
        self.assertFalse(opt.needs_encode(self.info(w=1280, h=720, fps=24), 1920, 1080, 30))
        self.assertFalse(opt.needs_encode(None, 1920, 1080, 30))

    def test_bigger_faster_other_codec_or_audio_is_encoded(self):
        self.assertTrue(opt.needs_encode(self.info(w=2560, h=1440), 1920, 1080, 30))
        self.assertTrue(opt.needs_encode(self.info(fps=60), 1920, 1080, 30))
        self.assertTrue(opt.needs_encode(self.info(codec='vp9'), 1920, 1080, 30))
        self.assertTrue(opt.needs_encode(self.info(streams=2), 1920, 1080, 30))

    def test_cache_key_follows_file_and_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / 'a.mp4'; f.write_bytes(b'x')
            a = opt.cache_path(str(f), 1920, 1080, 30)
            self.assertEqual(a, opt.cache_path(str(f), 1920, 1080, 30))
            self.assertNotEqual(a, opt.cache_path(str(f), 1920, 1080, 60))
            self.assertNotEqual(a, opt.cache_path(str(f), 2560, 1440, 30))
            f.write_bytes(b'xy')
            self.assertNotEqual(a, opt.cache_path(str(f), 1920, 1080, 30))


@unittest.skipUnless(HAVE_FFMPEG, 'ffmpeg not installed')
class OptimizeBuild(unittest.TestCase):
    def run_opt(self, *args, env):
        r = subprocess.run(['python3', str(OPT), *args], env=env, capture_output=True,
                           text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.split()

    def test_resolve_pending_build_then_cached(self):
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / 'big.mp4'
            make_clip(clip, size='640x360', rate=60, audio=True)
            env = dict(os.environ, XDG_CACHE_HOME=str(Path(tmp) / 'cache'))
            args = [str(clip), '--size', '320x180', '--fps', '30']
            self.assertEqual(self.run_opt(*args, env=env), [str(clip), 'pending'])
            out = self.run_opt(*args, '--build', env=env)
            self.assertEqual(len(out), 1); self.assertNotEqual(out[0], str(clip))
            info = opt.probe(out[0])
            self.assertEqual((info['w'], info['h'], info['codec'], info['streams']),
                             (320, 180, 'h264', 1))
            self.assertAlmostEqual(info['fps'], 30, delta=0.5)
            self.assertEqual(self.run_opt(*args, env=env), out)

    def test_small_clip_is_not_encoded(self):
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / 'small.mp4'
            make_clip(clip, size='320x180', rate=30)
            env = dict(os.environ, XDG_CACHE_HOME=str(Path(tmp) / 'cache'))
            self.assertEqual(self.run_opt(str(clip), '--size', '1920x1080', '--fps', '30', env=env),
                             [str(clip)])

    def test_eviction_keeps_newest_under_cap(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(opt, 'CACHE', tmp), \
                patch.object(opt, 'CACHE_CAP', 25):
            for i, name in enumerate(['old', 'mid', 'new']):
                f = Path(tmp) / f'{name}.mp4'; f.write_bytes(b'x' * 10)
                os.utime(f, (1000 + i, 1000 + i))
            opt.evict(str(Path(tmp) / 'new.mp4'))
            self.assertEqual(sorted(p.name for p in Path(tmp).glob('*.mp4')), ['mid.mp4', 'new.mp4'])


if __name__ == '__main__':
    unittest.main()
