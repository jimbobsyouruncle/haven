#!/usr/bin/env python3
"""
FILE: status/test_hub_urls.py
PURPOSE (plain English):
    Offline fixture tests for the domain cutover in status/app.py. No Docker,
    no network, no third-party dependency: the module is imported fresh with a
    known environment for each case and the hub page and status page are
    rendered from a fixture data dict.

    Proven here:
      (a) TLS on: the hub and the status page print https://<TLS_DOMAIN>,
          https://hermes.<TLS_DOMAIN> and https://status.<TLS_DOMAIN>, and no
          http:// URL for those hosts survives anywhere in either page;
      (b) TLS on: the OpenHands row is still the loopback SSH-tunnel address,
          byte-unchanged -- it never routes through the URL helper;
      (c) TLS on with an EMPTY TLS_DOMAIN: the domain falls back to
          LOCAL_DOMAIN, so no URL renders as "https://." or "https://hermes.";
      (d) TLS off: the URLs are exactly today's http://<LOCAL_DOMAIN>,
          http://hermes.<LOCAL_DOMAIN> and http://status.<LOCAL_DOMAIN>, with
          no TLS_DOMAIN name and no https:// service URL anywhere.

    Against the pre-cutover status/app.py every TLS-on case fails: that file had
    no URL helper and rendered http://<LOCAL_DOMAIN> names unconditionally.

USAGE:
    python3 status/test_hub_urls.py

EXIT CODES:
    0  every assertion passed
    1  one or more assertions failed
"""

import importlib.util
import os
import re
import sys

PASS = 0
FAIL = 0

LOCAL = "jarvis.lan"
PUBLIC = "daemonhub.dev"
# The OpenHands row must never move off loopback; only the SSH tunnel reaches it.
LOOPBACK = "127.0.0.1"
TUNNEL_ROW = "<code>http://%s:3001 via SSH tunnel</code>" % LOOPBACK
# Every http:// URL left in a TLS-on page must be that loopback tunnel address.
LOOPBACK_URL_RE = re.compile(r"http://(?!127\.0\.0\.1:3001)")
# Any https:// host, so a truncated one ("hermes.") is caught by label count.
HTTPS_HOST_RE = re.compile(r"https://([^\s\"'<>)/]+)")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_PATH = os.path.join(REPO_ROOT, "status", "app.py")

DATA = {
    "generated": "2026-01-01 00:00:00 UTC",
    "overall": "ok",
    "services": [{"name": "Open WebUI", "state": "ok", "detail": "up"}],
    "checks": [{"name": "Hermes Agent", "state": "ok", "detail": "up"}],
    "jobs": [{"name": "Backup", "state": "ok", "detail": "ok"}],
    "errors": [],
    "logs": {},
}


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"ok   {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"FAIL {msg}", file=sys.stderr)


def check(label: str, got, want) -> None:
    if got == want:
        ok(label)
    else:
        bad(f"{label} (want {want!r}, got {got!r})")


def render(tls_enabled, tls_domain):
    """Fresh import per call: app.py reads its env at import time."""
    os.environ["LOCAL_DOMAIN"] = LOCAL
    os.environ["TLS_ENABLED"] = tls_enabled
    os.environ["TLS_DOMAIN"] = tls_domain
    spec = importlib.util.spec_from_file_location("status_app_urls_under_test", APP_PATH)
    if spec is None or spec.loader is None:
        print(f"FAIL cannot load {APP_PATH}", file=sys.stderr)
        sys.exit(1)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    hub, status = mod.render_hub(DATA), mod.render_html(DATA)
    # Branding must work with every existing TLS/domain selection. Keep the
    # diagnostic download interface and HTTP server identity compatible.
    for label, page, title, heading in (
        ("hub", hub, "Haven hub", "Haven service hub"),
        ("status", status, "Haven status", "Haven status"),
    ):
        check(f"{tls_enabled}/{tls_domain}: {label} title",
              re.findall(r"<title>(.*?)</title>", page), [title])
        check(f"{tls_enabled}/{tls_domain}: {label} heading",
              re.findall(r"<h1>(.*?)</h1>", page), [heading])
        check(f"{tls_enabled}/{tls_domain}: {label} footer",
              bool(re.search(r"<footer>Haven(?: ·|</footer>)", page)), True)
    check("diagnostic download retains its legacy filename",
          "a.download = 'hybrid-ai-diagnostic-' + stamp + '.txt';" in status, True)
    check("HTTP server identity stays compatible", mod.Handler.server_version,
          "hybrid-ai-status")
    return hub, status


# The hub prints every service name; the status page links only the apex
# (Open WebUI) and leaves per-service names to the hub and the Caddyfile.
HOSTS = {
    "hub": ("", "hermes", "status"),
    "status page": ("",),
}

# --- TLS on ----------------------------------------------------------------
hub, status = render("yes", PUBLIC)
pages = {"hub": hub, "status page": status}

for page_name, subs in HOSTS.items():
    for sub in subs:
        url = f"https://{sub + '.' if sub else ''}{PUBLIC}"
        if url in pages[page_name]:
            ok(f"TLS on: {page_name} contains {url}")
        else:
            bad(f"TLS on: {page_name} is missing {url}")

for page_name, page in pages.items():
    if LOCAL in page:
        bad(f"TLS on: {page_name} still mentions {LOCAL}")
    else:
        ok(f"TLS on: {page_name} mentions {LOCAL} nowhere")

for page_name, page in pages.items():
    leftovers = LOOPBACK_URL_RE.findall(page)
    if leftovers:
        bad(f"TLS on: {page_name} keeps {len(leftovers)} non-loopback http:// URL(s)")
    else:
        ok(f"TLS on: {page_name} has no non-loopback http:// URL")

for plain in (f"http://{LOCAL}", f"http://hermes.{LOCAL}", f"http://status.{LOCAL}"):
    for page_name, page in pages.items():
        if plain in page:
            bad(f"TLS on: {page_name} still prints {plain}")
        else:
            ok(f"TLS on: {page_name} no longer prints {plain}")

if f"Domain: <strong>{PUBLIC}</strong>" in hub:
    ok("TLS on: hub subtitle names the bare certificate domain, with no scheme")
else:
    bad("TLS on: hub subtitle does not read 'Domain: <strong>daemonhub.dev</strong>'")

if "Local Domain:" in hub:
    bad("TLS on: hub subtitle still says 'Local Domain:'")
else:
    ok("TLS on: hub subtitle no longer says 'Local Domain:'")

if TUNNEL_ROW in hub:
    ok("TLS on: hub keeps the loopback OpenHands SSH-tunnel row, byte-unchanged")
else:
    bad("TLS on: hub lost the loopback OpenHands SSH-tunnel row")

bad_hosts = [h for h in HTTPS_HOST_RE.findall(hub) if h.count(".") < 1 or h.endswith(".")]
if bad_hosts:
    bad(f"TLS on: hub emitted a truncated host {bad_hosts}")
else:
    ok("TLS on: every https:// host in the hub has at least two labels")

# --- TLS on, TLS_DOMAIN empty: fall back, never emit "https://." -----------
hub_fb, _status_fb = render("yes", "")
fb_hosts = HTTPS_HOST_RE.findall(hub_fb)
broken = [h for h in fb_hosts if h.count(".") < 1 or h.endswith(".")]
if broken:
    bad(f"TLS on without TLS_DOMAIN: hub emitted a truncated host {broken}")
else:
    ok("TLS on without TLS_DOMAIN: no URL is emitted as https://. or https://hermes.")
for url in (f"https://{LOCAL}", f"https://hermes.{LOCAL}", f"https://status.{LOCAL}"):
    if url in hub_fb:
        ok(f"TLS on without TLS_DOMAIN: hub falls back to {url}")
    else:
        bad(f"TLS on without TLS_DOMAIN: hub is missing {url}")

# --- TLS on, other truthy spellings the installer accepts ------------------
for spelling in ("1", "true", "YES"):
    hub_v, _s = render(spelling, PUBLIC)
    if f"https://hermes.{PUBLIC}" in hub_v:
        ok(f"TLS_ENABLED={spelling} is treated as on")
    else:
        bad(f"TLS_ENABLED={spelling} is not treated as on")

# --- TLS off ---------------------------------------------------------------
hub_off, status_off = render("no", PUBLIC)
off_pages = {"hub": hub_off, "status page": status_off}

for page_name, subs in HOSTS.items():
    for sub in subs:
        url = f"http://{sub + '.' if sub else ''}{LOCAL}"
        if url in off_pages[page_name]:
            ok(f"TLS off: {page_name} keeps today's {url}")
        else:
            bad(f"TLS off: {page_name} is missing today's {url}")

# The trailing-path emitters keep today's apex spelling too.
for suffix in ("/ollama/", "/health"):
    url = f"http://{LOCAL}{suffix}"
    if url in hub_off:
        ok(f"TLS off: hub keeps today's {url}")
    else:
        bad(f"TLS off: hub is missing today's {url}")

# Every http:// URL in the TLS-off hub must be an apex/LOCAL_DOMAIN name; the
# one exception is the loopback OpenHands tunnel.
off_http = re.findall(r"http://([^\s\"'<>)/]+)", hub_off)
loopback_host = f"{LOOPBACK}:3001"
stray = [h for h in off_http if not (h == LOCAL or h.endswith("." + LOCAL) or h == loopback_host)]
if stray:
    bad(f"TLS off: hub prints unexpected http:// host(s) {sorted(set(stray))}")
else:
    ok("TLS off: every http:// host in the hub is a LOCAL_DOMAIN name or the loopback tunnel")

# The subtitle is the one prose line the cutover changed, so pin it exactly:
# TLS off must keep today's wording and markup, byte for byte.
if f"Local Domain: <strong>{LOCAL}</strong>" in hub_off:
    ok("TLS off: hub subtitle is exactly today's 'Local Domain: <strong>jarvis.lan</strong>'")
else:
    bad("TLS off: hub subtitle is not today's 'Local Domain: ...' markup")


for page_name, page in off_pages.items():
    if PUBLIC in page:
        bad(f"TLS off: {page_name} mentions {PUBLIC}")
    else:
        ok(f"TLS off: {page_name} mentions {PUBLIC} nowhere")
    if "https://" in page:
        bad(f"TLS off: {page_name} emitted an https:// URL")
    else:
        ok(f"TLS off: {page_name} emitted no https:// URL")

if TUNNEL_ROW in hub_off:
    ok("TLS off: hub keeps the loopback OpenHands SSH-tunnel row, byte-unchanged")
else:
    bad("TLS off: hub lost the loopback OpenHands SSH-tunnel row")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
