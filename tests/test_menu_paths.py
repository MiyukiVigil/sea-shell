import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('menu_paths',Path(__file__).parents[1]/'quickshell/scripts/menu/sea-appmenu.py')
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)

class MenuPathTests(unittest.TestCase):
    def test_recent_directory_label_is_one_item(self):
        leaf=(42,{'label':'~/Documents/Project'},[])
        recent=(3,{'label':'Open Recent'},[leaf])
        file=(2,{'label':'_File'},[recent])
        with patch.object(menu,'dbus_call',return_value=(1,(0,{},[file]))):
            self.assertEqual(menu.dbm_find(('bus','/menu'),'File/Open Recent/~/Documents/Project'),42)
