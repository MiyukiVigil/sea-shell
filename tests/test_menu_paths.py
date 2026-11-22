import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('menu_paths',Path(__file__).parents[1]/'quickshell/scripts/menu/sea-appmenu.py')
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)

class WrongWindowTests(unittest.TestCase):
    """_NET_ACTIVE_WINDOW keeps naming the last X11 window after focus moves to a Wayland app, so
    the id it gives can belong to any other program. Its menu must never be served for this one."""
    VSCODE=(':1.388','/com/canonical/menu/2600004')
    def lookup(self,owned):
        calls=[]
        def bus(name,path,iface,method,params,sig,timeout=2000):
            calls.append(method)
            if method=='GetMenuForWindow': return self.VSCODE
            if method=='GetMenus': return ([(0x2600004,)+self.VSCODE],)
            if method=='ListNames': return ([],)
            return None
        with patch.object(menu,'_REG_OWNED',owned),patch.object(menu,'_REG',{0x2600004:self.VSCODE}),\
             patch.object(menu,'dbus_call',bus),patch.object(menu,'owner_pid',lambda n:315942),\
             patch.object(menu,'name_gone',lambda n:False),patch.object(menu,'reg_save',lambda:None):
            return menu.dbm_for_pid(312353,0x2600004),menu.dbm_for_pid(315942,0x2600004)
    def test_the_daemon_will_not_serve_another_programs_menu(self):
        other,own=self.lookup(True)
        self.assertIsNone(other);self.assertEqual(own,self.VSCODE)
    def test_nor_will_the_short_lived_commands(self):
        other,own=self.lookup(False)
        self.assertIsNone(other);self.assertEqual(own,self.VSCODE)
    def test_a_wayland_window_never_consults_x11(self):
        source=Path(menu.__file__).read_text()
        for line in source.splitlines():
            if 'dbm_for_pid(' in line and 'x11_active_window()' in line:
                self.assertIn('is_xwayland',line)

class MenuPathTests(unittest.TestCase):
    def test_recent_directory_label_is_one_item(self):
        leaf=(42,{'label':'~/Documents/Project'},[])
        recent=(3,{'label':'Open Recent'},[leaf])
        file=(2,{'label':'_File'},[recent])
        with patch.object(menu,'dbus_call',return_value=(1,(0,{},[file]))):
            self.assertEqual(menu.dbm_find(('bus','/menu'),'File/Open Recent/~/Documents/Project'),42)
