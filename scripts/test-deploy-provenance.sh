#!/usr/bin/env bash
# Offline API/event fixtures for the existing deployment workflow.
set -Eeuo pipefail
python3 - <<'PY'
import copy
import io
from contextlib import redirect_stdout
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
        self.path = Path(self.tmp.name) / 'event.json'
        self.event = dict(repository=REPO, ref='refs/heads/main', after=SHA,
                          deleted=False, forced=False)
        self.env = dict(GITHUB_REPOSITORY=m.REPO, GITHUB_REF='refs/heads/main',
                        GITHUB_EVENT_NAME='push', GITHUB_EVENT_PATH=str(self.path),
                        AUTOMATIC_DEPLOYMENT='enabled')
        self.pr = dict(merged_at='synthetic', merge_commit_sha=SHA,
                       base=dict(ref='main', repo=REPO))
        self.run = dict(id=12, head_sha=SHA, path='.github/workflows/deploy.yml',
                        repository=REPO, head_repository=REPO, head_branch='main',
                        event='push', status='in_progress', conclusion=None)
        self.jobs = [dict(name='validate / Validate sources', status='completed', conclusion='success'),
                     dict(name='Deploy over Tailscale', status='in_progress', conclusion=None)]

    def authorize(self):
        self.path.write_text(json.dumps(self.event))
        with patch.dict(os.environ, self.env, clear=True), patch.object(m, 'get', side_effect=[
                [self.pr], {'object': {'sha': SHA}}]):
            m.authorize(SHA)

    def test_main_merge(self):
        self.authorize()

    def test_event_ref_repository_and_activation_refusals(self):
        for key, value in [('GITHUB_REPOSITORY', 'other/repo'),
                           ('GITHUB_REF', 'refs/heads/feature/x'),
                           ('GITHUB_EVENT_NAME', 'pull_request'),
                           ('GITHUB_EVENT_NAME', 'workflow_run'),
                           ('AUTOMATIC_DEPLOYMENT', '')]:
            with self.subTest(key=key, value=value):
                original = self.env[key]
                self.env[key] = value
                with self.assertRaises(ValueError): self.authorize()
                self.env[key] = original
        for key, value in [('repository', dict(full_name=m.REPO, fork=True)),
                           ('repository', dict(full_name='other/repo', fork=False)),
                           ('after', 'b'*40), ('deleted', True), ('forced', True)]:
            with self.subTest(key=key):
                original = self.event[key]
                self.event[key] = value
                with self.assertRaises(ValueError): self.authorize()
                self.event[key] = original

    def test_merged_main_provenance(self):
        for key, value in [('merged_at', None), ('merge_commit_sha', 'b'*40),
                           ('base', dict(ref='other', repo=REPO))]:
            with self.subTest(key=key):
                self.pr[key] = value
                with self.assertRaises(ValueError): self.authorize()

    def test_manual_exact_main_assent(self):
        self.env['GITHUB_EVENT_NAME'] = 'workflow_dispatch'
        self.event['inputs'] = dict(deployment_sha=SHA, authorize_production='true')
        self.path.write_text(json.dumps(self.event))
        with patch.dict(os.environ, self.env, clear=True), patch.object(m, 'get', return_value={'object': {'sha': SHA}}):
            m.authorize(SHA)
            self.event['inputs']['authorize_production'] = 'false'
            self.path.write_text(json.dumps(self.event))
            with self.assertRaises(ValueError): m.authorize(SHA)

    def runs(self):
        entries = [self.run, dict(id=13, head_sha=SHA, path='other.yml',
                                 status='completed', conclusion='success')]
        with patch.object(m, 'get', side_effect=[dict(total_count=2, workflow_runs=entries),
                                                dict(total_count=len(self.jobs), jobs=self.jobs)]):
            with redirect_stdout(io.StringIO()):
                m.runs(SHA)
        return entries

    def test_own_wait_does_not_deadlock(self):
        self.assertEqual(self.runs()[0]['status'], 'completed')

    def test_untrusted_runs_and_missing_failed_validation(self):
        for key, value in [('head_sha', 'b'*40), ('head_branch', 'other'),
                           ('head_repository', {'full_name': 'fork/repo'}),
                           ('repository', {'full_name': 'other/repo'}),
                           ('event', 'pull_request'), ('status', 'cancelled')]:
            with self.subTest(key=key):
                original = copy.deepcopy(self.run)
                self.run[key] = value
                with self.assertRaises(ValueError): self.runs()
                self.run = original
        for conclusion in ['failure', 'cancelled', 'timed_out', 'neutral', 'skipped', None]:
            with self.subTest(conclusion=conclusion):
                self.jobs[0]['conclusion'] = conclusion
                with self.assertRaises(ValueError): self.runs()
        self.jobs = self.jobs[1:]
        with self.assertRaises(ValueError): self.runs()

    def test_recovery_supersedes_only_prior_deploy_attempt(self):
        old = dict(self.run, id=1, status='completed', conclusion='failure')
        entries = [old, self.run]
        with patch.object(m, 'get', side_effect=[dict(total_count=2, workflow_runs=entries),
                                                dict(total_count=2, jobs=self.jobs)]):
            output = io.StringIO()
            with redirect_stdout(output): m.runs(SHA)
        result = json.loads(output.getvalue())['workflow_runs']
        self.assertEqual([r['id'] for r in result], [12])

    def test_queued_overlap_does_not_fail_active_deployment(self):
        future = dict(self.run, id=99, status='queued', conclusion=None)
        with patch.object(m, 'get', side_effect=[dict(total_count=2, workflow_runs=[self.run, future]),
                                                dict(total_count=2, jobs=self.jobs)]):
            output = io.StringIO()
            with redirect_stdout(output): m.runs(SHA)
        self.assertEqual([r['id'] for r in json.loads(output.getvalue())['workflow_runs']], [12])

    def test_api_shape_missing_or_excess_results(self):
        for data in [{}, dict(total_count=0, workflow_runs=[]),
                     dict(total_count=101, workflow_runs=[self.run]),
                     dict(total_count=1, workflow_runs=[dict(self.run, status='completed', conclusion='failure')])]:
            with self.subTest(data=data), patch.object(m, 'get', return_value=data):
                with self.assertRaises((ValueError, KeyError)): m.runs(SHA)

    def test_stale_main(self):
        self.path.write_text(json.dumps(self.event))
        with patch.dict(os.environ, self.env, clear=True), patch.object(m, 'get', side_effect=[
                [self.pr], {'object': {'sha': 'b'*40}}]):
            with self.assertRaises(ValueError): m.authorize(SHA)

    def test_post_start_failure_reaches_unit_result_and_resolved_log(self):
        root = Path(self.tmp.name)
        (root / 'lib').mkdir()
        (root / 'lib/haven-env.sh').write_text(Path('scripts/lib/haven-env.sh').read_text())
        wrapper = root / 'deploy-verify.sh'
        wrapper.write_text(Path('scripts/deploy-verify.sh').read_text())
        verifier = root / 'run-post-deploy-verify.sh'
        verifier.write_text('#!/bin/bash\nprintf "FAIL: fixture verification\\n"\nexit 23\n')
        verifier.chmod(0o755)
        log = root / 'custom.log'
        env = dict(os.environ, HAVEN_ENV_FILE=str(root / 'absent'),
                   HAVEN_STACK_ENV_FILE=str(root / 'absent'), HAVEN_POST_DEPLOY_VERIFY_LOG=str(log))
        result = subprocess.run(['bash', str(wrapper), SHA], env=env, capture_output=True)
        self.assertEqual(result.returncode, 23)
        self.assertIn('FAIL: fixture verification', log.read_text())
        self.assertEqual(result.stdout, b'')

    def test_map_bot_checks_dispatch_without_production_or_merge(self):
        workflow = Path('.github/workflows/agent-context-committer.yml').read_text()
        step = workflow.split('      - name: Dispatch the required workflows', 1)[1].split('      - name:', 1)[0]
        body = step.split('        run: |\n', 1)[1]
        import textwrap
        root = Path(self.tmp.name)
        mock = root / 'curl'
        log = root / 'calls'
        mock.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALL_LOG"\nprintf 204\n')
        mock.chmod(0o755)
        env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                   CALL_LOG=str(log), GITHUB_TOKEN='synthetic', REPO=m.REPO,
                   BRANCH='bot/agent-context-fixture')
        subprocess.run(['bash', '-euo', 'pipefail', '-c', textwrap.dedent(body)], env=env, check=True)
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all('/dispatches' in c and 'bot/agent-context-fixture' in c for c in calls))
        self.assertTrue(any('agent-context.yml/dispatches' in c for c in calls))
        self.assertTrue(any('sast-checks.yml/dispatches' in c for c in calls))
        self.assertNotIn('/merge', workflow)
        # Human merge is a normal push, including a map-only PR.
        self.authorize()
        self.env.update(GITHUB_REF='refs/heads/bot/agent-context-fixture',
                        GITHUB_EVENT_NAME='workflow_dispatch')
        with self.assertRaises(ValueError): self.authorize()

    def test_workflow_wiring(self):
        workflow = Path('.github/workflows/deploy.yml').read_text()
        self.assertIn('group: deploy-control-plane\n  cancel-in-progress: false', workflow)
        self.assertLess(workflow.index('Verify exact-main deployment provenance'), workflow.index('Connect to tailnet'))
        self.assertIn('needs: validate', workflow)
        unit = Path('deploy/haven-deploy@.service').read_text()
        self.assertIn('ExecStartPost=/bin/bash /opt/haven/scripts/deploy-verify.sh %i', unit)
        self.assertIn('/usr/bin/timeout --kill-after=30s 10m', Path('scripts/deploy-verify.sh').read_text())
        self.assertIn('Environment=HAVEN_VERIFY_INSTALL_ROOT=1', unit)
        self.assertIn('Environment=HAVEN_VERIFY_DEPLOY_JOB=1', unit)
        self.assertNotIn('Restart=', '\n'.join(l for l in unit.splitlines() if not l.startswith('#')))

unittest.main()
PY
