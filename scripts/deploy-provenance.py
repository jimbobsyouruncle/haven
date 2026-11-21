#!/usr/bin/env python3
"""Fail-closed main deployment provenance; API reads only, no host mutation."""
from datetime import datetime
import http.client
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = 'jimbobsyouruncle/haven'
API = 'https://api.github.com/repos/' + REPO
RECOVERY_SHA = '5c2df63a73c81ddfbad868dbfe617ee383242ff4'
RECOVERY_RUN = 44123963304
ELIGIBILITY_JOB = 'validate / Validate sources'
REQUIRED_CHECKS = ('Check agent context maps', 'Security & SAST gate')
GITHUB_ACTIONS_APP = 15368


class Refused(ValueError):
    def __init__(self, code, retry=False):
        self.code, self.retry = code, retry
        super().__init__(code)


def require(condition, code='PROVENANCE_POLICY'):
    if not condition:
        raise Refused(code)


def pending(code):
    raise Refused(code, retry=True)


def get(path, authenticated=False):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'haven-deployment'}
    # Only the Actions runner supplies a token. The root verifier is anonymous.
    if authenticated and os.environ.get('GH_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    request = urllib.request.Request(API + path, headers=headers)
    # Never forward credentials through an API redirect.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        retry = error.code in (408, 429, 500, 502, 503, 504) or (
            error.code == 403 and (error.headers.get('X-RateLimit-Remaining') == '0'
                                   or error.headers.get('Retry-After') is not None))
        error.close()
        raise Refused('PROVENANCE_API_TRANSIENT' if retry else 'PROVENANCE_API_HTTP', retry) from None
    except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError):
        raise Refused('PROVENANCE_API_TRANSPORT', retry=True) from None
    except (ValueError, UnicodeError):
        raise Refused('PROVENANCE_API_JSON', retry=True) from None


def merged(sha, *, authenticated=False):
    pulls = get('/commits/' + sha + '/pulls?per_page=100', authenticated=authenticated)
    require(isinstance(pulls, list) and len(pulls) < 100)
    matches = [p for p in pulls if p.get('merged_at') and p.get('merge_commit_sha') == sha
               and p.get('base', {}).get('ref') == 'main'
               and p.get('base', {}).get('repo', {}).get('full_name') == REPO]
    require(len(matches) == 1, 'PROVENANCE_MERGED_PR')
    return matches[0]


def require_current_main(sha, *, authenticated=False):
    require(get('/git/ref/heads/main', authenticated=authenticated).get('object', {}).get('sha') == sha,
            'PROVENANCE_MAIN_SHA')


DOC_PATH = re.compile(
    rb'(?:docs/(?:[a-zA-Z0-9_-]+/)*[a-zA-Z0-9_.-]+\.md|'
    rb'(?:[a-zA-Z0-9_-]+/)*README\.md|(?:SECURITY|REPO_MAP|CODE_INDEX)\.md|'
    rb'\.github/CICD\.md|deploy/IDENTITY-MIGRATION\.md)'
)


def application_changed(before, sha):
    require(re.fullmatch('[0-9a-f]{40}', before), 'PROVENANCE_PUSH_BASE')
    subprocess.run(['git', 'merge-base', '--is-ancestor', before, sha], check=True)
    paths = subprocess.check_output(
        ['git', 'diff', '--name-only', '--no-renames', '-z', before, sha, '--']
    ).split(b'\0')
    return any(path and not DOC_PATH.fullmatch(path) for path in paths)


def candidate(sha, before):
    checkout = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    require(checkout == sha, 'PROVENANCE_SHA')
    changed = application_changed(before, sha)
    if changed:
        require_current_main(sha, authenticated=True)
        require_merge_eligibility(sha, before)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        print('deploy=' + str(changed).lower(), file=output)


def require_merge_eligibility(sha, before):
    # Strict PR protection and no bypass govern the merge. Also confirm the
    # push base and PR head produce the same tree the runner would deploy.
    pr = merged(sha, authenticated=True)
    head = pr['head']['sha']
    require(re.fullmatch('[0-9a-f]{40}', head), 'PROVENANCE_PR_HEAD')
    commit = get('/git/commits/' + head, authenticated=True)
    tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip()
    require(commit['sha'] == head and commit['tree']['sha'] == tree, 'PROVENANCE_PR_TREE')
    # The original PR head may be absent locally after a squash or rebase.
    comparison = get(f'/compare/{before}...{head}?per_page=1', authenticated=True)
    require(comparison['merge_base_commit']['sha'] == before, 'PROVENANCE_PR_BASE')

    # Require actual successful checks from the configured GitHub App before
    # the merge. A skipped check or a success posted later cannot qualify it.
    merged_at = datetime.fromisoformat(pr['merged_at'].replace('Z', '+00:00'))
    for name in REQUIRED_CHECKS:
        query = urllib.parse.urlencode(dict(check_name=name, filter='latest', per_page=100))
        checks = evidence_list(get(f'/commits/{head}/check-runs?{query}', authenticated=True),
                               'check_runs')
        matches = [c for c in checks if c['name'] == name and c['app']['id'] == GITHUB_ACTIONS_APP]
        require(len(matches) == 1, 'PROVENANCE_PR_CHECK')
        check = matches[0]
        require((check['head_sha'], check['status'], check['conclusion']) ==
                (head, 'completed', 'success'), 'PROVENANCE_PR_CHECK')
        require(datetime.fromisoformat(check['completed_at'].replace('Z', '+00:00')) <= merged_at,
                'PROVENANCE_PR_CHECK_TIME')


def evidence_list(data, key):
    require(isinstance(data, dict), 'PROVENANCE_API_SHAPE')
    if key not in data or 'total_count' not in data:
        pending('PROVENANCE_INCOMPLETE')
    entries = data[key]
    require(isinstance(entries, list) and type(data['total_count']) is int
            and data['total_count'] >= 0, 'PROVENANCE_API_SHAPE')
    if data['total_count'] != len(entries) or len(entries) >= 100:
        pending('PROVENANCE_INCOMPLETE')
    return entries


def historical_deployment_jobs(run, sha):
    run_id, attempt = run['id'], run['run_attempt']
    require(type(run_id) is int and run_id > 0 and type(attempt) is int
            and attempt > 0, 'PROVENANCE_ATTEMPT')
    prefix = '/actions/runs/' + str(run_id)
    # History establishes which validation supersedes which. Never select any
    # old success merely because the current deployment job is a rerun.
    jobs = evidence_list(get(prefix + '/jobs?filter=all&per_page=100'), 'jobs')
    for job in jobs:
        require(job['run_id'] == run_id and job['head_sha'] == sha,
                'PROVENANCE_JOB_IDENTITY')
        require(type(job['run_attempt']) is int and 0 < job['run_attempt'] <= attempt,
                'PROVENANCE_ATTEMPT')
    validation = [j for j in jobs if j['name'] == 'validate / Validate sources']
    if not validation:
        pending('PROVENANCE_VALIDATION_MISSING')
    latest = max(j['run_attempt'] for j in validation)
    gates = [j for j in validation if j['run_attempt'] == latest]
    require(len(gates) == 1, 'PROVENANCE_VALIDATION_AMBIGUOUS')
    gate = gates[0]
    if gate['status'] != 'completed':
        pending('PROVENANCE_VALIDATION_PENDING')
    require(gate['conclusion'] == 'success', 'PROVENANCE_VALIDATION_FAILED')
    # Attempt-specific views authenticate both inherited validation and the
    # currently waiting deployment. Cross-view disagreement cannot pass.
    attempts = {}
    for number in sorted({latest, attempt}):
        attempts[number] = evidence_list(get(prefix + '/attempts/' + str(number)
                                            + '/jobs?per_page=100'), 'jobs')
        for job in attempts[number]:
            require(job['run_id'] == run_id and job['head_sha'] == sha
                    and job['run_attempt'] == number, 'PROVENANCE_JOB_IDENTITY')
    specific = [j for j in attempts[latest] if j['name'] == gate['name']]
    fields = ('id', 'run_id', 'head_sha', 'run_attempt', 'name', 'status', 'conclusion')
    if len(specific) != 1 or any(specific[0][key] != gate[key] for key in fields):
        pending('PROVENANCE_INCONSISTENT')
    current_validation = [j for j in attempts[attempt]
                          if j['name'] == 'validate / Validate sources']
    if latest != attempt and current_validation:
        pending('PROVENANCE_INCONSISTENT')
    deploy = [j for j in attempts[attempt] if j['name'] == 'Deploy over Tailscale']
    if not deploy:
        pending('PROVENANCE_DEPLOY_MISSING')
    require(len(deploy) == 1, 'PROVENANCE_DEPLOY_AMBIGUOUS')
    require((deploy[0]['status'], deploy[0]['conclusion']) ==
            ('completed', 'failure'),
            'PROVENANCE_DEPLOY_STATE')


def active_deployment(sha):
    # Use the current attempt only. A recovery rerun must rerun all jobs.
    path = '/actions/workflows/deploy.yml/runs?event=push&branch=main&head_sha=' + sha
    runs = evidence_list(get(path), 'workflow_runs')
    candidates = [run for run in runs if run['status'] == 'in_progress']
    if not candidates:
        pending('PROVENANCE_ACTIVE_MISSING')
    require(len(candidates) == 1, 'PROVENANCE_ACTIVE_AMBIGUOUS')
    current = candidates[0]
    trusted_run(current, sha)
    require((current['path'], current['event'], current['head_branch'], current['conclusion'])
            == ('.github/workflows/deploy.yml', 'push', 'main', None),
            'PROVENANCE_WORKFLOW_IDENTITY')
    run_id, attempt = current['id'], current['run_attempt']
    require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0,
            'PROVENANCE_ATTEMPT')
    prefix = f'/actions/runs/{run_id}'
    jobs = evidence_list(get(f'{prefix}/attempts/{attempt}/jobs?per_page=100'), 'jobs')
    for name, state in (
            (ELIGIBILITY_JOB, ('completed', 'success')),
            ('Deploy over Tailscale', ('in_progress', None))):
        matches = [job for job in jobs if job['name'] == name]
        if not matches:
            pending('PROVENANCE_JOB_MISSING')
        require(len(matches) == 1, 'PROVENANCE_JOB_IDENTITY')
        job = matches[0]
        require((job['run_id'], job['run_attempt'], job['head_sha']) == (run_id, attempt, sha),
                'PROVENANCE_JOB_IDENTITY')
        require((job['status'], job['conclusion']) == state, 'PROVENANCE_JOB_STATE')
    refreshed = get(prefix)
    trusted_run(refreshed, sha)
    require(all(refreshed[key] == current[key] for key in
                ('id', 'run_attempt', 'path', 'event', 'head_branch', 'status', 'conclusion')),
            'PROVENANCE_DEPLOY_STATE')
    merged(sha)
    return current


def authorize_host(sha):
    active_deployment(sha)
    require_current_main(sha)


def runs(sha):
    current = active_deployment(sha)
    # Report the successful eligibility gate to the root verifier. The deployment
    # run itself is still waiting for this verifier and SSH to finish.
    emit_evidence(dict(total_count=1, workflow_runs=[
        dict(id=current['id'], status='completed', conclusion='success')]))


def emit_evidence(data):
    # The shell verifier needs only these public identifiers and observations,
    # never GitHub's full response (actors, URLs, repository metadata, etc.).
    evidence = dict(total_count=data['total_count'], workflow_runs=[
        {key: run[key] for key in ('id', 'status', 'conclusion')}
        for run in data['workflow_runs']])
    if 'manual_cutover' in data:
        evidence['manual_cutover'] = data['manual_cutover']
    if 'historical_failure' in data:
        evidence['historical_failure'] = data['historical_failure']
    print(json.dumps(evidence))


def complete_list(data, key):
    entries = data[key]
    require(isinstance(entries, list) and 0 < len(entries) < 100)
    require(data['total_count'] == len(entries))
    return entries


def trusted_run(run, sha):
    require(run['head_sha'] == sha, 'PROVENANCE_SHA')
    require(run['repository']['full_name'] == REPO, 'PROVENANCE_REPOSITORY')
    require(run['head_repository']['full_name'] == REPO, 'PROVENANCE_REPOSITORY')


def manual_runs(sha, historical=False):
    """Explicit root manual-identity acceptance; never used by automatic deploys.

    Reuse checks from the PR that produced this exact main merge. Main push
    workflows do not include PR-only CI. No current-main equality is required:
    accepting an existing transaction must not deploy a later main revision.
    """
    pulls = get('/commits/' + sha + '/pulls?per_page=100')
    require(isinstance(pulls, list) and len(pulls) < 100)
    matches = [p for p in pulls if p.get('merged_at') and p.get('merge_commit_sha') == sha
               and p.get('base', {}).get('ref') == 'main'
               and p.get('base', {}).get('repo', {}).get('full_name') == REPO]
    require(len(matches) == 1)
    head = matches[0]['head']['sha']
    require(re.fullmatch('[0-9a-f]{40}', head))
    deployed = get('/git/commits/' + sha)
    tested = get('/git/commits/' + head)
    require(deployed['sha'] == sha and tested['sha'] == head)
    # A merged PR alone does not prove that base changes or conflict
    # resolutions were checked. This bounded recovery accepts only an
    # identical checked source tree, while retaining the deployed commit SHA.
    tree = deployed['tree']['sha']
    require(re.fullmatch('[0-9a-f]{40}', tree) and tested['tree']['sha'] == tree)
    required = {'.github/workflows/sast-checks.yml': 'Security & SAST gate',
                '.github/workflows/agent-context.yml': 'Check agent context maps'}
    checks = complete_list(get('/actions/runs?head_sha=' + head + '&per_page=100'), 'workflow_runs')
    evidence = []
    for path, gate in required.items():
        candidates = [r for r in checks if r.get('path') == path and r.get('event') == 'pull_request']
        require(candidates)
        run = max(candidates, key=lambda r: int(r['id']))
        trusted_run(run, head)
        require(run['status'] == 'completed' and run['conclusion'] == 'success')
        jobs = complete_list(get('/actions/runs/' + str(int(run['id'])) + '/jobs?per_page=100'), 'jobs')
        gates = [j for j in jobs if j.get('name') == gate]
        require(len(gates) == 1 and gates[0]['status'] == 'completed'
                and gates[0]['conclusion'] == 'success')
        if historical:
            attempt = run['run_attempt']
            require(type(attempt) is int and attempt > 0)
            require(gates[0]['run_id'] == run['id'] and gates[0]['head_sha'] == head
                    and gates[0]['run_attempt'] == attempt)
            specific = complete_list(get('/actions/runs/' + str(run['id']) + '/attempts/'
                                         + str(attempt) + '/jobs?per_page=100'), 'jobs')
            selected = [j for j in specific if j.get('name') == gate]
            require(len(selected) == 1 and all(selected[0].get(k) == gates[0].get(k)
                    for k in ('id', 'run_id', 'head_sha', 'run_attempt', 'name', 'status', 'conclusion')))
            refreshed = get('/actions/runs/' + str(run['id']))
            trusted_run(refreshed, head)
            require(all(refreshed.get(k) == run.get(k) for k in
                        ('id', 'path', 'event', 'status', 'conclusion', 'run_attempt')))
        evidence.append(run)
    data = get('/actions/runs?head_sha=' + sha + '&per_page=100')
    entries = complete_list(data, 'workflow_runs')
    retained, excluded = [], []
    for run in entries:
        trusted_run(run, sha)
        require(run['status'] == 'completed')
        if run.get('path') == '.github/workflows/deploy.yml':
            if historical:
                require(sha == RECOVERY_SHA)
                require(run['id'] == RECOVERY_RUN and run['head_branch'] == 'main'
                        and run['event'] == 'push' and run['conclusion'] == 'failure')
                historical_deployment_jobs(run, sha)
                refreshed = get('/actions/runs/' + str(run['id']))
                trusted_run(refreshed, sha)
                require(all(refreshed.get(k) == run.get(k) for k in
                            ('id', 'path', 'head_branch', 'event', 'status',
                             'conclusion', 'run_attempt')))
                excluded.append(run['id'])
                continue
            # Only the disabled push entrypoint with every job skipped is
            # inapplicable. Failed/manual/active/partially executed runs refuse.
            require(run['head_branch'] == 'main' and run['event'] == 'push')
            require(run['conclusion'] == 'skipped')
            jobs = complete_list(get('/actions/runs/' + str(int(run['id'])) + '/jobs?per_page=100'), 'jobs')
            expected = {'validate', 'Deploy over Tailscale'}
            names = {j['name'] for j in jobs}
            require(len(jobs) == len(names) and names in (expected, expected | {'pr-evidence'}))
            require(all(j['status'] == 'completed' and j['conclusion'] == 'skipped' for j in jobs))
            excluded.append(run['id'])
        else:
            require(run['conclusion'] == 'success')
            retained.append(run)
    require(excluded)
    if historical:
        require(len(excluded) == 1)
    # Preserve raw skipped observations separately; never rewrite them as PASS.
    data.update(workflow_runs=retained + evidence, total_count=len(retained) + len(evidence),
                manual_cutover=dict(merge_sha=sha, pr=matches[0]['number'], head_sha=head,
                                    intentionally_skipped_deploy_runs=excluded))
    if historical:
        data['historical_failure'] = dict(merge_sha=sha, pr=matches[0]['number'],
                                          head_sha=head, failed_deploy_run=excluded[0])
        del data['manual_cutover']
    emit_evidence(data)


def main():
    require(len(sys.argv) >= 3 and re.fullmatch('[0-9a-f]{40}', sys.argv[2]))
    action, sha = sys.argv[1:3]
    if action == 'candidate':
        require(len(sys.argv) == 4)
        candidate(sha, sys.argv[3])
        return
    require(len(sys.argv) == 3)
    if action == 'current-main':
        require_current_main(sha, authenticated=True)
    elif action == 'authorize-host':
        authorize_host(sha)
    elif action == 'manual-runs':
        manual_runs(sha)
    elif action == 'recovery-runs':
        manual_runs(sha, historical=True)
    else:
        require(action == 'runs')
        runs(sha)


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print(error.code, file=sys.stderr)
        sys.exit(75 if error.retry and sys.argv[1:2] == ['runs'] else 1)
    except (ValueError, KeyError, TypeError, OSError, IndexError, AttributeError, subprocess.CalledProcessError):
        sys.exit('PROVENANCE_INVALID')
