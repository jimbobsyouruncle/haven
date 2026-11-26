"""Focused offline tests for the canonical deployment driver."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import runpy


ROOT = Path(__file__).resolve().parent.parent
DRIVER = runpy.run_path(str(ROOT / 'scripts/deploy-host.py'))
Deployment = DRIVER['Deployment']
Refusal = DRIVER['Refusal']


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(os.umask, os.umask(0o022))
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.driver = Deployment(self.root, owner=os.getuid())
        self.app = self.driver.app
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.driver.remote = str(self.remote)
        self.driver.env['HOME'] = str(self.root)
        self.driver.path('/run/lock').mkdir(parents=True)
        self.driver.path('/etc/systemd/system').mkdir(parents=True)
        self.git(self.remote, 'init', '-q', '-b', 'main')

        self.write(self.remote / 'status/Caddyfile', 'sample configuration')
        self.write(self.remote / 'deploy/haven-deploy@.service', 'new unit')
        self.write(self.remote / 'scripts/deploy-provenance.py', '# fixture')
        self.write(self.remote / 'scripts/deploy-remote.sh', '# fixture')
        helper = self.remote / 'scripts/lib/haven-env.sh'
        helper.parent.mkdir()
        shutil.copyfile(ROOT / 'scripts/lib/haven-env.sh', helper)
        self.write(self.remote / 'backup/restore.sh', '# fixture')
        self.write(self.remote / 'updated', 'old source')
        self.write(self.remote / 'obsolete', 'old source')
        self.commit()
        self.app.parent.mkdir()
        self.git(self.root, 'clone', '-q', str(self.remote), str(self.app))
        self.baseline = self.git(self.app, 'rev-parse', 'HEAD')
        self.write(self.app / 'status/Caddyfile', 'validated production configuration')
        (self.remote / 'obsolete').unlink()
        self.write(self.remote / 'new-code', 'approved source')
        self.write(self.remote / 'updated', 'new source')
        self.sha = self.commit()

        self.data = self.root / 'data'
        self.database = self.data / 'persona/database'
        self.write(self.database, 'persistent data')
        self.database.chmod(0o600)
        self.before = self.database.stat()
        stack = self.root / 'etc/haven/stack.env'
        self.write(stack, '# private stack settings\n')
        stack.chmod(0o600)
        self.layout = (
            f'HAVEN_APP_DIR={self.app}\nHAVEN_STACK_ENV_FILE={stack}\n'
            f'HAVEN_DATA_DIR={self.data}\nHAVEN_LOG_DIR={self.root}/logs\n'
            f'HAVEN_WORK_DIR={self.root}/work\n'
        )
        self.write(self.driver.layout, self.layout)
        self.write(self.driver.keys, f'restrict,command="{self.app}/scripts/deploy-forced-command.sh" fixture\n')

    @staticmethod
    def write(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def git(self, cwd, *args):
        return self.driver.git(cwd, *args).strip()

    def commit(self):
        self.git(self.remote, 'add', '-A')
        self.git(self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'fixture')
        return self.git(self.remote, 'rev-parse', 'HEAD')

    def deploy(self, fail=False):
        original = self.driver.command

        def command(args, **kwargs):
            if args[0] == 'systemctl' or 'authorize-host' in args:
                return ''
            if len(args) > 1 and args[1] == str(self.app / 'scripts/deploy-remote.sh'):
                # A separate invocation must be excluded through verification.
                with self.assertRaises(BlockingIOError):
                    self.driver.lock_pair()
                if fail:
                    raise subprocess.CalledProcessError(1, args)
                return ''
            return original(args, **kwargs)

        with patch.object(self.driver, 'command', side_effect=command), patch.object(self.driver, 'open_log'):
            self.driver.deploy(self.sha)

    def assert_persistent_data(self):
        self.assertEqual(self.database.read_text(), 'persistent data')
        actual = self.database.stat()
        self.assertEqual((actual.st_ino, actual.st_uid, actual.st_gid, actual.st_mode),
                         (self.before.st_ino, self.before.st_uid, self.before.st_gid, self.before.st_mode))

    def test_converges_to_exact_main_and_keeps_validated_render(self):
        self.deploy()
        self.assertEqual(self.git(self.app, 'rev-parse', 'HEAD'), self.sha)
        self.assertEqual((self.app / 'new-code').read_text(), 'approved source')
        self.assertEqual((self.app / 'updated').read_text(), 'new source')
        self.assertFalse((self.app / 'obsolete').exists())
        self.assertEqual((self.app / 'status/Caddyfile').read_text(), 'validated production configuration')
        self.assert_persistent_data()
        with self.assertRaisesRegex(Refusal, 'exact main'):
            self.driver.update(self.baseline)

    def test_failure_releases_locks_and_next_deploy_ignores_old_journal(self):
        journal = self.driver.path('/var/lib/haven-install-root/current.json')
        self.write(journal, '{"phase":"awaiting_verifier"}')
        with self.assertRaisesRegex(Refusal, 'reconcile and verify'):
            self.deploy(fail=True)
        self.assert_persistent_data()
        self.deploy()
        self.assertEqual(journal.read_text(), '{"phase":"awaiting_verifier"}')

    def test_refuses_persistent_overlap_unrestricted_ssh_and_checkout_collision(self):
        self.driver.layout.write_text(self.layout.replace(str(self.data), str(self.app / 'data')))
        with self.assertRaisesRegex(Refusal, 'overlaps application'):
            self.driver.preflight()
        self.driver.layout.write_text(self.layout)
        restricted_key = self.driver.keys.read_text()
        self.driver.keys.write_text(restricted_key.removeprefix('restrict,'))
        with self.assertRaisesRegex(Refusal, 'restricted SSH'):
            self.driver.preflight()
        self.driver.keys.write_text(restricted_key)
        self.write(self.app / 'new-code', 'untracked local data')
        with self.assertRaisesRegex(Refusal, 'overlaps an untracked path'):
            self.deploy()
        self.assertEqual((self.app / 'new-code').read_text(), 'untracked local data')
        self.assertEqual(self.git(self.app, 'rev-parse', 'HEAD'), self.baseline)
        self.assert_persistent_data()


if __name__ == '__main__':
    unittest.main()
