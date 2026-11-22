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

if [[ ${1:-} == --pull && $# == 1 ]]; then
  podman --remote=false pull --platform linux/arm64 "$image"
elif (( $# != 0 )); then
  echo "Usage: $0 [--pull]" >&2
  exit 2
fi

api_key=$(openssl rand -hex 32)
container=$(podman --remote=false run --detach --rm --pull=never \
  --platform linux/arm64 --network none --http-proxy=false \
  --cap-drop ALL --security-opt no-new-privileges --image-volume=ignore \
  --log-driver=none --memory=3g --cpus=2.5 --pids-limit=512 \
  --env "LOCAL_BACKEND_API_KEY=$api_key" --env AGENT_CANVAS_DISABLE_TELEMETRY=1 \
  "$image")
trap 'podman --remote=false stop --time 5 "$container" >/dev/null 2>&1 || true' EXIT

podman --remote=false exec -i "$container" node --input-type=module - <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';

assert.notEqual(process.getuid(), 0, 'Agent image must run as non-root');
const status = readFileSync('/proc/self/status', 'utf8');
assert.match(status, /^CapEff:\s+0+$/m);
assert.match(status, /^NoNewPrivs:\s+1$/m);
assert.ok(Object.values(networkInterfaces()).flat().every(address => address.internal));
for (const path of ['/var/run/docker.sock', '/run/podman/podman.sock']) {
  assert.ok(!existsSync(path), 'Container engine socket must be absent');
}

function get(path, key, accept = 'application/json') {
  return fetch(new URL(path, 'http://localhost:8000'), {
    headers: key === undefined ? { accept } : { accept, 'X-Session-API-Key': key },
    redirect: 'error',
    signal: AbortSignal.timeout(3000),
  });
}

const apiKey = process.env.LOCAL_BACKEND_API_KEY;
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

const repo = mkdtempSync('/tmp/canvas-smoke-');
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
const backendDeadline = Date.now() + 60_000;
let backendStatus = 'unreachable';
let backendReady = false;
while (Date.now() < backendDeadline) {
  try {
    const response = await get(conversations, apiKey);
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
assert.ok(backendReady, `Authenticated Agent Server did not become ready (${backendStatus})`);

for (const [label, key] of [['missing', undefined], ['invalid', 'invalid-smoke-key']]) {
  const denied = await get(conversations, key);
  assert.ok([401, 403].includes(denied.status),
    `Backend must reject a ${label} session key (HTTP ${denied.status})`);
  await denied.body?.cancel();
}
console.log('Agent Server session authentication passed.');
JS
