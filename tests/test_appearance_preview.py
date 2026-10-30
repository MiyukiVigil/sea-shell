import json,subprocess,unittest
from pathlib import Path
from PySide6.QtCore import Qt,QUrl,QMetaObject,QPointF
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickItem
from PySide6.QtTest import QTest
from test_clipboard import APP
ROOT=Path(__file__).resolve().parents[1]
class PreviewTests(unittest.TestCase):
    def test_drafts_are_isolated_until_apply(self):
        engine=QQmlApplicationEngine();errors=[];engine.warnings.connect(lambda ws:errors.extend(str(w) for w in ws))
        catalog=json.loads(subprocess.check_output(['python3',str(ROOT/'quickshell/scripts/theme/sea-icons.py'),'--catalog']))
        engine.rootContext().setContextProperty('catalogData',catalog)
        code='''import QtQuick
import QtQuick.Window
import "'''+(ROOT/'quickshell/ui').as_uri()+'''" as Sea
Window { visible: true; width: 760; height: 580
 Sea.AppearancePreview { objectName: "preview"; anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
 baseLight: true; baseFont: "sans-serif"; baseIconTheme: "breeze"; iconCatalog: catalogData; fonts: ["sans-serif","monospace"] }
}'''
        engine.loadData(code.encode(),QUrl('file:///tmp/sea-preview-test.qml'))
        self.assertTrue(engine.rootObjects(),errors)
        window=engine.rootObjects()[0];preview=window.findChild(QQuickItem,'preview');applied=[]
        preview.applied.connect(lambda *args:applied.append(args))
        try:
            QMetaObject.invokeMethod(preview,'begin')
            preview.setProperty('draftLight',False);preview.setProperty('draftFont','monospace')
            self.assertTrue(preview.property('baseLight'));self.assertFalse(applied)
            self.assertEqual(preview.property('baseFont'),'sans-serif')
            APP.processEvents();QTest.qWait(30)
            button=window.findChild(QQuickItem,'appearanceApply')
            point=button.mapToScene(QPointF(button.width()/2,button.height()/2)).toPoint()
            QTest.mouseClick(window,Qt.LeftButton,Qt.NoModifier,point)
            self.assertEqual(len(applied),1)
            self.assertFalse(applied[0][0]);self.assertEqual(applied[0][2],'monospace')
            self.assertFalse(preview.property('editing'))
            self.assertFalse(errors,errors)
            QTest.qWait(150);window.grabWindow().save('/tmp/sea-appearance-preview.png')
        finally:window.close();APP.processEvents()
if __name__=='__main__':unittest.main()
