import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { networkInterfaces } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';

const [persona, peer, mode] = process.argv.slice(1);
const root = '/persona';
const checkout = `${root}/${persona}`;
const token = readFileSync(`${root}/repo-token-${persona}`, 'utf8').trim();
const port = id => 20000 + Number(id);
const base = id => `http://127.0.0.1:${port(id)}`;
const git = (...args) => execFileSync('git', args, { stdio: ['ignore', 'pipe', 'pipe'] }).toString();

if (mode !== 'probe') {
  if (!existsSync(`${checkout}/.git`)) {
    process.umask(0o077);
    mkdirSync(checkout, { mode: 0o700 });
    writeFileSync(`${checkout}/run.sh`, '#!/bin/sh\nprintf own-execution', { mode: 0o700 });
    git('-C', checkout, 'init');
    git('-C', checkout, 'add', 'run.sh');
    git('-C', checkout, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid.test',
      'commit', '-m', 'Synthetic persona checkout');
    git('-C', checkout, 'update-server-info');
    writeFileSync(`${root}/state-${persona}`, createHash('sha256').update(token).digest('hex'));
  }

  // Synthetic read-only Git remote grant. Only the selected repository's ref
  // advertisement is served. No general file routing, command handling or egress.
  createServer((req, res) => {
    const prefix = `/${persona}.git/`;
    const refs = req.url?.split('?')[0]?.slice(prefix.length);
    if (req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(403).end();
    } else if (req.method === 'GET' && req.url.startsWith(prefix)
      && ['HEAD', 'info/refs'].includes(refs)) {
      res.writeHead(200, { 'Content-Type': 'text/plain' })
        .end(readFileSync(`${checkout}/.git/${refs}`));
    } else {
      res.writeHead(404).end();
    }
  }).listen(port(persona), '127.0.0.1');
} else {
  assert.equal(process.getuid(), Number(persona));
  assert.equal(process.getgid(), Number(persona));
  assert.ok(process.getgroups().every(group => group === Number(persona)));
  assert.equal(statSync(root).mode & 0o777, 0o700);
  assert.equal(statSync(`${root}/repo-token-${persona}`).mode & 0o777, 0o600);
  assert.match(token, /^[a-f0-9]{64}$/);
  assert.equal(readFileSync(`${root}/state-${persona}`, 'utf8'),
    createHash('sha256').update(token).digest('hex'));
  const status = readFileSync('/proc/self/status', 'utf8');
  for (const set of ['Inh', 'Prm', 'Eff', 'Bnd', 'Amb']) {
    assert.match(status, new RegExp(`^Cap${set}:\\s+0+$`, 'm'));
  }
  assert.match(status, /^NoNewPrivs:\s+1$/m);
  assert.ok(Object.values(networkInterfaces()).flat().every(address => address.internal));
  for (const path of ['/var/run/docker.sock', '/run/podman/podman.sock',
    '/run/containerd/containerd.sock', `${root}/${peer}`, `${root}/repo-token-${peer}`, `${root}/state-${peer}`]) {
    assert.ok(!existsSync(path), 'Peer resources and host sockets must be absent');
  }
  assert.throws(() => execFileSync(`${root}/${peer}/run.sh`), { code: 'ENOENT' });
  assert.equal(execFileSync(`${checkout}/run.sh`, { encoding: 'utf8' }), 'own-execution');

  const request = (url, credential) => fetch(url, {
    headers: { Authorization: `Bearer ${credential}` },
    signal: AbortSignal.timeout(2000),
  });
  const ownRefs = `${base(persona)}/${persona}.git/info/refs`;
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      await (await request(ownRefs, token)).body?.cancel();
      break;
    } catch (error) {
      if (attempt === 29) throw error;
      await delay(200);
    }
  }
  const revision = git('-C', checkout, 'rev-parse', 'HEAD').trim();
  const refs = execFileSync('git', ['ls-remote', `${base(persona)}/${persona}.git`], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      ...process.env,
      GIT_CONFIG_COUNT: '1',
      GIT_CONFIG_KEY_0: 'http.extraHeader',
      GIT_CONFIG_VALUE_0: `Authorization: Bearer ${token}`,
    },
  });
  assert.ok(refs.includes(revision));
  assert.equal((await request(ownRefs, 'invalid')).status, 403);
  assert.equal((await request(`${base(persona)}/${peer}.git/info/refs`, token)).status, 404);
  await assert.rejects(request(`${base(peer)}/${peer}.git/info/refs`, token),
    error => error.cause?.code === 'ECONNREFUSED');
  console.log('Own checkout, persistent state, credential, execution and Git read grant passed. Peer and privilege denials passed.');
}
