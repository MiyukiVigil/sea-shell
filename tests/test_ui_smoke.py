"""Real QML keyboard smoke test using the offscreen Qt platform."""
import tempfile,time,unittest
from pathlib import Path
from PySide6.QtCore import Qt,QUrl
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtTest import QTest
from test_clipboard import APP,fm

class UiSmoke(unittest.TestCase):
    def wait(self,predicate):
        end=time.monotonic()+5
        while time.monotonic()<end:
            APP.processEvents()
            if predicate():return
            QTest.qWait(5)
        self.fail('UI action timed out')
    def test_keyboard_cut_paste_and_new_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);dest=folder/'destination';dest.mkdir();file=folder/'move me.txt';file.write_text('keep data')
            first=fm.FileManagerBackend(str(folder),secondary=True)
            second=fm.FileManagerBackend(str(folder),secondary=True)
            engine=QQmlApplicationEngine();warnings=[];engine.warnings.connect(lambda items:warnings.extend(str(i) for i in items))
            engine.addImageProvider('fileicon',fm.ThemeIconProvider())
            for name,value in {'be1':first,'be2':second,'backend':first,'undo':fm.UNDO(),'tagstore':fm.TAGS(),'ops':fm.OPS(),'stars':fm.STARS(),'prefs':fm.PREFS(),'appmenu':None}.items():
                engine.rootContext().setContextProperty(name,value)
            engine.load(QUrl.fromLocalFile(str(Path(__file__).resolve().parents[1]/'quickshell/ui/FileManager.qml')))
            self.assertTrue(engine.rootObjects(),warnings)
            window=engine.rootObjects()[0]
            try:
                self.wait(lambda:first.model.count==2 and not first.listingBusy)
                window.setProperty('selectedPaths',[str(file)]);window.setProperty('selectedPath',str(file))
                QTest.keyClick(window,Qt.Key_X,Qt.ControlModifier)
                mime=APP.clipboard().mimeData()
                self.assertTrue(mime.hasFormat('x-special/gnome-copied-files'))
                first.cd(str(dest));self.wait(lambda:not first.listingBusy)
                QTest.keyClick(window,Qt.Key_V,Qt.ControlModifier)
                self.wait(lambda:(dest/'move me.txt').exists() and not file.exists())
                self.assertEqual((dest/'move me.txt').read_text(),'keep data')
                QTest.keyClick(window,Qt.Key_N,Qt.ControlModifier|Qt.ShiftModifier)
                QTest.qWait(30)
                for char in 'created from keyboard':
                    QTest.keyClick(window,Qt.Key(ord(char.upper())))
                QTest.keyClick(window,Qt.Key_Return)
                self.wait(lambda:(dest/'created from keyboard').is_dir())
                self.assertFalse(warnings,warnings)
            finally:
                window.close();first._scan_cancel.set();second._scan_cancel.set()
                first._scan_pool.waitForDone();second._scan_pool.waitForDone();fm.OPS()._pool.waitForDone();APP.clipboard().clear();APP.processEvents()
if __name__=='__main__':unittest.main()
