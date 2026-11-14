"""Immutable-object coverage and fail-closed discovery regression tests."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from inventory import scan


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args])

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD").decode().strip()

    def test_reads_pinned_objects_including_hidden_files_not_worktree(self):
        (self.root / "hybrid-ai.txt").write_text("HYBRID_AI_DATA_DIR=/var/lib/hybrid-ai\n")
        (self.root / ".hidden").write_text("hybrid_ai.runpod_core\n")
        (self.root / "unmatched").write_text("ordinary text\n")
        revision = self.commit()
        (self.root / "hybrid-ai.txt").write_text("local content must not enter inventory")
        (self.root / "ignored.env").write_text("hybrid-ai ignored content")
        rows, manifest = scan(self.root, "haven", revision)
        self.assertEqual(len(manifest), 3)
        self.assertEqual(len(rows), 4)
        self.assertEqual({r[3] for r in rows}, {0, 1})
        self.assertNotIn("ignored.env", {r[2] for r in rows})
        self.assertEqual({r[1] for r in rows}, {revision})

    def test_symlinks_refused_without_following(self):
        (self.root / "link").symlink_to("/outside/unauthorized")
        revision = self.commit()
        with self.assertRaisesRegex(ValueError, "nonregular"):
            scan(self.root, "haven", revision)

    def test_non_utf8_cannot_disappear_from_coverage(self):
        (self.root / "binary").write_bytes(b"\xffhybrid-ai")
        revision = self.commit()
        with self.assertRaises(UnicodeDecodeError):
            scan(self.root, "haven", revision)

    def test_missing_revision_refuses(self):
        (self.root / "file").write_text("text")
        self.commit()
        with self.assertRaises(subprocess.CalledProcessError):
            scan(self.root, "haven", "0" * 40)


if __name__ == "__main__":
    unittest.main()
