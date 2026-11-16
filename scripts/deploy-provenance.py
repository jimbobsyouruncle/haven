#!/usr/bin/env python3
"""Fail-closed main deployment provenance; API reads only, no host mutation."""
import json
import os
from pathlib import Path
import re
import sys
import urllib.request

REPO = 'jimbobsyouruncle/haven'
API = 'https://api.github.com/repos/' + REPO


def require(condition):
    if not condition:
        raise ValueError('deployment provenance refused')


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
    with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
        return json.load(response)


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


def runs(sha):
    """Only the waiting deploy run may remain active, after its validation passed."""
    data = get('/actions/runs?head_sha=' + sha + '&per_page=100')
    entries = data['workflow_runs']
    require(isinstance(entries, list) and 0 < len(entries) < 100)
    require(data['total_count'] == len(entries))
    deployments = [r for r in entries if r.get('path') == '.github/workflows/deploy.yml'
                   and r.get('status') == 'in_progress']
    require(len(deployments) == 1)
    current = int(deployments[0]['id'])
    # The shared workflow concurrency group permits one active deployment.
    # Queued future pushes must not fail this deployment; a new explicitly
    # requested recovery may supersede failed attempts at this same SHA.
    # Neither case supersedes another workflow's failure.
    entries = [r for r in entries if r.get('path') != '.github/workflows/deploy.yml'
               or int(r['id']) == current]
    data.update(workflow_runs=entries, total_count=len(entries))
    waiting = []
    for run in entries:
        require(run['head_sha'] == sha)
        if run.get('path') != '.github/workflows/deploy.yml':
            continue
        require(run['repository']['full_name'] == REPO)
        require(run['head_repository']['full_name'] == REPO)
        require(run['head_branch'] == 'main')
        require(run['event'] in ('push', 'workflow_dispatch'))
        if run['status'] == 'completed':
            continue
        require(run['status'] == 'in_progress')
        jobs = get('/actions/runs/' + str(int(run['id'])) + '/jobs?per_page=100')
        require(jobs['total_count'] == len(jobs['jobs']) < 100)
        require(any(j['name'] == 'validate / Validate sources'
                    and j['status'] == 'completed' and j['conclusion'] == 'success'
                    for j in jobs['jobs']))
        require(any(j['name'] == 'Deploy over Tailscale' and j['status'] == 'in_progress'
                    for j in jobs['jobs']))
        waiting.append(run['id'])
        # The host gates are part of this run's still-pending deploy job. Do
        # not wait for that job to finish before allowing it to finish.
        run.update(status='completed', conclusion='success')
    require(len(waiting) == 1)
    print(json.dumps(data))


def complete_list(data, key):
    entries = data[key]
    require(isinstance(entries, list) and 0 < len(entries) < 100)
    require(data['total_count'] == len(entries))
    return entries


def trusted_run(run, sha):
    require(run['head_sha'] == sha)
    require(run['repository']['full_name'] == REPO)
    require(run['head_repository']['full_name'] == REPO)


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
    print(json.dumps(data))


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
    except (ValueError, KeyError, TypeError, OSError):
        sys.exit('deployment provenance unavailable or refused')
