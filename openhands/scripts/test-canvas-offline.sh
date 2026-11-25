#!/usr/bin/env bash
# Exercise the pinned ARM64 Canvas bundle with synthetic data and no host access.
set -euo pipefail

if ! command -v podman >/dev/null; then
  echo "Canvas smoke test requires local rootless Podman on ARM64." >&2
  exit 1
fi
if [[ $(uname -m) != aarch64 || $(podman --remote=false info --format '{{.Host.Security.Rootless}}') != true ]]; then
  echo "Canvas smoke test requires local rootless Podman on ARM64." >&2
  exit 1
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(awk '/^    image: ghcr[.]io\/openhands\/agent-canvas@sha256:/ { print $2 }' "$repo_root/docker-compose.yml.tmpl")
[[ "$image" =~ ^ghcr[.]io/openhands/agent-canvas@sha256:[0-9a-f]{64}$ ]]
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

podman --remote=false image inspect --format \
  'Canvas image: entrypoint={{json .Config.Entrypoint}} working-dir={{json .Config.WorkingDir}} volumes={{json .Config.Volumes}}' "$image"

api_key=$(openssl rand -hex 32)
fixture=$(mktemp -d)
container=
auth_container=
caddy_container=
cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ -n $container ]]; then
    # This container has synthetic credentials only. Mask generated keys so
    # failures can be diagnosed without copying them into Actions logs.
    podman --remote=false logs "$container" 2>&1 |
      sed -E 's/[[:xdigit:]]{64}/[fixture value]/g' >&2 || true
  fi
  for id in "$caddy_container" "$auth_container" "$container"; do
    if [[ -n $id ]]; then
      podman --remote=false stop --time 5 "$id" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n $container ]]; then
    podman --remote=false rm -f "$container" >/dev/null 2>&1 || true
  fi
  podman --remote=false unshare rm -rf -- "$fixture"
}
trap cleanup EXIT
install -d -m 0700 "$fixture/developer" "$fixture/projects" "$fixture/peer"
printf 'synthetic peer state\n' >"$fixture/peer/peer-state"
openssl rand -hex 32 >"$fixture/developer/repo-token"
chmod 0600 "$fixture/developer/repo-token"
container=$(podman --remote=false run --detach --pull=never \
  --platform linux/arm64 --network none --http-proxy=false \
  --user 980:980 --env HOME=/persona --env XDG_CONFIG_HOME=/persona/.config \
  --env OH_PERSISTENCE_DIR=/persona/.openhands \
  --cap-drop ALL --security-opt no-new-privileges --image-volume=ignore \
  --log-driver=k8s-file --memory=3g --cpus=2.5 --pids-limit=512 \
  --volume "$fixture/developer:/persona:rw,U,Z" \
  --volume "$fixture/developer:/home/openhands/.openhands:rw,U,Z" \
  --volume "$fixture/projects:/projects:rw,U,Z" \
  --env "OH_SESSION_API_KEYS_0=$api_key" --env AGENT_CANVAS_DISABLE_TELEMETRY=1 \
  --env AGENT_SERVER_PORT=18000 \
  "$image")
podman --remote=false inspect --format '{{json .Mounts}}' "$container" |
  python3 -c 'import json,sys
from pathlib import Path
root = Path(sys.argv[1])
actual = {(mount["Source"], mount["Destination"]) for mount in json.load(sys.stdin)}
expected = {
    (str(root / "developer"), "/persona"),
    (str(root / "developer"), "/home/openhands/.openhands"),
    (str(root / "projects"), "/projects"),
}
if actual != expected:
    raise SystemExit("Canvas fixture has an unexpected bind mount")' "$fixture"
[[ $(podman --remote=false inspect --format '{{.HostConfig.NetworkMode}}' "$container") == none ]]
pid=$(podman --remote=false inspect --format '{{.State.Pid}}' "$container")
if (( pid == 0 )); then
  echo "Canvas entrypoint stopped before the authentication fixture ran." >&2
  exit 1
fi
read -r uid gid <<<"$(ps -o euid=,egid= -p "$pid")"
[[ $uid != 0 && $gid != 0 ]]
for dir in developer projects; do
  if [[ $(stat -c '%u:%g' "$fixture/$dir") != "$uid:$gid" ]]; then
    echo "Canvas fixture has unexpected ownership on the $dir mount." >&2
    exit 1
  fi
done

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
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$fixture/tls.key" -out "$fixture/tls.crt" \
  >/dev/null 2>&1
# Exercise the same route intended for an authenticated Haven HTTPS site.
caddy_config=$(cat "$repo_root/openhands/canvas-ingress.caddyfile")
caddy_config+='
https://localhost:9081 {
  tls /tmp/canvas.crt /tmp/canvas.key
  import canvas_ingress localhost:8080 localhost:8000 canvas-fixture
}'
# Disable the admin listener and automatic redirects in the fixture.
caddy_config=$'{
  admin off
  auto_https off
}\n'"$caddy_config"
caddy_container=$(podman --remote=false run "${peer_flags[@]}" \
  --user 1000:1000 --entrypoint /bin/sh --env XDG_CONFIG_HOME=/tmp --env XDG_DATA_HOME=/tmp \
  --env "CANVAS_PASSWORD_HASH=$canvas_hash" \
  --env "FIXTURE_TLS_CERT=$(cat "$fixture/tls.crt")" \
  --env "FIXTURE_TLS_KEY=$(cat "$fixture/tls.key")" \
  --env "FIXTURE_CADDYFILE=$caddy_config" "$caddy_image" -ec '
    umask 077
    printf "%s\n" "$FIXTURE_TLS_CERT" >/tmp/canvas.crt
    printf "%s\n" "$FIXTURE_TLS_KEY" >/tmp/canvas.key
    printf "%s\n" "$FIXTURE_CADDYFILE" >/tmp/Caddyfile
    exec caddy run --config /tmp/Caddyfile
  ')
cookie=$(podman --remote=false exec "$auth_container" python3 -c \
  'import os,time,app; print(app.COOKIE_NAME+"="+app.sign_expiry(os.environ["HAVEN_AUTH_COOKIE_SECRET"].encode(), time.time()+300))')

for id in "$container" "$auth_container" "$caddy_container"; do
  [[ -z $(podman --remote=false port "$id") ]]
done
fixture_net=$(podman --remote=false exec "$container" readlink /proc/self/ns/net)
[[ -n $fixture_net && $(readlink /proc/self/ns/net) != "$fixture_net" ]]
podman --remote=false run --rm --pull=never --network none --http-proxy=false \
  --cap-drop ALL --security-opt no-new-privileges --entrypoint python3 "$auth_image" -c '
import socket

for port in (8000, 18000):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3):
            raise SystemExit(f"Canvas port {port} is reachable from a separate namespace")
    except ConnectionRefusedError:
        pass
'
echo 'The Canvas fixture uses a separate, loopback-only namespace with no host-published ports.'

podman --remote=false exec -i --env "FIXTURE_COOKIE=$cookie" \
  --env "CANVAS_PASSWORD=$canvas_password" --env "FIXTURE_TLS_CERT=$(cat "$fixture/tls.crt")" \
  "$container" sh -ec '
    cert=$(mktemp)
    printf "%s\n" "$FIXTURE_TLS_CERT" >"$cert"
    NODE_EXTRA_CA_CERTS=$cert exec node --input-type=module -
  ' <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { request } from 'node:https';
import { networkInterfaces } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';

assert.equal(process.getuid(), 980);
assert.equal(process.getgid(), 980);
assert.equal(process.env.HOME, '/persona');
assert.equal(process.env.OH_PERSISTENCE_DIR, '/persona/.openhands');
assert.ok(existsSync('/opt/agent-canvas/entrypoint.sh'), 'Expected the pinned Canvas entrypoint');
const defaultWorkspaceRoot = '/home/openhands/.openhands/agent-canvas/workspaces';
// Confirm the pinned client still requests the canonical absolute path.
execFileSync('grep', ['-rlF', '--include=*.js', defaultWorkspaceRoot, '/opt/agent-canvas/frontend'],
  { stdio: 'ignore' });
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

const repo = mkdtempSync('/projects/canvas-smoke-');
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
const proxy = 'https://localhost:9081';
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
async function websocketStatus(path, headers) {
  return new Promise((resolve, reject) => {
    const req = request(proxy + path, {
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': randomBytes(16).toString('base64'),
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
assert.equal(await proxyGet('/canvas', { cookie, authorization }), 200,
  'The Haven session and Canvas grant must allow the UI');
assert.equal(await proxyGet(conversations, { cookie, authorization, 'X-Session-API-Key': apiKey }), 200,
  'The Haven session, Canvas grant and backend key must allow the API through Caddy');
assert.ok(outcomes.every(outcome => outcome.status === 'fulfilled'),
  'Every backend listener must reject missing and invalid keys.');

async function createConversation(workingDir) {
  const created = await fetch(proxy + '/api/conversations', {
    method: 'POST',
    headers: {
      cookie, authorization, 'X-Session-API-Key': apiKey, 'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      agent: {
        kind: 'Agent', tools: [], llm: { model: 'openai/gpt-4o-mini', api_key: 'synthetic-unused' },
      },
      workspace: { kind: 'LocalWorkspace', working_dir: workingDir },
    }),
    redirect: 'error',
    signal: AbortSignal.timeout(30_000),
  });
  assert.ok(created.ok, `Conversation creation through Caddy returned HTTP ${created.status}`);
  const { id } = await created.json();
  assert.match(id, /^[0-9a-f-]{32,36}$/i);
  return id;
}

const defaultWorkspace = defaultWorkspaceRoot + '/' + randomBytes(16).toString('hex');
assert.ok(!existsSync(defaultWorkspace));
await createConversation(defaultWorkspace);
assert.ok(statSync(defaultWorkspace).isDirectory(), 'Agent Server must create the default workspace');
const workspaceFile = defaultWorkspace + '/haven-workspace-fixture.txt';
writeFileSync(workspaceFile, 'canvas default workspace\n', { mode: 0o600 });
assert.equal(statSync(workspaceFile).uid, 980);
assert.equal(statSync(workspaceFile).gid, 980);
assert.equal(readFileSync(workspaceFile.replace('/home/openhands/.openhands/', '/persona/'), 'utf8'),
  'canvas default workspace\n');
console.log('Agent Server created the default workspace and its files reached the persona bind.');

const id = await createConversation(repo + '/task');
const eventPath = '/sockets/events/' + id;
assert.equal(await websocketStatus(eventPath, {}), 302, 'Caddy must gate the conversation upgrade');
assert.equal(await websocketStatus(eventPath, { cookie }), 401,
  'The conversation upgrade must require the Canvas grant');

function conversationSocket(key) {
  const url = new URL(eventPath, proxy);
  url.protocol = 'wss:';
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers: { cookie, authorization } });
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error('Conversation WebSocket timed out'));
    }, 15_000);
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'auth', session_api_key: key }));
    });
    ws.addEventListener('message', ({ data }) => {
      try {
        const event = JSON.parse(data);
        if (key !== apiKey || event.kind === 'ConversationStateUpdateEvent') {
          clearTimeout(timeout);
          ws.close();
          resolve({ kind: event.kind });
        }
      } catch {
        clearTimeout(timeout);
        ws.close();
        reject(new Error('Conversation WebSocket returned an invalid event'));
      }
    });
    ws.addEventListener('close', ({ code }) => {
      clearTimeout(timeout);
      resolve({ code });
    });
    ws.addEventListener('error', () => {
      clearTimeout(timeout);
      reject(new Error('Conversation WebSocket failed to upgrade or exchange frames'));
    });
  });
}
assert.deepEqual(await conversationSocket('invalid-smoke-key'), { code: 4001 },
  'The Agent Server must reject an invalid key without sending conversation data');
assert.deepEqual(await conversationSocket(apiKey), { kind: 'ConversationStateUpdateEvent' },
  'The authorized socket must deliver conversation state through Caddy');
console.log('Haven Caddy browser, API, and authenticated conversation event stream passed.');
JS

# Verify the workspace is on the host bind after stopping the exact image.
podman --remote=false stop --time 5 "$container" >/dev/null
podman --remote=false unshare bash -ec '
  shopt -s nullglob
  files=("$1"/agent-canvas/workspaces/*/haven-workspace-fixture.txt)
  [[ ${#files[@]} == 1 && $(<"${files[0]}") == "canvas default workspace" ]]
' _ "$fixture/developer"

bash "$repo_root/openhands/scripts/test-canvas-personas.sh" "$image"
