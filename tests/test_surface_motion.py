import unittest
from pathlib import Path
from PySide6.QtCore import QUrl,QObject
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtTest import QTest
from test_clipboard import APP

class SurfaceMotionTests(unittest.TestCase):
    def test_reversal_close_and_reduced_motion(self):
        engine=QQmlApplicationEngine();errors=[]
        engine.warnings.connect(lambda ws:errors.extend(str(w) for w in ws))
        engine.load(QUrl.fromLocalFile(str(Path(__file__).resolve().parents[1]/'quickshell/ui/SurfaceMotion.qml')))
        self.assertTrue(engine.rootObjects(),errors)
        motion=engine.rootObjects()[0]
        self.assertEqual(motion.property('progress'),0)
        motion.setProperty('opened',True);QTest.qWait(100)
        self.assertGreater(motion.property('progress'),0)
        self.assertLess(motion.property('progress'),1)
        motion.setProperty('opened',False);QTest.qWait(30)
        self.assertTrue(motion.property('presenting'))
        motion.setProperty('opened',True);QTest.qWait(300)
        self.assertEqual(motion.property('progress'),1)
        motion.setProperty('opened',False);QTest.qWait(190)
        self.assertFalse(motion.property('presenting'))
        motion.setProperty('reduced',True);motion.setProperty('opened',True);APP.processEvents()
        self.assertEqual(motion.property('progress'),1)
        motion.setProperty('opened',False);APP.processEvents()
        self.assertEqual(motion.property('progress'),0)
        self.assertFalse(errors,errors)
