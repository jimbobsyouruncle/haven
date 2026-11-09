"""Offline regression cases for registry-reference classification in the audit."""
import unittest

from audit import PATTERN, classify, has_ghcr_reference


class RegistryReferenceTests(unittest.TestCase):
    def test_registry_references(self):
        for line in (
            'ghcr.io/owner/repo:tag',
            '`https://ghcr.io/owner/repo`',
            'package="ghcr.io/owner/repo"',
            '[package](https://GHCR.IO/owner/repo)',
            'ghcr.io/owner/repo@sha256:abcdef',
            'https://ghcr.io:443/owner/repo',
        ):
            with self.subTest(line=line):
                self.assertTrue(has_ghcr_reference(line))

    def test_deceptive_or_malformed_references(self):
        for line in (
            'https://ghcr.io.evil.example/owner/repo',
            'https://notghcr.io/owner/repo',
            'https://evil.example/ghcr.io/owner/repo',
            'https://evil.example/?registry=ghcr.io',
            'https://ghcr.io@evil.example/owner/repo',
            'https://evil.example@ghcr.io/owner/repo',
            'https://ghcr.io:invalid/owner/repo',
            'https://ghcr.io:8443/owner/repo',
            'http://ghcr.io/owner/repo',
            'ftp://ghcr.io/owner/repo',
            'https://ghcr.io/',
            'mention ghcr.io in prose',
        ):
            with self.subTest(line=line):
                self.assertFalse(has_ghcr_reference(line))

    def test_registry_evidence_affects_classification(self):
        for reference, expected_rule in (
            ('https://ghcr.io/owner/repo', 'P06'),
            ('https://ghcr.io.evil.example/owner/repo', 'M01'),
            ('https://evil.example/ghcr.io/owner/repo', 'M01'),
            ('https://ghcr.io@evil.example/owner/repo', 'M01'),
        ):
            line = 'hybrid ' + reference
            with self.subTest(reference=reference):
                match = PATTERN.search(line)
                self.assertIsNotNone(match)
                self.assertEqual(classify('example.txt', line, match, 'content')[1], expected_rule)


if __name__ == '__main__':
    unittest.main()
