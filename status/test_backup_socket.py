#!/usr/bin/env python3
"""Real Unix-socket integration; synthetic logs, no Docker."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("status_socket_test", ROOT / "status/app.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class BackupSocketTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="sbk-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.directory = self.root / "status-verifier"
        self.directory.mkdir(mode=0o700)
        self.path = str(self.directory / "backup.sock")
        self.log = self.root / "backup.log"
        self.patch = patch.object(app, "BACKUP_LOG", str(self.log))
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def request(self, path="/backup", method="GET"):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(4)
            client.connect(self.path)
            client.sendall(f"{method} {path} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
            chunks = []
            while data := client.recv(4096):
                chunks.append(data)
        headers, body = b"".join(chunks).split(b"\r\n\r\n", 1)
        return int(headers.split()[1]), body

    def write_success(self, age=0):
        when = datetime.now(timezone.utc) - timedelta(hours=age)
        self.log.write_text(f"EVENT ts={when:%Y-%m-%dT%H:%M:%SZ} event=backup_success detail=private\n")

    def test_live_state_and_minimal_output(self):
        with app.backup_verifier_socket(self.path):
            self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
            self.assertEqual(os.stat(self.path).st_uid, os.geteuid())
            for age, want in [(0, "ok"), (60, "warn"), (200, "fail")]:
                self.write_success(age)
                code, body = self.request()
                self.assertEqual(code, 200)
                self.assertEqual(json.loads(body), {"name": "Backups", "state": want})
                self.assertEqual(json.loads(body)["state"], app.probe_backups()["state"])
            self.log.unlink()
            self.assertEqual(json.loads(self.request()[1])["state"], "warn")
        self.assertFalse(os.path.lexists(self.path))

    def test_no_other_api_or_methods(self):
        with app.backup_verifier_socket(self.path):
            for path in ("/status/api", "/status/diagnostic", "/backup?detail=1", "/", "/../backup"):
                self.assertEqual(self.request(path), (404, b""))
            for method in ("POST", "PUT", "DELETE", "HEAD"):
                self.assertEqual(self.request(method=method)[0], 501)

    def test_probe_errors_do_not_leak(self):
        with app.backup_verifier_socket(self.path):
            with patch.object(app, "probe_backups", side_effect=ValueError("private sentinel")):
                self.assertEqual(self.request(), (503, b""))
            with patch.object(app, "probe_backups", return_value={"state": "invalid"}):
                self.assertEqual(self.request(), (503, b""))

    def test_stale_socket_recovery_and_active_refusal(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
            stale.bind(self.path)
        with app.backup_verifier_socket(self.path):
            self.assertEqual(self.request()[0], 200)
            with self.assertRaises(ValueError):
                with app.backup_verifier_socket(self.path):
                    self.fail("replaced active socket")
            self.assertEqual(self.request()[0], 200)

    def test_refuse_nonprivate_foreign_and_symlink_directory(self):
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError):
            with app.backup_verifier_socket(self.path):
                self.fail("accepted nonprivate directory")
        self.directory.chmod(0o700)
        with patch.object(app.os, "geteuid", return_value=os.geteuid() + 1):
            with self.assertRaises(ValueError):
                with app.backup_verifier_socket(self.path):
                    self.fail("accepted foreign owner")
        alias = self.root / "alias"
        alias.symlink_to(self.directory)
        with self.assertRaises(ValueError):
            with app.backup_verifier_socket(str(alias / "backup.sock")):
                self.fail("accepted directory symlink")

    def test_do_not_replace_files_or_symlinks(self):
        target = self.root / "sentinel"
        target.write_text("unchanged")
        for symlink in (False, True):
            if symlink:
                Path(self.path).symlink_to(target)
            else:
                Path(self.path).write_text("unchanged")
            with self.assertRaises(ValueError):
                with app.backup_verifier_socket(self.path):
                    self.fail("accepted non-socket")
            self.assertEqual(Path(self.path).read_text(), "unchanged")
            Path(self.path).unlink()
        self.assertEqual(target.read_text(), "unchanged")

    def test_cleanup_preserves_replacement(self):
        with app.backup_verifier_socket(self.path):
            Path(self.path).unlink()
            Path(self.path).write_text("replacement")
        self.assertEqual(Path(self.path).read_text(), "replacement")

    def test_partial_request_times_out(self):
        with app.backup_verifier_socket(self.path):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(4)
                client.connect(self.path)
                client.sendall(b"GET /backup HTTP/1.0\r\n")
                self.assertEqual(client.recv(1024), b"")
            self.assertEqual(self.request()[0], 200)

    def test_private_probe_with_real_curl(self):
        self.write_success()
        with app.backup_verifier_socket(self.path):
            result = subprocess.run(
                ["curl", "--disable", "--fail", "--silent", "--show-error", "--noproxy", "*",
                 "--unix-socket", self.path, "http://localhost/backup"],
                capture_output=True, check=True, timeout=10,
            )
        self.assertEqual(json.loads(result.stdout), {"name": "Backups", "state": "ok"})


if __name__ == "__main__":
    unittest.main()
