import os,tempfile,threading,time,unittest
from pathlib import Path
from unittest.mock import patch
from test_file_operations import fm

class Done:
    def __init__(self):self.calls=[]
    def emit(self,*args):self.calls.append(args)

class ScanCancellation(unittest.TestCase):
    def test_running_native_scan_is_killed_and_never_published(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);pidfile=root/'pid';helper=root/'helper'
            helper.write_text('#!/usr/bin/python3\nimport os,time\nfrom pathlib import Path\nPath('+repr(str(pidfile))+').write_text(str(os.getpid()))\ntime.sleep(20)\n')
            helper.chmod(0o755);cancel=threading.Event();done=Done()
            worker=fm.DirectoryScanWorker(str(root),'',False,cancel,1,done)
            with patch.object(fm,'native_core',return_value=helper):
                thread=threading.Thread(target=worker.run);thread.start()
                end=time.monotonic()+2
                while not pidfile.exists() and time.monotonic()<end:time.sleep(.005)
                self.assertTrue(pidfile.exists())
                pid=int(pidfile.read_text());cancel.set();thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertFalse(Path('/proc',str(pid)).exists())
            self.assertEqual(done.calls,[])
if __name__=='__main__':unittest.main()
