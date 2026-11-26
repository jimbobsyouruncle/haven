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


def active_deployment(sha):
    # Use the current attempt only. Rerun all jobs after failure.
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


def trusted_run(run, sha):
    require(run['head_sha'] == sha, 'PROVENANCE_SHA')
    require(run['repository']['full_name'] == REPO, 'PROVENANCE_REPOSITORY')
    require(run['head_repository']['full_name'] == REPO, 'PROVENANCE_REPOSITORY')


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
    else:
        require(action == 'authorize-bootstrap')
        require_current_main(sha)
        before = subprocess.check_output(['git', 'rev-parse', 'HEAD^1'], text=True).strip()
        require_merge_eligibility(sha, before)


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print(error.code, file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, TypeError, OSError, IndexError, AttributeError, subprocess.CalledProcessError):
        sys.exit('PROVENANCE_INVALID')
