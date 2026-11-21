#!/usr/bin/env bash
# Offline API/event fixtures for the existing deployment workflow.
set -Eeuo pipefail
python3 - <<'PY'
import copy
import io
from contextlib import contextmanager, redirect_stdout
import importlib.util
import json
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
        self.pr = dict(merged_at='synthetic', merge_commit_sha=SHA,
                       base=dict(ref='main', repo=REPO))
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
        commit('upgrade pin')
        git('switch', '-q', 'main')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            'merge', '--no-ff', '-qm', 'merge upgrade', 'upgrade')
        merged = git('rev-parse', 'HEAD')
        with patch.dict(os.environ, GITHUB_OUTPUT=str(output)), patch.object(m, 'get', side_effect=[
                {'object': {'sha': merged}}, [dict(self.pr, merge_commit_sha=merged)]]):
            with self.changed_directory(checkout):
                m.candidate(merged, base)
        self.assertEqual(output.read_text(), 'deploy=true\n')

        manifest.with_name('README.md').write_text('release notes\n')
        docs = commit('docs only')
        output.unlink()
        with patch.dict(os.environ, GITHUB_OUTPUT=str(output)), patch.object(m, 'get') as api:
            with self.changed_directory(checkout):
                m.candidate(docs, merged)
            api.assert_not_called()
        self.assertEqual(output.read_text(), 'deploy=false\n')

        workflow = Path('.github/workflows/deploy.yml').read_text()
        self.assertIn('  push:\n    branches: [main]', workflow)
        self.assertNotIn('workflow_dispatch:', workflow)
        self.assertIn('needs: candidate\n    if:', workflow)
        self.assertIn('uses: ./.github/workflows/validate.yml', workflow)
        self.assertIn('needs: validate', workflow)
        self.assertNotIn('secrets.', workflow.split('  deploy:\n', 1)[0])
        self.assertNotIn('workflow_run:', Path('.github/workflows/sast-checks.yml').read_text())

    @contextmanager
    def changed_directory(self, path):
        previous = Path.cwd()
        os.chdir(path)
        try:
            yield
        finally:
            os.chdir(previous)

    def same_run(self, jobs, main=SHA):
        responses = {
            '/actions/workflows/deploy.yml/runs?event=push&branch=main&head_sha=' + SHA:
                dict(total_count=1, workflow_runs=[self.run]),
            '/actions/runs/12/attempts/1/jobs?per_page=100': dict(total_count=len(jobs), jobs=jobs),
            '/actions/runs/12': self.run,
            '/git/ref/heads/main': {'object': {'sha': main}},
        }
        with patch.object(m, 'get', side_effect=lambda path, **kwargs: responses[path]):
            m.authorize_host(SHA)

    def test_requires_current_main_with_successful_same_attempt_validation(self):
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

    def manual_fixture(self):
        head = 'b' * 40
        pr = dict(self.pr, number=7, head=dict(sha=head))
        def run(id, path, sha=SHA, **kw):
            return dict(self.run, id=id, path='.github/workflows/' + path,
                        head_sha=sha, **kw)
        ci = [run(20, 'sast-checks.yml', head), run(21, 'agent-context.yml', head)]
        for r in ci:
            r.update(event='pull_request', status='completed', conclusion='success')
        deploy = run(12, 'deploy.yml')
        deploy.update(status='completed', conclusion='skipped')
        bot = run(13, 'agent-context-committer.yml')
        bot.update(status='completed', conclusion='success')
        jobs = lambda entries: dict(total_count=len(entries), jobs=entries)
        passed = lambda name: dict(name=name, status='completed', conclusion='success')
        self.manual_data = {
            '/commits/' + SHA + '/pulls?per_page=100': [pr],
            '/git/commits/' + SHA: dict(sha=SHA, tree=dict(sha='d'*40)),
            '/git/commits/' + head: dict(sha=head, tree=dict(sha='d'*40)),
            '/actions/runs?head_sha=' + head + '&per_page=100': dict(total_count=2, workflow_runs=ci),
            '/actions/runs/20/jobs?per_page=100': jobs([passed('Security & SAST gate')]),
            '/actions/runs/21/jobs?per_page=100': jobs([passed('Check agent context maps')]),
            '/actions/runs?head_sha=' + SHA + '&per_page=100': dict(total_count=2, workflow_runs=[deploy, bot]),
            '/actions/runs/12/jobs?per_page=100': jobs([
                dict(name=name, status='completed', conclusion='skipped')
                for name in ('validate', 'Deploy over Tailscale')])}
        return ci, deploy, bot

    def manual(self):
        output = io.StringIO()
        with patch.object(m, 'get', side_effect=lambda path: copy.deepcopy(self.manual_data[path])), redirect_stdout(output):
            m.manual_runs(SHA)
        return json.loads(output.getvalue())

    def recovery_fixture(self):
        ci, deploy, _ = self.manual_fixture()
        deploy.update(status='completed', conclusion='failure', run_attempt=2)
        validation = dict(self.jobs[0])
        failed1 = dict(self.jobs[1], status='completed', conclusion='failure')
        failed2 = dict(failed1, id=202, run_attempt=2)
        def jobs(items): return dict(total_count=len(items), jobs=items)
        self.manual_data['/actions/runs/12/jobs?filter=all&per_page=100'] = jobs([validation, failed1, failed2])
        self.manual_data['/actions/runs/12/attempts/1/jobs?per_page=100'] = jobs([validation, failed1])
        self.manual_data['/actions/runs/12/attempts/2/jobs?per_page=100'] = jobs([failed2])
        self.manual_data['/actions/runs/12'] = copy.deepcopy(deploy)
        for run in ci:
            gate = self.manual_data[f"/actions/runs/{run['id']}/jobs?per_page=100"]['jobs'][0]
            gate.update(id=run['id']*10, run_id=run['id'], head_sha='b'*40, run_attempt=1)
            self.manual_data[f"/actions/runs/{run['id']}/attempts/1/jobs?per_page=100"] = jobs([copy.deepcopy(gate)])
            self.manual_data[f"/actions/runs/{run['id']}"] = copy.deepcopy(run)

    def recovery(self):
        output = io.StringIO()
        with patch.object(m, 'RECOVERY_SHA', SHA), patch.object(m, 'RECOVERY_RUN', 12), \
             patch.object(m, 'get', side_effect=lambda path: copy.deepcopy(self.manual_data[path])), redirect_stdout(output):
            m.manual_runs(SHA, historical=True)
        return json.loads(output.getvalue())

    def test_recovery_preserves_failure_and_inherited_validation(self):
        self.recovery_fixture()
        result = self.recovery()
        self.assertEqual(result['historical_failure']['failed_deploy_run'], 12)
        self.assertNotIn(12, [r['id'] for r in result['workflow_runs']])
        self.assertEqual(self.recovery(), result)

    def test_recovery_rejects_wrong_or_incomplete_evidence(self):
        for path, key, value in [('/actions/runs/12', 'run_attempt', 3),
                                 ('/actions/runs/20', 'conclusion', 'failure')]:
            self.recovery_fixture()
            self.manual_data[path][key] = value
            with self.assertRaises(ValueError): self.recovery()
        self.recovery_fixture()
        self.manual_data['/actions/runs/12/attempts/2/jobs?per_page=100']['jobs'][0]['conclusion'] = 'success'
        with self.assertRaises(ValueError): self.recovery()
        self.recovery_fixture()
        data = self.manual_data['/actions/runs/12/jobs?filter=all&per_page=100']
        data['jobs'].append(dict(self.jobs[0], id=203, run_attempt=2, conclusion='failure'))
        data['total_count'] += 1
        with self.assertRaises(ValueError): self.recovery()

    def test_manual_cutover_reuses_exact_merge_pr_checks_preserves_skip(self):
        self.manual_fixture()
        result = self.manual()
        self.assertEqual(result['manual_cutover']['merge_sha'], SHA)
        self.assertEqual(result['manual_cutover']['intentionally_skipped_deploy_runs'], [12])
        self.assertEqual([r['id'] for r in result['workflow_runs']], [13, 20, 21])
        self.assertEqual(self.manual(), result)  # stable retry

    def test_manual_cutover_different_or_unproven_merged_tree_refused(self):
        for commit, key, value in [(SHA, 'tree', dict(sha='e'*40)),
                                   (SHA, 'sha', 'e'*40),
                                   ('b'*40, 'tree', dict(sha='invalid'))]:
            self.manual_fixture()
            self.manual_data['/git/commits/' + commit][key] = value
            with self.assertRaises(ValueError): self.manual()

    def test_manual_cutover_required_workflows_and_jobs_fail_closed(self):
        for index in (0, 1):
            for state in ('skipped', 'failure', 'cancelled', 'timed_out', 'neutral', None):
                with self.subTest(index=index, state=state):
                    ci, _, _ = self.manual_fixture()
                    ci[index]['conclusion'] = state
                    with self.assertRaises(ValueError): self.manual()
                    self.manual_fixture()
                    self.manual_data[f'/actions/runs/{20 + index}/jobs?per_page=100']['jobs'][0]['conclusion'] = state
                    with self.assertRaises(ValueError): self.manual()
            self.manual_fixture()
            self.manual_data[f'/actions/runs/{20 + index}/jobs?per_page=100']['jobs'][0]['name'] = 'unrelated'
            with self.assertRaises(ValueError): self.manual()
        ci, _, _ = self.manual_fixture()
        ci[0]['path'] = 'missing.yml'
        with self.assertRaises(ValueError): self.manual()

    def test_manual_cutover_exception_is_only_disabled_push(self):
        for field, value in [('event', 'workflow_dispatch'), ('head_branch', 'other'),
                             ('head_sha', 'c'*40), ('status', 'in_progress'),
                             ('conclusion', 'failure'), ('conclusion', 'success'),
                             ('repository', dict(full_name='other/repo'))]:
            with self.subTest(field=field, value=value):
                _, deploy, _ = self.manual_fixture()
                deploy[field] = value
                with self.assertRaises(ValueError): self.manual()
        for state in ('success', 'failure', None):
            self.manual_fixture()
            self.manual_data['/actions/runs/12/jobs?per_page=100']['jobs'][0]['conclusion'] = state
            with self.assertRaises(ValueError): self.manual()
        _, _, bot = self.manual_fixture()
        bot['conclusion'] = 'skipped'
        with self.assertRaises(ValueError): self.manual()

    def test_manual_cutover_missing_merge_fork_and_truncated_api_refused(self):
        ci, _, _ = self.manual_fixture()
        ci[0]['head_repository'] = dict(full_name='fork/repo')
        with self.assertRaises(ValueError): self.manual()
        self.manual_fixture()
        self.manual_data['/commits/' + SHA + '/pulls?per_page=100'][0]['merge_commit_sha'] = 'c'*40
        with self.assertRaises(ValueError): self.manual()
        self.manual_fixture()
        self.manual_data['/actions/runs?head_sha=' + SHA + '&per_page=100']['total_count'] = 101
        with self.assertRaises(ValueError): self.manual()


unittest.main()
PY
