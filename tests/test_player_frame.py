import unittest
from pathlib import Path
from PySide6.QtCore import QUrl,QPointF,Qt
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickItem
from PySide6.QtTest import QTest
from test_clipboard import APP

class PlayerFrameTests(unittest.TestCase):
    def test_tabs_swap_only_working_pane_and_keep_track(self):
        e=QQmlApplicationEngine();errors=[];e.warnings.connect(lambda ws:errors.extend(str(w) for w in ws))
        uri=(Path(__file__).resolve().parents[1]/'quickshell/ui').as_uri()
        e.loadData(('''import QtQuick
import QtQuick.Window
import "'''+uri+'''" as Sea
Window { width:620;height:300;visible:true;color:"#f5f3f8"
 QtObject { id: mock; property string trackTitle:"A track title that is quite long";property string trackArtist:"An artist";property string trackArtUrl:"";property string identity:"Test player"; property bool isPlaying:true }
 Sea.MediaPlayerFrame { id: frame;objectName:"frame";anchors.fill:parent;player:mock;viz:[20,80,40,100];onSelected: tab=>selectedTab=tab }
}''').encode(),QUrl('file:///tmp/player-frame-test.qml'))
        self.assertTrue(e.rootObjects(),errors);w=e.rootObjects()[0];frame=w.findChild(QQuickItem,'frame')
        def find(item,name):
            if item.objectName()==name:return item
            for child in item.childItems():
                result=find(child,name)
                if result:return result
        try:
            APP.processEvents();QTest.qWait(30)
            title=find(frame,'trackTitle');title_position=title.mapToScene(QPointF())
            for index,host in enumerate(['controlsHost','detailsHost','lyricsHost']):
                tab=find(frame,'player-tab-'+str(index));QTest.mouseClick(w,Qt.LeftButton,Qt.NoModifier,tab.mapToScene(QPointF(tab.width()/2,tab.height()/2)).toPoint());APP.processEvents()
                self.assertEqual(frame.property('selectedTab'),index)
                for name in ['controlsHost','detailsHost','lyricsHost']:self.assertEqual(find(frame,name).isVisible(),name==host)
                self.assertEqual(title.property('text'),'A track title that is quite long')
                self.assertEqual(title.mapToScene(QPointF()),title_position)
                self.assertLessEqual(find(frame,host).x()+find(frame,host).width(),frame.width())
            spectrum=find(frame,'cover-spectrum-1')
            self.assertIsNotNone(spectrum)
            QTest.qWait(100);self.assertGreater(spectrum.height(),2)
            frame.setProperty('active',False);QTest.qWait(120);self.assertEqual(spectrum.height(),2)
            w.setWidth(748);frame.setProperty('active',True);frame.setProperty('mascotSource',QUrl.fromLocalFile(str(Path(__file__).resolve().parent/'fixtures'/'sticker.gif')))
            APP.processEvents();QTest.qWait(100)
            mascot=find(frame,'mediaMascot')
            self.assertEqual(mascot.property('frameCount'),4)
            for tab in range(3):
                frame.setProperty('selectedTab',tab);APP.processEvents();self.assertTrue(mascot.isVisible())
            frame.setProperty('reducedMotion',True);APP.processEvents();self.assertFalse(mascot.property('playing'))
            frame.setProperty('active',False);APP.processEvents();self.assertFalse(mascot.property('playing'))
            self.assertFalse(errors,errors)
        finally:w.close();APP.processEvents()
