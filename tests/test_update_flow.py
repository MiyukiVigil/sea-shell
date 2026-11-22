import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPDATE = ROOT / 'quickshell/scripts/system/sea-update.sh'


def git(cwd, *args):
    subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True,
                   env={**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t',
                        'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'})


class UpdateFlowTests(unittest.TestCase):
    """Real git against a real remote. install.sh is a stand-in that does what matters here:
    replaces the deployed files and stamps version and commit."""

    INSTALL = '''#!/bin/bash
d="$HOME/.config/quickshell/sea-shell"
cp VERSION "$d/VERSION"; cp shell.qml "$d/shell.qml"; git rev-parse HEAD > "$d/INSTALLED_COMMIT"
'''

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.home, self.repo, self.bare, self.other = base / 'home', base / 'repo', base / 'r.git', base / 'other'
        self.qsd = self.home / '.config/quickshell/sea-shell'
        self.qsd.mkdir(parents=True)
        (self.home / '.config/hypr/sea-shell').mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(self.bare)], check=True)
        git(base, 'clone', '-q', str(self.bare), str(self.repo))
        git(self.repo, 'checkout', '-q', '-B', 'main')
        self.write_release(self.repo, '1.0.0', 'old', '## [1.0.0]\n\n- First.\n')
        (self.repo / 'install.sh').write_text(self.INSTALL)
        git(self.repo, 'add', '-A'); git(self.repo, 'commit', '-qm', 'one'); git(self.repo, 'push', '-q', '-u', 'origin', 'main')
        env = self.env()
        subprocess.run(['bash', 'install.sh'], cwd=self.repo, env=env, check=True)
        (self.qsd / 'REPO_PATH').write_text(str(self.repo))
        (self.qsd / 'sea-update.sh').write_text(UPDATE.read_text())
        self.bin = base / 'bin'; self.bin.mkdir()
        for tool in ['notify-send']:
            self.stub(tool, 'exit 0')
        git(base, 'clone', '-q', str(self.bare), str(self.other))

    def tearDown(self):
        self.tmp.cleanup()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def env(self, **extra):
        env = {**os.environ, 'HOME': str(self.home), 'XDG_STATE_HOME': str(self.home / '.state'),
               'SEA_UPDATE_SETTLE': '0', 'SEA_UPDATE_WATCH': '0'}
        env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
        if hasattr(self, 'bin'):
            env['PATH'] = str(self.bin) + ':' + os.environ['PATH']
        env.update(extra)
        return env

    def write_release(self, repo, version, code, log):
        (repo / 'VERSION').write_text(version + '\n')
        (repo / 'shell.qml').write_text(code)
        (repo / 'CHANGELOG.md').write_text(log)

    def publish(self, version='2.0.0', code='new'):
        self.write_release(self.other, version, code, '## [%s]\n\n- Nicer things.\n\n## [1.0.0]\n\n- First.\n' % version)
        git(self.other, 'add', '-A'); git(self.other, 'commit', '-qm', 'two'); git(self.other, 'push', '-q', 'origin', 'main')

    def run_cmd(self, *args, **env):
        return subprocess.run(['sh', str(self.qsd / 'sea-update.sh'), *args], text=True, capture_output=True,
                              env=self.env(**env)).stdout.strip()

    def state(self):
        return self.run_cmd('check').split('|')[0]

    def wait(self, *args, **env):
        self.run_cmd(*args, **env)
        for _ in range(300):
            phase = self.run_cmd('status').split('|')[0]
            if phase != 'working':
                return phase
            time.sleep(0.05)
        self.fail('never finished: ' + self.run_cmd('status'))

    def deployed(self):
        return (self.qsd / 'shell.qml').read_text()

    def test_states(self):
        self.assertEqual(self.state(), 'uptodate')
        self.publish()
        self.assertEqual(self.state(), 'available')
        self.assertEqual(self.run_cmd('check').split('|')[1:3], ['1.0.0', '2.0.0'])
        (self.repo / 'untracked').write_text('x')
        self.assertEqual(self.state(), 'dirty')

    def test_changes_are_only_what_is_new(self):
        self.publish()
        self.state()
        changes = self.run_cmd('changes')
        self.assertIn('Nicer things', changes)
        self.assertNotIn('First', changes)

    def test_update_then_undo_keeps_repo_and_offers_it_again(self):
        self.publish()
        self.state()
        self.assertEqual(self.wait('start'), 'updated')
        self.assertEqual(self.deployed(), 'new')
        self.assertEqual(self.state(), 'uptodate')
        self.assertEqual(self.run_cmd('undoable'), '1.0.0')
        self.assertEqual(self.wait('undo'), 'undone')
        self.assertEqual(self.deployed(), 'old')
        self.assertEqual(self.state(), 'pending')
        self.assertEqual(self.run_cmd('undoable'), '')

    def test_bad_install_puts_the_old_version_back(self):
        # The new version ships a broken installer, the way a real bad release would.
        (self.other / 'install.sh').write_text('#!/bin/bash\nd="$HOME/.config/quickshell/sea-shell"; echo half > "$d/shell.qml"; exit 1\n')
        self.publish()
        self.state()
        self.assertEqual(self.wait('start'), 'failed')
        self.assertEqual(self.deployed(), 'old')
        self.assertIn("didn't install", self.run_cmd('status'))

    def test_bar_that_will_not_stay_up_is_rolled_back(self):
        self.publish()
        self.state()
        # A new pid each look is what a crash loop looks like from outside.
        self.stub('hyprctl', 'echo ok')
        self.stub('pgrep', 'echo $$')
        self.assertEqual(self.wait('start', HYPRLAND_INSTANCE_SIGNATURE='x'), 'failed')
        self.assertEqual(self.deployed(), 'old')
        self.assertIn('stay up', self.run_cmd('status'))
        self.assertEqual(self.state(), 'pending')

    def test_steady_bar_passes(self):
        self.publish()
        self.state()
        self.stub('hyprctl', 'echo ok')
        self.stub('pgrep', 'echo 4242')
        self.assertEqual(self.wait('start', HYPRLAND_INSTANCE_SIGNATURE='x'), 'updated')
        self.assertEqual(self.deployed(), 'new')

    def test_uncommitted_work_is_refused_and_untouched(self):
        self.publish()
        (self.repo / 'mine').write_text('precious')
        self.assertEqual(self.wait('start'), 'failed')
        self.assertEqual(self.deployed(), 'old')
        self.assertEqual((self.repo / 'mine').read_text(), 'precious')

    def test_only_a_few_snapshots_are_kept(self):
        snaps = self.home / '.state/sea-shell/update-snapshots'
        for i in range(5):
            self.publish('2.0.%d' % i, 'v%d' % i)
            self.state()
            self.assertEqual(self.wait('start'), 'updated')
            time.sleep(1.05)
        self.assertLessEqual(len(list(snaps.iterdir())), 3)


class InstallDeployTests(unittest.TestCase):
    def test_deploy_swaps_whole_and_stamps_the_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            repo = base / 'repo'; (repo / 'quickshell/ui').mkdir(parents=True)
            (repo / 'quickshell/ui/a.qml').write_text('new')
            (repo / 'quickshell/sea-register-files.py').write_text('')
            git(base, 'init', '-q', str(repo)); git(repo, 'add', '-A'); git(repo, 'commit', '-qm', 'x')
            dest = base / 'dest'; dest.mkdir(); (dest / '.sea-shell').write_text(''); (dest / 'stale.qml').write_text('old')
            defs = (ROOT / 'install.sh').read_text().split('# ---- args (flags combine', 1)[0]
            script = defs + f'\nSCRIPT_DIR={repo}; QS_DEST={dest}; SEA_VERSION=9\ndeploy_qs copy\n'
            r = subprocess.run(['bash', '-c', script], env={**os.environ, 'HOME': str(base)}, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((dest / 'a.qml').read_text(), 'new')
            self.assertFalse((dest / 'stale.qml').exists())
            self.assertEqual(len((dest / 'INSTALLED_COMMIT').read_text().strip()), 40)
            self.assertEqual([p.name for p in base.iterdir() if '.new.' in p.name or '.old.' in p.name], [])


if __name__ == '__main__':
    unittest.main()
