#!/usr/bin/env python3
"""Recoverable installation/identity handoff using the ADR-0006 checkpoint.

CLI is deliberately fixed to the installed FHS layout. Tests import Transaction
with a scratch root and synthetic command runner; there is no CLI path override.
"""
import base64
import fcntl
import hashlib
import gzip
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tarfile
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
        self.identity_cutover = False
        if self.path('/etc/haven/haven.env').exists():
            self.layout = self.path('/etc/haven/haven.env')
            self.keys = self.path('/var/lib/haven-deploy/.ssh/authorized_keys')
        self.project = 'haven' if self.layout.parent.name == 'haven' else 'hybrid-ai'
        # Historical archives remain at their recorded locations. Never move a
        # live lock or rewrite an old recovery journal to change its spelling.
        canonical = self.path('/var/lib/haven-install-root')
        if canonical.exists() or self.project == 'haven':
            self.state = canonical
            self.journal = self.state / 'current.json'

    def mapping(self):
        # Exact supported bootstrapped layout, not a general filesystem mover.
        return [(self.path(old), self.path(new)) for old, new in (
            ('/etc/hybrid-ai', '/etc/haven'),
            ('/etc/credstore/hybrid-ai-backup', '/etc/credstore/haven-backup'),
            ('/var/lib/hybrid-ai', '/var/lib/haven'),
            ('/var/lib/hybrid-ai-agent', '/var/lib/haven-agent'),
            ('/var/lib/hybrid-ai-repos', '/var/lib/haven-repos'),
            ('/var/lib/hybrid-ai-deploy', '/var/lib/haven-deploy'),
            ('/var/lib/hybrid-ai-backup', '/var/lib/haven-backup'),
            ('/var/log/hybrid-ai', '/var/log/haven'),
            ('/var/log/hybrid-ai-backup', '/var/log/haven-backup'),
            ('/var/log/hybrid-ai-post-deploy-verify.log', '/var/log/haven-post-deploy-verify.log'),
            ('/var/log/hybrid-ai-tls-check.log', '/var/log/haven-tls-check.log'),
            ('/var/cache/hybrid-ai-backup', '/var/cache/haven-backup'),
            ('/var/cache/hybrid-ai-backup-root', '/var/cache/haven-backup-root'))]

    def mapped(self, value):
        for old, new in self.mapping():
            if value == str(old) or value.startswith(str(old) + '/'):
                return str(new) + value[len(str(old)):]
        return value

    def mapped_literal(self, raw):
        quote = raw[0] if raw[:1] in ('"', "'") and raw[-1:] == raw[:1] else ''
        return quote + self.mapped(raw[1:-1] if quote else raw) + quote

    @staticmethod
    def installation_environment():
        # The old dispatcher exports resolved paths. Never let those exports
        # override the migrated layout and recreate empty legacy bind sources.
        derived = {'OPENHANDS_WORKSPACE', 'AGENT_REPOS_DIR', 'OPENHANDS_STATE_DIR',
                   'BACKUP_CONF_DIR', 'RESTIC_CACHE_DIR', 'BACKUP_LOG',
                   'BACKUP_CONTAINER_CONTROL', 'BACKUP_GROUP_GID'}
        return {k: v for k, v in os.environ.items()
                if k not in derived and not k.startswith(('HAVEN_', 'HYBRID_AI_'))}

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

    def translate(self, content, layout=False):
        # Known keys only; retain raw quoting, dollars and credential bytes.
        helper = (self.app / 'scripts/lib/haven-env.sh').read_text()
        aliases = set(re.findall(r'HYBRID_AI_[A-Z_]+', helper))
        path_keys = {'OPENHANDS_WORKSPACE', 'AGENT_REPOS_DIR', 'OPENHANDS_STATE_DIR',
                     'RESTIC_CACHE_DIR', 'BACKUP_LOG', 'BACKUP_CONF_DIR'}
        path_keys.update('HAVEN_' + k[10:] for k in aliases if any(
            k.endswith(s) for s in ('_DIR', '_FILE', '_LOG', '_BASE')))
        rows = []
        seen = {}
        for line in content.splitlines(keepends=True):
            match = re.fullmatch(r'([A-Z_][A-Z_0-9]*)=(.*?)(\n?)', line)
            if not match:
                rows.append(line)
                continue
            key, raw, newline = match.groups()
            key = 'HAVEN_' + key[10:] if key in aliases else key
            if key in seen and seen[key] != raw:
                raise Refusal('conflicting configuration aliases or duplicate keys')
            seen[key] = raw
            if key in path_keys:
                quote = raw[0] if raw[:1] in ('"', "'") and raw[-1:] == raw[:1] else ''
                value = raw[1:-1] if quote else raw
                value = self.mapped(value)
                if key == 'HAVEN_ENV_FILE' and value == str(self.path('/etc/haven/hybrid-ai.env')):
                    value = str(self.path('/etc/haven/haven.env'))
                raw = quote + value + quote
            if layout and key == 'HAVEN_APP_DIR':
                raw = str(self.app)
            # Only these locally built platform images change names. Never
            # translate vendor images, remote repositories, buckets or keys.
            if key in ('CADDY_IMAGE', 'AUTH_IMAGE', 'HERMES_IMAGE'):
                raw = re.sub(r'^([\"\']?)hybrid-ai-(caddy|auth|hermes):', r'\1haven-\2:', raw)
            rows.append(key + '=' + raw + newline)
        return ''.join(rows)

    def identity_preflight(self, values):
        if self.project != 'hybrid-ai':
            raise Refusal('identity cutover requires the supported legacy installation')
        if values.get('HAVEN_BACKUP_MODE', values.get('HYBRID_AI_BACKUP_MODE')) != 'system':
            raise Refusal('identity cutover requires the supported system-mode backup layout')
        # A nested host mount may follow the live rename but replay at its old
        # path on reboot. That needs an explicit mount-unit/fstab procedure.
        for line in self.path('/proc/self/mountinfo').read_text().splitlines():
            fields = line.split()
            if len(fields) < 6:
                raise Refusal('cannot establish host mount topology')
            target = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[4])
            mounted = Path(target)
            if any(mounted == old or old in mounted.parents for old, _ in self.mapping()):
                raise Refusal('nested host mount requires a reviewed persistent mount mapping')
        required = {'HYBRID_AI_DATA_DIR': '/var/lib/hybrid-ai',
                    'HYBRID_AI_LOG_DIR': '/var/log/hybrid-ai',
                    'HYBRID_AI_STACK_ENV_FILE': '/etc/hybrid-ai/stack.env',
                    'OPENHANDS_WORKSPACE': '/var/lib/hybrid-ai-agent',
                    'AGENT_REPOS_DIR': '/var/lib/hybrid-ai-repos',
                    'OPENHANDS_STATE_DIR': '/var/lib/hybrid-ai/openhands'}
        for key, expected in required.items():
            if values.get(key) != str(self.path(expected)):
                raise Refusal('unsupported identity layout; bounded mapping requires review')
        moves = []
        for old, new in self.mapping():
            self.trusted(old.parent)
            self.trusted(new.parent)
            if old.is_symlink() or new.exists() or new.is_symlink():
                raise Refusal('identity path conflict or symlink')
            if old.exists():
                info = old.stat()
                if not (old.is_dir() or old.is_file()) or info.st_dev != new.parent.stat().st_dev:
                    raise Refusal('unsupported cross-filesystem identity move')
                moves.append(dict(old=str(old), new=str(new), device=info.st_dev, inode=info.st_ino))
        # NSS must resolve the local files entry exactly. Refuse LDAP/other NSS
        # identities and collisions instead of changing their identity provider.
        accounts = []
        for old in ('hybrid-ai', 'hybrid-ai-backup', 'hybrid-ai-deploy'):
            new = old.replace('hybrid-ai', 'haven', 1)
            records = {}
            for database in ('passwd', 'group'):
                local = [line for line in self.path('/etc/' + database).read_text().splitlines()
                         if line.split(':')[0] == old]
                if len(local) != 1 or self.command(['getent', database, old]) != local[0]:
                    raise Refusal('identity accounts must be unambiguous local NSS entries')
                result = self.run(['getent', database, new], capture_output=True, text=True)
                if result.returncode != 2:
                    raise Refusal('canonical account/group already exists or NSS lookup failed')
                records[database] = local[0]
            passwd = records['passwd'].split(':')
            if passwd[5] != str(self.path('/var/lib/' + old)):
                raise Refusal('unsupported service account home')
            groups = self.command(['id', '-G', old]).split()
            if not all(group.isdecimal() for group in groups):
                raise Refusal('cannot establish numeric service group membership')
            accounts.append(dict(old=old, new=new, uid=passwd[2], gid=passwd[3],
                                 home=passwd[5], groups=sorted(groups), records=records))
        for directory in (self.units, self.path('/run/systemd/system'), self.path('/usr/lib/systemd/system')):
            for prefix in ('hybrid-ai-', 'haven-'):
                if any(directory.glob(prefix + '*.d')):
                    raise Refusal('identity unit overrides require explicit review')
        known = {p.name.replace('haven-', 'hybrid-ai-', 1)
                 for rel in ('deploy', 'backup', 'backup/system')
                 for p in (Path(__file__).resolve().parent.parent / rel).glob('*')
                 if p.suffix in ('.service', '.timer')}
        if any(p.name not in known for p in self.units.glob('hybrid-ai-*') if p.is_file()):
            raise Refusal('unknown legacy unit requires explicit review')
        if self.path('/run/hybrid-ai-backup').exists():
            # The helper's pause ledger belongs to a specific capture, not the
            # migration. Never guess whether an interrupted capture is complete.
            if any(self.path('/run/hybrid-ai-backup').iterdir()):
                raise Refusal('backup runtime state must be recovered before identity cutover')
        ids = self.command(['docker', 'ps', '-aq']).split()
        containers = json.loads(self.command(['docker', 'inspect', *ids])) if ids else []
        owned = []
        names = {'ollama': 'ollama', 'open-webui': 'open-webui', 'hermes': 'hermes-agent',
                 'proxy': self.project + '-proxy', 'status': 'hybrid-ai-status',
                 'openhands': 'hybrid-ai-openhands', 'auth': 'hybrid-ai-auth'}
        found = set()
        for container in containers:
            labels = container.get('Config', {}).get('Labels') or {}
            project = labels.get('com.docker.compose.project')
            mounts = container.get('Mounts', [])
            touches = any(self.mapped(m.get('Source', '')) != m.get('Source', '') for m in mounts)
            if project != 'hybrid-ai':
                if project == 'haven' or touches or container.get('Name', '').lstrip('/') in names.values():
                    raise Refusal('foreign/duplicate stack or external data consumer')
                continue
            service = labels.get('com.docker.compose.service')
            if service not in names or service in found or container['Name'].lstrip('/') != names[service]:
                raise Refusal('unknown or duplicate owned Docker service')
            found.add(service)
            if any(m.get('Type') != 'bind' for m in mounts):
                raise Refusal('unknown persistent Docker volume requires reviewed mapping')
            for mount in mounts:
                source = Path(mount['Source'])
                if not source.exists() or any(p.is_symlink() for p in (source, *source.parents)):
                    raise Refusal('missing or symlink Docker bind source')
                if source.is_dir() and self.mapped(str(source)) != str(source):
                    info = source.stat()
                    mount['identity'] = dict(device=info.st_dev, inode=info.st_ino)
            if not re.fullmatch(r'sha256:[a-f0-9]{64}', container.get('Image', '')):
                raise Refusal('missing immutable service image')
            owned.append(dict(id=container['Id'], service=service, image=container['Image'],
                              name=container['Name'].lstrip('/'),
                              mounts=mounts, running=container['State']['Running'],
                              restart=container['HostConfig']['RestartPolicy']))
        if not {'ollama', 'open-webui', 'hermes', 'proxy', 'status', 'openhands'} <= found:
            raise Refusal('required original Docker services are absent')
        required_mounts = {'ollama': ('/root/.ollama', '/var/lib/hybrid-ai/ollama_data'),
                           'open-webui': ('/app/backend/data', '/var/lib/hybrid-ai/webui_data'),
                           'hermes': ('/root/.hermes', '/var/lib/hybrid-ai/hermes_data'),
                           'proxy': ('/data', '/var/lib/hybrid-ai/caddy')}
        for container in owned:
            if container['service'] in required_mounts:
                target, source = required_mounts[container['service']]
                if not any(m['Destination'] == target and m['Source'] == str(self.path(source))
                           for m in container['mounts']):
                    raise Refusal('original durable mount does not match supported layout')
        return dict(moves=moves, accounts=accounts, containers=owned,
                    boundary='pre_activation', units=[], translated={})

    def identity_prepare(self, journal):
        identity = journal['identity']
        # Fence all fixed entrypoints BEFORE draining jobs or touching data.
        # The cutover runs as root through this driver, outside the deploy UID
        # and its old unit, so renaming a busy SSH login is never required.
        unit_names = sorted({p.name.replace('haven-', 'hybrid-ai-', 1)
                             for rel in ('deploy', 'backup', 'backup/system')
                             for p in (self.app / rel).glob('*.service')} |
                            {p.name.replace('haven-', 'hybrid-ai-', 1)
                             for rel in ('deploy', 'backup', 'backup/system')
                             for p in (self.app / rel).glob('*.timer')})
        for name in unit_names:
            enabled = self.run(['systemctl', 'is-enabled', name], capture_output=True, text=True)
            active = self.run(['systemctl', 'is-active', name], capture_output=True, text=True)
            identity['units'].append(dict(name=name, enabled=enabled.stdout.strip(),
                                          active=active.stdout.strip()))
        self.save(journal)
        rule = self.path('/etc/polkit-1/rules.d/50-hybrid-ai-deploy.rules')
        self.atomic(rule, b'// Legacy deploy grant fenced by Haven identity transaction.\n', 0o644)
        rotate = self.path('/etc/logrotate.d/hybrid-ai-tls')
        if rotate.exists():
            self.atomic(rotate, b'# Legacy log producer fenced by Haven identity transaction.\n', 0o644)
        for unit in identity['units']:
            if unit['name'].endswith('.timer'):
                self.command(['systemctl', 'disable', '--now', unit['name']])
        for unit in identity['units']:
            name = unit['name']
            if '@' not in name and name.endswith('.service'):
                self.command(['systemctl', 'stop', name])
            if name.endswith('.service'):
                self.atomic(self.units / name,
                            b'[Unit]\nRefuseManualStart=yes\n[Service]\nType=oneshot\nExecStart=/usr/bin/false\n', 0o644)
        self.command(['systemctl', 'daemon-reload'])
        for container in identity['containers']:
            self.command(['docker', 'update', '--restart=no', container['id']])
            self.command(['docker', 'stop', '--time', '60', container['id']])
        for account in identity['accounts']:
            result = self.run(['pgrep', '-u', account['uid']], capture_output=True, text=True)
            if result.returncode != 1:
                raise Refusal('service account still has writers; identity cutover refused')
        for move in identity['moves']:
            old, new = Path(move['old']), Path(move['new'])
            self.check_move(move, old)
            if new.exists() or new.is_symlink():
                raise Refusal('destination changed after identity preflight')
            old.rename(new)
            self.sync(old.parent)
            self.sync(new.parent)
        for account in identity['accounts']:
            self.command(['groupmod', '--new-name', account['new'], account['old']])
            self.command(['usermod', '--login', account['new'], '--home',
                          self.mapped(account['home']), account['old']])
            if sorted(self.command(['id', '-G', account['new']]).split()) != account['groups']:
                raise Refusal('numeric group membership changed during identity handoff')
        self.layout = self.path('/etc/haven/hybrid-ai.env')
        self.keys = self.path('/var/lib/haven-deploy/.ssh/authorized_keys')
        self.layout.rename(self.path('/etc/haven/haven.env'))
        self.sync(self.layout.parent)
        self.layout = self.path('/etc/haven/haven.env')
        for path in (self.layout, self.path('/etc/haven/stack.env')):
            info = path.stat()
            content = self.translate(path.read_text(), layout=path == self.layout)
            identity['translated'][str(path)] = [hashlib.sha256(path.read_bytes()).hexdigest(),
                                                hashlib.sha256(content.encode()).hexdigest()]
            self.save(journal)
            self.atomic(path, content.encode(), stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
        # r2.env is never sourced. Only its exact password-file locator changes;
        # the repository URL, access credentials and password file stay intact.
        path = self.path('/etc/credstore/haven-backup/r2.env')
        if path.exists():
            info = path.stat()
            content = re.sub(r'(?m)^RESTIC_PASSWORD_FILE=(.*)$',
                             lambda m: 'RESTIC_PASSWORD_FILE=' + self.mapped_literal(m[1]), path.read_text())
            identity['translated'][str(path)] = [hashlib.sha256(path.read_bytes()).hexdigest(),
                                                hashlib.sha256(content.encode()).hexdigest()]
            self.save(journal)
            self.atomic(path, content.encode(), stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
        self.project = 'haven'
        journal['receipt'] = self.mapped(journal['receipt'])
        self.save(journal)

    def identity_activate(self, journal):
        identity = journal['identity']
        # These networks are empty until the installer starts containers. Keep
        # legacy networks/rules for recovery; never disconnect foreign stacks.
        for name, key, internal in (('haven', 'default', False), ('haven-coder', 'coder-net', True)):
            result = self.run(['docker', 'network', 'inspect', name], capture_output=True, text=True)
            if result.returncode == 0:
                networks = json.loads(result.stdout)
                labels = networks[0].get('Labels') or {}
                if (labels.get('com.docker.compose.project') != 'haven' or
                        labels.get('com.docker.compose.network') != key or
                        networks[0].get('Containers') or networks[0].get('Internal') != internal):
                    raise Refusal('canonical network conflict before activation')
            else:
                self.command(['docker', 'network', 'create',
                              '--label', 'com.docker.compose.project=haven',
                              '--label', 'com.docker.compose.network=' + key,
                              *(['--internal'] if internal else []), name])
        firewall = str(self.app / 'scripts/sandbox-firewall.sh')
        self.command(['bash', firewall, 'apply'])
        self.command(['bash', firewall, 'check'])
        for move in identity['moves']:
            self.check_move(move, Path(move['new']))
        self.check_identity_binds(identity)
        # Write-ahead boundary. Even a crash BEFORE docker rm/up is treated as
        # possibly written: rollback must never infer the absence of new writes.
        identity['boundary'] = 'post_activation'
        journal['writers_possible'] = True
        self.save(journal)
        for container in identity['containers']:
            # Remove exact stopped owned IDs, preserving images and all binds.
            self.command(['docker', 'rm', container['id']])

    def recover(self, sha):
        journal = self.load()
        if (not journal or journal['sha'] != sha or not journal.get('writers_possible')
                or journal['phase'] not in ('activating', 'awaiting_verifier', 'recovery_required')):
            raise Refusal('no matching current-data recovery transaction')
        self.wiring(sha)
        identity = journal['identity']
        for move in identity['moves']:
            self.check_move(move, Path(move['new']))
        self.check_identity_binds(identity)
        # An interrupted removal is resolved by exact ID and ownership. Do not
        # recreate a legacy container or restore any checkpoint configuration.
        legacy_ids = self.command(['docker', 'ps', '-aq', '--filter',
                                   'label=com.docker.compose.project=hybrid-ai']).split()
        originals = {item['id'] for item in identity['containers']}
        if not set(legacy_ids) <= originals:
            raise Refusal('unexpected legacy container during forward recovery')
        for container_id in legacy_ids:
            self.command(['docker', 'stop', '--time', '60', container_id])
            self.command(['docker', 'rm', container_id])
        journal['phase'] = 'awaiting_verifier'
        self.save(journal)
        env = self.installation_environment()
        env.update(HAVEN_APP_DIR=str(self.app), HAVEN_ENV_FILE=str(self.layout),
                   HAVEN_INSTALL_ROOT_HANDOFF='1', HAVEN_VERIFY_INSTALL_ROOT='1',
                   HAVEN_IDENTITY_DRIVER='1', HAVEN_REPOSITORY_SLUG='jimbobsyouruncle/haven')
        try:
            self.run(['bash', str(self.app / 'scripts/deploy-remote.sh'), sha],
                     cwd=self.app, env=env, check=True, pass_fds=(9, 8))
        except (Exception, KeyboardInterrupt):
            journal['phase'] = 'recovery_required'
            self.save(journal)
            raise

    def verify_identity(self, journal):
        if not journal or 'identity' not in journal:
            return
        identity = journal['identity']
        if not journal.get('writers_possible'):
            raise Refusal('identity activation has not reached verification')
        for move in identity['moves']:
            self.check_move(move, Path(move['new']))
        self.check_identity_binds(identity)
        legacy = self.command(['docker', 'ps', '-aq', '--filter',
                               'label=com.docker.compose.project=hybrid-ai'])
        if legacy:
            raise Refusal('legacy Docker stack remains during identity acceptance')
        ids = self.command(['docker', 'ps', '-aq', '--filter',
                            'label=com.docker.compose.project=haven']).split()
        if not ids:
            raise Refusal('canonical Docker stack is absent')
        containers = json.loads(self.command(['docker', 'inspect', *ids]))
        expected = {c['service']: c for c in identity['containers']}
        found = set()
        for container in containers:
            labels = container.get('Config', {}).get('Labels') or {}
            service = labels.get('com.docker.compose.service')
            if labels.get('com.docker.compose.project') != 'haven' or service not in expected or service in found:
                raise Refusal('canonical Docker ownership mismatch')
            name = expected[service]['name'].replace('hybrid-ai-', 'haven-', 1)
            if container.get('Name', '').lstrip('/') != name:
                raise Refusal('canonical Docker container identity mismatch')
            found.add(service)
            before = {(self.mapped(m['Source']), m['Destination'], m['RW']) for m in expected[service]['mounts']}
            after = {(m['Source'], m['Destination'], m['RW']) for m in container['Mounts'] if m['Type'] == 'bind'}
            if before != after or len(after) != len(container['Mounts']):
                raise Refusal('canonical Docker data mounts do not match original binds')
        if found != set(expected):
            raise Refusal('canonical Docker service inventory incomplete')
        for account in identity['accounts']:
            current = self.command(['getent', 'passwd', account['new']]).split(':')
            if current[2:4] != [account['uid'], account['gid']] or current[5] != self.mapped(account['home']):
                raise Refusal('canonical service account identity mismatch')
            if sorted(self.command(['id', '-G', account['new']]).split()) != account['groups']:
                raise Refusal('canonical service group privileges changed')
        for unit in identity['units']:
            result = self.run(['systemctl', 'is-enabled', unit['name']], capture_output=True, text=True)
            if result.stdout.strip() not in ('disabled', 'masked', 'not-found', 'static'):
                raise Refusal('legacy unit is not fenced')
        rule = self.path('/etc/polkit-1/rules.d/50-haven-deploy.rules')
        self.trusted(rule)
        if rule.read_bytes() != (self.app / 'deploy/50-haven-deploy.rules').read_bytes():
            raise Refusal('canonical deployment privilege rule mismatch')
        self.command(['bash', str(self.app / 'scripts/sandbox-firewall.sh'), 'check'])

    def check_identity_binds(self, identity):
        for container in identity['containers']:
            for mount in container['mounts']:
                if 'identity' in mount:
                    self.check_move(mount['identity'], Path(self.mapped(mount['Source'])))

    @staticmethod
    def check_move(move, path):
        if path.is_symlink() or not path.exists():
            raise Refusal('identity move source missing or symlink')
        info = path.stat()
        if (info.st_dev, info.st_ino) != (move['device'], move['inode']):
            raise Refusal('identity move inode changed; recovery requires review')

    def identity_restore(self, journal):
        identity = journal['identity']
        if identity['boundary'] != 'pre_activation':
            raise Refusal('identity writers may have started; use current-data forward recovery')
        for name, digests in identity['translated'].items():
            path = Path(name)
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() not in digests:
                raise Refusal('identity controls changed; refusing stale recovery')
        # Resolve interruptions between rename and journal publication by inode,
        # never by copying old data over a destination that may have new writes.
        for account in reversed(identity['accounts']):
            result = self.run(['getent', 'passwd', account['new']], capture_output=True, text=True)
            if result.returncode == 0:
                if result.stdout.split(':')[2:4] != [account['uid'], account['gid']]:
                    raise Refusal('account numeric identity changed; recovery refused')
                self.command(['usermod', '--login', account['old'], '--home', account['home'], account['new']])
            result = self.run(['getent', 'group', account['new']], capture_output=True, text=True)
            if result.returncode == 0:
                if result.stdout.split(':')[2] != account['records']['group'].split(':')[2]:
                    raise Refusal('group numeric identity changed; recovery refused')
                self.command(['groupmod', '--new-name', account['old'], account['new']])
        renamed_layout = self.path('/etc/haven/haven.env')
        old_layout_name = self.path('/etc/haven/hybrid-ai.env')
        if renamed_layout.exists():
            if old_layout_name.exists():
                raise Refusal('conflicting layout during identity recovery')
            renamed_layout.rename(old_layout_name)
            self.sync(old_layout_name.parent)
        for move in reversed(identity['moves']):
            old, new = Path(move['old']), Path(move['new'])
            if new.exists():
                if old.exists() or old.is_symlink():
                    raise Refusal('conflicting original path during identity recovery')
                self.check_move(move, new)
                new.rename(old)
                self.sync(old.parent)
            else:
                self.check_move(move, old)
        self.layout = self.path('/etc/hybrid-ai/hybrid-ai.env')
        self.keys = self.path('/var/lib/hybrid-ai-deploy/.ssh/authorized_keys')
        self.project = 'hybrid-ai'

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
        if self.journal.exists():
            return json.loads(self.journal.read_text())
        previous = self.path('/var/lib/hybrid-ai-install-root/current.json')
        self.trusted(previous)
        return json.loads(previous.read_text()) if previous.exists() else None

    @staticmethod
    def values(content):
        values = {}
        for line in content.splitlines():
            match = re.fullmatch(r'\s*([A-Z_][A-Z_0-9]*)=(.*)', line)
            if match:
                values[match[1]] = match[2].strip('"\'')
        for old in ('HYBRID_AI_APP_DIR', 'HYBRID_AI_STACK_ENV_FILE',
                    'HYBRID_AI_DATA_DIR', 'HYBRID_AI_LOG_DIR', 'HYBRID_AI_WORK_DIR'):
            canonical = 'HAVEN_' + old.removeprefix('HYBRID_AI_')
            if old in values and canonical in values and values[old] != values[canonical]:
                raise Refusal('conflicting layout aliases')
            if canonical in values:
                values[old] = values[canonical]
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
            return self.command(args, timeout=180)
        except (OSError, subprocess.SubprocessError):
            raise Refusal(gate + ': inspection or artifact operation failed') from None

    def recovery_image(self, running):
        # Optional durable selection for a validated alternative. No per-SHA
        # approval, expiration or manual receipts. Never resolve a mutable tag.
        path = self.layout.parent / 'proxy-recovery-image'
        if path.exists() or path.is_symlink():
            self.trusted(path)
            if not path.is_file():
                raise Refusal('RECOVERY_IMAGE: selection must be a regular file')
            selected = path.read_text().strip()
        else:
            selected = running
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', selected):
            raise Refusal('RECOVERY_IMAGE: selection must be an immutable digest')
        return selected

    @staticmethod
    def verify_archive(archive, metadata):
        """Verify docker-save content without extracting or equating index/config IDs."""
        try:
            with tarfile.open(archive, 'r:') as tar:
                def read(name):
                    member = tar.getmember(name)
                    if not member.isfile():
                        raise ValueError
                    return tar.extractfile(member)

                manifests = json.load(read('manifest.json'))
                if len(manifests) != 1:
                    raise ValueError
                manifest = manifests[0]
                config_bytes = read(manifest['Config']).read()
                config_id = 'sha256:' + hashlib.sha256(config_bytes).hexdigest()
                # Docker 26 names the config <hash>.json; containerd uses blobs.
                name = manifest['Config']
                expected = name.removeprefix('blobs/sha256/').removesuffix('.json')
                if config_id != 'sha256:' + expected:
                    raise ValueError
                config = json.loads(config_bytes)
                if (config['os'] != metadata['Os']
                        or config['architecture'] != metadata['Architecture']
                        or any(config.get('config', {}).get(k) != metadata['Config'].get(k)
                               for k in set(config.get('config', {})) | set(metadata['Config']))
                        or config['rootfs']['diff_ids'] != metadata['RootFS']['Layers']):
                    raise ValueError
                layers = manifest['Layers']
                if not layers or len(layers) != len(config['rootfs']['diff_ids']):
                    raise ValueError
                for name, expected in zip(layers, config['rootfs']['diff_ids']):
                    digest = hashlib.sha256()
                    # OCI archives may retain compressed blobs. Verify the
                    # blob digest first, then the uncompressed filesystem ID.
                    with read(name) as stream:
                        prefix = stream.read(2)
                        stream.seek(0)
                        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                            digest.update(chunk)
                    if name.startswith('blobs/sha256/') and name != 'blobs/sha256/' + digest.hexdigest():
                        raise ValueError
                    if prefix == b'\x1f\x8b':
                        digest = hashlib.sha256()
                        with read(name) as stream, gzip.GzipFile(fileobj=stream) as unpacked:
                            for chunk in iter(lambda: unpacked.read(1024 * 1024), b''):
                                digest.update(chunk)
                    if 'sha256:' + digest.hexdigest() != expected:
                        raise ValueError
                return config_id
        except (OSError, EOFError, ValueError, KeyError, TypeError, tarfile.TarError):
            raise Refusal('RECOVERY_ARTIFACT: archive configuration or layer integrity mismatch') from None

    def compatible_proxy(self, recovery, source, metadata):
        running = json.loads(self.gate_command('PROXY_IDENTITY',
                            ['docker', 'container', 'inspect', '--format', '{{json .}}',
                             self.project + '-proxy']))
        if (metadata['Os'] != 'linux' or metadata['Architecture'] !=
                self.gate_command('RECOVERY_IMAGE', ['docker', 'info', '--format', '{{.Architecture}}'])
                .replace('aarch64', 'arm64').replace('x86_64', 'amd64')):
            raise Refusal('RECOVERY_IMAGE: incompatible host platform')
        caddyfile = source / 'status/Caddyfile'
        self.trusted(caddyfile)
        if not caddyfile.is_file():
            raise Refusal('RECOVERY_CONFIGURATION: installed Caddyfile unavailable')
        mounts = []
        # Match the existing TLS validator's protected credential mount, never
        # inherit arbitrary production volumes or the Docker socket.
        secrets = set(re.findall(r'\{file\.(/run/secrets/(?:cloudflare_dns_token|rfc2136_key_secret))\}',
                                 caddyfile.read_text()))
        for destination in sorted(secrets):
            candidates = [m for m in running.get('Mounts', [])
                          if m.get('Destination') == destination and m.get('Type') == 'bind']
            if len(candidates) != 1:
                raise Refusal('RECOVERY_CONFIGURATION: DNS credential bind unavailable')
            path = Path(candidates[0]['Source'])
            self.trusted(path)
            if not path.is_file() or not path.stat().st_size or path.stat().st_mode & 0o077:
                raise Refusal('RECOVERY_CONFIGURATION: DNS credential must be a private nonempty file')
            mounts += ['--mount', 'type=bind,src=' + str(path) + ',dst=' + destination + ',readonly']
        # Only the proxy's effective environment, never the entire stack's
        # credentials. The private temporary file is removed on every exit.
        fd, name = tempfile.mkstemp(prefix='proxy-env-', dir=self.state)
        try:
            with os.fdopen(fd, 'w') as stream:
                for entry in running['Config']['Env']:
                    if '\n' in entry or '\r' in entry or '=' not in entry:
                        raise Refusal('RECOVERY_CONFIGURATION: unsupported proxy environment')
                    stream.write(entry + '\n')
            base = ['docker', 'run', '--rm', '--pull=never', '--network=none',
                    '--read-only', '--cap-drop=ALL', '--cap-add=NET_BIND_SERVICE',
                    '--security-opt=no-new-privileges',
                    '--memory=128m', '--cpus=0.5', '--tmpfs', '/data', '--tmpfs', '/config',
                    '--env-file', name, '--mount',
                    'type=bind,src=' + str(caddyfile) + ',dst=/etc/caddy/Caddyfile,readonly',
                    *mounts, '--entrypoint', '/usr/bin/caddy', recovery]
            version = self.gate_command('RECOVERY_COMPATIBILITY', base + ['version'])
            current = self.gate_command('RECOVERY_COMPATIBILITY',
                       ['docker', 'exec', self.project + '-proxy', '/usr/bin/caddy', 'version'])
            if not version or not current or version.split()[0] != current.split()[0]:
                raise Refusal('RECOVERY_COMPATIBILITY: Caddy version mismatch')
            modules = self.gate_command('RECOVERY_COMPATIBILITY', base + ['list-modules']).splitlines()
            if not {'dns.providers.cloudflare', 'dns.providers.rfc2136'} <= set(modules):
                raise Refusal('RECOVERY_COMPATIBILITY: required DNS modules unavailable')
            self.gate_command('RECOVERY_CONFIGURATION', base + [
                'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
        finally:
            os.unlink(name)

    def proxy_preflight(self, source):
        project = self.gate_command('PROXY_IDENTITY', ['docker', 'container', 'inspect', '--format',
                                '{{index .Config.Labels "com.docker.compose.project"}}',
                                self.project + '-proxy'])
        if project != self.project:
            raise Refusal('PROXY_IDENTITY: existing Compose project requires owner reconciliation')
        image = self.gate_command('PROXY_IDENTITY', ['docker', 'container', 'inspect', '--format',
                              '{{.Image}}', self.project + '-proxy'])
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
            raise Refusal('PROXY_IDENTITY: cannot establish current exact proxy image')
        recovery = self.recovery_image(image)
        metadata = json.loads(self.gate_command('RECOVERY_IMAGE', ['docker', 'image', 'inspect',
                                     '--format', '{{json .}}', recovery]))
        # Inspect by immutable reference; its returned Id may be an index or
        # configuration digest. Bind the exported content via Config + RootFS.
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', metadata.get('Id', '')):
            raise Refusal('RECOVERY_IMAGE: invalid local immutable identity')
        archive, digest = self.retain_recovery(recovery)
        config_id = self.verify_archive(archive, metadata)
        self.compatible_proxy(recovery, source, metadata)
        return dict(running_image_id=image, recovery_image_id=recovery,
                    configuration_id=config_id, platform=metadata['Os'] + '/' + metadata['Architecture'],
                    archive=str(archive), archive_sha256=digest)

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
        files = [self.layout, self.keys, self.layout.parent / 'stack.env',
                 self.path('/usr/local/sbin/run-post-deploy-verify.sh')]
        files.extend(self.units.glob('hybrid-ai-*.service'))
        files.extend(self.units.glob('hybrid-ai-*.timer'))
        if self.identity_cutover:
            files.extend([self.path('/etc/polkit-1/rules.d/50-hybrid-ai-deploy.rules'),
                          self.path('/etc/polkit-1/rules.d/50-haven-deploy.rules'),
                          self.path('/etc/credstore/hybrid-ai-backup/r2.env'),
                          self.path('/etc/logrotate.d/hybrid-ai-tls'),
                          self.path('/etc/logrotate.d/haven-tls')])
        # Include absent templates too, so rollback removes only files this
        # handoff installed, never unrelated units or override directories.
        for rel in ('deploy', 'backup/system'):
            files.extend(self.units / p.name for p in (self.app / rel).glob('*')
                         if p.suffix in ('.service', '.timer'))
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
        # Persisted BEFORE any writer can be started. A lost response or crash
        # after that point cannot prove that data is still at the checkpoint.
        # Keep current data and controls for bounded forward recovery instead.
        if journal.get('writers_possible'):
            raise Refusal('writers may have started; retain current data and controls for forward recovery')
        if 'identity' in journal:
            self.identity_restore(journal)
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
        if 'identity' in journal:
            for container in journal['identity']['containers']:
                restart = container['restart']
                policy = restart['Name']
                if policy == 'on-failure' and restart.get('MaximumRetryCount'):
                    policy += ':' + str(restart['MaximumRetryCount'])
                self.command(['docker', 'update', '--restart=' + policy, container['id']])
            for unit in journal['identity']['units']:
                if unit['enabled'] == 'enabled':
                    self.command(['systemctl', 'enable', unit['name']])
            # Restoring controls is not a runtime restart. The owner explicitly
            # selects when to resume old containers/timers after inspection.
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
        prefix = self.project
        for path in self.units.glob(prefix + '-*.service'):
            if b'/opt/hybrid-ai' in path.read_bytes():
                raise Refusal('installed service still uses legacy root')

    def accept(self, sha, evidence):
        journal = self.load()
        if not journal or journal['sha'] != sha or journal['phase'] != 'awaiting_verifier':
            raise Refusal('no matching pending installation transaction')
        self.wiring(sha)
        self.verify_identity(journal)
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
        if self.identity_cutover:
            self.state = self.path('/var/lib/haven-install-root')
            self.journal = self.state / 'current.json'
        self.trusted(self.state)
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        if stat.S_IMODE(self.state.stat().st_mode) != 0o700:
            raise Refusal('RECOVERY_STORAGE: checkpoint directory must be private')
        journal = self.load()
        if journal and journal.get('writers_possible') and journal['phase'] != 'accepted':
            raise Refusal('identity transaction requires current-data recover action')
        if journal and journal['phase'] == 'activating':
            self.restore(journal)
        elif journal and journal['phase'] == 'awaiting_verifier':
            raise Refusal('previous deployment awaits verifier; inspect or explicitly roll back')
        source, values = self.source()
        identity = self.identity_preflight(values) if self.identity_cutover else None
        proxy_recovery = self.proxy_preflight(source)
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
        if identity is not None:
            journal['identity'] = identity
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
            shutil.copytree(source, legacy_previous)
            if self.git(legacy_previous, 'rev-parse', 'HEAD') != previous_sha:
                self.git(legacy_previous, 'reset', '--hard', previous_sha)
                # An old dispatcher may already have reset code. Preserve the
                # available rendered runtime inputs alongside its prior code.
                for rel in ('status/Caddyfile', 'docker-compose.yml',
                            'openhands/docker-compose.openhands.yml',
                            'hermes/docker-compose.hermes.yml'):
                    if (source / rel).is_file():
                        shutil.copy2(source / rel, legacy_previous / rel)
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
            if identity is not None:
                self.identity_prepare(journal)
            layout = self.layout.read_text()
            layout = re.sub(r'^\s*((?:HYBRID_AI|HAVEN)_APP_DIR)=.*$',
                            lambda match: match[1] + '=' + str(self.app), layout, flags=re.M)
            self.atomic(self.layout, layout.encode(), 0o644)
            key_data = self.keys.read_bytes()
            old = f'command="{source}/scripts/deploy-forced-command.sh"'.encode()
            new = f'command="{self.app}/scripts/deploy-forced-command.sh"'.encode()
            if old not in key_data:
                raise Refusal('expected restricted SSH entrypoint is absent')
            info = self.keys.stat()
            if identity is not None:
                identity['translated'][str(self.keys)] = [hashlib.sha256(key_data).hexdigest(),
                    hashlib.sha256(key_data.replace(old, new)).hexdigest()]
                self.save(journal)
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
            if identity is not None:
                self.identity_activate(journal)
            env = self.installation_environment()
            env.update(HAVEN_APP_DIR=str(self.app), HAVEN_ENV_FILE=str(self.layout),
                       HAVEN_INSTALL_ROOT_HANDOFF='1', HAVEN_VERIFY_INSTALL_ROOT='1',
                       HAVEN_IDENTITY_DRIVER='1',
                       HAVEN_REPOSITORY_SLUG='jimbobsyouruncle/haven',
                       HYBRID_AI_APP_DIR=str(self.app), HYBRID_AI_ENV_FILE=str(self.layout),
                       HYBRID_AI_INSTALL_ROOT_HANDOFF='1', HYBRID_AI_VERIFY_INSTALL_ROOT='1',
                       HYBRID_AI_REPOSITORY_SLUG='jimbobsyouruncle/haven')
            self.run(['bash', str(self.app / 'scripts/deploy-remote.sh'), sha],
                     cwd=self.app, env=env, check=True, pass_fds=((9, 8) if self.identity_cutover or self.project == 'haven' else (9,)))
            journal['active_files'] = {
                entry['path']: (hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest()
                                if Path(entry['path']).exists() else None)
                for entry in files}
            self.save(journal)
        except (Exception, KeyboardInterrupt):
            if journal.get('writers_possible'):
                journal['phase'] = 'recovery_required'
                self.save(journal)
            else:
                self.restore(journal)
            raise


def main():
    os.umask(0o022)
    actions = ('deploy', 'migrate', 'recover', 'accept', 'verify', 'rollback')
    if len(sys.argv) != 3 or sys.argv[1] not in actions \
            or not re.fullmatch(r'[0-9a-f]{40}', sys.argv[2]):
        raise Refusal('usage: install-root.py deploy|migrate|recover|accept|verify|rollback <full SHA>')
    if os.geteuid() != 0:
        raise Refusal('installation handoff requires root')
    action, sha = sys.argv[1:]
    # Fixed order, unchanged old lock inode. Open without truncation or symlink
    # following; /run/lock can be shared. Never trust inherited fd numbers.
    transaction = Transaction()
    acquired = transaction.lock_pair()
    # Preserve both descriptions even if inherited descriptors made open()
    # return 8 or 9. Never overwrite the other lock while arranging pass_fds.
    preserved = [fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 10) for fd in acquired]
    for fd in acquired:
        os.close(fd)
    for opened, fd in zip(preserved, (9, 8)):
        os.dup2(opened, fd)
        os.close(opened)
    if action == 'migrate':
        transaction.identity_cutover = True
        transaction.deploy(sha)
    elif action == 'deploy' and transaction.project != 'haven':
        raise Refusal('legacy identity needs owner-authorized migrate from reviewed driver')
    elif action == 'deploy':
        transaction.trusted(transaction.layout)
        values = transaction.values(transaction.layout.read_text())
        log_dir = Path(values['HYBRID_AI_LOG_DIR']) / 'deploy'
        transaction.trusted(log_dir)
        log_dir.mkdir(mode=0o750, exist_ok=True)
        gid = int(transaction.command(['getent', 'group', 'haven-deploy']).split(':')[2])
        os.chown(log_dir, 0, gid)
        log = log_dir / (sha + '.log')
        transaction.trusted(log)
        stream = os.open(log, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o640)
        os.fchmod(stream, 0o640)
        os.fchown(stream, 0, gid)
        os.dup2(stream, 1)
        os.dup2(stream, 2)
        os.close(stream)
        transaction.deploy(sha)
    elif action == 'rollback':
        journal = transaction.load()
        if not journal or journal['sha'] != sha or journal['phase'] not in ('activating', 'awaiting_verifier', 'accepted'):
            raise Refusal('no matching recoverable transaction')
        transaction.restore(journal)
    elif action == 'verify':
        transaction.wiring(sha)
        transaction.verify_identity(transaction.load())
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
    except BlockingIOError:
        print('::error::install-root: another operation holds the deployment lock', file=sys.stderr)
        return 3
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Never print subprocess output, control-file contents or secrets.
        print('::error::install-root: handoff refused or incomplete; inspect protected journal and recovery guidance',
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(cli())
