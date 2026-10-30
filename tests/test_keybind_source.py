import importlib.util,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('keybind_source',Path(__file__).resolve().parents[1]/'quickshell/scripts/keybinds/sea-keybinds.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class KeybindSourceTests(unittest.TestCase):
    def test_edit_and_delete_exact_saved_binding_preserve_others(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'keybinds.lua'
            p.write_text('local mod = "SUPER"\nhl.bind(mod .. " + C", hl.dsp.exec_cmd("code --one"), { description = "Code" })\nhl.bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("code --two"), { description = "Code" }) -- keep\n')
            first,second=m.records(p)
            self.assertEqual(first['command'],'code --one')
            m.mutate(p,second['id'],['SUPER','ALT'],'V','app "quoted" --path \\foo')
            records=m.records(p);self.assertEqual(records[0]['command'],'code --one')
            self.assertEqual(records[1]['command'],'app "quoted" --path \\foo')
            self.assertEqual(records[1]['mods'],['SUPER','ALT'])
            self.assertTrue(p.read_text().endswith('-- keep\n'))
            with self.assertRaises(ValueError):m.mutate(p,second['id'],delete=True)
            m.mutate(p,records[1]['id'],delete=True)
            self.assertEqual(len(m.records(p)),1)
            self.assertEqual(m.records(p)[0]['command'],'code --one')
    def test_nonexec_rebind_keeps_action(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'keybinds.lua';p.write_text('hl.bind("SUPER + Q", hl.dsp.window.close(), { description = "Close" })\n')
            r=m.records(p)[0];self.assertIsNone(r['command'])
            m.mutate(p,r['id'],['SUPER','SHIFT'],'Q')
            self.assertIn('hl.dsp.window.close()',p.read_text())
    def test_list_uses_source_command_instead_of_runtime_handle(self):
        from unittest.mock import patch
        import io,json
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'keybinds.lua';p.write_text('hl.bind("SUPER + C", hl.dsp.exec_cmd("code"), { description = "Code" })\n')
            runtime=[dict(key='C',modmask=64,description='Code',dispatcher='HL.Dispatcher(exec_cmd)',arg='295')]
            output=io.StringIO()
            with patch.object(m,'config_path',return_value=p),patch.object(m.subprocess,'check_output',return_value=json.dumps(runtime).encode()),patch('sys.stdout',output):m.main(['--list'])
            result=json.loads(output.getvalue())[0]
            self.assertEqual(result['sourceCommand'],'code')
            self.assertEqual(result['arg'],'295')
            self.assertTrue(result['sourceId'])
