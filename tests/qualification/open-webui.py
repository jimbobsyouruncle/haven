"""Exercise only the loopback API of the disposable Open WebUI container."""

import base64
import io
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4

BASE = "http://127.0.0.1:8080"
PHASE = os.environ["QUALIFICATION_PHASE"]
PASSWORD = "Synthetic-Only-Password-A9!"
CHAT_TITLE = "Haven synthetic private chat"
FUNCTION = "haven_qualification_runpod"


class ToolFixture(BaseHTTPRequestHandler):
    def json_response(self, document):
        payload = json.dumps(document).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path != "/openapi.json":
            self.send_error(404)
            return
        spec = {
            "openapi": "3.0.0",
            "info": {"title": "Haven synthetic tool", "version": "1.0"},
            "paths": {"/ping": {"get": {"operationId": "ping", "responses": {
                "200": {"description": "Synthetic response"},
            }}}},
        }
        self.server.received_spec.set()
        self.json_response(spec)

    def do_POST(self):
        if self.path != "/v1/images/generations":
            self.send_error(404)
            return
        from PIL import Image

        self.rfile.read(int(self.headers["Content-Length"]))
        payload = io.BytesIO()
        Image.new("RGB", (1, 1)).save(payload, format="PNG")
        self.server.generated.set()
        self.json_response({"data": [{"b64_json": base64.b64encode(payload.getvalue()).decode()}]})


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
if PHASE == "seed":
    request("/api/v1/auths/add", {
        "email": "member@example.test", "password": PASSWORD, "name": "member", "role": "user",
    }, owner["token"])
member = account("member")
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
    request(f"/api/v1/functions/id/{FUNCTION}/toggle", {}, owner_token)

chats = request("/api/v1/chats/", token=owner_token)
chat = next(row for row in chats if row["title"] == CHAT_TITLE)
assert request(f"/api/v1/chats/{chat['id']}", token=owner_token)["id"] == chat["id"]
request(f"/api/v1/chats/{chat['id']}", allowed=(401, 403))
request(f"/api/v1/chats/{chat['id']}", token=member_token, allowed=(401, 403, 404))
assert CHAT_TITLE not in {row["title"] for row in request("/api/v1/chats/", token=member_token)}
function = request(f"/api/v1/functions/id/{FUNCTION}", token=owner_token)
assert function["content"] == source and function["type"] == "pipe" and function["is_active"]
models = request("/api/models", token=owner_token)
assert any(row["id"].split(".", 1)[0] == FUNCTION for row in models["data"])

if PHASE == "migrate":
    from websockets.sync.client import connect

    config = request("/api/config", token=member_token)
    assert config["features"]["enable_image_generation"] is False
    request("/api/v1/images/generations", {"prompt": "fixture only"}, member_token,
            allowed=(400, 403))
    with ThreadingHTTPServer(("127.0.0.1", 0), ToolFixture) as tool:
        tool.received_spec = threading.Event()
        tool.generated = threading.Event()
        thread = threading.Thread(target=tool.serve_forever, daemon=True)
        thread.start()
        connection = {
            "url": f"http://127.0.0.1:{tool.server_port}",
            "path": "openapi.json",
            "type": "openapi",
            "auth_type": "none",
            "key": "",
            "config": {},
        }
        try:
            request("/api/v1/configs/tool_servers/verify", connection, member_token, allowed=(401, 403))
            assert not tool.received_spec.is_set()
            request("/api/v1/configs/tool_servers/verify", connection, owner_token)
            assert tool.received_spec.wait(timeout=3)
            request("/api/v1/images/config", token=member_token, allowed=(401, 403))
            images = request("/api/v1/images/config", token=owner_token)
            migrated = next(row for row in images["IMAGE_CONNECTIONS"]
                            if row["url"] == "http://fixture.invalid/v1")
            migrated["url"] = f"http://127.0.0.1:{tool.server_port}/v1"
            migrated["config"].update(
                model_ids=["gpt-image-1"],
                access_grants=[{"principal_type": "user", "principal_id": owner["id"], "permission": "read"}],
            )
            images.update(ENABLE_IMAGE_GENERATION=True, IMAGE_CONNECTIONS=[migrated])
            request("/api/v1/images/config/update", images, owner_token)
            model = request("/api/v1/images/models", token=owner_token)[0]["id"]
            assert request("/api/v1/images/models", token=member_token) == []
            body = {"model": model, "prompt": "fixture only"}
            request("/api/v1/images/generations", body, member_token, allowed=(400, 403))
            assert not tool.generated.is_set()
            request("/api/v1/images/generations", body, owner_token)
            assert tool.generated.wait(timeout=3)
        finally:
            tool.shutdown()
            thread.join()
    session = request("/api/v1/auths/sessions", {"name": "Haven synthetic Tether"}, owner_token)
    with connect(f"ws://127.0.0.1:8080/api/v1/tether/connect", open_timeout=10) as relay:
        relay.send(json.dumps({
            "type": "hello", "version": 2, "token": session["token"],
            "connection_id": str(uuid4()), "name": "Synthetic Tether",
            "services": [],
        }))
        assert json.loads(relay.recv(timeout=10))["type"] == "ready"

print(f"Open WebUI {PHASE}: login, private chat and RunPod Function persistence checks passed")
