"""Exercise only the loopback API of the disposable Open WebUI container."""

import base64
import json
import os
import socket
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:8080"
PHASE = os.environ["QUALIFICATION_PHASE"]
PASSWORD = "Synthetic-Only-Password-A9!"
CHAT_TITLE = "Haven synthetic private chat"
FUNCTION = "haven_qualification_runpod"


def request(path, body=None, token=None, allowed=(200,)):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(BASE + path, None if body is None else json.dumps(body).encode(), headers)
    try:
        with urlopen(req, timeout=15) as response:
            if response.status not in allowed:
                raise AssertionError(f"{path} returned {response.status}, expected {allowed}")
            return json.load(response)
    except HTTPError as error:
        if error.code not in allowed:
            raise AssertionError(f"{path} returned {error.code}, expected {allowed}") from error
        return None


def account(name, seed=False):
    path = "/api/v1/auths/signup" if seed else "/api/v1/auths/signin"
    return request(path, {"email": f"{name}@example.test", "password": PASSWORD, "name": name})


for _ in range(120):
    try:
        request("/health")
        break
    except (URLError, TimeoutError):
        time.sleep(2)
else:
    raise SystemExit("Open WebUI health did not come up")

owner = account("owner", PHASE == "seed")
member = account("member", PHASE == "seed")
assert owner["role"] == "admin" and member["role"] == "user"
owner_token, member_token = owner["token"], member["token"]
source = base64.b64decode(os.environ["QUALIFICATION_PIPE"]).decode()
assert not os.path.exists("/var/run/docker.sock")
assert not os.path.exists("/run/secrets")
try:
    with socket.create_connection(("192.0.2.1", 443), timeout=2):
        raise AssertionError("isolated container reached an unauthorized network")
except OSError:
    pass

if PHASE == "seed":
    request("/api/v1/chats/new", {"chat": {"title": CHAT_TITLE, "messages": []}}, owner_token)
    request("/api/v1/functions/create", {
        "id": FUNCTION,
        "name": "Haven qualification RunPod",
        "content": source,
        "meta": {"description": "Synthetic fixture using the Haven RunPod Function"},
    }, owner_token)

chats = request("/api/v1/chats/", token=owner_token)
chat = next(row for row in chats if row["title"] == CHAT_TITLE)
request(f"/api/v1/chats/{chat['id']}", allowed=(401, 403))
request(f"/api/v1/chats/{chat['id']}", token=member_token, allowed=(403, 404))
assert CHAT_TITLE not in {row["title"] for row in request("/api/v1/chats/", token=member_token)}
function = request(f"/api/v1/functions/id/{FUNCTION}", token=owner_token)
assert function["content"] == source and function["type"] == "pipe"

if PHASE == "migrate":
    from websockets.sync.client import connect

    config = request("/api/config", token=member_token)
    assert config["features"]["enable_image_generation"] is False
    session = request("/api/v1/auths/sessions", {"name": "Haven synthetic Tether"}, owner_token)
    with connect(f"ws://127.0.0.1:8080/api/v1/tether/connect", open_timeout=10) as relay:
        relay.send(json.dumps({
            "type": "hello", "version": 2, "token": session["access_token"],
            "connection_id": "haven-qualification", "name": "Synthetic Tether",
            "services": [],
        }))
        assert json.loads(relay.recv(timeout=10))["type"] == "ready"

print(f"Open WebUI {PHASE}: login, private chat and RunPod Function persistence checks passed")
