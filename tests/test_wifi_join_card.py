import unittest
from pathlib import Path
from PySide6.QtCore import QUrl,QObject,Qt,QEvent
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickItem
from PySide6.QtGui import QKeyEvent
from PySide6.QtTest import QTest
from test_clipboard import APP

class WifiEditorTests(unittest.TestCase):
    def test_scan_rebuild_keeps_draft_focus_and_retry(self):
        engine=QQmlApplicationEngine();errors=[]
        engine.warnings.connect(lambda ws:errors.extend(str(w) for w in ws))
        uri=(Path(__file__).resolve().parents[1]/'quickshell/ui').as_uri()
        code='''import QtQuick
import QtQuick.Window
import "'''+uri+'''" as Sea
Window { width: 360; height: 400; visible: true; property int scan: 2
 Column { width: parent.width
 Sea.WifiJoinCard { id: card; objectName: "card"; width: parent.width; ssid: "Test network"
 onEdited: value => draft = value }
 Repeater { model: scan; delegate: Text { text: "network " + index } }
 }}'''
        engine.loadData(code.encode(),QUrl('file:///tmp/sea-wifi-editor-test.qml'))
        self.assertTrue(engine.rootObjects(),errors)
        w=engine.rootObjects()[0];c=w.findChild(QQuickItem,'card');pw=w.findChild(QQuickItem,'wifiPassword')
        try:
            w.requestActivate();APP.processEvents();pw.forceActiveFocus();QTest.qWait(30)
            for char in 'sample-draft-123':
                APP.sendEvent(w,QKeyEvent(QEvent.KeyPress,0,Qt.NoModifier,char))
                APP.sendEvent(w,QKeyEvent(QEvent.KeyRelease,0,Qt.NoModifier,char))
            text=pw.property('text');cursor=pw.property('cursorPosition')
            self.assertEqual(text,'sample-draft-123')
            for count in (5,0,8,2):
                w.setProperty('scan',count);APP.processEvents()
                self.assertEqual(pw.property('text'),text)
                self.assertEqual(pw.property('cursorPosition'),cursor)
                self.assertTrue(pw.hasActiveFocus())
            c.setProperty('busy',True);c.setProperty('message','Connecting…');APP.processEvents()
            c.setProperty('busy',False);c.setProperty('failed',True);c.setProperty('message','Could not connect')
            self.assertEqual(pw.property('text'),text)
            submitted=[];c.submitted.connect(submitted.append);pw.forceActiveFocus()
            QTest.keyClick(w,Qt.Key_Return)
            self.assertEqual(submitted,[text])
            self.assertFalse(errors,errors)
        finally:w.close();APP.processEvents()
