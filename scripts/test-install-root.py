#!/usr/bin/env python3
"""Offline real-Git migration tests; no network, Docker, systemd or root."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('install_root', Path(__file__).with_name('install-root.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        previous_umask = os.umask(0o022)
        self.addCleanup(os.umask, previous_umask)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / 'public-fixture'
        self.remote.mkdir()
        files = {
            'install.sh': '#!/bin/bash\nexit 0\n',
            'scripts/deploy-remote.sh': '#!/bin/bash\nexit 0\n',
            'scripts/install-root.py': '# fixture\n',
            'deploy/hybrid-ai-deploy@.service': '[Service]\nExecStart=/opt/haven/scripts/deploy-instance.sh %i\n',
            'backup/system/hybrid-ai-backup-capture.service': '[Service]\nExecStart=/opt/haven/backup/backup.sh --stage-only\n',
        }
        for name, data in files.items():
            path = self.remote / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        self.git(self.remote, 'init', '-q')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'fixture')
        self.sha = self.git(self.remote, 'rev-parse', 'HEAD')
        self.git(self.remote, 'branch', '-M', 'main')
        self.calls = []
        self.fail_install = self.proxy_missing = self.interrupt = False
        self.tx = MODULE.Transaction(self.root, self.runner, os.getuid())
        self.tx.legacy.parent.mkdir()
        self.tx.units.mkdir(parents=True)
        self.tx.layout.parent.mkdir(parents=True)
        self.tx.keys.parent.mkdir(parents=True)
        self.git(self.root, 'clone', '-q', str(self.remote), str(self.tx.legacy))
        self.git(self.tx.legacy, 'remote', 'set-url', 'origin',
                 'https://github.com/jimbobsyouruncle/haven.git')
        self.original_key = (f'restrict,command="{self.tx.legacy}/scripts/deploy-forced-command.sh" '
                             'ssh-ed25519 SYNTHETIC\n# unrelated line\n')
        self.tx.keys.write_text(self.original_key)
        values = {'HYBRID_AI_APP_DIR': str(self.tx.legacy)}
        for key, rel in {
            'HYBRID_AI_STACK_ENV_FILE': '/etc/hybrid-ai/stack.env',
            'HYBRID_AI_DATA_DIR': '/var/lib/hybrid-ai',
            'HYBRID_AI_LOG_DIR': '/var/log/hybrid-ai',
            'HYBRID_AI_WORK_DIR': '/var/lib/hybrid-ai/work',
            'OPENHANDS_WORKSPACE': '/var/lib/hybrid-ai-agent',
            'AGENT_REPOS_DIR': '/var/lib/hybrid-ai-repos',
            'OPENHANDS_STATE_DIR': '/var/lib/hybrid-ai/openhands',
        }.items():
            values[key] = str(self.tx.path(rel))
        self.tx.layout.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
        self.layout_before = self.tx.layout.read_bytes()
        self.secret = self.tx.path('/etc/hybrid-ai/stack.env')
        self.secret.write_text('SYNTHETIC_SECRET=preserve-exact-bytes\n')
        self.secret.chmod(0o600)
        self.data = self.tx.path('/var/lib/hybrid-ai/database')
        self.data.parent.mkdir(parents=True)
        self.data.write_bytes(b'synthetic persistent data\x00')
        self.data_inode = self.data.stat().st_ino
        self.old_unit = self.tx.units / 'hybrid-ai-deploy@.service'
        self.old_unit.write_text('[Service]\nExecStart=/opt/hybrid-ai/scripts/deploy-instance.sh %i\n')

    @staticmethod
    def git(directory, *args):
        return subprocess.check_output(['git', '-C', str(directory), *args],
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def runner(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == 'git':
            args = list(args)
            if 'fetch' in args:
                args[args.index('fetch') + 2] = str(self.remote)
            return subprocess.run(args, **kwargs)
        if args[0] == 'docker':
            if self.proxy_missing and args[1] == 'image':
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, 'sha256:' + 'a' * 64, '')
        if args[0] == 'systemctl':
            if self.interrupt:
                self.interrupt = False
                raise SystemExit('synthetic power loss')
            return subprocess.CompletedProcess(args, 0, '', '')
        if self.fail_install:
            raise subprocess.CalledProcessError(4, args)
        return subprocess.CompletedProcess(args, 0, '', '')

    def receipt(self):
        journal = self.tx.load()
        path = Path(journal['receipt'])
        path.parent.mkdir(parents=True, exist_ok=True)
        gates = {name: {'required': True, 'state': 'PASS'} for name in
                 ('workflow_runs', 'deployed_head', 'installation_root', 'runtime_health', 'backup_tile')}
        evidence = dict(schema_version=2, sha=self.sha, head=self.sha,
                        app_dir=str(self.tx.app), rc=0, verdict='PASS', gates=gates)
        path.write_text(json.dumps(evidence))
        return evidence

    def assert_preserved(self):
        self.assertEqual(self.data.read_bytes(), b'synthetic persistent data\x00')
        self.assertEqual(self.data.stat().st_ino, self.data_inode)
        self.assertEqual(self.secret.read_text(), 'SYNTHETIC_SECRET=preserve-exact-bytes\n')
        self.assertEqual(self.secret.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.tx.legacy.is_dir())
        self.assertFalse(self.tx.app.is_symlink())

    def test_legacy_and_repeated_deployment(self):
        self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['phase'], 'awaiting_verifier')
        self.assertIn(str(self.tx.app), self.tx.layout.read_text())
        self.assertIn('# unrelated line', self.tx.keys.read_text())
        self.assertIn('restrict,command=', self.tx.keys.read_text())
        self.tx.wiring(self.sha)
        self.tx.accept(self.sha, self.receipt())
        self.assertEqual(self.tx.load()['phase'], 'accepted')
        self.tx.deploy(self.sha)
        self.assertTrue(Path(self.tx.load()['previous']).is_dir())
        self.tx.accept(self.sha, self.receipt())
        self.assert_preserved()
        self.assertTrue(any('merge-base' in c and '--is-ancestor' in c for c in self.calls))
        self.assertTrue(all('core.hooksPath=/dev/null' in c for c in self.calls if c[0] == 'git'))

    def test_pending_blocks_even_with_forged_public_receipt(self):
        self.tx.deploy(self.sha)
        self.receipt()
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['phase'], 'awaiting_verifier')

    def test_missing_failed_skipped_wrong_and_stale_receipts(self):
        self.tx.deploy(self.sha)
        with self.assertRaises(FileNotFoundError):
            self.tx.accept(self.sha, {})
        for field in ('sha', 'head', 'app_dir', 'verdict'):
            evidence = self.receipt()
            evidence[field] = 'wrong'
            with self.assertRaises(MODULE.Refusal):
                self.tx.accept(self.sha, evidence)
        for state in ('FAIL', 'SKIPPED', 'WARN', 'NOT VERIFIED'):
            evidence = self.receipt()
            evidence['gates']['runtime_health']['state'] = state
            with self.assertRaises(MODULE.Refusal):
                self.tx.accept(self.sha, evidence)
        evidence = self.receipt()
        os.utime(Path(self.tx.load()['receipt']), ns=(1, 1))
        with self.assertRaises(MODULE.Refusal):
            self.tx.accept(self.sha, evidence)

    def test_install_failure_restores_controls(self):
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertEqual(self.tx.keys.read_text(), self.original_key)
        self.assertIn('/opt/hybrid-ai', self.old_unit.read_text())
        self.assertFalse(self.tx.app.exists())
        self.assertTrue(Path(self.tx.load()['failed']).exists())
        self.assertEqual(self.tx.load()['phase'], 'rolled_back')
        self.assert_preserved()

    def test_canonical_failure_restores_checkout_inode(self):
        self.tx.deploy(self.sha)
        self.tx.accept(self.sha, self.receipt())
        inode = self.tx.app.stat().st_ino
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.app.stat().st_ino, inode)
        self.tx.wiring(self.sha)
        self.assert_preserved()

    def test_interrupted_activation_recovers_before_retry(self):
        self.interrupt = True
        with self.assertRaises(SystemExit):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['phase'], 'activating')
        self.tx.deploy(self.sha)
        self.tx.accept(self.sha, self.receipt())
        self.assert_preserved()

    def test_proxy_gate_precedes_activation(self):
        self.proxy_missing = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.app.exists())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertFalse(any(c[0] == 'bash' for c in self.calls))

    def test_conflicting_and_symlinked_roots(self):
        self.tx.app.mkdir()
        (self.tx.app / 'unrelated').write_text('preserve')
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertEqual((self.tx.app / 'unrelated').read_text(), 'preserve')
        shutil.rmtree(self.tx.app)
        self.tx.app.symlink_to(self.root / 'absent')
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertTrue(self.tx.app.is_symlink())

    def test_untrusted_and_foreign_checkout(self):
        self.tx.legacy.chmod(0o777)
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.tx.legacy.chmod(0o755)
        self.git(self.tx.legacy, 'remote', 'set-url', 'origin', 'https://example.invalid/foreign.git')
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.app.exists())

    def test_repo_local_data_requires_preparation(self):
        self.tx.layout.write_text(self.tx.layout.read_text().replace(
            str(self.tx.path('/var/lib/hybrid-ai')) + '\n', str(self.tx.legacy) + '\n'))
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.app.exists())

    def test_unmerged_sha_before_activation(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy('f' * 40)
        self.assertFalse(self.tx.app.exists())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)

    def test_foreign_previous_revision_is_not_a_rollback_source(self):
        (self.tx.legacy / 'foreign').write_text('unpublished synthetic change')
        self.git(self.tx.legacy, 'add', '.')
        self.git(self.tx.legacy, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'foreign')
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.app.exists())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)

    def test_custom_unit_override(self):
        directory = self.tx.units / 'hybrid-ai-deploy@.service.d'
        directory.mkdir()
        (directory / 'override.conf').write_text('[Service]\nWorkingDirectory=/opt/hybrid-ai\n')
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.app.exists())

    def test_old_dispatcher_previous_revision_survives_failure(self):
        previous_sha = self.sha
        (self.remote / 'new-version').write_text('next deploy')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'next')
        self.sha = self.git(self.remote, 'rev-parse', 'HEAD')
        self.git(self.tx.legacy, 'fetch', str(self.remote), 'main')
        self.git(self.tx.legacy, 'reset', '--hard', self.sha)
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertEqual(self.git(self.tx.legacy, 'rev-parse', 'HEAD'), previous_sha)
        self.assertEqual(self.tx.load()['previous_sha'], previous_sha)
        self.assert_preserved()

    def test_accepted_rollback_and_later_secret_rotation_protection(self):
        self.tx.deploy(self.sha)
        self.tx.accept(self.sha, self.receipt())
        self.secret.write_text('SYNTHETIC_SECRET=owner-rotated\n')
        with self.assertRaises(MODULE.Refusal):
            self.tx.restore(self.tx.load())
        self.assertEqual(self.secret.read_text(), 'SYNTHETIC_SECRET=owner-rotated\n')
        self.secret.write_text('SYNTHETIC_SECRET=preserve-exact-bytes\n')
        self.tx.restore(self.tx.load())
        self.assertFalse(self.tx.app.exists())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assert_preserved()

    def test_canonical_power_loss_after_each_directory_rename(self):
        self.tx.deploy(self.sha)
        self.tx.accept(self.sha, self.receipt())
        rename = Path.rename
        for failure_after in (1, 2):
            count = 0

            def interrupted(path, destination):
                nonlocal count
                result = rename(path, destination)
                count += 1
                if count == failure_after:
                    raise SystemExit('power loss after rename')
                return result

            with patch.object(Path, 'rename', interrupted):
                with self.assertRaises(SystemExit):
                    self.tx.deploy(self.sha)
            self.assertEqual(self.tx.load()['phase'], 'activating')
            self.tx.deploy(self.sha)
            self.tx.accept(self.sha, self.receipt())
            self.assert_preserved()


if __name__ == '__main__':
    unittest.main()
