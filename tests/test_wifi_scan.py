import json,unittest
from pathlib import Path
from PySide6.QtQml import QJSEngine
from test_clipboard import APP

SOURCE=(Path(__file__).resolve().parents[1]/'quickshell/ui/shell.qml').read_text()
PARSER=SOURCE.split('stdout: StdioCollector { id: wifiOut; onStreamFinished: {',1)[1].split('\n        } }',1)[0]
class WifiScanTests(unittest.TestCase):
    def parse(self,lines):
        engine=QJSEngine()
        engine.evaluate('var root={ssid:"current",wifiSeen:0,wifiList:[]}; var wifiOut={text:'+json.dumps('\n'.join(lines))+'};')
        result=engine.evaluate(PARSER)
        self.assertFalse(result.isError(),result.toString())
        return json.loads(engine.evaluate('JSON.stringify({seen:root.wifiSeen,list:root.wifiList})').toString())
    def test_connected_network_remains_visible_among_stronger_networks(self):
        data=self.parse(['no:99:WPA2:network'+str(i) for i in range(12)]+['yes:8:WPA3:current'])
        self.assertEqual(data['seen'],13)
        self.assertEqual(len(data['list']),8)
        self.assertEqual(data['list'][0]['ssid'],'current')
        self.assertTrue(data['list'][0]['active'])
    def test_mesh_networks_keep_strongest_signal_without_duplicates(self):
        data=self.parse(['no:12:WPA2:mesh','no:88:WPA2:mesh','yes:42:WPA3:current'])
        self.assertEqual(data['seen'],2)
        self.assertEqual(data['list'][1]['signal'],88)
