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
                        event='push', status='in_progress', conclusion=None, run_attempt=1)
        self.jobs = [dict(id=101, run_id=12, head_sha=SHA, run_attempt=1, name='validate / Validate sources', status='completed', conclusion='success'),
                     dict(id=102, run_id=12, head_sha=SHA, run_attempt=1, name='Deploy over Tailscale', status='in_progress', conclusion=None)]

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
        self.assertIn('needs: validate', workflow)
        unit = Path('deploy/haven-deploy@.service').read_text()
        self.assertIn('ExecStartPost=/bin/bash /opt/haven/scripts/deploy-verify.sh %i', unit)
        self.assertIn('/usr/bin/timeout --kill-after=30s 10m', Path('scripts/deploy-verify.sh').read_text())
        self.assertIn('Environment=HAVEN_VERIFY_INSTALL_ROOT=1', unit)
        self.assertIn('Environment=HAVEN_VERIFY_DEPLOY_JOB=1', unit)
        self.assertNotIn('Restart=', '\n'.join(l for l in unit.splitlines() if not l.startswith('#')))

unittest.main()
PY
