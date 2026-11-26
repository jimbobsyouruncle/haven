#!/usr/bin/env bash
# Offline API/event fixtures for the existing deployment workflow.
set -Eeuo pipefail
python3 - <<'PY'
from contextlib import contextmanager
import importlib.util
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('provenance', 'scripts/deploy-provenance.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SHA = 'a' * 40
REPO = {'full_name': m.REPO, 'fork': False}

class Provenance(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pr = dict(merged_at='2026-11-21T17:30:00Z', merge_commit_sha=SHA,
                       base=dict(ref='main', repo=REPO), head=dict(sha='b' * 40))
        self.run = dict(id=12, head_sha=SHA, path='.github/workflows/deploy.yml',
                        repository=REPO, head_repository=REPO, head_branch='main',
                        event='push', status='in_progress', conclusion=None, run_attempt=1)
        self.jobs = [
            dict(id=101, run_id=12, head_sha=SHA, run_attempt=1, name='validate / Validate sources',
                 status='completed', conclusion='success'),
            dict(id=102, run_id=12, head_sha=SHA, run_attempt=1, name='Deploy over Tailscale',
                 status='in_progress', conclusion=None),
        ]

    def test_main_merge_of_pinned_image_uses_one_workflow(self):
        root = Path(self.tmp.name)
        output = root / 'output'
        checkout = root / 'repo'
        checkout.mkdir()

        def git(*args):
            return subprocess.check_output(['git', '-C', str(checkout), *args], text=True).strip()

        def commit(message):
            git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-qm', message)
            return git('rev-parse', 'HEAD')

        git('init', '-q', '-b', 'main')
        manifest = checkout / 'docker-compose.yml.tmpl'
        manifest.write_text('services:\n  web:\n    image: alpine:3.20\n')
        base = commit('starting pin')
        git('switch', '-qc', 'upgrade')
        manifest.write_text('services:\n  web:\n    image: alpine:3.21\n')
        head = commit('upgrade pin')
        git('switch', '-q', 'main')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            'merge', '--no-ff', '-qm', 'merge upgrade', 'upgrade')
        merged = git('rev-parse', 'HEAD')
        responses = self.eligibility_fixture(merged, base, head, git('rev-parse', 'HEAD^{tree}'))
        with patch.dict(os.environ, GITHUB_OUTPUT=str(output)), self.changed_directory(checkout):
            with patch.object(m, 'get', side_effect=lambda path, **kwargs: responses[path]):
                m.candidate(merged, base)
            self.assertEqual(output.read_text(), 'deploy=true\n')

            check_path = next(path for path in responses if '/check-runs?' in path)
            failures = [
                ('/commits/' + merged + '/pulls?per_page=100', [], 'PROVENANCE_MERGED_PR'),
                ('/git/commits/' + head, dict(sha=head, tree=dict(sha='e' * 40)),
                 'PROVENANCE_PR_TREE'),
                (f'/compare/{base}...{head}?per_page=1', dict(merge_base_commit=dict(sha=head)),
                 'PROVENANCE_PR_BASE'),
                (check_path, dict(total_count=0, check_runs=[]), 'PROVENANCE_PR_CHECK'),
            ]
            for changes, code in (
                    (dict(app=dict(id=1)), 'PROVENANCE_PR_CHECK'),
                    (dict(head_sha=merged), 'PROVENANCE_PR_CHECK'),
                    (dict(conclusion='skipped'), 'PROVENANCE_PR_CHECK'),
                    (dict(conclusion='failure'), 'PROVENANCE_PR_CHECK'),
                    (dict(completed_at='2026-11-21T17:31:00Z'), 'PROVENANCE_PR_CHECK_TIME')):
                check = dict(responses[check_path]['check_runs'][0], **changes)
                failures.append((check_path, dict(total_count=1, check_runs=[check]), code))
            output.unlink()
            for path, value, code in failures:
                with self.subTest(code=code, value=value), patch.dict(responses, {path: value}):
                    with patch.object(m, 'get', side_effect=lambda path, **kwargs: responses[path]):
                        with self.assertRaisesRegex(m.Refused, code):
                            m.candidate(merged, base)
                    self.assertFalse(output.exists())

        manifest.with_name('README.md').write_text('release notes\n')
        docs = commit('docs only')
        with patch.dict(os.environ, GITHUB_OUTPUT=str(output)), patch.object(m, 'get') as api:
            with self.changed_directory(checkout):
                m.candidate(docs, merged)
            api.assert_not_called()
        self.assertEqual(output.read_text(), 'deploy=false\n')

        workflow = Path('.github/workflows/deploy.yml').read_text()
        self.assertIn('  push:\n    branches: [main]', workflow)
        self.assertNotIn('workflow_dispatch:', workflow)
        self.assertIn('  validate:\n', workflow)
        self.assertIn('name: validate / Validate sources', workflow)
        self.assertNotIn('uses: ./.github/workflows/validate.yml', workflow)
        self.assertIn("needs: validate\n    if: needs.validate.outputs.deploy == 'true'", workflow)
        self.assertNotIn('secrets.', workflow.split('  deploy:\n', 1)[0])
        self.assertNotIn('workflow_run:', Path('.github/workflows/sast-checks.yml').read_text())

    def eligibility_fixture(self, merged, base, head, tree):
        data = {
            '/git/ref/heads/main': dict(object=dict(sha=merged)),
            f'/commits/{merged}/pulls?per_page=100': [
                dict(self.pr, merge_commit_sha=merged, head=dict(sha=head))],
            f'/git/commits/{head}': dict(sha=head, tree=dict(sha=tree)),
            f'/compare/{base}...{head}?per_page=1': dict(merge_base_commit=dict(sha=base)),
        }
        for name, encoded in [('Check agent context maps', 'Check+agent+context+maps'),
                              ('Security & SAST gate', 'Security+%26+SAST+gate')]:
            check = dict(name=name, app=dict(id=15368), head_sha=head, status='completed',
                         conclusion='success', completed_at=self.pr['merged_at'])
            data[f'/commits/{head}/check-runs?check_name={encoded}&filter=latest&per_page=100'] = (
                dict(total_count=1, check_runs=[check]))
        return data

    @contextmanager
    def changed_directory(self, path):
        previous = Path.cwd()
        os.chdir(path)
        try:
            yield
        finally:
            os.chdir(previous)

    def same_run(self, jobs, main=SHA, merged=True):
        responses = {
            '/actions/workflows/deploy.yml/runs?event=push&branch=main&head_sha=' + SHA:
                dict(total_count=1, workflow_runs=[self.run]),
            '/actions/runs/12/attempts/1/jobs?per_page=100': dict(total_count=len(jobs), jobs=jobs),
            '/actions/runs/12': self.run,
            '/git/ref/heads/main': {'object': {'sha': main}},
            '/commits/' + SHA + '/pulls?per_page=100': [self.pr] if merged else [],
        }
        with patch.object(m, 'get', side_effect=lambda path, **kwargs: responses[path]):
            m.authorize_host(SHA)

    def test_requires_current_main_merge_with_successful_same_attempt_gate(self):
        self.same_run(self.jobs)
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_MAIN_SHA'):
            self.same_run(self.jobs, 'b' * 40)
        for conclusion in ('failure', 'skipped', 'cancelled'):
            with self.assertRaisesRegex(m.Refused, 'PROVENANCE_JOB_STATE'):
                self.same_run([dict(self.jobs[0], conclusion=conclusion), self.jobs[1]])
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_JOB_IDENTITY'):
            self.same_run([dict(self.jobs[0], run_attempt=2), self.jobs[1]])
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_JOB_MISSING'):
            self.same_run(self.jobs[1:])
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_MERGED_PR'):
            self.same_run(self.jobs, merged=False)

unittest.main()
PY
