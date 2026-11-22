#!/usr/bin/env bash
# Exercise the pinned ARM64 Canvas bundle with synthetic data and no host access.
set -euo pipefail

image=ghcr.io/openhands/agent-canvas@sha256:c349868d301e879a50da45f7f51e3c1f5f2814c8265b4a8ef8979d115956f59c
if ! command -v podman >/dev/null; then
  echo "Canvas smoke test requires local rootless Podman on ARM64." >&2
  exit 1
fi
if [[ $(uname -m) != aarch64 || $(podman --remote=false info --format '{{.Host.Security.Rootless}}') != true ]]; then
  echo "Canvas smoke test requires local rootless Podman on ARM64." >&2
  exit 1
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
caddy_image=$(awk '/^FROM caddy@sha256:/ { image=$2 } END { print image }' "$repo_root/caddy/Dockerfile")
auth_image=localhost/haven-canvas-auth-fixture
if [[ ${1:-} == --pull && $# == 1 ]]; then
  podman --remote=false pull --platform linux/arm64 "$image"
  podman --remote=false pull --platform linux/arm64 "$caddy_image"
  podman --remote=false build --tag "$auth_image" "$repo_root/auth"
elif (( $# != 0 )); then
  echo "Usage: $0 [--pull]" >&2
  exit 2
fi

api_key=$(openssl rand -hex 32)
fixture=$(mktemp -d)
container=
auth_container=
caddy_container=
cleanup() {
  for id in "$caddy_container" "$auth_container" "$container"; do
    if [[ -n $id ]]; then
      podman --remote=false stop --time 5 "$id" >/dev/null 2>&1 || true
    fi
  done
  podman --remote=false unshare rm -rf -- "$fixture"
}
trap cleanup EXIT
install -d -m 0700 "$fixture/developer" "$fixture/peer"
printf 'synthetic peer state\n' >"$fixture/peer/peer-state"
openssl rand -hex 32 >"$fixture/developer/repo-token"
chmod 0600 "$fixture/developer/repo-token"
container=$(podman --remote=false run --detach --rm --pull=never \
  --platform linux/arm64 --network none --http-proxy=false \
  --cap-drop ALL --security-opt no-new-privileges --image-volume=ignore \
  --log-driver=none --memory=3g --cpus=2.5 --pids-limit=512 \
  --volume "$fixture/developer:/persona:rw,U,Z" \
  --env "OH_SESSION_API_KEYS_0=$api_key" --env AGENT_CANVAS_DISABLE_TELEMETRY=1 \
  --env AGENT_SERVER_PORT=18000 \
  "$image")
[[ $(podman --remote=false inspect --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{end}}' "$container") == "$fixture/developer:/persona" ]]
pid=$(podman --remote=false inspect --format '{{.State.Pid}}' "$container")
read -r uid gid <<<"$(ps -o euid=,egid= -p "$pid")"
[[ $uid != 0 && $gid != 0 ]]
[[ $(stat -c '%u:%g' "$fixture/developer") == "$uid:$gid" ]]

cookie_secret=$(openssl rand -hex 32)
peer_flags=(--detach --rm --pull=never --network "container:$container"
  --http-proxy=false --cap-drop ALL --security-opt no-new-privileges --log-driver=none)
auth_container=$(podman --remote=false run "${peer_flags[@]}" \
  --env HAVEN_AUTH_USER=canvas-fixture --env HAVEN_AUTH_HASH=fixture-unused \
  --env "HAVEN_AUTH_COOKIE_SECRET=$cookie_secret" --env TLS_DOMAIN=canvas.invalid "$auth_image")
# Reuse the configured Caddy runtime and production forward_auth contract.
# Container networking is disabled apart from the shared fixture loopback.
canvas_password=$(openssl rand -hex 32)
canvas_hash=$(podman --remote=false exec --env "CANVAS_PASSWORD=$canvas_password" "$auth_container" \
  python3 -c 'import bcrypt,os; print(bcrypt.hashpw(os.environ["CANVAS_PASSWORD"].encode(), bcrypt.gensalt()).decode())')
# Caddy expands its environment placeholder when it loads this config.
# shellcheck disable=SC2016
caddy_config='{
  admin off
  auto_https off
}
:9081 {
  route {
    forward_auth localhost:8080 {
      uri /verify
    }
    basic_auth {
      canvas-fixture {$CANVAS_PASSWORD_HASH}
    }
    reverse_proxy localhost:8000 {
      header_up -Authorization
      header_up -Cookie
    }
  }
}'
caddy_container=$(podman --remote=false run "${peer_flags[@]}" \
  --user 1000:1000 --entrypoint /bin/sh --env XDG_CONFIG_HOME=/tmp --env XDG_DATA_HOME=/tmp \
  --env "CANVAS_PASSWORD_HASH=$canvas_hash" \
  --env "FIXTURE_CADDYFILE=$caddy_config" "$caddy_image" \
  -ec 'printf "%s\n" "$FIXTURE_CADDYFILE" >/tmp/Caddyfile; exec caddy run --config /tmp/Caddyfile')
cookie=$(podman --remote=false exec "$auth_container" python3 -c \
  'import os,time,app; print(app.COOKIE_NAME+"="+app.sign_expiry(os.environ["HAVEN_AUTH_COOKIE_SECRET"].encode(), time.time()+300))')


podman --remote=false exec -i --env "FIXTURE_COOKIE=$cookie" \
  --env "CANVAS_PASSWORD=$canvas_password" "$container" node --input-type=module - <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, statSync } from 'node:fs';
import { request } from 'node:http';
import { networkInterfaces } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';

assert.notEqual(process.getuid(), 0, 'Agent image must run as non-root');
const status = readFileSync('/proc/self/status', 'utf8');
for (const set of ['Inh', 'Prm', 'Eff', 'Bnd', 'Amb']) {
  assert.match(status, new RegExp(`^Cap${set}:\\s+0+$`, 'm'));
}
assert.match(status, /^NoNewPrivs:\s+1$/m);
assert.ok(Object.values(networkInterfaces()).flat().every(address => address.internal));
assert.equal(statSync('/persona').mode & 0o777, 0o700);
assert.equal(statSync('/persona/repo-token').mode & 0o777, 0o600);
assert.match(readFileSync('/persona/repo-token', 'utf8').trim(), /^[a-f0-9]{64}$/);
for (const path of ['/var/run/docker.sock', '/run/podman/podman.sock',
  '/run/containerd/containerd.sock', '/persona/peer-state']) {
  assert.ok(!existsSync(path), 'Host sockets and peer state must be absent');
}

function get(path, key, accept = 'application/json', port = 8000) {
  return fetch(new URL(path, `http://localhost:${port}`), {
    headers: key === undefined ? { accept } : { accept, 'X-Session-API-Key': key },
    redirect: 'error',
    signal: AbortSignal.timeout(3000),
  });
}

const apiKey = process.env.OH_SESSION_API_KEYS_0;
assert.ok(apiKey);
let asset;
const observations = new Map();
const deadline = Date.now() + 120_000;
while (!asset && Date.now() < deadline) {
  for (const path of ['/canvas/', '/canvas', '/canvas/index.html']) {
    try {
      const response = await get(path, undefined, 'text/html');
      const html = await response.text();
      const tags = [...html.matchAll(/<(script|meta|title|link|iframe)\b/gi)].map(match => match[1]);
      observations.set(path, { status: response.status, bytes: html.length, tags: tags.slice(0, 20) });
      if (!response.ok || !response.headers.get('content-type')?.includes('text/html')) {
        continue;
      }
      // Canvas can declare bundled JavaScript through link preloads or scripts.
      const js = html.match(/<(?:link|script)\b[^>]*?\s(?:href|src)\s*=\s*["']?([^"'\s>]+\.(?:m?js))(?:["'\s>])/i);
      if (js) {
        assert.ok(!html.includes(apiKey), 'Canvas HTML must keep the session key private');
        asset = new URL(js[1], response.url);
        break;
      }
    } catch (error) {
      if (error.code === 'ERR_ASSERTION') throw error;
      // Ingress may still be starting or canonicalizing this path.
    }
  }
  if (!asset) await delay(1000);
}
if (!asset) {
  console.error('Canvas ingress response shapes:', Object.fromEntries(observations));
}
assert.ok(asset, 'Canvas ingress must serve HTML with a JavaScript asset');
assert.equal(asset.origin, new URL('http://localhost:8000').origin);
const client = await get(asset.pathname + asset.search, undefined, '*/*');
assert.ok(client.ok, 'Canvas client script must load through ingress');
assert.match(client.headers.get('content-type') ?? '', /javascript/);
await client.body?.cancel();

const repo = mkdtempSync('/persona/canvas-smoke-');
function git(...args) {
  execFileSync('git', ['-C', repo, ...args], { stdio: 'ignore' });
}
git('init');
git('-c', 'user.name=Canvas Smoke', '-c', 'user.email=smoke@invalid.test',
  'commit', '--allow-empty', '-m', 'Synthetic fixture');
git('worktree', 'add', '-b', 'smoke-task', repo + '/task');
assert.ok(existsSync(repo + '/task/.git'), 'Git worktree must be available inside the container');
console.log('Canvas HTML, JavaScript asset, and synthetic worktree passed.');

const conversations = '/api/conversations/search';
const listeners = [
  ['bundled ingress', 8000],
  ['direct Agent Server', 18000],
];
const outcomes = await Promise.allSettled(listeners.map(async ([name, port]) => {
  const backendDeadline = Date.now() + 60_000;
  let backendStatus = 'unreachable';
  let backendReady = false;
  while (Date.now() < backendDeadline) {
    try {
      const response = await get(conversations, apiKey, 'application/json', port);
      const contentType = response.headers.get('content-type');
      backendStatus = `${response.status} ${contentType}`;
      if (response.ok && contentType?.includes('application/json')) {
        await response.json();
        backendReady = true;
        break;
      }
      await response.body?.cancel();
    } catch {
      // Backend startup can lag behind the static UI.
    }
    await delay(1000);
  }
  assert.ok(backendReady, `${name}: authenticated backend did not become ready (${backendStatus})`);

  const denials = [];
  for (const [label, key] of [['missing', undefined], ['invalid', 'invalid-smoke-key']]) {
    const denied = await get(conversations, key, 'application/json', port);
    if (![401, 403].includes(denied.status)) {
      denials.push(`${label} session key returned HTTP ${denied.status}`);
    }
    await denied.body?.cancel();
  }
  assert.equal(denials.length, 0, `${name}: ${denials.join('; ')}`);
  console.log(`${name}: session authentication passed.`);
}));
for (const outcome of outcomes) {
  if (outcome.status === 'rejected') console.error(outcome.reason.message);
}
const proxy = 'http://localhost:9081';
const cookie = process.env.FIXTURE_COOKIE;
function canvasGrant(password) {
  return 'Basic ' + Buffer.from('canvas-fixture:' + password).toString('base64');
}
const authorization = canvasGrant(process.env.CANVAS_PASSWORD);
async function proxyGet(path, headers) {
  const response = await fetch(proxy + path, {
    headers, redirect: 'manual', signal: AbortSignal.timeout(3000),
  });
  await response.body?.cancel();
  return response.status;
}
async function websocketStatus(headers) {
  return new Promise((resolve, reject) => {
    const req = request(proxy + '/sockets/events', {
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': Buffer.alloc(16).toString('base64'),
        ...headers,
      },
    }, response => {
      response.resume();
      resolve(response.statusCode);
    });
    req.on('upgrade', (response, socket) => {
      socket.destroy();
      resolve(response.statusCode);
    });
    req.on('error', reject);
    req.setTimeout(3000, () => req.destroy(new Error('WebSocket probe timed out')));
    req.end();
  });
}

assert.equal(await proxyGet('/canvas'), 302, 'Caddy must gate the browser');
assert.equal(await proxyGet('/canvas', { authorization }), 302,
  'A Canvas grant alone must not bypass Haven login');
assert.equal(await proxyGet(conversations, { 'X-Session-API-Key': apiKey }), 302,
  'Caddy must require a Haven cookie even with a valid backend key');
assert.equal(await proxyGet(conversations, {
  cookie: cookie + 'tampered',
  'X-Session-API-Key': apiKey,
}), 302, 'Caddy must reject a tampered Haven cookie even with a valid backend key');
assert.equal(await proxyGet('/canvas', { cookie }), 401,
  'A Haven cookie alone must not grant Canvas access');
assert.equal(await proxyGet('/canvas', { cookie, authorization: canvasGrant('invalid') }), 401,
  'Caddy must reject an invalid Canvas grant');
assert.ok([401, 403].includes(await proxyGet(conversations, { cookie, authorization })),
  'Both ingress credentials must not substitute for the backend session key');
assert.equal(await websocketStatus(), 302, 'Caddy must gate WebSocket upgrades');
assert.equal(await websocketStatus({ cookie }), 401, 'WebSocket upgrades must require the Canvas grant');
assert.equal(await proxyGet('/canvas', { cookie, authorization }), 200,
  'The Haven session and Canvas grant must allow the UI');
assert.equal(await proxyGet(conversations, { cookie, authorization, 'X-Session-API-Key': apiKey }), 200,
  'The Haven session, Canvas grant and backend key must allow the API through Caddy');
console.log('Haven Caddy browser, API, and WebSocket authentication gate passed.');

assert.ok(outcomes.every(outcome => outcome.status === 'fulfilled'),
  'Every backend listener must reject missing and invalid keys.');
JS

bash "$repo_root/openhands/scripts/test-canvas-personas.sh" "$image"
