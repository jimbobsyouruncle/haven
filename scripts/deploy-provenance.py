#!/usr/bin/env python3
"""Fail-closed main deployment provenance; API reads only, no host mutation."""
import json
import os
from pathlib import Path
import re
import sys
import urllib.request
import urllib.error

REPO = 'jimbobsyouruncle/haven'
API = 'https://api.github.com/repos/' + REPO


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
    except (urllib.error.URLError, TimeoutError, OSError):
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


def authorize(sha):
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
    require(get('/git/ref/heads/main', authenticated=True).get('object', {}).get('sha') == sha)


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


def deployment_jobs(run, sha):
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
    require(deploy[0]['status'] == 'in_progress', 'PROVENANCE_DEPLOY_STATE')


def runs(sha):
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
    require(refreshed['status'] == 'in_progress', 'PROVENANCE_DEPLOY_STATE')
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


def manual_runs(sha):
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
        evidence.append(run)
    data = get('/actions/runs?head_sha=' + sha + '&per_page=100')
    entries = complete_list(data, 'workflow_runs')
    retained, excluded = [], []
    for run in entries:
        trusted_run(run, sha)
        require(run['status'] == 'completed')
        if run.get('path') == '.github/workflows/deploy.yml':
            # Only the disabled push entrypoint with BOTH jobs skipped is
            # inapplicable. Failed/manual/active/partially executed runs refuse.
            require(run['head_branch'] == 'main' and run['event'] == 'push')
            require(run['conclusion'] == 'skipped')
            jobs = complete_list(get('/actions/runs/' + str(int(run['id'])) + '/jobs?per_page=100'), 'jobs')
            require(len(jobs) == 2 and {j['name'] for j in jobs} == {'validate', 'Deploy over Tailscale'})
            require(all(j['status'] == 'completed' and j['conclusion'] == 'skipped' for j in jobs))
            excluded.append(run['id'])
        else:
            require(run['conclusion'] == 'success')
            retained.append(run)
    require(excluded)
    # Preserve raw skipped observations separately; never rewrite them as PASS.
    data.update(workflow_runs=retained + evidence, total_count=len(retained) + len(evidence),
                manual_cutover=dict(merge_sha=sha, pr=matches[0]['number'], head_sha=head,
                                    intentionally_skipped_deploy_runs=excluded))
    emit_evidence(data)


def main():
    require(len(sys.argv) == 3 and re.fullmatch('[0-9a-f]{40}', sys.argv[2]))
    require(sys.argv[1] in ('authorize', 'runs', 'manual-runs'))
    if sys.argv[1] == 'authorize':
        authorize(sys.argv[2])
    elif sys.argv[1] == 'manual-runs':
        manual_runs(sys.argv[2])
    else:
        runs(sys.argv[2])


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print(error.code, file=sys.stderr)
        sys.exit(75 if error.retry and sys.argv[1:2] == ['runs'] else 1)
    except (ValueError, KeyError, TypeError, OSError, IndexError, AttributeError):
        sys.exit('PROVENANCE_INVALID')
