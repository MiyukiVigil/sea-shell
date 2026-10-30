import tempfile,time,unittest
from pathlib import Path
from test_clipboard import APP,fm

class UndoAsyncTests(unittest.TestCase):
    def test_move_undo_is_queued_and_completes(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);original=root/'original';moved=root/'moved';moved.write_text('data')
            journal=fm.UndoJournal();journal.record('move','Move',[{'src':str(original),'dst':str(moved)}])
            results=[];journal.finished.connect(results.append)
            message=journal.undo()
            self.assertIn('Undoing',message)
            self.assertTrue(journal.busy)
            self.assertFalse(journal.canUndo)
            self.assertEqual(journal.undo(),'Undo is already running')
            end=time.monotonic()+4
            while not results and time.monotonic()<end:
                APP.processEvents();time.sleep(.001)
            self.assertTrue(results)
            self.assertFalse(journal.busy)
            self.assertEqual(original.read_text(),'data')
            self.assertFalse(moved.exists())
            fm.OPS()._pool.waitForDone()
if __name__=='__main__':unittest.main()
