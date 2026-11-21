#!/usr/bin/env python3
"""Offline real-Git fixtures for deployment impact decisions."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLASSIFIER = Path(__file__).with_name('deploy-impact.py').resolve()
COMPOSE = 'docker-compose.yml.tmpl'


class DeploymentImpactTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.write('README.md', 'initial')
        self.pin('0.1')
        self.base = self.commit('accepted')
        self.git('branch', 'accepted')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content + '\n')

    def pin(self, version):
        self.write(COMPOSE, 'services:\n  ollama:\n    image: '
                   '${OLLAMA_IMAGE:-ollama/ollama:' + version + '@sha256:' + 'a' * 64 + '}')

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-qm', message)
        return self.git('rev-parse', 'HEAD')

    def result(self, base=None):
        return subprocess.run([sys.executable, str(CLASSIFIER), str(self.root), base or self.base,
                               self.git('rev-parse', 'HEAD')],
                              capture_output=True, text=True)

    def assert_impact(self, expected):
        result = self.result()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected)

    def test_docs_only_then_routine(self):
        self.write('docs/how-to.md', 'instructions')
        self.commit('docs')
        self.assert_impact('docs-only')
        self.pin('0.2')
        self.commit('pin')
        self.assert_impact('routine')

    def test_protected_then_docs_then_routine_even_after_revert(self):
        self.write('scripts/install-root.py', '# protected')
        bad = self.commit('trusted bootstrap change')
        self.write('README.md', 'docs follow-up')
        self.commit('docs')
        self.assert_impact('protected')
        self.pin('0.2')
        self.commit('pin')
        self.assert_impact('protected')
        self.git('revert', '--no-edit', bad)
        self.assert_impact('protected')

    def test_rename_delete_and_mode_change(self):
        self.git('mv', 'README.md', 'docs.md')
        rename = self.commit('rename')
        self.assert_impact('protected')
        (self.root / 'docs.md').unlink()
        self.commit('delete')
        self.assertEqual(self.result(rename).stdout.strip(), 'protected')
        self.git('checkout', '-q', '--detach', self.base)
        (self.root / 'README.md').chmod(0o755)
        self.commit('executable docs')
        self.assert_impact('protected')

    def test_unknown_and_security_sensitive_configuration(self):
        self.write(COMPOSE, 'services:\n  ollama:\n    privileged: true')
        self.commit('protected runtime configuration')
        self.assert_impact('protected')
        self.git('checkout', '-q', '--detach', self.base)
        self.write('docs/new.py', '# executable content in a documentation directory')
        self.commit('unknown')
        self.assert_impact('protected')

    def test_missing_and_rewritten_baselines(self):
        self.assertIn('AUTHORIZATION_REQUIRED', self.result('a' * 40).stderr)
        self.write('README.md', 'another main commit')
        orphan = self.commit('discarded main')
        self.git('checkout', '-q', '--detach', self.base)
        self.write('README.md', 'replacement main commit')
        self.commit('rewritten main')
        result = self.result(orphan)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AUTHORIZATION_REQUIRED', result.stderr)

    def test_merge_preserves_transient_topic_changes(self):
        self.git('checkout', '-qb', 'topic')
        self.write('scripts/install-root.py', '# protected')
        self.commit('temporary policy change')
        (self.root / 'scripts/install-root.py').unlink()
        self.commit('remove temporary policy change')
        self.git('checkout', '-q', 'main')
        self.git('merge', '--no-ff', '--no-edit', 'topic')
        self.assert_impact('protected')


if __name__ == '__main__':
    unittest.main()
