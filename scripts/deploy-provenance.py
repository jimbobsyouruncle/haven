#!/usr/bin/env python3
"""Fail-closed main deployment provenance; API reads only, no host mutation."""
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

REPO = 'jimbobsyouruncle/haven'
API = 'https://api.github.com/repos/' + REPO
RECOVERY_SHA = '5c2df63a73c81ddfbad868dbfe617ee383242ff4'
RECOVERY_RUN = 44123963304


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


def merged(sha):
    pulls = get('/commits/' + sha + '/pulls?per_page=100', authenticated=True)
    require(isinstance(pulls, list) and len(pulls) < 100)
    require(any(p.get('merged_at') and p.get('merge_commit_sha') == sha
                and p.get('base', {}).get('ref') == 'main'
                and p.get('base', {}).get('repo', {}).get('full_name') == REPO
                for p in pulls))


def require_current_main(sha, *, authenticated=False):
    require(get('/git/ref/heads/main', authenticated=authenticated).get('object', {}).get('sha') == sha,
            'PROVENANCE_MAIN_SHA')


def authorize(sha):
    reuse_attempt = os.environ.get('REUSE_ATTEMPT')
    require(not reuse_attempt or reuse_attempt == os.environ.get('GITHUB_RUN_ATTEMPT'),
            'PR_VALIDATION_RERUN_ALL_JOBS')
    require(os.environ.get('GITHUB_REPOSITORY') == REPO)
    require(os.environ.get('GITHUB_REF') == 'refs/heads/main')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    require(event.get('repository', {}).get('full_name') == REPO)
    require(event.get('repository', {}).get('fork') is False)
    kind = os.environ.get('GITHUB_EVENT_NAME')
    if kind == 'push':
        require(os.environ.get('AUTOMATIC_DEPLOYMENT') == 'enabled')
        require(event.get('ref') == 'refs/heads/main' and event.get('after') == sha)
        require(event.get('deleted') is False and event.get('forced') is False)
        merged(sha)
    else:
        require(kind == 'workflow_dispatch')
        inputs = event.get('inputs', {})
        require(inputs.get('authorize_production') in (True, 'true'))
        require(inputs.get('deployment_sha') == sha)
    require_current_main(sha, authenticated=True)


PR_WORKFLOWS = {
    '.github/workflows/sast-checks.yml': (
        'Security & SAST gate', 'Validate sources / Validate sources',
        'ShellCheck (Bash)', 'Semgrep (SAST)', 'CodeQL (python)', 'CodeQL (actions)',
    ),
    '.github/workflows/agent-context.yml': ('Check agent context maps',),
}


def pr_runs(head, branch):
    entries = evidence_list(get('/actions/runs?head_sha=' + head + '&per_page=100',
                                authenticated=True), 'workflow_runs')
    selected = {}
    for path in PR_WORKFLOWS:
        candidates = [r for r in entries if r['path'] == path and r['event'] == 'pull_request']
        require(candidates, 'PR_VALIDATION_NO_REQUIRED_RUN')
        for run in candidates:
            trusted_run(run, head)
            require(run['head_branch'] == branch and type(run['run_number']) is int,
                    'PR_VALIDATION_RUN_IDENTITY')
        latest = max(r['run_number'] for r in candidates)
        current = [r for r in candidates if r['run_number'] == latest]
        require(len(current) == 1, 'PR_VALIDATION_AMBIGUOUS_RUN')
        run = current[0]
        require(run['status'] == 'completed' and run['conclusion'] == 'success',
                'PR_VALIDATION_REQUIRED_RUN_UNSUCCESSFUL')
        require(all(type(run[k]) is int and run[k] > 0 for k in ('id', 'run_attempt')),
                'PR_VALIDATION_ATTEMPT')
        selected[path] = run
    return selected


def required_pr_jobs(run, names):
    run_id, attempt = run['id'], run['run_attempt']
    path = f'/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100'
    jobs = evidence_list(get(path, authenticated=True), 'jobs')
    result = {}
    for job in jobs:
        require((job['run_id'], job['run_attempt'], job['head_sha']) ==
                (run_id, attempt, run['head_sha']), 'PR_VALIDATION_JOB_IDENTITY')
        name = job['name']
        if name in names:
            require(name not in result, 'PR_VALIDATION_AMBIGUOUS_JOB')
            require((job['status'], job['conclusion']) == ('completed', 'success'),
                    'PR_VALIDATION_REQUIRED_JOB_UNSUCCESSFUL')
            result[name] = job
    # Failed-jobs-only reruns may inherit jobs from older attempts. Require a
    # complete successful attempt so that it cannot conceal mixed evidence.
    require(set(result) == set(names), 'PR_VALIDATION_INCOMPLETE_ATTEMPT')
    return result


def checkout_step(job, receipt):
    steps = [step for step in job['steps'] if step['name'].startswith('PR checkout ')]
    if not steps:
        return False
    require(len(steps) == 1 and steps[0]['name'] == receipt
            and (steps[0]['status'], steps[0]['conclusion']) == ('completed', 'success'),
            'PR_VALIDATION_CHECKOUT_MISMATCH')
    return True


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)


def pr_validation(sha):
    require(os.environ.get('GH_TOKEN'), 'PR_VALIDATION_TOKEN')
    require(os.environ.get('GITHUB_REPOSITORY') == REPO
            and os.environ.get('GITHUB_EVENT_NAME') == 'push'
            and os.environ.get('GITHUB_REF') == 'refs/heads/main'
            and os.environ.get('AUTOMATIC_DEPLOYMENT') == 'enabled')
    attempt = os.environ['GITHUB_RUN_ATTEMPT']
    require(re.fullmatch('[1-9][0-9]*', attempt), 'PR_VALIDATION_ATTEMPT')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    require(event['repository']['full_name'] == REPO and event['repository']['fork'] is False
            and event['ref'] == 'refs/heads/main' and event['after'] == sha
            and event['deleted'] is False and event['forced'] is False)
    base = event['before']
    require(re.fullmatch('[0-9a-f]{40}', base), 'PR_VALIDATION_BASE')
    require(git('rev-parse', 'HEAD', 'HEAD^1').decode().splitlines() == [sha, base],
            'PR_VALIDATION_MAIN_PARENT')
    # Public association endpoint needs a separate pull-requests token scope
    # for authenticated reads. HTTPS public metadata adds no token privileges.
    pulls = get(f'/commits/{sha}/pulls?per_page=100')
    require(isinstance(pulls, list) and len(pulls) < 100, 'PR_VALIDATION_PULL_LIST')
    matches = [p for p in pulls if p['merged_at'] and p['merge_commit_sha'] == sha
               and p['base']['ref'] == 'main' and p['base']['repo']['full_name'] == REPO]
    require(len(matches) == 1, 'PR_VALIDATION_MERGED_PULL')
    pr = matches[0]
    number, head = pr['number'], pr['head']['sha']
    require(type(number) is int and number > 0 and re.fullmatch('[0-9a-f]{40}', head)
            and pr['head']['repo']['full_name'] == REPO and pr['head']['repo']['fork'] is False,
            'PR_VALIDATION_UNTRUSTED_PULL')
    # The approved workflows must be byte-identical to the previous main tree.
    # A successful GitHub Actions check name can also come from changed YAML.
    paths = git('diff', '--name-only', '-z', '--no-renames', base, sha, '--').split(b'\0')
    security_paths = (*PR_WORKFLOWS, '.github/workflows/validate.yml',
                      'scripts/deploy-provenance.py',
                      'scripts/ci-components.py', 'scripts/check-agent-context.sh',
                      'scripts/test-check-agent-context.sh', 'scripts/check-no-masked-literals.sh',
                      '.semgrepignore', '.shellcheckrc')
    require(not any(p.encode() in paths for p in security_paths),
            'PR_VALIDATION_SECURITY_POLICY_CHANGED')

    runs = pr_runs(head, pr['head']['ref'])
    sast_path, context_path = PR_WORKFLOWS
    sast, context = runs[sast_path], runs[context_path]
    refs = sast['referenced_workflows']
    require(isinstance(refs, list) and len(refs) == 1, 'PR_VALIDATION_WORKFLOW_REFERENCE')
    ref = refs[0]
    tested = ref['sha']
    require(re.fullmatch('[0-9a-f]{40}', tested)
            and ref['ref'] == f'refs/pull/{number}/merge'
            and ref['path'] == f'{REPO}/.github/workflows/validate.yml@{tested}',
            'PR_VALIDATION_WORKFLOW_REFERENCE')
    commit = get('/git/commits/' + tested, authenticated=True)
    require(commit['sha'] == tested and [p['sha'] for p in commit['parents']] == [base, head],
            'PR_VALIDATION_TESTED_PARENTS')
    require(commit['tree']['sha'] == git('rev-parse', 'HEAD^{tree}').decode().strip(),
            'PR_VALIDATION_TESTED_TREE')
    receipt = f'PR checkout {number} {base} {tested}'
    sast_jobs = required_pr_jobs(sast, PR_WORKFLOWS[sast_path])
    context_jobs = required_pr_jobs(context, PR_WORKFLOWS[context_path])
    require(checkout_step(context_jobs['Check agent context maps'], receipt),
            'PR_VALIDATION_CONTEXT_CHECKOUT_MISSING')
    source_job = sast_jobs['Validate sources / Validate sources']
    source = checkout_step(source_job, receipt)
    # Detect superseding runs and reruns across the separate jobs/API reads.
    require(pr_runs(head, pr['head']['ref']) == runs, 'PR_VALIDATION_EVIDENCE_CHANGED')

    if not source or any(p.startswith(b'.github/') for p in paths):
        print('Full deployment validation: source evidence unavailable or CI policy changed.')
        return
    steps = [step['name'] for step in source_job['steps']
             if (step['status'], step['conclusion']) == ('completed', 'success')]
    require({'Select component tests', 'Shell syntax check', 'Python syntax check',
             'Assert no secrets are tracked'} <= set(steps), 'PR_VALIDATION_SOURCE_COVERAGE')
    flags = subprocess.check_output(['python3', 'scripts/ci-components.py', '--base', base],
                                    text=True).splitlines()
    if 'full=true' in flags:
        print('Full deployment validation: cross-cutting or unknown source paths.')
        return
    require('full=false' in flags, 'PR_VALIDATION_SELECTION')
    print(f'Reusing PR #{number} source tree {commit["tree"]["sha"]} '
          f'(SAST run {sast["id"]} attempt {sast["run_attempt"]}; '
          f'context run {context["id"]} attempt {context["run_attempt"]}).')
    print('PR component selection: ' + ', '.join(flags))
    print('Successful PR validation steps: ' + json.dumps(steps))
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        print(f'reuse_attempt={attempt}', file=output)


def verify_pr_evidence(sha):
    # Restart the entire evidence check so a retry cannot combine results
    # from different GitHub snapshots. No reuse output is written on refusal.
    for delay in (1, 2):
        try:
            return pr_validation(sha)
        except Refused as error:
            if not error.retry:
                raise
            print(f'{error.code}: retrying PR evidence in {delay}s', file=sys.stderr)
            time.sleep(delay)
    return pr_validation(sha)


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


def deployment_jobs(run, sha, historical=False):
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
            (('completed', 'failure') if historical else ('in_progress', None)),
            'PROVENANCE_DEPLOY_STATE')


def active_deployment(sha):
    """Only the waiting deploy run may remain active, after validation passed."""
    data = get('/actions/runs?head_sha=' + sha + '&per_page=100')
    entries = evidence_list(data, 'workflow_runs')
    for run in entries:
        trusted_run(run, sha)
    deployments = [r for r in entries if r.get('path') == '.github/workflows/deploy.yml'
                   and r.get('status') == 'in_progress']
    if not deployments:
        require(not any(r.get('path') == '.github/workflows/deploy.yml'
                        and r.get('status') == 'completed' for r in entries),
                'PROVENANCE_DEPLOY_STATE')
        pending('PROVENANCE_ACTIVE_MISSING')
    require(len(deployments) == 1, 'PROVENANCE_ACTIVE_AMBIGUOUS')
    current = deployments[0]
    require(current['conclusion'] is None, 'PROVENANCE_DEPLOY_STATE')
    require(current['head_branch'] == 'main' and current['event'] in ('push', 'workflow_dispatch'),
            'PROVENANCE_WORKFLOW_IDENTITY')
    deployment_jobs(current, sha)
    # Recheck after separate API reads, so a new attempt cannot inherit this
    # snapshot's successful evidence. A completed failed run is never accepted.
    refreshed = get('/actions/runs/' + str(current['id']))
    trusted_run(refreshed, sha)
    require(refreshed['id'] == current['id'] and refreshed['path'] == current['path']
            and refreshed['head_branch'] == 'main'
            and refreshed['event'] == current['event'], 'PROVENANCE_WORKFLOW_IDENTITY')
    if refreshed['run_attempt'] != current['run_attempt']:
        pending('PROVENANCE_ATTEMPT_CHANGED')
    require(refreshed['status'] == 'in_progress' and refreshed['conclusion'] is None,
            'PROVENANCE_DEPLOY_STATE')
    return data, entries, current


def authorize_host(sha):
    _, _, current = active_deployment(sha)
    # Resolve main after checking the run and attempt. The bootstrap checks
    # it again against the ref obtained by the subsequent Git fetch.
    require_current_main(sha)
    print(current['event'])


def runs(sha):
    data, entries, current = active_deployment(sha)
    entries = [r for r in entries if r.get('path') != '.github/workflows/deploy.yml'
               or r['id'] == current['id']]
    current.update(status='completed', conclusion='success')
    data.update(workflow_runs=entries, total_count=len(entries))
    emit_evidence(data)


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
                deployment_jobs(run, sha, historical=True)
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
    require(len(sys.argv) == 3 and re.fullmatch('[0-9a-f]{40}', sys.argv[2]))
    require(sys.argv[1] in ('authorize', 'authorize-host', 'pr-validation', 'runs', 'manual-runs',
                            'recovery-runs'))
    if sys.argv[1] == 'authorize':
        authorize(sys.argv[2])
    elif sys.argv[1] == 'authorize-host':
        authorize_host(sys.argv[2])
    elif sys.argv[1] == 'pr-validation':
        verify_pr_evidence(sys.argv[2])
    elif sys.argv[1] == 'manual-runs':
        manual_runs(sys.argv[2])
    elif sys.argv[1] == 'recovery-runs':
        manual_runs(sys.argv[2], historical=True)
    else:
        runs(sys.argv[2])


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print(error.code, file=sys.stderr)
        sys.exit(75 if error.retry and sys.argv[1:2] == ['runs'] else 1)
    except (ValueError, KeyError, TypeError, OSError, IndexError, AttributeError, subprocess.CalledProcessError):
        sys.exit('PROVENANCE_INVALID')
