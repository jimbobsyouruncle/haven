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


def main():
    require(len(sys.argv) == 3 and re.fullmatch('[0-9a-f]{40}', sys.argv[2]))
    require(sys.argv[1] in ('authorize', 'runs'))
    if sys.argv[1] == 'authorize':
        authorize(sys.argv[2])
    else:
        runs(sys.argv[2])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError):
        sys.exit('deployment provenance unavailable or refused')
