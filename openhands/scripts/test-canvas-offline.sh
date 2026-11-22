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

function get(path, key) {
  return fetch(new URL(path, 'http://localhost:8000'), {
    headers: key === undefined ? {} : { 'X-Session-API-Key': key },
    redirect: 'error',
    signal: AbortSignal.timeout(3000),
  });
}

let asset;
const deadline = Date.now() + 120_000;
while (!asset && Date.now() < deadline) {
  for (const path of ['/canvas/', '/canvas']) {
    try {
      const response = await get(path);
      const html = await response.text();
      if (!response.ok || !response.headers.get('content-type')?.includes('text/html')) {
        continue;
      }
      // The production HTML minifier can omit quotes around asset URLs.
      const script = html.match(/<script\b[^>]*?\ssrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/i);
      if (script) {
        asset = new URL(script[1] ?? script[2] ?? script[3], response.url);
        break;
      }
    } catch {
      // Ingress may still be starting or canonicalizing this path.
    }
  }
  if (!asset) await delay(1000);
}
assert.ok(asset, 'Canvas ingress must serve HTML with a client script');
assert.equal(asset.origin, new URL('http://localhost:8000').origin);
const client = await get(asset.pathname + asset.search);
assert.ok(client.ok, 'Canvas client script must load through ingress');
assert.match(client.headers.get('content-type') ?? '', /javascript/);
await client.body?.cancel();

for (const key of [undefined, 'invalid-smoke-key']) {
  const denied = await get('/api/conversations/search', key);
  assert.ok([401, 403].includes(denied.status), 'Backend must reject missing and invalid keys');
  await denied.body?.cancel();
}
const allowed = await get('/api/conversations/search', process.env.LOCAL_BACKEND_API_KEY);
assert.ok(allowed.ok, 'Backend must accept the disposable session key');
await allowed.json();

const repo = mkdtempSync('/tmp/canvas-smoke-');
function git(...args) {
  execFileSync('git', ['-C', repo, ...args], { stdio: 'ignore' });
}
git('init');
git('-c', 'user.name=Canvas Smoke', '-c', 'user.email=smoke@invalid.test',
  'commit', '--allow-empty', '-m', 'Synthetic fixture');
git('worktree', 'add', '-b', 'smoke-task', repo + '/task');
assert.ok(existsSync(repo + '/task/.git'), 'Git worktree must be available inside the container');
console.log('Canvas ingress, Agent Server session authentication, and offline Git worktree passed.');
JS
