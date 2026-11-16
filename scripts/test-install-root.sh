#!/usr/bin/env bash
# ADR-0006 and coordinated identity fixtures; no network, Docker, systemd or root.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/test-install-root.sh" <<'PYTEST'
import sys
__file__ = sys.argv.pop(1)
#!/usr/bin/env python3
"""Offline real-Git migration tests; no network, Docker, systemd or root."""
import importlib.util
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
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
        self.proxy_mounts = []
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
        self.selection = self.tx.path('/etc/hybrid-ai/proxy-recovery-image')
        self.selection.write_text(self.recovery_image + '\n')
        self.selection.chmod(0o600)
        self.layer = b'synthetic filesystem layer'
        self.config = dict(os='linux', architecture='arm64', config={'Env': ['LOCAL_DOMAIN=fixture']},
                           rootfs={'type': 'layers', 'diff_ids': [
                               'sha256:' + hashlib.sha256(self.layer).hexdigest()]})
        self.config_bytes = json.dumps(self.config).encode()
        self.config_id = 'sha256:' + hashlib.sha256(self.config_bytes).hexdigest()

    def write_archive(self, path):
        config_name = self.config_id[7:] + '.json'
        manifest = [dict(Config=config_name, RepoTags=None, Layers=['layer.tar'])]
        with tarfile.open(path, 'w') as tar:
            for name, content in [('manifest.json', json.dumps(manifest).encode()),
                                  (config_name, self.config_bytes), ('layer.tar', self.layer)]:
                member = tarfile.TarInfo(name)
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))

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
                path = Path(args[args.index('--output') + 1])
                if self.export_empty:
                    path.write_bytes(b'')
                else:
                    self.write_archive(path)
                return subprocess.CompletedProcess(args, 0, '', '')
            if args[1] == 'info':
                return subprocess.CompletedProcess(args, 0, 'aarch64', '')
            if args[1] in ('run', 'exec'):
                if args[-1] == 'version':
                    output = 'v2.11.7 fixture'
                elif args[-1] == 'list-modules':
                    output = 'dns.providers.cloudflare\ndns.providers.rfc2136'
                else:
                    output = ''
                return subprocess.CompletedProcess(args, 0, output, '')
            if args[1:3] == ['container', 'inspect'] and args[-2] == '{{json .}}':
                return subprocess.CompletedProcess(args, 0, json.dumps({
                    'Config': {'Env': ['LOCAL_DOMAIN=fixture']}, 'Mounts': self.proxy_mounts}), '')
            if args[1] == 'image':
                metadata = self.image_metadata or dict(Id=self.recovery_image, Os='linux',
                                                       Architecture='arm64', Variant='', Config=self.config['config'],
                                                       RootFS={'Layers': self.config['rootfs']['diff_ids']})
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

    def test_canonical_layout(self):
        self.tx.layout.write_text(self.tx.layout.read_text().replace('HYBRID_AI_', 'HAVEN_'))
        self.tx.deploy(self.sha)
        self.assertIn('HAVEN_APP_DIR=' + str(self.tx.app), self.tx.layout.read_text())
        self.tx.accept(self.sha, self.receipt())
        self.tx.wiring(self.sha)

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

    def test_no_manual_records_required_for_migration_or_repeat(self):
        self.selection.unlink()
        self.tx.deploy(self.sha)
        self.tx.accept(self.sha, self.receipt())
        self.tx.deploy(self.sha)
        self.tx.accept(self.sha, self.receipt())
        self.assert_preserved()

    def test_mutable_selection_and_symlink_refused(self):
        self.selection.write_text('caddy:latest')
        self.assert_recovery_refused('RECOVERY_IMAGE')
        self.selection.unlink()
        self.selection.symlink_to(self.secret)
        self.assert_recovery_refused('symlink')

    def test_unexportable_and_empty_archive(self):
        self.export_missing = True
        self.assert_recovery_refused('RECOVERY_ARTIFACT')
        self.export_missing = False
        self.export_empty = True
        self.assert_recovery_refused('RECOVERY_ARTIFACT')

    def test_index_and_configuration_identity_can_differ(self):
        self.approve_recovery('sha256:' + 'd' * 64)
        self.tx.deploy(self.sha)
        recovery = self.tx.load()['proxy_recovery']
        self.assertNotEqual(recovery['recovery_image_id'], recovery['configuration_id'])
        self.assertEqual(recovery['configuration_id'], self.config_id)
        self.assert_preserved()

    def test_corrupt_layer_and_config_are_refused(self):
        for target in ('layer', 'config_bytes'):
            with self.subTest(target=target):
                self.approve_recovery()
                setattr(self, target, getattr(self, target) + b'corruption')
                self.assert_recovery_refused('RECOVERY_ARTIFACT')

    def test_incompatible_platform_config_and_layers_are_refused(self):
        base = dict(Id=self.recovery_image, Os='linux', Architecture='arm64',
                    Config=self.config['config'], RootFS={'Layers': self.config['rootfs']['diff_ids']})
        for field, value in [('Architecture', 'amd64'), ('Config', {}),
                             ('RootFS', {'Layers': ['sha256:' + 'f' * 64]})]:
            self.image_metadata = dict(base, **{field: value})
            self.assert_recovery_refused('RECOVERY_ARTIFACT')

    def test_compatibility_failures_precede_activation_and_remove_private_env(self):
        original = self.runner
        for failure in ('version', 'list-modules', 'caddyfile'):
            def runner(args, **kwargs):
                if args[0:2] == ['docker', 'run'] and args[-1] == failure:
                    raise subprocess.CalledProcessError(1, args, stderr='SYNTHETIC_PRIVATE_DETAIL')
                return original(args, **kwargs)
            self.tx.run = runner
            self.assert_recovery_refused('RECOVERY_')
            self.assertEqual(list(self.tx.state.glob('proxy-env-*')), [])

    def test_compressed_oci_layer_and_config_members(self):
        archive = self.root / 'oci.tar'
        config_name = 'blobs/sha256/' + self.config_id[7:]
        compressed = gzip.compress(self.layer)
        layer_name = 'blobs/sha256/' + hashlib.sha256(compressed).hexdigest()
        manifest = [dict(Config=config_name, Layers=[layer_name])]
        with tarfile.open(archive, 'w') as tar:
            for name, content in [('manifest.json', json.dumps(manifest).encode()),
                                  (config_name, self.config_bytes), (layer_name, compressed)]:
                member = tarfile.TarInfo(name)
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))
        metadata = dict(Os='linux', Architecture='arm64', Config=self.config['config'],
                        RootFS={'Layers': self.config['rootfs']['diff_ids']})
        self.assertEqual(self.tx.verify_archive(archive, metadata), self.config_id)
        with patch.object(MODULE.gzip, 'GzipFile', side_effect=EOFError):
            with self.assertRaisesRegex(MODULE.Refusal, 'RECOVERY_ARTIFACT'):
                self.tx.verify_archive(archive, metadata)

    def test_missing_modules_version_and_host_architecture_refuse(self):
        original = self.runner
        for failure in ('version', 'list-modules', 'info'):
            def runner(args, **kwargs):
                if ((args[:2] == ['docker', 'run'] and args[-1] == failure)
                        or args[:2] == ['docker', failure]):
                    return subprocess.CompletedProcess(args, 0, 'incompatible', '')
                return original(args, **kwargs)
            self.tx.run = runner
            self.assert_recovery_refused('RECOVERY_')

    def test_first_rollback_preserves_rendered_runtime_inputs(self):
        rendered = b'# locally rendered runtime configuration\n'
        path = self.tx.legacy / 'status/Caddyfile'
        path.write_bytes(rendered)
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertEqual(path.read_bytes(), rendered)
        self.assert_preserved()

    def test_all_seven_layers_are_verified(self):
        layers = [b'filesystem layer ' + str(i).encode() for i in range(7)]
        config = dict(self.config, rootfs=dict(type='layers', diff_ids=[
            'sha256:' + hashlib.sha256(layer).hexdigest() for layer in layers]))
        content = json.dumps(config).encode()
        config_name = hashlib.sha256(content).hexdigest() + '.json'
        names = [str(i) + '/layer.tar' for i in range(7)]
        archive = self.root / 'seven-layers.tar'
        metadata = dict(Os='linux', Architecture='arm64', Config=config['config'],
                        RootFS={'Layers': config['rootfs']['diff_ids']})
        for corrupt_last in (False, True):
            with tarfile.open(archive, 'w') as tar:
                entries = [('manifest.json', json.dumps([dict(Config=config_name, Layers=names)]).encode()),
                           (config_name, content), *zip(names, layers)]
                for name, data in entries:
                    if corrupt_last and name == names[-1]:
                        data += b'corrupt'
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
            if corrupt_last:
                with self.assertRaisesRegex(MODULE.Refusal, 'RECOVERY_ARTIFACT'):
                    self.tx.verify_archive(archive, metadata)
            else:
                self.assertEqual(self.tx.verify_archive(archive, metadata), 'sha256:' + config_name[:-5])

    def test_writable_selection_refused_and_no_environment_bypass(self):
        self.selection.chmod(0o666)
        self.assert_recovery_refused('not trusted')
        self.selection.chmod(0o600)
        self.proxy_missing = True
        with patch.dict(os.environ, HYBRID_AI_SKIP_PROXY_RECOVERY='1', CADDY_IMAGE='caddy:latest'):
            self.assert_recovery_refused('RECOVERY_IMAGE')

    def test_dns_credential_readonly_mount_and_validator_capability(self):
        token = self.tx.path('/etc/hybrid-ai/dns-token')
        token.write_text('SYNTHETIC_DNS_TOKEN')
        token.chmod(0o600)
        destination = '/run/secrets/cloudflare_dns_token'
        (self.tx.legacy / 'status/Caddyfile').write_text('dns cloudflare {file.' + destination + '}')
        self.assert_recovery_refused('RECOVERY_CONFIGURATION')
        self.proxy_mounts = [dict(Type='bind', Source=str(token), Destination=destination),
                             dict(Type='bind', Source='/var/run/docker.sock', Destination='/var/run/docker.sock')]
        token.chmod(0o644)
        self.assert_recovery_refused('RECOVERY_CONFIGURATION')
        token.chmod(0o600)
        self.tx.deploy(self.sha)
        commands = [c for c in self.calls if c[:2] == ['docker', 'run']]
        self.assertTrue(commands)
        for command in commands:
            self.assertIn('--cap-drop=ALL', command)
            self.assertIn('--cap-add=NET_BIND_SERVICE', command)
            self.assertIn('--network=none', command)
            self.assertIn('type=bind,src=' + str(token) + ',dst=' + destination + ',readonly', command)
            self.assertNotIn('/var/run/docker.sock', ' '.join(command))
            self.assertNotIn('SYNTHETIC_DNS_TOKEN', ' '.join(command))
        self.assertEqual(token.read_text(), 'SYNTHETIC_DNS_TOKEN')
        self.assertEqual(list(self.tx.state.glob('proxy-env-*')), [])
        self.assert_preserved()

    def test_inspected_configuration_id_may_differ_from_selected_index(self):
        self.approve_recovery('sha256:' + 'd' * 64)
        self.image_metadata = dict(Id=self.config_id, Os='linux', Architecture='arm64',
                                   Config=self.config['config'],
                                   RootFS={'Layers': self.config['rootfs']['diff_ids']})
        self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['proxy_recovery']['configuration_id'], self.config_id)

    def test_production_workflow_is_inert_until_explicit_activation(self):
        workflow = (Path(__file__).resolve().parent.parent /
                    '.github/workflows/deploy.yml').read_text()
        self.assertIn('default: false', workflow)
        for name in ('validate', 'deploy'):
            job = workflow.split('\n  ' + name + ':\n', 1)[1]
            condition = next(line for line in job.splitlines() if line.startswith('    if:'))
            for guard in ("github.repository == 'jimbobsyouruncle/haven'",
                          "github.ref == 'refs/heads/main'",
                          "vars.HAVEN_AUTOMATIC_DEPLOYMENT == 'enabled'",
                          "inputs.authorize_production == true", 'inputs.deployment_sha == github.sha'):
                self.assertIn(guard, condition)
        self.assertIn('    environment: production', workflow)
        self.assertIn('          ref: ${{ github.sha }}', workflow)

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
        self.assertFalse(any('pull' in c or 'load' in c for c in self.calls))

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
            self.assertEqual(args[:3], ['compose', '-p', 'haven'])
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



class IdentityTests(MigrationTests):
    def identity_fixture(self):
        # Add the candidate's real alias allowlist to the synthetic Git remote.
        helper = Path(__file__).parent / 'lib/haven-env.sh'
        target = self.remote / 'scripts/lib/haven-env.sh'
        target.parent.mkdir(parents=True)
        target.write_bytes(helper.read_bytes())
        for name in ('deploy/haven-deploy@.service', 'backup/system/haven-backup-capture.service'):
            path = self.remote / name
            path.write_text('[Service]\nExecStart=/opt/haven/install.sh\n')
        (self.remote / 'deploy/50-haven-deploy.rules').write_text('// synthetic canonical rule\n')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'identity candidate')
        self.sha = self.git(self.remote, 'rev-parse', 'HEAD')
        self.tx.identity_cutover = True
        self.tx.path('/proc/self').mkdir(parents=True, exist_ok=True)
        self.tx.path('/proc/self/mountinfo').write_text('')
        with self.tx.layout.open('a') as layout:
            layout.write('HAVEN_BACKUP_MODE=system\n')
        self.layout_before = self.tx.layout.read_bytes()
        self.accounts = {}
        self.groups = {}
        for n, name in enumerate(('hybrid-ai', 'hybrid-ai-backup', 'hybrid-ai-deploy'), 11001):
            home = self.tx.path('/var/lib/' + name)
            home.mkdir(parents=True, exist_ok=True)
            self.accounts[name] = f'{name}:x:{n}:{n}:Synthetic:{home}:/usr/sbin/nologin'
            self.groups[name] = f'{name}:x:{n}:'
        self.tx.path('/etc/passwd').write_text('\n'.join(self.accounts.values()) + '\n')
        self.tx.path('/etc/group').write_text('\n'.join(self.groups.values()) + '\n')
        for parent in ('/etc/credstore', '/etc/polkit-1/rules.d', '/etc/logrotate.d', '/var/cache'):
            self.tx.path(parent).mkdir(parents=True, exist_ok=True)
        self.tx.path('/etc/polkit-1/rules.d/50-hybrid-ai-deploy.rules').write_text('// synthetic grant\n')
        self.containers = []
        required = {'ollama': ('/root/.ollama', 'ollama_data'),
                    'open-webui': ('/app/backend/data', 'webui_data'),
                    'hermes': ('/root/.hermes', 'hermes_data'), 'proxy': ('/data', 'caddy')}
        names = {'ollama': 'ollama', 'open-webui': 'open-webui', 'hermes': 'hermes-agent',
                 'proxy': 'hybrid-ai-proxy', 'status': 'hybrid-ai-status', 'openhands': 'hybrid-ai-openhands'}
        for n, (service, name) in enumerate(names.items()):
            mounts = []
            if service in required:
                destination, relative = required[service]
                path = self.tx.path('/var/lib/hybrid-ai') / relative
                path.mkdir()
                (path / 'original').write_bytes(b'original data\x00')
                mounts.append(dict(Type='bind', Source=str(path), Destination=destination, RW=True))
            self.containers.append(dict(Id=f'{n:064x}', Name='/' + name, Image=self.running_image,
                Config={'Labels': {'com.docker.compose.project': 'hybrid-ai',
                                   'com.docker.compose.service': service}}, Mounts=mounts,
                State={'Running': True}, HostConfig={'RestartPolicy': {'Name': 'unless-stopped'}}))
        self.identity_busy = False
        self.tx.run = self.identity_runner

    def identity_runner(self, args, **kwargs):
        def result(out='', rc=0):
            if kwargs.get('check') and rc:
                raise subprocess.CalledProcessError(rc, args)
            return subprocess.CompletedProcess(args, rc, out, '')
        if args[0] == 'getent':
            entries = self.accounts if args[1] == 'passwd' else self.groups
            return result(entries.get(args[2], ''), 0 if args[2] in entries else 2)
        if args[0] == 'id':
            record = self.accounts[args[-1]].split(':')
            return result(record[3] + ' 777')
        if args[0] == 'pgrep':
            return result(rc=0 if self.identity_busy else 1)
        if args[0] in ('usermod', 'groupmod'):
            entries = self.accounts if args[0] == 'usermod' else self.groups
            old = args[-1]
            new = args[args.index('--login' if args[0] == 'usermod' else '--new-name') + 1]
            fields = entries.pop(old).split(':')
            fields[0] = new
            if args[0] == 'usermod':
                fields[5] = args[args.index('--home') + 1]
            entries[new] = ':'.join(fields)
            return result()
        if args[:3] == ['docker', 'ps', '-aq']:
            selected = self.containers
            if '--filter' in args:
                project = args[-1].split('=')[-1]
                selected = [c for c in selected if c['Config']['Labels']['com.docker.compose.project'] == project]
            return result('\n'.join(c['Id'] for c in selected))
        if args[:2] == ['docker', 'inspect']:
            return result(json.dumps([c for c in self.containers if c['Id'] in args[2:]]))
        if args[:3] == ['docker', 'network', 'inspect']:
            return result(rc=1)
        if args[:2] == ['docker', 'rm']:
            self.containers[:] = [c for c in self.containers if c['Id'] != args[2]]
            return result()
        if args[:2] in (['docker', 'update'], ['docker', 'stop']) or args[:3] == ['docker', 'network', 'create']:
            return result()
        if args[:2] == ['systemctl', 'show']:
            return result('loaded')
        if args[0] == 'systemctl' and args[1] in ('is-enabled', 'is-active'):
            return result('disabled' if args[1] == 'is-enabled' else 'inactive', 1)
        if args[0] == 'bash' and args[1].endswith('/sandbox-firewall.sh'):
            return result()
        if args[0] == 'bash' and args[1].endswith('/deploy-remote.sh'):
            self.install_env = kwargs['env']
            if self.fail_install:
                raise subprocess.CalledProcessError(4, args)
            self.containers = []
            for original in self.tx.load()['identity']['containers']:
                self.containers.append(dict(Id=original['id'],
                    Name='/' + original['name'].replace('hybrid-ai-', 'haven-', 1),
                    Config={'Labels': {'com.docker.compose.project': 'haven',
                                      'com.docker.compose.service': original['service']}},
                    Mounts=[dict(m, Source=self.tx.mapped(m['Source'])) for m in original['mounts']]))
            self.tx.path('/etc/polkit-1/rules.d/50-haven-deploy.rules').write_bytes(
                (self.tx.app / 'deploy/50-haven-deploy.rules').read_bytes())
            return result()
        return self.runner(args, **kwargs)

    def socket_fixture(self):
        import socket
        self.identity_fixture()
        self.tx.path('/run').mkdir()
        self.tx.path('/var/run').symlink_to('../run')
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(self.tx.path('/run/docker.sock')))
        self.tx.path('/run/docker.sock').chmod(0o660)
        for container in self.containers:
            service = container['Config']['Labels']['com.docker.compose.service']
            if service in ('status', 'openhands'):
                container['Mounts'].append(dict(Type='bind', Source=str(self.tx.path('/var/run/docker.sock')),
                    Destination='/var/run/docker.sock', RW=service == 'openhands'))

    def test_identity_socket_alias_migration_and_canonical_inspect_acceptance(self):
        self.socket_fixture()
        self.tx.deploy(self.sha)
        # Docker may report either spelling; only this socket is normalized.
        for container in self.containers:
            for mount in container['Mounts']:
                if mount['Destination'] == '/var/run/docker.sock':
                    mount['Source'] = str(self.tx.path('/run/docker.sock'))
        self.tx.accept(self.sha, self.receipt())
        self.assertEqual(self.tx.load()['phase'], 'accepted')

    def test_identity_socket_invalid_mapping_refuses_before_mutation(self):
        self.socket_fixture()
        _, values = self.tx.source()
        mount = self.containers[-1]['Mounts'][0]
        original = dict(mount)
        for field, value in [('Source', str(self.root / 'other.sock')),
                             ('Destination', '/other.sock'), ('Type', 'volume')]:
            with self.subTest(field=field):
                mount[field] = value
                with self.assertRaises(MODULE.Refusal):
                    self.tx.identity_preflight(values)
                mount.clear()
                mount.update(original)
        self.containers[0]['Mounts'].append(dict(original))
        with self.assertRaisesRegex(MODULE.Refusal, 'socket bind mapping'):
            self.tx.identity_preflight(values)
        self.assertFalse(self.tx.journal.exists())
        self.assert_preserved()

    def test_identity_socket_owner_parent_and_inode_drift_refuse(self):
        import socket
        self.socket_fixture()
        mount = self.containers[-1]['Mounts'][0]
        canonical = self.tx.path('/run/docker.sock')
        original_stat = Path.stat
        def wrong_owner(path, *args, **kwargs):
            info = original_stat(path, *args, **kwargs)
            if path == canonical:
                fields = list(info)
                fields[4] = self.tx.owner + 1
                return os.stat_result(fields)
            return info
        with patch.object(Path, 'stat', wrong_owner):
            with self.assertRaisesRegex(MODULE.Refusal, 'socket identity'):
                self.tx.docker_socket_bind('openhands', mount)
        canonical.parent.chmod(0o777)
        with self.assertRaisesRegex(MODULE.Refusal, 'not trusted'):
            self.tx.docker_socket_bind('openhands', mount)
        canonical.parent.chmod(0o755)
        self.tx.deploy(self.sha)
        canonical.rename(canonical.with_name('retained.sock'))
        replacement = socket.socket(socket.AF_UNIX)
        self.addCleanup(replacement.close)
        replacement.bind(str(canonical))
        canonical.chmod(0o660)
        with self.assertRaisesRegex(MODULE.Refusal, 'socket identity changed'):
            self.tx.accept(self.sha, self.receipt())

    def test_identity_socket_duplicate_destination_refuses(self):
        self.socket_fixture()
        self.containers[-1]['Mounts'].append(dict(self.containers[-1]['Mounts'][0]))
        with self.assertRaisesRegex(MODULE.Refusal, 'ambiguous'):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.journal.exists())

    def test_identity_socket_unsafe_paths_and_types_refuse(self):
        self.socket_fixture()
        _, values = self.tx.source()
        alias = self.tx.path('/var/run')
        alias.unlink()
        alias.symlink_to(self.root)
        with self.assertRaisesRegex(MODULE.Refusal, 'parent alias'):
            self.tx.identity_preflight(values)
        alias.unlink()
        alias.symlink_to('../run')
        source = self.tx.path('/run/docker.sock')
        source.chmod(0o666)
        with self.assertRaisesRegex(MODULE.Refusal, 'socket identity'):
            self.tx.identity_preflight(values)
        source.unlink()
        with self.assertRaisesRegex(MODULE.Refusal, 'missing'):
            self.tx.identity_preflight(values)
        source.write_text('not a socket')
        with self.assertRaisesRegex(MODULE.Refusal, 'socket identity'):
            self.tx.identity_preflight(values)
        source.unlink()
        source.symlink_to(self.data)
        with self.assertRaisesRegex(MODULE.Refusal, 'symlink Docker socket'):
            self.tx.identity_preflight(values)

    def test_identity_socket_exception_does_not_allow_persistent_symlinks(self):
        self.socket_fixture()
        data = self.tx.path('/var/lib/hybrid-ai/ollama_data')
        data.rename(data.with_name('real-data'))
        data.symlink_to('real-data')
        with self.assertRaisesRegex(MODULE.Refusal, 'symlink Docker bind'):
            self.tx.deploy(self.sha)
        self.assertFalse(self.tx.journal.exists())

    def test_identity_socket_forward_recovery_and_changed_identity_refusal(self):
        self.socket_fixture()
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        current = self.tx.path('/var/lib/haven/database')
        current.write_bytes(b'current writes')
        source = self.tx.path('/run/docker.sock')
        source.chmod(0o600)
        self.fail_install = False
        with self.assertRaisesRegex(MODULE.Refusal, 'socket identity changed'):
            self.tx.recover(self.sha)
        self.assertEqual(current.read_bytes(), b'current writes')
        source.chmod(0o660)
        self.tx.recover(self.sha)
        self.assertEqual(current.read_bytes(), b'current writes')
        self.containers[-1]['Mounts'][0]['RW'] = False
        with self.assertRaisesRegex(MODULE.Refusal, 'data mounts'):
            self.tx.accept(self.sha, self.receipt())

    def test_identity_migration_preserves_data_and_numeric_ids(self):
        self.identity_fixture()
        inode = self.data.stat().st_ino
        with patch.dict(os.environ, HYBRID_AI_DATA_DIR='/old/path', OPENHANDS_WORKSPACE='/old/workspace'):
            self.tx.deploy(self.sha)
        self.assertNotIn('HYBRID_AI_DATA_DIR', self.install_env)
        self.assertNotIn('OPENHANDS_WORKSPACE', self.install_env)
        journal = self.tx.load()
        self.assertEqual(journal['identity']['boundary'], 'post_activation')
        self.assertTrue(journal['writers_possible'])
        migrated = self.tx.path('/var/lib/haven/database')
        self.assertEqual(migrated.stat().st_ino, inode)
        self.assertEqual(migrated.read_bytes(), b'synthetic persistent data\x00')
        self.assertEqual(self.tx.path('/etc/haven/stack.env').read_bytes(), b'SYNTHETIC_SECRET=preserve-exact-bytes\n')
        self.assertEqual(set(self.accounts), {'haven', 'haven-backup', 'haven-deploy'})
        self.assertEqual(self.accounts['haven'].split(':')[2:4], ['11001', '11001'])
        self.assertFalse(self.tx.path('/etc/haven/hybrid-ai.env').exists())
        self.assertIn('HAVEN_DATA_DIR=' + str(self.tx.path('/var/lib/haven')), self.tx.layout.read_text())
        with self.assertRaisesRegex(MODULE.Refusal, 'writers may have started'):
            self.tx.restore(journal)
        self.tx.accept(self.sha, self.receipt())

    def test_identity_post_activation_failure_never_restores_old_controls(self):
        self.identity_fixture()
        self.fail_install = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        journal = self.tx.load()
        self.assertEqual(journal['phase'], 'recovery_required')
        self.assertTrue(self.tx.path('/etc/haven/haven.env').exists())
        self.assertFalse(self.tx.path('/etc/hybrid-ai').exists())
        current = self.tx.path('/var/lib/haven/database')
        current.write_bytes(b'new writes')
        with self.assertRaises(MODULE.Refusal):
            self.tx.restore(journal)
        self.fail_install = False
        self.tx.recover(self.sha)
        self.assertEqual(current.read_bytes(), b'new writes')
        self.assertEqual(self.tx.load()['phase'], 'awaiting_verifier')

    def test_identity_busy_account_recovers_before_activation(self):
        self.identity_fixture()
        self.identity_busy = True
        with self.assertRaisesRegex(MODULE.Refusal, 'still has writers'):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['phase'], 'rolled_back')
        self.assert_preserved()
        self.assertEqual(set(self.accounts), {'hybrid-ai', 'hybrid-ai-backup', 'hybrid-ai-deploy'})

    def test_identity_path_conflict_and_foreign_mount_refuse_before_mutation(self):
        self.identity_fixture()
        conflict = self.tx.path('/var/lib/haven')
        conflict.mkdir()
        with self.assertRaisesRegex(MODULE.Refusal, 'path conflict'):
            self.tx.deploy(self.sha)
        conflict.rmdir()
        self.containers[0]['Config']['Labels']['com.docker.compose.project'] = 'foreign'
        with self.assertRaisesRegex(MODULE.Refusal, 'foreign/duplicate'):
            self.tx.deploy(self.sha)
        self.assert_preserved()
        self.assertFalse(self.tx.journal.exists())

    def test_identity_power_loss_after_each_data_rename_recovers_by_inode(self):
        self.identity_fixture()
        _, values = self.tx.source()
        identity = self.tx.identity_preflight(values)
        self.tx.state.mkdir(mode=0o700, exist_ok=True)
        # Exercise actual filesystem renames interrupted before any publication.
        for move in identity['moves']:
            old, new = Path(move['old']), Path(move['new'])
            old.rename(new)
            self.tx.identity_restore({'identity': identity})
            self.assertEqual(old.stat().st_ino, move['inode'])
            self.assertFalse(new.exists())
        self.assert_preserved()

    def test_identity_literal_translation_and_conflicting_aliases(self):
        self.identity_fixture()
        # Translate using the real candidate helper without evaluating shell data.
        self.tx.app = self.remote
        text = 'HYBRID_AI_AUTH_COOKIE_SECRET=\'literal$(false)$$key\'\nUNRELATED=hybrid-ai\n'
        result = self.tx.translate(text)
        self.assertEqual(result, text.replace('HYBRID_AI_AUTH_COOKIE_SECRET', 'HAVEN_AUTH_COOKIE_SECRET'))
        with self.assertRaisesRegex(MODULE.Refusal, 'conflicting'):
            self.tx.translate('HYBRID_AI_AUTH_USER=one\nHAVEN_AUTH_USER=two\n')

    def test_identity_unknown_volume_and_missing_mount_refused(self):
        self.identity_fixture()
        _, values = self.tx.source()
        self.containers[0]['Mounts'][0]['Type'] = 'volume'
        with self.assertRaisesRegex(MODULE.Refusal, 'volume'):
            self.tx.identity_preflight(values)
        self.containers[0]['Mounts'][0]['Type'] = 'bind'
        self.containers[0]['Mounts'][0]['Source'] = str(self.root / 'missing')
        with self.assertRaisesRegex(MODULE.Refusal, 'missing'):
            self.tx.identity_preflight(values)

    def test_identity_account_collision_refuses(self):
        self.identity_fixture()
        self.accounts['haven'] = self.accounts['hybrid-ai'].replace('hybrid-ai', 'haven')
        with self.assertRaisesRegex(MODULE.Refusal, 'already exists'):
            self.tx.deploy(self.sha)
        self.assert_preserved()


    def test_identity_checkpoint_interruptions(self):
        self.identity_fixture()
        for event in ('account', 'configuration'):
            with self.subTest(event=event):
                original_run, original_atomic = self.tx.run, self.tx.atomic
                fired = []
                def interrupted_run(args, **kwargs):
                    result = original_run(args, **kwargs)
                    if event == 'account' and args[0] == 'usermod' and not fired:
                        fired.append(True)
                        raise SystemExit('synthetic power loss after account rename')
                    return result
                def interrupted_atomic(path, *args, **kwargs):
                    result = original_atomic(path, *args, **kwargs)
                    if event == 'configuration' and Path(path) == self.tx.path('/etc/haven/stack.env') and not fired:
                        fired.append(True)
                        raise SystemExit('synthetic power loss after config publication')
                    return result
                with patch.object(self.tx, 'run', interrupted_run), patch.object(self.tx, 'atomic', interrupted_atomic):
                    with self.assertRaises(SystemExit):
                        self.tx.deploy(self.sha)
                self.assertTrue(fired)
                self.tx.restore(self.tx.load())
                self.assert_preserved()
                self.assertEqual(set(self.accounts), {'hybrid-ai', 'hybrid-ai-backup', 'hybrid-ai-deploy'})

    def test_identity_acceptance_refuses_wrong_mounts(self):
        self.identity_fixture()
        self.tx.deploy(self.sha)
        self.containers[0]['Mounts'][0]['Source'] = str(self.root / 'replacement')
        with self.assertRaisesRegex(MODULE.Refusal, 'data mounts'):
            self.tx.accept(self.sha, self.receipt())
        self.assertEqual(self.tx.load()['phase'], 'awaiting_verifier')


    def test_identity_native_lock_exclusion_and_symlink_refusal(self):
        import fcntl
        directory = self.tx.path('/run/lock')
        directory.mkdir(parents=True)
        locks = self.tx.lock_pair()
        try:
            with self.assertRaises(BlockingIOError):
                self.tx.lock_pair()
        finally:
            for fd in locks:
                os.close(fd)
        canonical = os.open(directory / 'haven-deploy.lock', os.O_WRONLY)
        try:
            fcntl.flock(canonical, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.tx.lock_pair()
        finally:
            os.close(canonical)
        # Failed canonical acquisition released the legacy lock as well.
        locks = self.tx.lock_pair()
        for fd in locks:
            os.close(fd)
        legacy = directory / 'hybrid-ai-deploy.lock'
        legacy.unlink()
        sentinel = self.root / 'sentinel'
        sentinel.write_bytes(b'never truncate')
        legacy.symlink_to(sentinel)
        with self.assertRaises(OSError):
            self.tx.lock_pair()
        self.assertEqual(sentinel.read_bytes(), b'never truncate')


    def test_identity_absent_system_units_are_fenced_without_stop(self):
        self.identity_fixture()
        for name in ('haven-check.service', 'haven-check.timer'):
            (self.remote / 'backup' / name).write_text('[Unit]\nDescription=Synthetic optional user unit\n')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'absent system unit candidates')
        self.sha = self.git(self.remote, 'rev-parse', 'HEAD')
        original = self.tx.run
        calls = []
        def runner(args, **kwargs):
            calls.append(args)
            if args[:2] == ['systemctl', 'show']:
                return subprocess.CompletedProcess(args, 0, 'not-found', '')
            if args[:2] in (['systemctl', 'stop'], ['systemctl', 'disable']):
                raise subprocess.CalledProcessError(5, args, stderr='synthetic absent unit')
            return original(args, **kwargs)
        self.tx.run = runner
        operation = self.tx.operation
        def inspect_fence(journal, stage, item=0):
            operation(journal, stage, item)
            if stage == 'reload-fences':
                self.assertIn(b'RefuseManualStart=yes',
                    (self.tx.units / 'hybrid-ai-backup-capture.service').read_bytes())
        with patch.object(self.tx, 'operation', inspect_fence):
            self.tx.deploy(self.sha)
        self.assertTrue(self.tx.load()['writers_possible'])
        self.assertFalse(any(c[:2] in (['systemctl', 'stop'], ['systemctl', 'disable']) for c in calls))

    def test_identity_operation_failures_restore_without_starting_writers(self):
        # Late failures exercise real rename/account/control recovery; earlier
        # failures prove manager errors are not mistaken for absent units.
        for stage in ('unit-state', 'disable-timer', 'stop-service',
                      'fence-service', 'reload-fences', 'disable-container-restart',
                      'stop-container', 'check-account-writers', 'move-identity-path',
                      'rename-group', 'rename-account', 'verify-account-groups',
                      'rename-layout', 'translate-config', 'translate-backup-locator'):
            with self.subTest(stage=stage):
                if stage != 'unit-state':
                    self.tearDown()
                    self.doCleanups()
                    self.setUp()
                self.identity_fixture()
                accounts = dict(self.accounts)
                groups = dict(self.groups)
                runner = self.tx.run
                calls = []
                def recording(args, **kwargs):
                    calls.append(args)
                    return runner(args, **kwargs)
                self.tx.run = recording
                operation = self.tx.operation
                def failing(journal, name, item=0):
                    operation(journal, name, item)
                    if name == stage:
                        raise subprocess.CalledProcessError(5, ['synthetic-secret-command'],
                            output='SYNTHETIC_SECRET_OUTPUT', stderr='SYNTHETIC_SECRET_STDERR')
                log = io.StringIO()
                with patch.object(self.tx, 'operation', failing), redirect_stderr(log):
                    with self.assertRaises(subprocess.CalledProcessError):
                        self.tx.deploy(self.sha)
                journal = self.tx.load()
                self.assertEqual(journal['failure']['stage'], stage)
                self.assertEqual(journal['failure']['code'], 5)
                self.assertEqual(journal['phase'], 'rolled_back')
                self.assertEqual(journal['identity']['boundary'], 'pre_activation')
                self.assertFalse(journal.get('writers_possible'))
                self.assertEqual(self.accounts, accounts)
                self.assertEqual(self.groups, groups)
                self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
                self.assertTrue(Path(journal['failed']).is_dir())
                self.assertEqual(self.git(self.tx.legacy, 'rev-parse', 'HEAD'), journal['previous_sha'])
                self.assertFalse(any(c[:2] in (['docker', 'rm'], ['docker', 'start']) or
                                     (c[0] == 'bash' and c[1].endswith('deploy-remote.sh')) or
                                     c[:2] == ['systemctl', 'start'] for c in calls))
                self.assertIn('operation=' + stage, log.getvalue())
                self.assertNotIn('SYNTHETIC_SECRET', log.getvalue())
                self.assertNotIn('synthetic-secret-command', json.dumps(journal))
                for relative in ('ollama_data', 'webui_data', 'hermes_data', 'caddy'):
                    self.assertEqual((self.tx.path('/var/lib/hybrid-ai') / relative / 'original').read_bytes(),
                                     b'original data\x00')

    def test_identity_translation_exception_is_redacted_and_restored(self):
        self.identity_fixture()
        log = io.StringIO()
        with patch.object(self.tx, 'translate', side_effect=ValueError('SYNTHETIC_SECRET')), redirect_stderr(log):
            with self.assertRaises(ValueError):
                self.tx.deploy(self.sha)
        journal = self.tx.load()
        self.assertEqual(journal['failure'], dict(stage='translate-config', item=1, kind='internal'))
        self.assertEqual(journal['phase'], 'rolled_back')
        self.assertEqual(self.tx.layout.read_bytes(), self.layout_before)
        self.assertFalse(journal['identity']['translated'])
        self.assertNotIn('SYNTHETIC_SECRET', log.getvalue())
        self.assertNotIn('SYNTHETIC_SECRET', json.dumps(journal))

    def test_identity_rollback_failure_preserves_original_diagnostic(self):
        self.identity_fixture()
        log = io.StringIO()
        with patch.object(self.tx, 'translate', side_effect=ValueError('SYNTHETIC_SECRET')), \
                patch.object(self.tx, 'identity_restore', side_effect=OSError(5, 'PRIVATE_RECOVERY')), \
                redirect_stderr(log):
            with self.assertRaises(OSError):
                self.tx.deploy(self.sha)
        journal = self.tx.load()
        self.assertEqual(journal['failure']['stage'], 'translate-config')
        self.assertEqual(journal['rollback_failure'],
                         dict(stage='pre-activation-rollback', item=0, kind='filesystem', code=5))
        self.assertNotEqual(journal['phase'], 'rolled_back')
        self.assertFalse(journal.get('writers_possible'))
        self.assertNotIn('SYNTHETIC_SECRET', log.getvalue())
        self.assertNotIn('PRIVATE_RECOVERY', log.getvalue())
        self.assertIn('rollback incomplete', log.getvalue())

    def test_identity_absent_fence_removed_on_rollback(self):
        self.identity_fixture()
        candidate = self.remote / 'backup/haven-check.service'
        candidate.write_text('[Unit]\nDescription=Synthetic user unit\n')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'absent fence fixture')
        self.sha = self.git(self.remote, 'rev-parse', 'HEAD')
        target = self.tx.units / 'hybrid-ai-check.service'
        self.assertFalse(target.exists())
        operation = self.tx.operation
        def failing(journal, stage, item=0):
            operation(journal, stage, item)
            if stage == 'rename-layout':
                self.assertIn(b'RefuseManualStart=yes', target.read_bytes())
                raise OSError(5, 'SYNTHETIC_SECRET')
        with patch.object(self.tx, 'operation', failing), redirect_stderr(io.StringIO()):
            with self.assertRaises(OSError):
                self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['phase'], 'rolled_back')
        self.assertFalse(target.exists())
        self.assertFalse(self.tx.load().get('writers_possible'))

    def test_identity_load_state_error_is_not_absence(self):
        self.identity_fixture()
        runner = self.tx.run
        def failing(args, **kwargs):
            if args[:2] == ['systemctl', 'show']:
                raise subprocess.CalledProcessError(1, args, stderr='SYNTHETIC_SECRET')
            return runner(args, **kwargs)
        self.tx.run = failing
        with redirect_stderr(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
            self.tx.deploy(self.sha)
        self.assertEqual(self.tx.load()['failure']['stage'], 'stop-service')
        self.assertEqual(self.tx.load()['phase'], 'rolled_back')

    def test_identity_rotated_secret_blocks_pre_activation_rollback(self):
        self.identity_fixture()
        secret = self.tx.path('/etc/haven/stack.env')
        def changed_before_activation(journal):
            secret.write_bytes(b'SYNTHETIC_SECRET=rotated\n')
            raise RuntimeError('synthetic failure before activation')
        with patch.object(self.tx, 'identity_activate', changed_before_activation):
            with self.assertRaisesRegex(MODULE.Refusal, 'controls changed'):
                self.tx.deploy(self.sha)
        self.assertEqual(secret.read_bytes(), b'SYNTHETIC_SECRET=rotated\n')
        self.assertEqual(self.tx.load()['phase'], 'awaiting_verifier')
        self.assertNotIn('writers_possible', self.tx.load())
        with self.assertRaisesRegex(MODULE.Refusal, 'controls changed'):
            self.tx.restore(self.tx.load())
        self.assertFalse(self.tx.path('/etc/hybrid-ai/stack.env').exists())


    def test_identity_nested_host_mount_refuses(self):
        self.identity_fixture()
        target = self.tx.path('/var/lib/hybrid-ai/webui_data')
        self.tx.path('/proc/self/mountinfo').write_text(f'1 0 1:1 / {target} rw - tmpfs fixture rw\n')
        with self.assertRaisesRegex(MODULE.Refusal, 'nested host mount'):
            self.tx.deploy(self.sha)
        self.assert_preserved()


suite = unittest.defaultTestLoader.loadTestsFromTestCase(MigrationTests)
suite.addTests(IdentityTests(name) for name in dir(IdentityTests)
               if name.startswith('test_identity_'))
result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(not result.wasSuccessful())
PYTEST
