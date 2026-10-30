import unittest
from pathlib import Path
from PySide6.QtQml import QJSEngine
from test_clipboard import APP

SOURCE = (Path(__file__).resolve().parents[1] / 'quickshell/ui/settings.qml').read_text()

class SettingsNavigationTests(unittest.TestCase):
    def test_search_opens_each_appearance_subtab_before_scrolling(self):
        function = SOURCE.split('    function jumpTo(entry) {', 1)[1].split('\n    function doJump()', 1)[0]
        engine = QJSEngine()
        engine.evaluate('var root = {tab:8, apSubTab:5, showTab:function(t){this.tab=t}}; '
                        'var jumpTimer = {count:0,restart:function(){this.count++}}; '
                        'function jumpTo(entry) {' + function)
        for tab in range(6):
            result = engine.evaluate('var item={parent:{appearanceSubTab:'+str(tab)+',parent:null}}; '
                                     'jumpTo({tab:4,item:item}); '
                                     'root.tab===4 && root.apSubTab==='+str(tab)+' && root.pendingJump===item')
            self.assertFalse(result.isError(), result.toString())
            self.assertTrue(result.toBool())
        self.assertEqual(engine.evaluate('jumpTimer.count').toInt(), 6)

    def test_section_shortcuts_exclude_hidden_appearance_tabs(self):
        body = SOURCE.split('readonly property var pageSections: {', 1)[1].split('\n    // Switching page', 1)[0].rsplit('}', 1)[0]
        engine = QJSEngine()
        engine.evaluate('var pane={}; var root={apSubTab:2,tab:4,sectionTick:1,sectionsReady:true,sectionIndex:[]}; '
                        'function sections(){'+body+'}')
        result = engine.evaluate('root.sectionIndex=[0,1,2,3,4,5].map(function(t){return {tab:4,title:String(t),item:{parent:{appearanceSubTab:t,parent:null}}}}); sections().map(function(e){return e.title}).join(",")')
        self.assertFalse(result.isError(), result.toString())
        self.assertEqual(result.toString(), '2')

    def test_open_tab_validates_ipc_input(self):
        body = SOURCE.split('    function openTab(t) {', 1)[1].split('\n    function closePanel()', 1)[0]
        engine = QJSEngine()
        engine.evaluate('var root={tab:8,tabMeta:{0:{},4:{},8:{},23:{}},showTab:function(t){this.tab=t}}; function openTab(t){'+body)
        for value, expected in [('4',4), ('23',23), ('-1',8), ('99',8), ('undefined',8), ('"4"',4)]:
            result = engine.evaluate('openTab('+value+'); root.tab')
            self.assertFalse(result.isError(), result.toString())
            self.assertEqual(result.toInt(), expected)
