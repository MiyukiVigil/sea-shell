import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_alt_release_binds_survive_tab():
    # Hyprland drops a release bind once another key went down since, unless it is transparent.
    # Without this, releasing Alt never switches and the switcher just stays open.
    lua = (ROOT / "hypr" / "keybinds.lua").read_text()
    assert '"ALT + code:64"' in lua, "left Alt must go by keycode: its name does not match on release"
    assert '"ALT + Alt_L", ' not in lua
    commit = re.search(r'for _, key in ipairs\(\{[^}]*\}\) do\s+hl\.bind\(key, hl\.dsp\.global\("sea-shell:switcher-commit"\), \{([^}]*)\}', lua)
    assert commit, "commit binds not found"
    assert "release = true" in commit.group(1) and "transparent = true" in commit.group(1)


def test_every_switcher_shortcut_has_a_listener():
    lua = (ROOT / "hypr" / "keybinds.lua").read_text()
    qml = (ROOT / "quickshell" / "ui" / "WindowSwitcher.qml").read_text()
    names = set(re.findall(r'sea-shell:(switcher-\w+)', lua))
    assert names == {"switcher-next", "switcher-prev", "switcher-app", "switcher-cancel", "switcher-commit"}
    for name in names:
        assert f'name: "{name}"' in qml


class WindowSwitcherTests(unittest.TestCase):
    test_alt_release_binds_survive_tab = staticmethod(test_alt_release_binds_survive_tab)
    test_every_switcher_shortcut_has_a_listener = staticmethod(test_every_switcher_shortcut_has_a_listener)
