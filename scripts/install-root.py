#!/usr/bin/env python3
"""Recoverable code-root handoff. Host-only; never moves persistent data.

CLI is deliberately fixed to the installed FHS layout. Tests import Transaction
with a scratch root and synthetic command runner; there is no CLI path override.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


class Refusal(RuntimeError):
    """A fixed, non-sensitive diagnostic safe for deployment logs."""


class Transaction:
    def __init__(self, root=Path('/'), runner=subprocess.run, owner=0):
        self.root = Path(root)
        self.run = runner
        self.owner = owner
        self.app = self.path('/opt/haven')
        self.legacy = self.path('/opt/hybrid-ai')
        self.state = self.path('/var/lib/hybrid-ai-install-root')
        self.journal = self.state / 'current.json'
        self.layout = self.path('/etc/hybrid-ai/hybrid-ai.env')
        self.keys = self.path('/var/lib/hybrid-ai-deploy/.ssh/authorized_keys')
        self.units = self.path('/etc/systemd/system')

    def path(self, value):
        return self.root / value.lstrip('/')

    def command(self, args, **kwargs):
        # Never inherit Git config injection, askpass, SSH or credential state.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith('GIT_') and k not in ('SSH_ASKPASS',)}
        env.update(GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1',
                   GIT_CONFIG_GLOBAL='/dev/null')
        return self.run(args, check=True, capture_output=True, text=True,
                        env=env, **kwargs).stdout.strip()

    def git(self, directory, *args):
        return self.command(['git', '-c', 'core.hooksPath=/dev/null', '-c',
                             'credential.helper=', '-c', 'http.extraHeader=',
                             '-C', str(directory), *args])

    def trusted(self, path, tree=False):
        """Reject symlinks, foreign ownership and writable code/control parents."""
        path = Path(path)
        for item in [path, *path.parents]:
            if item == self.root.parent and self.root != Path('/'):
                break
            if item.is_symlink():
                raise Refusal('symlink in installation/control path')
            if item.exists():
                mode = item.stat()
                if mode.st_uid != self.owner or mode.st_mode & 0o022:
                    raise Refusal('installation/control path is not trusted')
            if item == self.root:
                break
        if tree and path.exists():
            for item in path.rglob('*'):
                mode = item.lstat()
                if stat.S_ISLNK(mode.st_mode):
                    raise Refusal('symlink in code checkout')
                if mode.st_uid != self.owner or mode.st_mode & 0o022:
                    raise Refusal('code checkout is not root controlled')

    def atomic(self, path, data, mode=0o600, uid=None, gid=None):
        path = Path(path)
        # Some SSH files belong to the deploy account; parent traversal must
        # still never follow a symlink. Do not widen any existing permissions.
        for item in [path, *path.parents]:
            if item.is_symlink():
                raise Refusal('symlink in control path')
        fd, name = tempfile.mkstemp(prefix='.haven-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fchmod(stream.fileno(), mode)
                if uid is not None:
                    os.fchown(stream.fileno(), uid, gid)
                os.fsync(stream.fileno())
            os.replace(name, path)
            self.sync(path.parent)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    @staticmethod
    def sync(directory):
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def save(self, journal):
        self.atomic(self.journal, json.dumps(journal).encode())

    def load(self):
        self.trusted(self.state, tree=True)
        return json.loads(self.journal.read_text()) if self.journal.exists() else None

    @staticmethod
    def values(content):
        values = {}
        for line in content.splitlines():
            match = re.fullmatch(r'\s*([A-Z_][A-Z_0-9]*)=(.*)', line)
            if match:
                values[match[1]] = match[2].strip('"\'')
        return values

    def source(self):
        self.trusted(self.layout)
        values = self.values(self.layout.read_text())
        source = Path(values.get('HYBRID_AI_APP_DIR', ''))
        if source not in (self.legacy, self.app):
            raise Refusal('layout must name a supported installation root')
        self.trusted(source, tree=True)
        if not (source / '.git').is_dir():
            raise Refusal('installation is not a standalone Git checkout')
        origin = self.git(source, 'config', '--get', 'remote.origin.url')
        if origin not in ('https://github.com/jimbobsyouruncle/haven.git',
                          'https://github.com/jimbobsyouruncle/hybrid-ai.git'):
            raise Refusal('installation origin is not an approved public repository')
        # A normal bootstrapped deployment has external FHS storage. Do not
        # silently create empty databases by changing a repository-relative default.
        for key in ('HYBRID_AI_STACK_ENV_FILE', 'HYBRID_AI_DATA_DIR',
                    'HYBRID_AI_LOG_DIR', 'HYBRID_AI_WORK_DIR',
                    'OPENHANDS_WORKSPACE', 'AGENT_REPOS_DIR', 'OPENHANDS_STATE_DIR'):
            value = Path(values.get(key, ''))
            if not value.is_absolute() or any(
                    value.resolve() == p or p in value.resolve().parents
                    for p in (self.app, self.legacy)) or any(
                    value == p or p in value.parents for p in (self.app, self.legacy)):
                raise Refusal('layout requires separate persistent-path preparation')
        # Overrides that execute from the old checkout could bypass our handoff.
        for directory in (self.units, self.path('/run/systemd/system'),
                          self.path('/usr/lib/systemd/system')):
            for override in directory.glob('hybrid-ai-*.service.d/*.conf'):
                self.trusted(override)
                content = override.read_text()
                if '/opt/hybrid-ai' in content or re.search(
                        r'^\s*(ExecStart|WorkingDirectory|RootDirectory|EnvironmentFile)=', content, re.M):
                    raise Refusal('legacy path in systemd override requires owner review')
        self.trusted(self.app)
        if source == self.legacy and self.app.exists():
            raise Refusal('conflicting canonical directory; manual reconciliation required')
        return source, values

    def gate_command(self, gate, args):
        try:
            return self.command(args)
        except (OSError, subprocess.CalledProcessError):
            raise Refusal(gate + ': inspection or artifact operation failed') from None

    def protected_json(self, path, gate):
        try:
            self.trusted(path)
            mode = path.stat()
            if not stat.S_ISREG(mode.st_mode) or stat.S_IMODE(mode.st_mode) != 0o600:
                raise ValueError
            value = json.loads(path.read_text())
            if not isinstance(value, dict):
                raise ValueError
            return value
        except (OSError, ValueError, Refusal):
            raise Refusal(gate + ': missing or untrusted protected record') from None

    def recovery_approval(self, sha, source, image):
        # Fixed root-owned files, never a CLI/env/SSH flag. Root records the
        # owner's decision only after separately authorized compatibility work.
        directory = self.path('/etc/hybrid-ai/install-root-approvals')
        approval_path = directory / (sha + '.json')
        evidence_path = directory / (sha + '.evidence.json')
        approval = self.protected_json(approval_path, 'RECOVERY_APPROVAL')
        evidence = self.protected_json(evidence_path, 'RECOVERY_COMPATIBILITY')
        now = int(time.time())
        issued, expires = approval.get('approved_at'), approval.get('expires_at')
        if (approval.get('schema_version') != 1
                or approval.get('decision') != 'approve-install-root-deployment-and-proxy-recovery'
                or approval.get('requested_sha') != sha
                or not isinstance(issued, int) or isinstance(issued, bool)
                or not isinstance(expires, int) or isinstance(expires, bool)
                or not issued <= now < expires <= issued + 86400
                or approval.get('evidence_sha256') != hashlib.sha256(evidence_path.read_bytes()).hexdigest()):
            raise Refusal('RECOVERY_APPROVAL: decision, revision, evidence or validity mismatch')
        recovery = evidence.get('recovery_image_id', '')
        if (evidence.get('schema_version') != 1 or evidence.get('running_image_id') != image
                or not isinstance(recovery, str)
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', recovery)):
            raise Refusal('RECOVERY_COMPATIBILITY: immutable image identities do not match')
        # Bind validation to the currently installed runtime inputs. Hashes
        # stay protected: even a secret-file hash must not enter CI output.
        paths = {'caddyfile': source / 'status/Caddyfile',
                 'compose': source / 'docker-compose.yml',
                 'stack_env': self.path('/etc/hybrid-ai/stack.env')}
        hashes = {}
        for name, path in paths.items():
            try:
                self.trusted(path)
                hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            except (OSError, Refusal):
                raise Refusal('RECOVERY_CONFIGURATION: unavailable or untrusted input') from None
        checks = evidence.get('checks')
        if (evidence.get('configuration_sha256') != hashes
                or not isinstance(checks, dict)
                or set(checks) != {'caddy_version', 'dns_modules', 'config_validation',
                                   'platform', 'recovery_procedure'}
                or any(not isinstance(check, dict) or check.get('state') != 'PASS'
                       or not isinstance(check.get('receipt_sha256'), str)
                       or not re.fullmatch(r'[0-9a-f]{64}', check['receipt_sha256'])
                       for check in checks.values())):
            raise Refusal('RECOVERY_COMPATIBILITY: configuration or mandatory evidence mismatch')
        return recovery, evidence, hashlib.sha256(approval_path.read_bytes()).hexdigest()

    def proxy_preflight(self, sha, source):
        project = self.gate_command('PROXY_IDENTITY', ['docker', 'container', 'inspect', '--format',
                                '{{index .Config.Labels "com.docker.compose.project"}}',
                                'hybrid-ai-proxy'])
        if project != 'hybrid-ai':
            raise Refusal('PROXY_IDENTITY: existing Compose project requires owner reconciliation')
        image = self.gate_command('PROXY_IDENTITY', ['docker', 'container', 'inspect', '--format',
                              '{{.Image}}', 'hybrid-ai-proxy'])
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
            raise Refusal('PROXY_IDENTITY: cannot establish current exact proxy image')
        # .Image is the running immutable ID. .Config.Image/RepoTags are only
        # mutable references and cannot establish recovery equivalence.
        recovery, evidence, approval_hash = self.recovery_approval(sha, source, image)
        metadata = self.gate_command('RECOVERY_IMAGE', ['docker', 'image', 'inspect',
                                     '--format', '{{json .}}', recovery])
        try:
            metadata = json.loads(metadata)
            platform = '/'.join(metadata[k] for k in ('Os', 'Architecture'))
            if metadata.get('Variant'):
                platform += '/' + metadata['Variant']
            if metadata['Id'] != recovery or platform != evidence.get('platform'):
                raise ValueError
        except (ValueError, KeyError, TypeError):
            raise Refusal('RECOVERY_IMAGE: immutable identity or validated platform mismatch') from None
        # Inspect alone does not demonstrate layer availability. Save by ID to
        # a unique protected checkpoint, both testing exportability and keeping
        # recovery independent of later tag changes/builds/pruning. Never clean
        # up successful archives automatically, including on rollback.
        archive, digest = self.retain_recovery(recovery)
        return dict(running_image_id=image, recovery_image_id=recovery,
                    platform=platform, archive=str(archive), archive_sha256=digest,
                    approval_sha256=approval_hash)

    def retain_recovery(self, recovery):
        archive = self.state / ('proxy-recovery-' + uuid.uuid4().hex + '.tar')
        try:
            fd = os.open(archive, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            self.gate_command('RECOVERY_ARTIFACT', ['docker', 'image', 'save',
                                                 '--output', str(archive), recovery])
            if not archive.is_file() or archive.stat().st_size == 0:
                raise Refusal('RECOVERY_ARTIFACT: recovery export is empty or unavailable')
            archive.chmod(0o600)
            with archive.open('rb') as stream:
                os.fsync(stream.fileno())
                checksum = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    checksum.update(chunk)
            self.sync(self.state)
            return archive, checksum.hexdigest()
        except OSError:
            raise Refusal('RECOVERY_ARTIFACT: cannot retain durable recovery export') from None

    def snapshots(self):
        files = [self.layout, self.keys, self.path('/etc/hybrid-ai/stack.env'),
                 self.path('/usr/local/sbin/run-post-deploy-verify.sh')]
        files.extend(self.units.glob('hybrid-ai-*.service'))
        # Include absent templates too, so rollback removes only files this
        # handoff installed, never unrelated units or override directories.
        for rel in ('deploy', 'backup/system'):
            files.extend(self.units / p.name for p in (self.app / rel).glob('*.service'))
        result = []
        for path in sorted(set(files)):
            for item in [path, *path.parents]:
                if item.is_symlink():
                    raise Refusal('symlink in control file path')
            entry = {'path': str(path), 'data': None}
            if path.exists():
                mode = path.stat()
                if not stat.S_ISREG(mode.st_mode):
                    raise Refusal('control file is not regular')
                entry.update(data=base64.b64encode(path.read_bytes()).decode(),
                             mode=stat.S_IMODE(mode.st_mode), uid=mode.st_uid, gid=mode.st_gid)
            result.append(entry)
        return result

    def restore(self, journal):
        if journal['phase'] == 'accepted':
            # Later owner edits/rotations must never be overwritten by a stale
            # checkpoint. A different active revision also needs reconciliation.
            self.wiring(journal['sha'])
            for name, digest in journal.get('active_files', {}).items():
                path = Path(name)
                current = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
                if current != digest:
                    raise Refusal('control files changed since deployment; review rollback first')
        # Intent is written before every rename; existence resolves a crash
        # between the rename and its journal update. Nothing is deleted here.
        previous = Path(journal['previous'])
        stage = Path(journal['stage'])
        failed = Path(journal['failed'])
        if journal['source'] == str(self.legacy):
            legacy_previous = Path(journal['legacy_previous'])
            if legacy_previous.exists():
                legacy_failed = Path(journal['legacy_failed'])
                if self.legacy.exists():
                    if legacy_failed.exists():
                        raise Refusal('conflicting legacy checkpoint during recovery')
                    self.legacy.rename(legacy_failed)
                legacy_previous.rename(self.legacy)
        if previous.exists():
            if self.app.exists():
                if failed.exists():
                    raise Refusal('conflicting failed checkout during recovery')
                self.app.rename(failed)
            previous.rename(self.app)
        elif journal['source'] == str(self.legacy) and self.app.exists() and not stage.exists():
            if failed.exists():
                raise Refusal('conflicting failed checkout during recovery')
            self.app.rename(failed)
        for entry in journal['files']:
            path = Path(entry['path'])
            if entry['data'] is None:
                if path.is_symlink():
                    raise Refusal('symlink in rollback control path')
                if path.exists():
                    path.unlink()  # newly installed control file only, never data
            else:
                self.atomic(path, base64.b64decode(entry['data']),
                            entry['mode'], entry['uid'], entry['gid'])
        self.sync(self.app.parent)
        self.command(['systemctl', 'daemon-reload'])
        journal['phase'] = 'rolled_back'
        self.save(journal)

    def wiring(self, sha):
        self.trusted(self.app, tree=True)
        self.trusted(self.layout)
        values = self.values(self.layout.read_text())
        if values.get('HYBRID_AI_APP_DIR') != str(self.app):
            raise Refusal('layout does not select canonical root')
        if self.git(self.app, 'rev-parse', 'HEAD') != sha:
            raise Refusal('canonical root does not contain requested SHA')
        if f'command="{self.app}/scripts/deploy-forced-command.sh"' not in self.keys.read_text():
            raise Refusal('SSH forced command does not select canonical root')
        for path in self.units.glob('hybrid-ai-*.service'):
            if b'/opt/hybrid-ai' in path.read_bytes():
                raise Refusal('installed service still uses legacy root')

    def accept(self, sha, evidence):
        journal = self.load()
        if not journal or journal['sha'] != sha or journal['phase'] != 'awaiting_verifier':
            raise Refusal('no matching pending installation transaction')
        self.wiring(sha)
        receipt = Path(journal['receipt'])
        if receipt.is_symlink() or receipt.stat().st_mtime_ns < journal['started_ns']:
            raise Refusal('verification receipt is stale or untrusted')
        # Evidence is supplied on stdin by the root verifier, not read back
        # from the service-account-owned public receipt (which is untrusted).
        gates = evidence.get('gates', {})
        if (evidence.get('schema_version') != 2 or evidence.get('sha') != sha
                or evidence.get('head') != sha or evidence.get('app_dir') != str(self.app)
                or evidence.get('rc') != 0 or evidence.get('verdict') not in ('PASS', 'WARN')
                or not all(gates.get(k, {}).get('state') == 'PASS' for k in
                           ('workflow_runs', 'deployed_head', 'installation_root', 'runtime_health'))
                or any(g.get('state') != 'PASS' for g in gates.values() if g.get('required'))):
            raise Refusal('requested SHA or mandatory verification gates are unsuccessful')
        journal['phase'] = 'accepted'
        self.save(journal)

    def deploy(self, sha):
        self.trusted(self.state)
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        if stat.S_IMODE(self.state.stat().st_mode) != 0o700:
            raise Refusal('RECOVERY_STORAGE: checkpoint directory must be private')
        journal = self.load()
        if journal and journal['phase'] == 'activating':
            self.restore(journal)
        elif journal and journal['phase'] == 'awaiting_verifier':
            raise Refusal('previous deployment awaits verifier; inspect or explicitly roll back')
        source, values = self.source()
        proxy_recovery = self.proxy_preflight(sha, source)
        sha_before = self.git(source, 'rev-parse', 'HEAD')
        token = uuid.uuid4().hex
        stage = self.app.parent / ('.haven-stage-' + token)
        previous = self.app.parent / ('.haven-previous-' + token)
        self.trusted(self.app.parent)
        stage.mkdir(mode=0o755)
        self.git(stage, 'init', '--quiet')
        remote = 'https://github.com/jimbobsyouruncle/haven.git'
        self.git(stage, 'remote', 'add', 'origin', remote)
        self.git(stage, 'fetch', '--no-tags', remote,
                 '+refs/heads/main:refs/remotes/origin/main')
        self.git(stage, 'merge-base', '--is-ancestor', sha, 'origin/main')
        self.git(stage, 'checkout', '--quiet', '--detach', sha)
        if self.git(stage, 'rev-parse', 'HEAD') != sha:
            raise Refusal('staged checkout does not match requested SHA')
        self.git(stage, 'merge-base', '--is-ancestor', sha_before, 'origin/main')
        self.trusted(stage, tree=True)
        for name in ('install.sh', 'scripts/deploy-remote.sh', 'scripts/install-root.py'):
            if not (stage / name).is_file():
                raise Refusal('staged checkout lacks mandatory deployment files')
        # Keep a historical record rather than overwrite earlier rollback evidence.
        if self.journal.exists():
            self.atomic(self.state / (token + '.json'), self.journal.read_bytes())
        # Snapshot all candidate unit destinations before its directory is renamed.
        files = self.snapshots()
        for rel in ('deploy', 'backup/system'):
            for unit in (stage / rel).glob('*.service'):
                target = self.units / unit.name
                if not any(f['path'] == str(target) for f in files):
                    files.append({'path': str(target), 'data': None})
        journal = dict(phase='activating', sha=sha, started_ns=time.time_ns(),
                       proxy_recovery=proxy_recovery,
                       source=str(source), previous=str(previous), stage=str(stage),
                       failed=str(self.app.parent / ('.haven-failed-' + token)),
                       previous_sha=sha_before, files=files,
                       receipt=str(Path(values['HYBRID_AI_DATA_DIR']) /
                                   'hermes_data/deploy-verdicts' / (sha + '.json')))
        if source == self.legacy:
            if sha_before == sha:
                try:
                    journal['previous_sha'] = self.git(source, 'rev-parse', 'ORIG_HEAD')
                except subprocess.CalledProcessError:
                    pass
            # An older installed dispatcher has already reset the legacy tree.
            # Retain an independent checkout of the pre-reset revision too,
            # never relying solely on the now-updated legacy code directory.
            previous_sha = journal['previous_sha']
            if not re.fullmatch(r'[0-9a-f]{40}', previous_sha):
                raise Refusal('previous revision could not be established')
            self.git(stage, 'merge-base', '--is-ancestor', previous_sha, 'origin/main')
            legacy_previous = self.app.parent / ('.haven-legacy-previous-' + token)
            shutil.copytree(stage, legacy_previous)
            self.git(legacy_previous, 'reset', '--hard', previous_sha)
            if self.git(legacy_previous, 'rev-parse', 'HEAD') != previous_sha:
                raise Refusal('legacy recovery checkout revision mismatch')
            self.trusted(legacy_previous, tree=True)
            journal.update(legacy_previous=str(legacy_previous),
                           legacy_failed=str(self.app.parent / ('.haven-legacy-failed-' + token)))
        self.save(journal)
        try:
            if source == self.app:
                self.app.rename(previous)
                self.sync(self.app.parent)
            stage.rename(self.app)
            self.sync(self.app.parent)
            layout = self.layout.read_text()
            layout = re.sub(r'^\s*HYBRID_AI_APP_DIR=.*$',
                            'HYBRID_AI_APP_DIR=' + str(self.app), layout, flags=re.M)
            self.atomic(self.layout, layout.encode(), 0o644)
            key_data = self.keys.read_bytes()
            old = f'command="{source}/scripts/deploy-forced-command.sh"'.encode()
            new = f'command="{self.app}/scripts/deploy-forced-command.sh"'.encode()
            if old not in key_data:
                raise Refusal('expected restricted SSH entrypoint is absent')
            info = self.keys.stat()
            self.atomic(self.keys, key_data.replace(old, new),
                        stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
            # Install all code-path-bearing units before the next invocation.
            for rel in ('deploy', 'backup/system'):
                for unit in (self.app / rel).glob('*.service'):
                    if '__REPO_DIR__' in unit.read_text():
                        data = unit.read_text().replace('__REPO_DIR__', str(self.app)).encode()
                    else:
                        data = unit.read_bytes()
                    self.atomic(self.units / unit.name, data, 0o644)
            self.command(['systemctl', 'daemon-reload'])
            self.wiring(sha)
            # The waiter must see this state even if it executes immediately.
            journal['phase'] = 'awaiting_verifier'
            self.save(journal)
            env = os.environ.copy()
            env.update(HYBRID_AI_APP_DIR=str(self.app), HYBRID_AI_ENV_FILE=str(self.layout),
                       HYBRID_AI_INSTALL_ROOT_HANDOFF='1', HYBRID_AI_VERIFY_INSTALL_ROOT='1',
                       HYBRID_AI_REPOSITORY_SLUG='jimbobsyouruncle/haven')
            self.run(['bash', str(self.app / 'scripts/deploy-remote.sh'), sha],
                     cwd=self.app, env=env, check=True, pass_fds=(9,))
            journal['active_files'] = {
                entry['path']: (hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest()
                                if Path(entry['path']).exists() else None)
                for entry in files}
            self.save(journal)
        except (Exception, KeyboardInterrupt):
            self.restore(journal)
            raise


def main():
    os.umask(0o022)
    if len(sys.argv) != 3 or sys.argv[1] not in ('deploy', 'accept', 'verify', 'rollback') \
            or not re.fullmatch(r'[0-9a-f]{40}', sys.argv[2]):
        raise Refusal('usage: install-root.py deploy|accept|verify|rollback <full SHA>')
    if os.geteuid() != 0:
        raise Refusal('installation handoff requires root')
    # A separate open of the SAME lock also serializes verifier acceptance and
    # operator rollback. Deploy inherits fd 9 from the root dispatcher.
    action, sha = sys.argv[1:]
    if action == 'deploy':
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
    else:
        lock = os.open('/run/lock/hybrid-ai-deploy.lock', os.O_CREAT | os.O_WRONLY, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    transaction = Transaction()
    if action == 'rollback':
        journal = transaction.load()
        if not journal or journal['sha'] != sha or journal['phase'] not in ('activating', 'awaiting_verifier', 'accepted'):
            raise Refusal('no matching recoverable transaction')
        transaction.restore(journal)
    elif action == 'verify':
        transaction.wiring(sha)
    elif action == 'accept':
        transaction.accept(sha, json.load(sys.stdin))
    else:
        getattr(transaction, action)(sha)


def cli():
    try:
        main()
    except Refusal as error:
        print('::error::install-root: ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        # Never print subprocess output, control-file contents or secrets.
        print('::error::install-root: handoff refused or incomplete; inspect protected journal and recovery guidance',
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(cli())
