#!/usr/bin/env bash
# Offline API/event fixtures for the existing deployment workflow.
set -Eeuo pipefail
python3 - <<'PY'
import base64
import copy
import io
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import json
import os
import subprocess
import sys
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
                        event='push', status='in_progress', conclusion=None, run_attempt=1)
        self.jobs = [dict(id=101, run_id=12, head_sha=SHA, run_attempt=1, name='validate / Validate sources', status='completed', conclusion='success'),
                     dict(id=102, run_id=12, head_sha=SHA, run_attempt=1, name='Deploy over Tailscale', status='in_progress', conclusion=None)]

    def authorize(self):
        self.path.write_text(json.dumps(self.event))
        with patch.dict(os.environ, self.env, clear=True), patch.object(m, 'get', side_effect=[
                [self.pr], {'object': {'sha': SHA}}]):
            m.authorize(SHA)

    def test_acceptance_signature_is_bound_to_sha_run_attempt_and_key(self):
        root = Path(self.tmp.name)
        private_key = root / 'signing-key'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(private_key)],
                       check=True, capture_output=True)
        public_key = subprocess.check_output(
            ['openssl', 'pkey', '-in', str(private_key), '-pubout'], text=True)
        message = root / 'message'
        message.write_text(f'haven-production-v1 {SHA} 12 1')
        encoded = base64.b64encode(subprocess.check_output([
            'openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(private_key), '-in', str(message)]))
        log = b'2026-11-21T13:19:40.123Z ' + message.read_bytes() + b' ' + encoded + b'\r\n'
        m.verify_receipt(log, SHA, 12, 1, public_key)
        for sha, run, attempt in (('b' * 40, 12, 1), (SHA, 13, 1), (SHA, 12, 2)):
            actual = log.replace(message.read_bytes(),
                                 f'haven-production-v1 {sha} {run} {attempt}'.encode())
            with self.assertRaisesRegex(m.Refused, 'AUTHORIZATION_REQUIRED_RECEIPT'):
                m.verify_receipt(actual, sha, run, attempt, public_key)

    def test_runner_refuses_newest_incomplete_deployment_without_falling_back(self):
        current = dict(self.run, id=13)
        previous = dict(self.run, status='completed', conclusion='failure')
        job = dict(self.jobs[1], status='completed', conclusion='failure',
                   steps=[dict(name='Trigger deploy', started_at='synthetic', conclusion='failure')])
        env = dict(GITHUB_RUN_ID='13', DEPLOY_RECEIPT_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----')
        with patch.dict(os.environ, env, clear=True), patch.object(m, 'get', side_effect=[
                dict(workflow_runs=[current, previous]), dict(jobs=[job], total_count=1)]), \
                patch.object(subprocess, 'check_output') as logs:
            with self.assertRaisesRegex(m.Refused, 'AUTHORIZATION_REQUIRED_RECEIPT'):
                m.accepted_baseline()
            logs.assert_not_called()

    def test_preflight_exports_only_classified_outcomes(self):
        self.path.write_text(json.dumps(self.event))
        output = Path(self.tmp.name) / 'outputs'
        self.env['GITHUB_OUTPUT'] = str(output)
        for impact in ('docs-only', 'routine', 'protected'):
            with self.subTest(impact=impact), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(m, 'require_current_main'), \
                    patch.object(m, 'accepted_baseline', return_value='b' * 40), \
                    patch.object(m, 'git', return_value=Path('scripts/deploy-impact.py').read_bytes()) \
                    as git, patch.object(subprocess, 'check_output', return_value=impact):
                with redirect_stdout(io.StringIO()) as log:
                    self.assertEqual(m.preflight_impact(SHA), impact)
                git.assert_called_once_with('show', 'b' * 40 + ':scripts/deploy-impact.py')
                self.assertEqual('AUTHORIZATION_REQUIRED' in log.getvalue(), impact == 'protected')
        self.assertEqual(output.read_text().splitlines(),
                         ['impact=docs-only', 'impact=routine', 'impact=protected'])

    def test_cumulative_preflight_refuses_forced_push_before_receipt_lookup(self):
        self.event['forced'] = True
        self.path.write_text(json.dumps(self.event))
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(m, 'require_current_main'), patch.object(m, 'accepted_baseline') as baseline:
            with self.assertRaisesRegex(m.Refused, 'AUTHORIZATION_REQUIRED_MAIN_HISTORY'):
                m.preflight_impact(SHA)
            baseline.assert_not_called()

    def test_pr_evidence_retries_transient_api_errors(self):
        errors = [m.Refused('PROVENANCE_API_TRANSIENT', retry=True),
                  m.Refused('PROVENANCE_API_TRANSPORT', retry=True)]
        with patch.object(m, 'pr_validation', side_effect=[*errors, None]) as verify, \
                patch.object(m.time, 'sleep') as sleep, redirect_stderr(io.StringIO()):
            m.verify_pr_evidence(SHA)
        self.assertEqual([call.args for call in verify.call_args_list], [(SHA,)] * 3)
        self.assertEqual([call.args for call in sleep.call_args_list], [(1,), (2,)])

    def test_pr_evidence_stops_after_transient_retry_budget(self):
        error = m.Refused('PROVENANCE_API_TRANSIENT', retry=True)
        with patch.object(m, 'pr_validation', side_effect=error) as verify, \
                patch.object(m.time, 'sleep'), redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(m.Refused, 'PROVENANCE_API_TRANSIENT'):
                m.verify_pr_evidence(SHA)
        self.assertEqual(verify.call_count, 3)

    def test_pr_evidence_does_not_retry_policy_refusal(self):
        error = m.Refused('PR_VALIDATION_TESTED_TREE')
        with patch.object(m, 'pr_validation', side_effect=error) as verify, \
                patch.object(m.time, 'sleep') as sleep:
            with self.assertRaisesRegex(m.Refused, 'PR_VALIDATION_TESTED_TREE'):
                m.verify_pr_evidence(SHA)
        verify.assert_called_once_with(SHA)
        sleep.assert_not_called()

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

    def test_both_event_modes_reject_a_superseded_main_sha(self):
        self.event['inputs'] = dict(deployment_sha=SHA, authorize_production='true')
        self.path.write_text(json.dumps(self.event))
        for event in ('push', 'workflow_dispatch'):
            with self.subTest(event=event), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(m, 'merged'), patch.object(m, 'get', return_value={
                        'object': {'sha': 'b' * 40}}):
                os.environ['GITHUB_EVENT_NAME'] = event
                with self.assertRaisesRegex(ValueError, 'PROVENANCE_MAIN_SHA'):
                    m.authorize(SHA)

    def run_api(self, entries=None, history=None, attempt_jobs=None, refreshed=None):
        run = copy.deepcopy(self.run)
        entries = copy.deepcopy(entries if entries is not None else [run, dict(
            id=13, head_sha=SHA, path='other.yml', repository=REPO, head_repository=REPO,
            status='completed', conclusion='success')])
        history = copy.deepcopy(self.jobs if history is None else history)
        attempt_jobs = attempt_jobs or {run['run_attempt']: history}
        self.responses = {
            '/actions/runs?head_sha=' + SHA + '&per_page=100': dict(total_count=len(entries), workflow_runs=entries),
            '/actions/runs/12/jobs?filter=all&per_page=100': dict(total_count=len(history), jobs=history),
            '/actions/runs/12': copy.deepcopy(refreshed or run)}
        for attempt, jobs in attempt_jobs.items():
            self.responses[f'/actions/runs/12/attempts/{attempt}/jobs?per_page=100'] = dict(total_count=len(jobs), jobs=copy.deepcopy(jobs))

    def execute(self):
        output = io.StringIO()
        with patch.object(m, 'get', side_effect=lambda path: copy.deepcopy(self.responses[path])), redirect_stdout(output):
            m.runs(SHA)
        return json.loads(output.getvalue())['workflow_runs']

    def runs(self):
        self.run_api()
        return self.execute()

    def test_own_wait_does_not_deadlock(self):
        self.assertEqual(self.runs()[0], dict(id=12, status='completed', conclusion='success'))

    def host_authorize(self, current=SHA):
        self.responses['/git/ref/heads/main'] = {'object': {'sha': current}}

        def api(path, *, authenticated=False):
            self.assertFalse(authenticated)
            return copy.deepcopy(self.responses[path])

        with patch.object(m, 'get', side_effect=api):
            m.authorize_host(SHA)

    def test_host_requires_an_active_validated_run_for_current_main(self):
        self.run_api()
        self.host_authorize()
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_MAIN_SHA'):
            self.host_authorize(current='b' * 40)
        for entries, jobs, reason in (
            ([], self.jobs, 'ACTIVE_MISSING'),
            ([self.run, dict(self.run, id=99)], self.jobs, 'ACTIVE_AMBIGUOUS'),
            ([self.run], self.jobs[1:], 'VALIDATION_MISSING'),
            ([self.run], [*self.jobs, dict(self.jobs[0], id=103)], 'VALIDATION_AMBIGUOUS'),
            ([self.run], [dict(self.jobs[0], conclusion='failure'), self.jobs[1]], 'VALIDATION_FAILED'),
        ):
            with self.subTest(reason=reason):
                self.run_api(entries=entries, history=jobs)
                with self.assertRaisesRegex(m.Refused, reason):
                    self.host_authorize()

    def test_host_fails_closed_on_api_error(self):
        with patch.object(m.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = OSError('SYNTHETIC_PRIVATE_DETAIL')
            with self.assertRaisesRegex(m.Refused, '^PROVENANCE_API_TRANSPORT$'):
                m.authorize_host(SHA)

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
        self.run_api(entries=entries)
        result = self.execute()
        self.assertEqual([r['id'] for r in result], [12])

    def test_queued_overlap_does_not_fail_active_deployment(self):
        future = dict(self.run, id=99, status='queued', conclusion=None)
        self.run_api(entries=[self.run, future])
        self.assertEqual([r['id'] for r in self.execute()], [12])

    def test_api_shape_missing_or_excess_results(self):
        for data in [{}, dict(total_count=0, workflow_runs=[]),
                     dict(total_count=101, workflow_runs=[self.run]),
                     dict(total_count=1, workflow_runs=[dict(self.run, status='completed', conclusion='failure')])]:
            with self.subTest(data=data), patch.object(m, 'get', return_value=data):
                with self.assertRaises((ValueError, KeyError)): m.runs(SHA)

    def rerun_fixture(self, inherited=True):
        self.run['run_attempt'] = 2
        old_validation, old_deploy = copy.deepcopy(self.jobs)
        old_deploy.update(status='completed', conclusion='failure')
        deploy = dict(old_deploy, id=202, run_attempt=2, status='in_progress', conclusion=None)
        current = [deploy]
        if not inherited:
            current.insert(0, dict(old_validation, id=201, run_attempt=2))
        self.run_api(history=[old_validation, old_deploy] + current,
                     attempt_jobs={1: [old_validation, old_deploy], 2: current})

    def test_failed_job_rerun_inherits_validation(self):
        self.rerun_fixture()
        self.assertEqual(self.execute()[0]['conclusion'], 'success')

    def test_github_copied_validation_in_latest_attempt(self):
        self.rerun_fixture(inherited=False)
        self.assertEqual(self.execute()[0]['conclusion'], 'success')

    def test_later_validation_supersedes_success(self):
        for state in ('failure', 'cancelled', 'skipped', 'timed_out', 'neutral', None):
            self.rerun_fixture(inherited=False)
            for data in self.responses.values():
                for job in data.get('jobs', []):
                    if job['id'] == 201:
                        job['conclusion'] = state
            with self.assertRaisesRegex(m.Refused, 'PROVENANCE_VALIDATION_FAILED'):
                self.execute()

    def test_attempt_change_and_incomplete_evidence_retry(self):
        self.rerun_fixture()
        self.responses['/actions/runs/12']['run_attempt'] = 3
        with self.assertRaises(m.Refused) as caught: self.execute()
        self.assertTrue(caught.exception.retry)
        self.rerun_fixture()
        self.responses['/actions/runs/12/jobs?filter=all&per_page=100']['total_count'] = 99
        with self.assertRaises(m.Refused) as caught: self.execute()
        self.assertTrue(caught.exception.retry)

    def test_job_identity_duplicate_and_cross_view_disagreement(self):
        for key, value in [('head_sha', 'b'*40), ('run_id', 99), ('run_attempt', 3)]:
            self.rerun_fixture()
            self.responses['/actions/runs/12/jobs?filter=all&per_page=100']['jobs'][0][key] = value
            with self.assertRaises(m.Refused): self.execute()
        self.rerun_fixture()
        data = self.responses['/actions/runs/12/jobs?filter=all&per_page=100']
        data['jobs'].append(copy.deepcopy(data['jobs'][0])); data['total_count'] += 1
        with self.assertRaisesRegex(m.Refused, 'AMBIGUOUS'): self.execute()
        self.rerun_fixture()
        self.responses['/actions/runs/12/attempts/1/jobs?per_page=100']['jobs'][0]['conclusion'] = 'failure'
        with self.assertRaises(m.Refused) as caught: self.execute()
        self.assertTrue(caught.exception.retry)

    def test_active_failed_conclusions_are_not_accepted(self):
        self.rerun_fixture()
        self.responses['/actions/runs/12/attempts/2/jobs?per_page=100']['jobs'][0]['conclusion'] = 'failure'
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_DEPLOY_STATE'): self.execute()
        self.rerun_fixture()
        self.responses['/actions/runs/12']['conclusion'] = 'failure'
        with self.assertRaisesRegex(m.Refused, 'PROVENANCE_DEPLOY_STATE'): self.execute()

    def test_transport_http_and_json_diagnostics_are_fixed(self):
        import urllib.error
        errors = [(urllib.error.URLError('private fixture'), 'PROVENANCE_API_TRANSPORT', True),
                  (m.http.client.BadStatusLine('private fixture'), 'PROVENANCE_API_TRANSPORT', True),
                  (urllib.error.HTTPError('private', 503, 'private', {}, None), 'PROVENANCE_API_TRANSIENT', True),
                  (urllib.error.HTTPError('private', 403, 'private', {'X-RateLimit-Remaining': '0'}, None), 'PROVENANCE_API_TRANSIENT', True),
                  (urllib.error.HTTPError('private', 403, 'private', {}, None), 'PROVENANCE_API_HTTP', False),
                  (urllib.error.HTTPError('private', 404, 'private', {}, None), 'PROVENANCE_API_HTTP', False)]
        for error, code, retry in errors:
            with patch.object(m.urllib.request, 'build_opener') as opener:
                opener.return_value.open.side_effect = error
                with self.assertRaises(m.Refused) as caught: m.get('/fixture')
                self.assertEqual(str(caught.exception), code)
                self.assertEqual(caught.exception.retry, retry)
        with patch.object(m.urllib.request, 'build_opener'), patch.object(m.json, 'load', side_effect=ValueError('private')):
            with self.assertRaisesRegex(m.Refused, '^PROVENANCE_API_JSON$'): m.get('/fixture')

    def test_cli_diagnostics_never_include_exception_payload(self):
        import contextlib
        import runpy
        for command, error, expected in [
                ('runs', m.urllib.error.URLError('PRIVATE_FIXTURE'), 75),
                ('authorize', m.urllib.error.URLError('PRIVATE_FIXTURE'), 1),
                ('runs', m.urllib.error.HTTPError('PRIVATE_FIXTURE', 401, 'PRIVATE_FIXTURE', {}, None), 1)]:
            stderr = io.StringIO()
            with patch.object(m.urllib.request, 'build_opener') as opener:
                opener.return_value.open.side_effect = error
                with patch.object(m.sys, 'argv', ['deploy-provenance.py', command, SHA]), \
                     patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stderr(stderr):
                    self.path.write_text(json.dumps(self.event))
                    with self.assertRaises(SystemExit) as caught:
                        runpy.run_path('scripts/deploy-provenance.py', run_name='__main__')
            self.assertEqual(caught.exception.code, expected)
            self.assertRegex(stderr.getvalue(), r'^PROVENANCE_[A-Z_]+\n$')
            self.assertNotIn('PRIVATE_FIXTURE', stderr.getvalue())

    def test_pending_missing_and_terminal_run_evidence(self):
        for changed in ('validation', 'deploy', 'empty'):
            self.rerun_fixture()
            path = '/actions/runs/12/attempts/2/jobs?per_page=100'
            if changed == 'validation':
                path = '/actions/runs/12/jobs?filter=all&per_page=100'
                self.responses[path]['jobs'][0]['status'] = 'in_progress'
            elif changed == 'deploy':
                self.responses[path] = dict(total_count=0, jobs=[])
            else:
                self.responses[path] = {}
            with self.assertRaises(m.Refused) as caught: self.execute()
            self.assertTrue(caught.exception.retry)
        self.rerun_fixture()
        self.responses['/actions/runs/12'].update(status='completed', conclusion='failure')
        with self.assertRaises(m.Refused) as caught: self.execute()
        self.assertFalse(caught.exception.retry)

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
        self.assertIn('needs: [pr-evidence, validate]', workflow)
        unit = Path('deploy/haven-deploy@.service').read_text()
        self.assertIn('ExecStartPost=/bin/bash /opt/haven/scripts/deploy-verify.sh %i', unit)
        self.assertIn('/usr/bin/timeout --kill-after=30s 10m', Path('scripts/deploy-verify.sh').read_text())
        self.assertIn('Environment=HAVEN_VERIFY_INSTALL_ROOT=1', unit)
        self.assertIn('Environment=HAVEN_VERIFY_DEPLOY_JOB=1', unit)
        self.assertNotIn('Restart=', '\n'.join(l for l in unit.splitlines() if not l.startswith('#')))

class PRValidation(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.output = root / 'output'
        self.event_path = root / 'event'
        self.base, self.head, self.tested, self.tree = (key * 40 for key in 'bcde')
        self.event = dict(repository=REPO, ref='refs/heads/main', before=self.base, after=SHA,
                          deleted=False, forced=False)
        self.env = dict(GH_TOKEN='fixture', GITHUB_REPOSITORY=m.REPO, GITHUB_REF='refs/heads/main',
                        GITHUB_EVENT_NAME='push', AUTOMATIC_DEPLOYMENT='enabled',
                        GITHUB_EVENT_PATH=str(self.event_path), GITHUB_OUTPUT=str(self.output),
                        GITHUB_RUN_ATTEMPT='2')
        self.runs = []
        self.api = {}
        self.pr = dict(number=15, merged_at='synthetic', merge_commit_sha=SHA,
                       base=dict(ref='main', repo=REPO),
                       head=dict(ref='feature', sha=self.head, repo=dict(REPO)))
        self.api[f'/commits/{SHA}/pulls?per_page=100'] = [self.pr]
        self.commit = dict(sha=self.tested, tree=dict(sha=self.tree),
                           parents=[dict(sha=self.base), dict(sha=self.head)])
        self.api[f'/git/commits/{self.tested}'] = self.commit
        receipt = dict(name=f'PR checkout 15 {self.base} {self.tested}',
                       status='completed', conclusion='success')
        self.jobs = {}
        for run_id, (path, names) in enumerate(m.PR_WORKFLOWS.items(), 20):
            run = dict(path=path, id=run_id, run_number=1, run_attempt=1, head_sha=self.head,
                       repository=REPO, head_repository=REPO, head_branch='feature',
                       event='pull_request', status='completed', conclusion='success')
            self.runs.append(run)
            jobs = [dict(run_id=run_id, run_attempt=1, head_sha=self.head, name=name,
                         status='completed', conclusion='success', steps=[dict(receipt)])
                    for name in names]
            self.jobs.update((job['name'], job) for job in jobs)
            self.api[f'/actions/runs/{run_id}/attempts/1/jobs?per_page=100'] = dict(
                jobs=jobs, total_count=len(jobs))
        source = self.jobs['Validate sources / Validate sources']
        self.source_steps = source['steps']
        self.source_steps.extend(dict(receipt, name=name) for name in (
            'Select component tests', 'Shell syntax check', 'Python syntax check',
            'Assert no secrets are tracked'))
        self.runs[0]['referenced_workflows'] = [
            dict(ref='refs/pull/15/merge', sha=self.tested,
                 path=f'{m.REPO}/.github/workflows/validate.yml@{self.tested}')]
        self.list_path = f'/actions/runs?head_sha={self.head}&per_page=100'
        self.api[self.list_path] = dict(workflow_runs=self.runs, total_count=len(self.runs))
        self.paths = b'auth/app.py\0'
        self.checked_out = f'{SHA}\n{self.base}\n'.encode()
        self.flags = 'full=false\nauth=true\nproxy=true\n'

    def verify(self):
        self.event_path.write_text(json.dumps(self.event))
        def get(path, authenticated=False):
            self.assertEqual(authenticated, '/pulls?' not in path)
            return copy.deepcopy(self.api[path])
        with patch.dict(os.environ, self.env, clear=True), patch.object(m, 'get', side_effect=get), \
                patch.object(m, 'git', side_effect=[self.checked_out, self.paths, self.tree.encode()]), \
                patch.object(m.subprocess, 'check_output', return_value=self.flags), \
                redirect_stdout(io.StringIO()) as log:
            m.pr_validation(SHA)
            return log.getvalue()

    def test_reuses_exact_checked_tree_and_reports_coverage(self):
        log = self.verify()
        self.assertIn('Reusing PR #15', log)
        self.assertIn('auth=true', log)
        self.assertEqual(self.output.read_text(), 'reuse_attempt=2\n')

    def test_missing_source_receipt_or_full_selection_runs_full(self):
        self.jobs['Validate sources / Validate sources']['steps'] = []
        self.assertIn('Full deployment validation', self.verify())
        self.assertFalse(self.output.exists())
        self.jobs['Validate sources / Validate sources']['steps'] = self.source_steps
        self.flags = 'full=true\n'
        self.assertIn('cross-cutting', self.verify())
        self.assertFalse(self.output.exists())

    def test_missing_required_source_step_does_not_reuse(self):
        self.source_steps[-1]['conclusion'] = 'skipped'
        with self.assertRaisesRegex(ValueError, 'SOURCE_COVERAGE'):
            self.verify()

    def test_latest_failed_or_cancelled_run_cannot_use_older_green(self):
        for failure in ('failure', 'cancelled'):
            latest = dict(self.runs[0], id=32, run_number=2, conclusion=failure)
            self.api[self.list_path] = dict(workflow_runs=self.runs + [latest], total_count=3)
            with self.subTest(failure=failure), self.assertRaisesRegex(ValueError, 'UNSUCCESSFUL'):
                self.verify()
        self.assertFalse(self.output.exists())

    def test_missing_context_and_failed_security_jobs_refuse(self):
        context = self.jobs['Check agent context maps']
        receipt = context['steps'].pop()
        with self.assertRaisesRegex(ValueError, 'CONTEXT_CHECKOUT_MISSING'):
            self.verify()
        context['steps'].append(receipt)
        for name in ('CodeQL (python)', 'CodeQL (actions)', 'ShellCheck (Bash)', 'Semgrep (SAST)'):
            with self.subTest(job=name), self.assertRaisesRegex(ValueError, 'REQUIRED_JOB_UNSUCCESSFUL'):
                job = self.jobs[name]
                job['conclusion'] = 'failure'
                try:
                    self.verify()
                finally:
                    job['conclusion'] = 'success'
        self.assertFalse(self.output.exists())

    def test_different_checkout_tree_base_and_pr_ref_refused(self):
        for obj, field, value, reason in (
            (self.commit, 'tree', dict(sha='f'*40), 'TESTED_TREE'),
            (self.commit, 'parents', [dict(sha=self.head), dict(sha=self.base)], 'TESTED_PARENTS'),
            (self.runs[0]['referenced_workflows'][0], 'ref', 'refs/pull/16/merge', 'WORKFLOW_REFERENCE'),
            (self.jobs['Check agent context maps']['steps'][0], 'name',
             f'PR checkout 15 {self.base} {self.head}', 'CHECKOUT_MISMATCH'),
        ):
            old = obj[field]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, reason):
                obj[field] = value
                try:
                    self.verify()
                finally:
                    obj[field] = old

    def test_push_modes_and_workflow_policy(self):
        self.env['GITHUB_EVENT_NAME'] = 'workflow_dispatch'
        with self.assertRaises(ValueError):
            self.verify()
        self.env['GITHUB_EVENT_NAME'] = 'push'
        # Merge and squash have the same admissible first parent. A multi-
        # commit rebase or batched push lacks this exact push-base binding.
        self.checked_out = f'{SHA}\n{self.head}\n'.encode()
        with self.assertRaisesRegex(ValueError, 'MAIN_PARENT'):
            self.verify()
        self.checked_out = f'{SHA}\n{self.base}\n'.encode()
        self.api[f'/commits/{SHA}/pulls?per_page=100'] = []
        with self.assertRaisesRegex(ValueError, 'MERGED_PULL'):
            self.verify()
        self.api[f'/commits/{SHA}/pulls?per_page=100'] = [self.pr]
        self.pr['head']['repo']['fork'] = True
        with self.assertRaisesRegex(ValueError, 'UNTRUSTED_PULL'):
            self.verify()
        self.pr['head']['repo']['fork'] = False
        self.paths = b'.github/workflows/deploy.yml\0'
        self.assertIn('Full deployment validation', self.verify())
        self.paths = b'.github/workflows/sast-checks.yml\0'
        with self.assertRaisesRegex(ValueError, 'SECURITY_POLICY_CHANGED'):
            self.verify()
        self.paths = b'scripts/deploy-provenance.py\0'
        with self.assertRaisesRegex(ValueError, 'SECURITY_POLICY_CHANGED'):
            self.verify()
        self.assertFalse(self.output.exists())

    def test_reruns_require_complete_current_attempt_and_consistent_jobs(self):
        path = '/actions/runs/20/attempts/1/jobs?per_page=100'
        jobs = self.api[path]['jobs']
        self.runs[0]['run_attempt'] = 2
        current = '/actions/runs/20/attempts/2/jobs?per_page=100'
        self.api[current] = dict(jobs=[], total_count=0)
        with self.assertRaisesRegex(ValueError, 'INCOMPLETE_ATTEMPT'):
            self.verify()
        self.api[current] = dict(jobs=jobs, total_count=len(jobs))
        with self.assertRaisesRegex(ValueError, 'JOB_IDENTITY'):
            self.verify()
        for job in jobs:
            job['run_attempt'] = 2
        self.assertIn('SAST run 20 attempt 2', self.verify())

    def test_incomplete_and_malformed_api_results_refuse(self):
        data = self.api[self.list_path]
        for count, reason in ((101, 'INCOMPLETE'), ('2', 'SHAPE')):
            with self.subTest(count=count), self.assertRaisesRegex(ValueError, reason):
                data['total_count'] = count
                self.verify()


CLASSIFIER = Path('scripts/deploy-impact.py').resolve()
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


unittest.main()
PY
