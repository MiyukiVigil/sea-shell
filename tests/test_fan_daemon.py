"""Drive sea-fand against a fake hwmon directory with a simulated steep fan."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sea_fand', ROOT / 'quickshell/scripts/system/sea-fand.py')
fand = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fand)

# The measured points: pwm % to rpm
FAN = [(0, 0), (5, 2000), (20, 3850), (32, 4900), (42, 5400), (45, 5750), (55, 6100), (100, 8000)]


class Bench:
    def __init__(self, tmp, mode='auto', temp=60, rpm=3300):
        self.hw = Path(tmp)
        self.mode_file = self.hw / 'mode'
        self.mode_file.write_text(mode + '\n')
        self.cpu = self.hw / 'cpu'
        self.set_temp(temp)
        (self.hw / 'temp2_input').write_text('40000')
        for n in (1, 2):
            (self.hw / f'fan{n}_input').write_text(str(rpm))
            (self.hw / f'pwm{n}').write_text('255')
            (self.hw / f'pwm{n}_enable').write_text('2')
        self.boost_file = self.hw / 'max_perf_pct'
        self.boost_file.write_text('100')
        self.ec_floor = 0
        self.ctl = fand.Controller(str(self.hw), str(self.cpu), str(self.mode_file), str(self.boost_file))

    def set_temp(self, c):
        self.cpu.write_text(str(c * 1000))

    def run(self, seconds):
        """Tick, with the tach following pwm. Returns the rpm seen at each tick."""
        seen = []
        for _ in range(int(seconds / fand.TICK)):
            self.ctl.step(fand.TICK)
            for n in (1, 2):
                pct = int((self.hw / f'pwm{n}').read_text()) / 2.55
                (self.hw / f'fan{n}_input').write_text(str(max(self.ec_floor, int(fand.lerp(FAN, pct)))))
            seen.append(int((self.hw / 'fan1_input').read_text()))
        return seen


class FanDaemon(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def bench(self, **kw):
        return Bench(self.tmp.name, **kw)

    def test_curves_only_climb_and_quiet_is_never_louder(self):
        for pts in fand.CURVES.values():
            self.assertEqual(pts, sorted(pts))
            self.assertEqual([p[1] for p in pts], sorted(p[1] for p in pts))
        for c in range(30, 96):
            q, a, m = (fand.lerp(fand.CURVES[k], c) for k in ('quiet', 'auto', 'max'))
            self.assertLessEqual(q, a, c)
            self.assertLess(a, m, c)

    def test_takeover_never_starts_from_full_speed(self):
        b = self.bench(rpm=3300)
        self.assertLess(int((b.hw / 'pwm1').read_text()), 100)
        self.assertEqual((b.hw / 'pwm1_enable').read_text(), '1')

    def test_settles_on_the_curve(self):
        for mode, temp in (('auto', 85), ('quiet', 92), ('max', 88)):
            with self.subTest(mode=mode):
                with tempfile.TemporaryDirectory() as tmp:
                    b = Bench(tmp, mode=mode, temp=temp)
                    seen = b.run(300)[-20:]
                    want = fand.lerp(fand.CURVES[mode], temp)
                    for rpm in seen:
                        self.assertLess(abs(rpm - want), 400)

    def test_does_not_hunt_at_a_steady_temperature(self):
        b = self.bench(temp=85)
        seen = b.run(300)[-60:]
        self.assertLess(max(seen) - min(seen), 500)

    def test_a_short_spike_barely_moves_the_fans(self):
        b = self.bench(temp=60)
        before = b.run(120)[-1]
        b.set_temp(95)
        spike = b.run(4)
        b.set_temp(60)
        after = b.run(10)
        self.assertLess(max(spike + after) - before, 500)

    def test_sudden_heat_ramps_instead_of_blasting(self):
        b = self.bench(temp=50, rpm=2500)
        b.run(60)
        b.set_temp(97)
        seen = b.run(120)
        jumps = [y - x for x, y in zip(seen, seen[1:])]
        self.assertGreater(seen[-1], 6000)
        self.assertLess(max(jumps), 800)

    def test_idle_gets_below_the_old_20_percent_floor(self):
        b = self.bench(temp=50, rpm=3850)
        self.assertLess(b.run(120)[-1], 3000)

    def test_a_stalled_fan_raises_its_floor_and_stays_up(self):
        b = self.bench(temp=50, rpm=2200)
        b.run(60)
        (b.hw / 'fan1_input').write_text('0')
        b.ctl.step(fand.TICK)
        stalled_at = b.ctl.floor['1']
        self.assertGreater(stalled_at, fand.MIN_PCT)
        b.run(60)
        self.assertGreaterEqual(b.ctl.pct['1'], stalled_at)

    def test_quiet_caps_the_cpu_and_other_presets_put_it_back(self):
        b = self.bench(mode='quiet')
        b.ctl.step(fand.TICK)
        self.assertEqual(b.boost_file.read_text(), '60')
        b.mode_file.write_text('auto\n')
        b.ctl.step(fand.TICK)
        self.assertEqual(b.boost_file.read_text(), '100')

    def test_release_lifts_the_cpu_cap(self):
        b = self.bench(mode='quiet')
        b.ctl.step(fand.TICK)
        fand.release(str(b.hw), str(b.boost_file))
        self.assertEqual(b.boost_file.read_text(), '100')

    def test_above_an_unreachable_target_still_responds_quickly_to_heat(self):
        # The EC holds the fans at 3900 whatever the pwm says, so the loop winds to its floor.
        b = self.bench(temp=50, rpm=3900)
        b.ec_floor = 3900
        b.run(180)
        self.assertEqual(b.ctl.pct['1'], fand.MIN_PCT)
        b.ec_floor = 0
        b.set_temp(95)
        seen = b.run(90)
        self.assertGreater(seen[-1], 5000)

    def test_ec_pulses_become_one_steady_speed(self):
        # Measured: turbo spikes make the EC jump 3500 to 4900 rpm for seconds, every ~30 s.
        b = self.bench(temp=55, rpm=2700)
        b.run(120)
        seen = []
        for _ in range(4):
            b.ec_floor = 4900
            seen += b.run(6)
            b.ec_floor = 0
            seen += b.run(24)
        after_first = seen[3:]
        # Held about halfway between the curve (~2700) and the spike, not at the spike.
        self.assertGreater(min(after_first), 3500)
        self.assertLess(sorted(after_first)[len(after_first) // 2], 4300)
        # What is left of each pulse is about half the 2200 rpm swing the EC makes alone.
        drops = [x - y for x, y in zip(after_first, after_first[1:])]
        self.assertLess(max(drops), 1250)

    def test_a_held_speed_winds_down_gradually(self):
        b = self.bench(temp=55, rpm=2700)
        b.run(120)
        b.ec_floor = 4900
        b.run(6)
        b.ec_floor = 0
        seen = b.run(400)
        drops = [x - y for x, y in zip(seen, seen[1:])]
        self.assertLess(max(drops), 300)
        self.assertLess(seen[-1], 3200)

    def test_tach_step_noise_at_full_speed_does_not_pin_the_hold(self):
        # Measured on the Nitro: fan1 stuck at 7894, fan2 steps ~183 rpm (7317↔7500). That used
        # to look like an EC jump every few ticks and kept re-arming the hold forever.
        b = self.bench(temp=55, mode='auto', rpm=7894)
        b.ctl.pct = {n: 100 for n in b.ctl.fans}
        for n in b.ctl.fans:
            b.ctl.apply(n)
        steps = (7317, 7317, 7500, 7500)
        for i in range(90):
            (b.hw / 'fan1_input').write_text('7894')
            (b.hw / 'fan2_input').write_text(str(steps[i % len(steps)]))
            b.ctl.step(fand.TICK)
        self.assertLess(b.ctl.target, 4000)
        self.assertLess(b.ctl.pct['1'], 50)

    def test_reclaims_the_fans_after_suspend(self):
        b = self.bench()
        (b.hw / 'pwm1_enable').write_text('2')
        b.ctl.step(fand.TICK)
        self.assertEqual((b.hw / 'pwm1_enable').read_text(), '1')

    def test_preset_changes_take_effect_and_bad_values_fall_back(self):
        b = self.bench(temp=70)
        b.mode_file.write_text('max\n')
        self.assertGreater(b.run(120)[-1], 5800)
        b.mode_file.write_text('nonsense\n')
        self.assertEqual(b.ctl.mode(), 'auto')
        b.mode_file.unlink()
        self.assertEqual(b.ctl.mode(), 'auto')

    def test_release_returns_every_fan_to_firmware(self):
        b = self.bench()
        fand.release(str(b.hw), str(b.boost_file))
        for n in (1, 2):
            self.assertEqual((b.hw / f'pwm{n}_enable').read_text(), '2')

    def test_missing_sensor_raises_so_main_can_release(self):
        b = self.bench()
        b.cpu.unlink()
        with self.assertRaises(OSError):
            b.ctl.step(fand.TICK)


if __name__ == '__main__':
    unittest.main()
