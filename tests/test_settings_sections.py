"""settings search reads a generated list of every page's sections, because pages are only built
when opened. Run this file with --write after adding or renaming a section."""
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

UI = Path(__file__).resolve().parents[1] / 'quickshell/ui'
INDEX = UI / 'SettingsIndex.qml'


def sections():
    rows = []
    for path in sorted(UI.glob('SettingsPage*.qml')):
        text = path.read_text()
        tab = re.search(r'property int tabIdx: (\d+)', text).group(1)
        for line in re.findall(r'\bSection\s*\{[^\n]*', text):
            title = re.search(r'title:\s*"([^"]+)"', line)
            icon = re.search(r'icon:\s*"([^"]+)"', line)
            rows.append((int(tab), title.group(1), icon.group(1) if icon else ''))
    return sorted(rows)


def render():
    lines = ['// Generated: python3 tests/test_settings_sections.py --write', 'import QtQuick', '', 'QtObject {',
             '    readonly property var sections: [']
    lines += ['        { tab: %d, title: "%s", icon: "%s" },' % row for row in sections()]
    lines += ['    ]', '}', '']
    return '\n'.join(lines)


class SettingsSectionsTests(unittest.TestCase):
    def test_index_lists_every_section(self):
        self.assertEqual(INDEX.read_text(), render(), 'run: python3 tests/test_settings_sections.py --write')

    def test_every_section_has_a_literal_title(self):
        for path in UI.glob('SettingsPage*.qml'):
            for line in re.findall(r'\bSection\s*\{[^\n]*', path.read_text()):
                self.assertIn('title: "', line, path.name)

    def test_page_ids_are_not_reached_from_the_root_file(self):
        root = (UI / 'settings.qml').read_text()
        for path in UI.glob('SettingsPage*.qml'):
            for name in re.findall(r'\bid:\s*(\w+)(?![\w.])', path.read_text()):
                self.assertIsNone(re.search(r'\b%s\.\w+' % name, root), '%s from %s' % (name, path.name))


class QmlSyntaxTests(unittest.TestCase):
    """A page with a syntax error only fails when it's opened, and then just shows up blank."""

    def test_every_file_parses(self):
        lint = shutil.which('qmllint') or '/usr/lib/qt6/bin/qmllint'
        if not Path(lint).exists():
            self.skipTest('qmllint is not installed')
        for path in sorted(UI.glob('*.qml')):
            out = subprocess.run([lint, '--bare', str(path)], capture_output=True, text=True)
            bad = [line for line in (out.stdout + out.stderr).splitlines() if line.endswith('[syntax]')]
            self.assertEqual(bad, [], path.name)


if __name__ == '__main__':
    if '--write' in sys.argv:
        INDEX.write_text(render())
    else:
        unittest.main()
