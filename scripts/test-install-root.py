#!/usr/bin/env python3
"""Offline real-Git migration tests; no network, Docker, systemd or root."""
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from contextlib import redirect_stderr

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
            'status/Caddyfile': '# synthetic installed configuration\n',
            'docker-compose.yml': '# synthetic installed compose\n',
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
        self.project = 'hybrid-ai'
        self.running_image = 'sha256:' + 'a' * 64
        self.recovery_image = self.running_image
        self.image_metadata = None
        self.export_missing = False
        self.export_empty = False
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
        self.approve_recovery()

    def approve_recovery(self, recovery=None):
        self.recovery_image = recovery or self.running_image
        directory = self.tx.path('/etc/hybrid-ai/install-root-approvals')
        directory.mkdir(mode=0o700, exist_ok=True)
        self.approval_path = directory / (self.sha + '.json')
        self.evidence_path = directory / (self.sha + '.evidence.json')
        source = self.tx.app if self.tx.app.exists() else self.tx.legacy
        evidence = dict(schema_version=1, running_image_id=self.running_image,
                        recovery_image_id=self.recovery_image, platform='linux/arm64',
                        configuration_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest()
                                              for name, path in {
                                                  'caddyfile': source / 'status/Caddyfile',
                                                  'compose': source / 'docker-compose.yml',
                                                  'stack_env': self.secret}.items()},
                        checks={name: dict(state='PASS', receipt_sha256='b' * 64) for name in
                                ('caddy_version', 'dns_modules', 'config_validation',
                                 'platform', 'recovery_procedure')})
        self.evidence_path.write_text(json.dumps(evidence))
        self.evidence_path.chmod(0o600)
        now = int(time.time())
        approval = dict(schema_version=1, requested_sha=self.sha,
                        decision='approve-install-root-deployment-and-proxy-recovery',
                        approved_at=now, expires_at=now + 3600,
                        evidence_sha256=hashlib.sha256(self.evidence_path.read_bytes()).hexdigest())
        self.approval_path.write_text(json.dumps(approval))
        self.approval_path.chmod(0o600)

    def change_record(self, path, **changes):
        record = json.loads(path.read_text())
        record.update(changes)
        path.write_text(json.dumps(record))
        if path == self.evidence_path:
            self.change_record(self.approval_path,
                               evidence_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

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
            if any('com.docker.compose.project' in arg for arg in args):
                return subprocess.CompletedProcess(args, 0, self.project, '')
            if self.proxy_missing and args[1] == 'image':
                raise subprocess.CalledProcessError(1, args)
            if args[1:3] == ['image', 'save']:
                if self.export_missing:
                    raise subprocess.CalledProcessError(1, args, stderr='SYNTHETIC_PRIVATE_DETAIL')
                Path(args[args.index('--output') + 1]).write_bytes(
                    b'' if self.export_empty else b'synthetic complete image archive')
                return subprocess.CompletedProcess(args, 0, '', '')
            if args[1] == 'image':
                metadata = self.image_metadata or dict(Id=self.recovery_image, Os='linux',
                                                       Architecture='arm64', Variant='')
                return subprocess.CompletedProcess(args, 0, json.dumps(metadata), '')
            return subprocess.CompletedProcess(args, 0, self.running_image, '')
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
        with self.assertRaisesRegex(MODULE.Refusal, 'RECOVERY_IMAGE'):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.app.exists())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertFalse(any(c[0] == 'bash' for c in self.calls))

    def assert_recovery_refused(self, gate):
        with self.assertRaisesRegex(MODULE.Refusal, gate) as caught:
            self.tx.deploy(self.sha)
        self.assertNotIn('SYNTHETIC_PRIVATE_DETAIL', str(caught.exception))
        self.assertFalse(self.tx.app.exists())
        self.assertFalse(self.tx.journal.exists())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertEqual(self.tx.keys.read_text(), self.original_key)
        self.assertFalse(any(c[0] in ('bash', 'systemctl') for c in self.calls))
        self.assert_preserved()

    def test_missing_approval_cannot_be_replaced_by_environment(self):
        self.approval_path.unlink()
        with patch.dict(os.environ, HYBRID_AI_SKIP_PROXY_RECOVERY='1',
                        HYBRID_AI_APPROVE_RECOVERY='1', CADDY_IMAGE='matching-tag'):
            self.assert_recovery_refused('RECOVERY_APPROVAL')
        self.assertFalse(any(c[1:3] == ['image', 'save'] for c in self.calls))

    def test_approval_expiry_revision_decision_and_evidence_binding(self):
        for changes in ({'expires_at': 1}, {'approved_at': int(time.time()) + 1000},
                        {'expires_at': int(time.time()) + 90000},
                        {'requested_sha': 'f' * 40}, {'decision': 'approve'},
                        {'evidence_sha256': 'c' * 64}):
            with self.subTest(changes=changes):
                self.approve_recovery()
                self.change_record(self.approval_path, **changes)
                self.assert_recovery_refused('RECOVERY_APPROVAL')

    def test_untrusted_approval_and_evidence(self):
        for name in ('approval_path', 'evidence_path'):
            for mode in (0o644, 0o666):
                with self.subTest(name=name, mode=mode):
                    self.approve_recovery()
                    getattr(self, name).chmod(mode)
                    self.assert_recovery_refused('RECOVERY_')
            self.approve_recovery()
            path = getattr(self, name)
            saved = path.with_suffix('.saved')
            path.rename(saved)
            path.symlink_to(saved)
            self.assert_recovery_refused('RECOVERY_')
            path.unlink()
            saved.rename(path)

    def test_missing_and_incomplete_compatibility_evidence(self):
        self.evidence_path.unlink()
        self.assert_recovery_refused('RECOVERY_COMPATIBILITY')
        for changes in ({'running_image_id': 'sha256:' + 'c' * 64},
                        {'recovery_image_id': 'hybrid-ai-caddy:2.11.7-dns'},
                        {'configuration_sha256': {}}, {'checks': {}}):
            with self.subTest(changes=changes):
                self.approve_recovery()
                self.change_record(self.evidence_path, **changes)
                self.assert_recovery_refused('RECOVERY_COMPATIBILITY')
        for state in ('FAILED', 'WARN', 'SKIPPED', 'NOT VERIFIED', 'PENDING'):
            self.approve_recovery()
            evidence = json.loads(self.evidence_path.read_text())
            evidence['checks']['config_validation']['state'] = state
            self.change_record(self.evidence_path, checks=evidence['checks'])
            self.assert_recovery_refused('RECOVERY_COMPATIBILITY')

    def test_changed_configuration_invalidates_approval(self):
        for path in (self.tx.legacy / 'status/Caddyfile',
                     self.tx.legacy / 'docker-compose.yml', self.secret):
            with self.subTest(path=path.name):
                before = path.read_bytes()
                path.write_bytes(before + b'# changed\n')
                with self.assertRaisesRegex(MODULE.Refusal, 'RECOVERY_COMPATIBILITY'):
                    self.tx.deploy(self.sha)
                path.write_bytes(before)
                self.assert_preserved()

    def test_compatibility_binds_the_resolved_stack_environment(self):
        custom = self.secret.with_name('custom-stack.env')
        self.secret.rename(custom)
        self.tx.layout.write_text(self.tx.layout.read_text().replace(str(self.secret), str(custom)))
        self.secret = custom
        self.approve_recovery()
        self.tx.deploy(self.sha)
        self.assert_preserved()

    def test_wrong_image_platform_and_unexportable_layers(self):
        for metadata in (dict(Id='sha256:' + 'c' * 64, Os='linux', Architecture='arm64'),
                         dict(Id=self.recovery_image, Os='linux', Architecture='amd64'),
                         dict(Id=self.recovery_image, Os='linux', Architecture='arm64', Variant='v8')):
            self.image_metadata = metadata
            self.assert_recovery_refused('RECOVERY_IMAGE')
        self.image_metadata = None
        self.export_missing = True
        self.assert_recovery_refused('RECOVERY_ARTIFACT')
        self.export_missing = False
        self.export_empty = True
        self.assert_recovery_refused('RECOVERY_ARTIFACT')

    def test_production_workflow_requires_manual_exact_sha_authorization(self):
        workflow = (Path(__file__).resolve().parent.parent /
                    '.github/workflows/deploy.yml').read_text()
        triggers = workflow.split('\non:\n', 1)[1].split('\nconcurrency:', 1)[0]
        self.assertEqual([line.strip() for line in triggers.splitlines()
                          if line.startswith('  ') and not line.startswith('   ')
                          and not line.lstrip().startswith('#')], ['workflow_dispatch:'])
        self.assertIn('default: false', triggers)
        job = workflow.split('\n  deploy:\n', 1)[1]
        conditions = next(line.strip()[4:] for line in job.splitlines()
                          if line.startswith('    if: '))
        self.assertEqual(conditions.split(' && '), [
            "github.event_name == 'workflow_dispatch'", "github.ref == 'refs/heads/main'",
            'inputs.authorize_production == true', 'inputs.deployment_sha == github.sha'])
        self.assertIn('    environment: production', job)

    def test_cli_gate_annotation_never_contains_subprocess_output(self):
        with self.assertRaises(MODULE.Refusal) as caught:
            with patch.object(self.tx, 'command', side_effect=subprocess.CalledProcessError(
                    1, ['docker'], output='PRIVATE_STDOUT', stderr='PRIVATE_STDERR')):
                self.tx.gate_command('RECOVERY_IMAGE', ['docker'])
        for error in (caught.exception, OSError('PRIVATE_HOST_PATH'),
                      subprocess.CalledProcessError(1, ['PRIVATE_ARG'], output='PRIVATE_STDOUT')):
            output = io.StringIO()
            with patch.object(MODULE, 'main', side_effect=error), redirect_stderr(output):
                self.assertEqual(MODULE.cli(), 1)
            self.assertTrue(output.getvalue().startswith('::error::install-root: '))
            self.assertNotIn('PRIVATE_', output.getvalue())
        self.assertIn('RECOVERY_IMAGE', str(caught.exception))

    def test_approved_alternative_is_exported_by_id_and_preserved_on_rollback(self):
        self.approve_recovery('sha256:' + 'd' * 64)
        self.tx.deploy(self.sha)
        journal = self.tx.load()
        recovery = journal['proxy_recovery']
        self.assertEqual(recovery['running_image_id'], self.running_image)
        self.assertEqual(recovery['recovery_image_id'], self.recovery_image)
        archive = Path(recovery['archive'])
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), recovery['archive_sha256'])
        self.assertTrue(any(c[1:3] == ['image', 'save'] and c[-1] == self.recovery_image
                            for c in self.calls))
        self.tx.accept(self.sha, self.receipt())
        journal = self.tx.load()
        self.tx.restore(journal)
        self.assertTrue(archive.is_file())
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertEqual(self.tx.keys.read_text(), self.original_key)
        self.assert_preserved()
        self.assertTrue(all(c[1:3] in (['image', 'inspect'], ['image', 'save'],
                                     ['container', 'inspect']) for c in self.calls if c[0] == 'docker'))

    def test_foreign_compose_project_is_not_taken_over(self):
        self.project = 'another-project'
        with self.assertRaises(MODULE.Refusal):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertFalse(self.tx.app.exists())

    def test_agent_control_selects_same_project_from_both_roots(self):
        binary = self.root / 'bin'
        binary.mkdir()
        trace = self.root / 'compose-argv.json'
        docker = binary / 'docker'
        docker.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                          'with open(os.environ["ROOT_COMPOSE_LOG"], "w") as out:\n'
                          '    json.dump(sys.argv[1:], out)\n')
        docker.chmod(0o755)
        control = Path(__file__).resolve().parent.parent / 'openhands/scripts/openhands-control.sh'
        self.tx.app.mkdir()
        for directory in (self.tx.legacy, self.tx.app):
            env = os.environ.copy()
            env.update(PATH=str(binary) + os.pathsep + env['PATH'],
                       ROOT_COMPOSE_LOG=str(trace), HYBRID_AI_APP_DIR=str(directory),
                       HYBRID_AI_ENV_FILE=str(self.tx.layout),
                       HYBRID_AI_STACK_ENV_FILE=str(self.secret))
            subprocess.run(['bash', str(control), 'status'], env=env, check=True, capture_output=True)
            args = json.loads(trace.read_text())
            self.assertEqual(args[:3], ['compose', '-p', 'hybrid-ai'])
            self.assertEqual(args[args.index('--project-directory') + 1], str(directory))
            self.assertEqual(args[-2:], ['ps', 'openhands'])

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
        self.sha = 'f' * 40
        self.approve_recovery()
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
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
        self.approve_recovery()
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
