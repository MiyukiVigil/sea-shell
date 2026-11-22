import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('sea_attention', Path(__file__).resolve().parents[1] / 'quickshell/scripts/system/sea-attention.py')
attention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(attention)


class AttentionTests(unittest.TestCase):
    def test_optional_tools_are_one_row_and_never_urgent(self):
        rows = attention.doctor_rows(['warn|optional|grim|x', 'warn|optional|fd|x', 'ok|fonts|a|b', 'warn|bluetooth|x|y'])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['level'], 'info')
        self.assertIn('fd, grim', rows[0]['detail'])

    def test_critical_doctor_row_is_bad(self):
        self.assertEqual(attention.doctor_rows(['crit|bar|process|NOT RUNNING'])[0]['level'], 'bad')

    def test_healthy_machine_is_silent(self):
        self.assertEqual(attention.drive_rows({'drives': {'nvme0n1': {'status': 'good', 'temp': 40}}}), [])
        self.assertEqual(attention.space_rows(40, 100), [])
        self.assertEqual(attention.failed_unit_rows([], []), [])
        self.assertEqual(attention.fan_row(True, 'a', 'a', True), [])
        self.assertEqual(attention.fan_row(False, None, 'a', False), [])

    def test_fan_setup_states(self):
        self.assertEqual(attention.fan_row(True, None, 'a', False)[0]['id'], 'fans:setup')
        self.assertEqual(attention.fan_row(True, 'old', 'new', True)[0]['id'], 'fans:stale')
        self.assertEqual(attention.fan_row(True, 'a', 'a', False)[0]['id'], 'fans:stopped')

    def test_full_drive(self):
        self.assertEqual(attention.space_rows(10, 100)[0]['level'], 'warn')
        self.assertEqual(attention.space_rows(2, 100)[0]['level'], 'bad')

    def test_only_when_convenient_rows_can_be_dismissed_and_order_is_urgent_first(self):
        rows = [attention.row('a', 'info', 't', 'd'), attention.row('b', 'bad', 't', 'd'), attention.row('c', 'warn', 't', 'd')]
        self.assertEqual([r['id'] for r in attention.visible(rows, set())], ['b', 'c', 'a'])
        self.assertEqual([r['id'] for r in attention.visible(rows, {'a', 'b'})], ['b', 'c'])

    def test_replaced_kernel(self):
        self.assertEqual(attention.kernel_row('no-such-kernel', '/nonexistent')[0]['level'], 'warn')
        self.assertEqual(attention.kernel_row('', '/'), [])

    def test_stale_backup_only(self):
        self.assertEqual(attention.backup_row(1000, 1000 + 86400), [])
        self.assertEqual(attention.backup_row(0, 86400 * 100)[0]['level'], 'info')
        self.assertEqual(attention.backup_row(None, 0)[0]['run'], 'backup')


if __name__ == '__main__':
    unittest.main()
