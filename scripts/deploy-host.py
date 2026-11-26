#!/usr/bin/env python3
"""Reconcile the canonical Haven installation to an approved main commit."""

from contextlib import ExitStack
import fcntl
import grp
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys


class Refusal(RuntimeError):
    pass


class Deployment:
    def __init__(self, root=Path('/'), runner=subprocess.run, owner=0):
        self.root = root
        self.run = runner
        self.owner = owner
        self.app = self.path('/opt/haven')
        self.layout = self.path('/etc/haven/haven.env')
        self.keys = self.path('/var/lib/haven-deploy/.ssh/authorized_keys')
        self.remote = 'https://github.com/jimbobsyouruncle/haven.git'
        self.env = {
            'PATH': '/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin',
            'HOME': '/root',
            'USER': 'root',
            'LOGNAME': 'root',
            'HAVEN_ENV_FILE': str(self.layout),
            'GIT_TERMINAL_PROMPT': '0',
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': '/dev/null',
        }

    def lock_pair(self):
        locks = []
        try:
            for name in ('hybrid-ai-deploy.lock', 'haven-deploy.lock'):
                fd = os.open(self.path('/run/lock/' + name),
                             os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                locks.append(fd)
                info = os.fstat(fd)
                if (info.st_uid != self.owner or not stat.S_ISREG(info.st_mode)
                        or info.st_nlink != 1 or info.st_mode & 0o022):
                    raise Refusal('deployment lock is not a root-controlled regular file')
                os.fchmod(fd, 0o600)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return locks
        except BaseException:
            for fd in locks:
                os.close(fd)
            raise

    def path(self, value):
        return self.root / value.lstrip('/')


    def command(self, args, *, capture=True, **kwargs):
        return self.run(args, check=True, capture_output=capture, text=True,
                        env=self.env, **kwargs).stdout

    def git(self, directory, *args, **kwargs):
        return self.command(['git', '-c', 'core.hooksPath=/dev/null', '-c',
                             'credential.helper=', '-c', 'http.extraHeader=',
                             '-C', str(directory), *args], **kwargs)

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


    def preflight(self):
        self.trusted(self.app, tree=True)
        self.trusted(self.layout)
        self.trusted(self.keys.parents[2])
        deploy_uid = (pwd.getpwnam('haven-deploy').pw_uid
                      if self.root == Path('/') else self.owner)
        for key_path in (self.keys.parent.parent, self.keys.parent, self.keys):
            info = key_path.lstat()
            if (stat.S_ISLNK(info.st_mode) or info.st_uid not in (self.owner, deploy_uid)
                    or info.st_mode & 0o022):
                raise Refusal('restricted SSH path is not trusted')
        if not self.keys.is_file() or self.keys.stat().st_nlink != 1:
            raise Refusal('restricted SSH key file is not a standalone regular file')
        if not (self.app / '.git').is_dir():
            raise Refusal('canonical installation must be a standalone Git checkout')
        if self.git(self.app, 'config', '--get', 'remote.origin.url').strip() != self.remote:
            raise Refusal('installation origin is not the canonical public repository')
        key_lines = self.keys.read_text().splitlines()
        if (len(key_lines) != 1 or not key_lines[0].startswith(
                f'restrict,command="{self.app}/scripts/deploy-forced-command.sh" ')):
            raise Refusal('restricted SSH entry point does not select canonical Haven')
        # Use the same path/alias parser as install.sh, including default paths.
        paths = self.command(['bash', '-ec', """
          source "$1/scripts/lib/haven-env.sh" >&2
          printf '%s\n' "$HAVEN_APP_DIR" "$HAVEN_STACK_ENV_FILE" "$HAVEN_LOG_DIR" \
            "$HAVEN_DATA_DIR" "$HAVEN_WORK_DIR" "$OPENHANDS_WORKSPACE" \
            "$AGENT_REPOS_DIR" "$OPENHANDS_STATE_DIR" "$HAVEN_HERMES_HOME_DIR" \
            "$HAVEN_BACKUP_CRED_DIR"
        """, 'haven-layout', str(self.app)]).splitlines()
        if len(paths) != 10 or paths[0] != str(self.app):
            raise Refusal('layout does not select canonical Haven')
        for raw in paths[1:]:
            path = Path(raw)
            resolved = path.resolve()
            if (not path.is_absolute() or self.app in (resolved, *resolved.parents)
                    or resolved in self.app.parents):
                raise Refusal('persistent or protected path overlaps application checkout')
        stack = Path(paths[1])
        self.trusted(stack)
        if not stack.is_file() or stack.stat().st_mode & 0o077:
            raise Refusal('stack configuration must be a protected file')
        return Path(paths[2]) / 'deploy'

    def open_log(self, log_dir, sha):
        self.trusted(log_dir)
        log_dir.mkdir(mode=0o750, exist_ok=True)
        gid = grp.getgrnam('haven-deploy').gr_gid
        os.chown(log_dir, 0, gid)
        log = log_dir / (sha + '.log')
        self.trusted(log)
        with os.fdopen(os.open(log, os.O_CREAT | os.O_WRONLY
                              | os.O_NOFOLLOW, 0o640), 'w') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Refusal('deployment log must be a standalone regular file')
            os.ftruncate(stream.fileno(), 0)
            os.fchmod(stream.fileno(), 0o640)
            os.fchown(stream.fileno(), 0, gid)
            for fd in (1, 2):
                os.dup2(stream.fileno(), fd)

    def update(self, sha):
        self.git(self.app, 'fetch', '--no-tags', self.remote,
                 '+refs/heads/main:refs/remotes/origin/main')
        if self.git(self.app, 'rev-parse', 'origin/main').strip() != sha:
            raise Refusal('requested commit is no longer exact main')

        def paths(*args):
            return set(self.git(self.app, *args).split('\0')) - {''}

        generated = {'docker-compose.yml', 'status/Caddyfile'}
        untracked = paths('ls-files', '--others', '-z')
        tree = paths('ls-tree', '-r', '-z', sha)
        if any(entry.split(' ', 1)[0] not in ('100644', '100755') for entry in tree):
            raise Refusal('approved checkout contains a symlink or special file')
        incoming = {entry.split('\t', 1)[1] for entry in tree}
        untracked_dirs = {str(parent) for name in untracked for parent in Path(name).parents}
        if incoming & (untracked | untracked_dirs) or any(
                str(parent) in untracked for name in incoming for parent in Path(name).parents):
            raise Refusal('approved application tree overlaps an untracked path')

        # Keep the installed, validated render intact until the installer has
        # validated its replacement. A container restart must never pick up
        # the tracked sample configuration from an incomplete deployment.
        prior = paths('ls-tree', '-r', '--name-only', '-z', 'HEAD')
        for name in prior - incoming - generated:
            path = self.app / name
            if path.is_file():
                path.unlink()
        self.git(self.app, 'read-tree', '--reset', sha)
        changed = paths('diff-files', '--name-only', '-z') - generated
        self.git(self.app, 'checkout-index', '--force', '--stdin', '-z',
                 input=''.join(name + '\0' for name in sorted(changed)))
        self.git(self.app, 'update-ref', '--no-deref', 'HEAD', sha)
        if self.git(self.app, 'rev-parse', 'HEAD').strip() != sha:
            raise Refusal('installed checkout does not match requested SHA')
        self.trusted(self.app, tree=True)
        for name in ('backup/restore.sh', 'scripts/lib/haven-env.sh'):
            actual = self.git(self.app, 'hash-object', '--no-filters', '--', name).strip()
            expected = self.git(self.app, 'rev-parse', f'{sha}:{name}').strip()
            if actual != expected:
                raise Refusal(f'restore entry point does not match approved source: {name}')

    def deploy(self, sha, bootstrap=None):
        stage = 'lock deployment'
        try:
            with ExitStack() as stack:
                for fd in self.lock_pair():
                    stack.callback(os.close, fd)
                stage = 'verify installation layout'
                log_dir = self.preflight()
                if bootstrap is None:
                    stage = 'open deployment log'
                    self.open_log(log_dir, sha)
                stage = 'authorize requested commit'
                policy = (bootstrap or self.app) / 'scripts/deploy-provenance.py'
                self.trusted(policy)
                if bootstrap is not None:
                    self.trusted(bootstrap, tree=True)
                    if self.git(bootstrap, 'rev-parse', 'HEAD').strip() != sha:
                        raise Refusal('bootstrap checkout does not match approved SHA')
                self.command([sys.executable, '-IB', str(policy),
                              'authorize-host' if bootstrap is None else 'authorize-bootstrap', sha],
                             cwd=bootstrap or self.app, timeout=150, capture=False)
                stage = 'update application checkout'
                self.update(sha)
                stage = 'install deployment unit'
                unit = self.path('/etc/systemd/system/haven-deploy@.service')
                self.trusted(unit)
                staged_unit = unit.with_suffix('.service.haven-new')
                self.trusted(staged_unit)
                self.command(['install', '-m', '0644', str(self.app / 'deploy' / unit.name),
                              str(staged_unit)])
                staged_unit.replace(unit)
                self.command(['systemctl', 'daemon-reload'])
                stage = 'render, reconcile and verify'
                self.command(['bash', str(self.app / 'scripts/deploy-remote.sh'), sha],
                             cwd=self.app, capture=False)
                print(f'Haven deployment succeeded: {sha}', flush=True)
        except (KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
            detail = f': {error}' if isinstance(error, Refusal) else ''
            raise Refusal(f'{stage} failed{detail}') from error


def main():
    args = sys.argv[1:]
    bootstrap = len(args) == 2 and args[0] == '--bootstrap'
    if (os.geteuid() != 0 or len(args) != (2 if bootstrap else 1)
            or not re.fullmatch(r'[0-9a-f]{40}', args[-1])):
        raise Refusal('usage (as root): deploy-host.py [--bootstrap] FULL_SHA')
    os.umask(0o022)
    Deployment().deploy(args[-1], Path(__file__).resolve().parent.parent if bootstrap else None)


if __name__ == '__main__':
    try:
        main()
    except Refusal as error:
        print(f'deploy-host: {error}', file=sys.stderr)
        sys.exit(1)
