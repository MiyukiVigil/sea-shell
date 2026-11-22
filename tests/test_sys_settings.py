"""Tests for the redesigned macOS-style Settings architecture and sea-sys-settings.py backend."""
import base64
import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "quickshell/ui"
SCRIPT = ROOT / "quickshell/scripts/system/sea-sys-settings.py"

spec = importlib.util.spec_from_file_location("sea_sys_settings", SCRIPT)
sys_settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sys_settings)


class SysSettingsBackendTests(unittest.TestCase):
    def test_render_compositor_lua_contains_all_sections(self):
        cfg = dict(sys_settings.COMPOSITOR_DEFAULTS)
        cfg.update({
            "gaps_in": 8,
            "gaps_out": 16,
            "border_size": 3,
            "rounding": 12,
            "blur_enabled": False,
            "kb_layout": "gb",
            "kb_options": "caps:escape",
            "repeat_rate": 40,
            "repeat_delay": 300,
            "cursor_size": 32,
            "zoom_factor": 1.5,
        })
        lua = sys_settings.render_compositor_lua(cfg)
        self.assertIn("gaps_in = 8", lua)
        self.assertIn("gaps_out = 16", lua)
        self.assertIn("border_size = 3", lua)
        self.assertIn("rounding = 12", lua)
        self.assertIn("enabled = false", lua)
        self.assertIn('kb_layout = "gb"', lua)
        self.assertIn('kb_options = "caps:escape"', lua)
        self.assertIn("repeat_rate = 40", lua)
        self.assertIn("repeat_delay = 300", lua)
        self.assertIn("zoom_factor = 1.50", lua)
        self.assertIn("hl.env('XCURSOR_SIZE', '32')", lua)

    def test_compositor_set_clamps_and_writes_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            orig_json = sys_settings.COMPOSITOR_JSON
            orig_lua = sys_settings.COMPOSITOR_LUA
            orig_run = sys_settings.run
            try:
                sys_settings.COMPOSITOR_JSON = tmp_path / "compositor.json"
                sys_settings.COMPOSITOR_LUA = tmp_path / "compositor.lua"
                sys_settings.run = lambda *a, **kw: (0, "", "")
                payload = base64.b64encode(json.dumps({
                    "gaps_in": 999,
                    "rounding": -5,
                    "repeat_rate": 5,
                    "cursor_size": 128,
                    "zoom_factor": 9.0,
                    "kb_layout": "de",
                }).encode()).decode()
                sys_settings.compositor_set(payload)
                saved = json.loads(sys_settings.COMPOSITOR_JSON.read_text())
                self.assertEqual(saved["gaps_in"], 40)
                self.assertEqual(saved["rounding"], 0)
                self.assertEqual(saved["repeat_rate"], 10)
                self.assertEqual(saved["cursor_size"], 64)
                self.assertEqual(saved["zoom_factor"], 3.0)
                self.assertEqual(saved["kb_layout"], "de")
                self.assertTrue(sys_settings.COMPOSITOR_LUA.exists())
            finally:
                sys_settings.COMPOSITOR_JSON = orig_json
                sys_settings.COMPOSITOR_LUA = orig_lua
                sys_settings.run = orig_run

    def test_parse_desktop_file_and_toggle(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            orig_auto = sys_settings.AUTOSTART_DIR
            try:
                sys_settings.AUTOSTART_DIR = tmp_path
                sample = tmp_path / "demo.desktop"
                sample.write_text("[Desktop Entry]\nName=Demo App\nExec=demo\nHidden=false\n")
                parsed = sys_settings.parse_desktop_file(sample)
                self.assertIsNotNone(parsed)
                self.assertEqual(parsed["name"], "Demo App")
                self.assertTrue(parsed["enabled"])

                sys_settings.startup_toggle_app("demo.desktop", "false")
                parsed2 = sys_settings.parse_desktop_file(sample)
                self.assertFalse(parsed2["enabled"])

                sys_settings.startup_toggle_app("demo.desktop", "true")
                parsed3 = sys_settings.parse_desktop_file(sample)
                self.assertTrue(parsed3["enabled"])
            finally:
                sys_settings.AUTOSTART_DIR = orig_auto


class SettingsArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.src = (UI / "settings.qml").read_text()
        meta_block = self.src.split("readonly property var tabMeta: ({", 1)[1].split("})", 1)[0]
        self.meta_tabs = {int(m) for m in re.findall(r"^\s*(\d+):\s*\{", meta_block, re.M)}
        self.parents = {int(k): int(v) for k, v in re.findall(r"^\s*(\d+):[^\n]*parent:\s*(\d+)", meta_block, re.M)}
        self.sidebar_tabs = {int(m) for m in re.findall(r"TabBtn\s*\{[^\n]*idx:\s*(\d+)", self.src)}

    def test_every_page_loader_matches_tab_meta_and_file(self):
        loaders = re.findall(r'PageLoader\s*\{\s*page:\s*(\d+);\s*source:\s*Qt\.resolvedUrl\("([^"]+)"\)', self.src)
        self.assertGreaterEqual(len(loaders), 35)
        for page_str, filename in loaders:
            page = int(page_str)
            self.assertIn(page, self.meta_tabs, f"PageLoader page {page} missing from tabMeta")
            path = UI / filename
            self.assertTrue(path.exists(), f"Missing page file {filename}")
            tab_match = re.search(r"property int tabIdx:\s*(\d+)", path.read_text())
            self.assertIsNotNone(tab_match, f"{filename} missing tabIdx")
            self.assertEqual(int(tab_match.group(1)), page, f"{filename} tabIdx mismatch")

    def test_every_drilldown_parent_exists_in_sidebar(self):
        for child, parent in self.parents.items():
            self.assertIn(parent, self.sidebar_tabs, f"Parent {parent} of child {child} not in sidebar")

    def test_every_mac_nav_row_destination_is_valid(self):
        for path in sorted(UI.glob("SettingsPage*.qml")):
            for dest in re.findall(r"\bdestination:\s*(\d+)", path.read_text()):
                self.assertIn(int(dest), self.meta_tabs, f"Invalid destination {dest} in {path.name}")


if __name__ == "__main__":
    unittest.main()
