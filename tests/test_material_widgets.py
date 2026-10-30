import unittest
from pathlib import Path
from PySide6.QtCore import QUrl,QPointF,Qt,QMetaObject,Q_ARG,QObject
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickItem
from PySide6.QtTest import QTest
from test_clipboard import APP

class MaterialWidgetsTests(unittest.TestCase):
    def test_cards_render_and_media_respects_capabilities(self):
        e=QQmlApplicationEngine();errors=[];e.warnings.connect(lambda ws:errors.extend(str(w) for w in ws))
        uri=(Path(__file__).resolve().parents[1]/'quickshell/ui').as_uri()
        code='''import QtQuick
import QtQuick.Window
import "'''+uri+'''" as Sea
Window { width: 760; height: 680; visible: true; color: "#edeaf3"
 QtObject { id: mock; objectName: "player"; property string trackTitle: "A track with a very long title that should wrap"
 property string trackArtist: "Sea artist"; property string trackAlbum: "Sea album"; property string trackArtUrl: ""
 property string identity: "Test player"; property real position: 20; property real length: 200
 property bool isPlaying: false; property bool canTogglePlaying: true; property bool canGoNext: false; property bool canGoPrevious: true; property bool canSeek: true
 property int toggles: 0; property int nextCalls: 0
 function togglePlaying(){toggles++;isPlaying=!isPlaying} function next(){nextCalls++} function previous(){} }
 Sea.MaterialWidget { x:16;y:16;width:300;height:300;kind:"clock";now:new Date(2026,9,30,10,25) }
 Sea.MaterialWidget { x:334;y:16;width:410;height:150;kind:"weather";readings:({wxTemp:"26°C",wxCond:"Light rain shower"}) }
 Sea.MaterialWidget { x:334;y:184;width:410;height:132;kind:"system";readings:({cpu:25,memPct:62,gpu:12}) }
 Sea.MaterialWidget { objectName:"media"; x:16;y:334;width:728;height:320;kind:"media";player:mock;viz:[15,35,60,90,70,50,30,10] }
}'''
        e.loadData(code.encode(),QUrl('file:///tmp/material-test.qml'));self.assertTrue(e.rootObjects(),errors)
        w=e.rootObjects()[0]
        try:
            APP.processEvents();QTest.qWait(100)
            player=w.findChild(QObject,'player')
            media=w.findChild(QQuickItem,'media')
            def find(item,name):
                if item.objectName()==name:return item
                for child in item.childItems():
                    found=find(child,name)
                    if found:return found
            play=find(media,'media-play')
            self.assertIsNotNone(play,errors)
            point=play.mapToScene(QPointF(play.width()/2,play.height()/2)).toPoint()
            QTest.mouseClick(w,Qt.LeftButton,Qt.NoModifier,point)
            self.assertEqual(player.property('toggles'),1)
            QMetaObject.invokeMethod(media,'transport',Q_ARG('QVariant','next'))
            self.assertEqual(player.property('nextCalls'),0)
            QMetaObject.invokeMethod(media,'seek',Q_ARG('QVariant',0.5))
            self.assertEqual(player.property('position'),100)
            player.setProperty('canSeek',False)
            QMetaObject.invokeMethod(media,'seek',Q_ARG('QVariant',0.9))
            self.assertEqual(player.property('position'),100)
            for width,height in [(320,244),(350,270),(728,294),(320,200)]:
                media.setWidth(width);media.setHeight(height);APP.processEvents();QTest.qWait(20)
                button=find(media,'media-play')
                bottom=button.mapToItem(media,QPointF(0,button.height())).y()
                self.assertLessEqual(bottom,media.height(),(width,height,bottom))
            media.setProperty('mediaPart','controls');media.setWidth(330);media.setHeight(108)
            APP.processEvents();QTest.qWait(20)
            button=find(media,'media-play')
            self.assertTrue(button.isVisible())
            self.assertLessEqual(button.mapToItem(media,QPointF(0,button.height())).y(),media.height())
            media.setProperty('mediaPart','art');APP.processEvents();self.assertFalse(button.isVisible())
            media.setProperty('mediaPart','all')
            media.setWidth(728);media.setHeight(320);APP.processEvents()
            self.assertFalse(errors,errors)
            QTest.qWait(160);w.grabWindow().save('/tmp/sea-material-widgets-preview.png')
        finally:w.close();APP.processEvents()
