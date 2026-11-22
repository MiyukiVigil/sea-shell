import unittest
from pathlib import Path
from PySide6.QtQml import QJSEngine
from test_clipboard import APP

SOURCE = (Path(__file__).resolve().parents[1] / 'quickshell/ui/Launcher.qml').read_text()


class LauncherSettingsTests(unittest.TestCase):
    def test_plain_language_destinations(self):
        registry = SOURCE.split('readonly property var settingDestinations: ', 1)[1].split('\n    ]\n', 1)[0] + ']'
        body = SOURCE.split('    function settingsMatches(query) {', 1)[1].split('\n    // ---------- build', 1)[0]
        engine = QJSEngine()
        result = engine.evaluate('var root = {settingDestinations:' + registry + '}; '
                                 'function esc(s){return s}; function settingsMatches(query){' + body)
        self.assertFalse(result.isError(), result.toString())
        for query, tab in [('connect Wi-Fi', 2), ('make text bigger', 4),
                           ('change wallpaper', 21), ('pair headphones', 9)]:
            result = engine.evaluate('settingsMatches(' + repr(query) + ')[0].tab')
            self.assertFalse(result.isError(), result.toString())
            self.assertEqual(result.toInt(), tab)
        for query in ['', '   ', 'unrelated application']:
            self.assertEqual(engine.evaluate('settingsMatches(' + repr(query) + ').length').toInt(), 0)
