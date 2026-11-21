#!/usr/bin/env python3
"""Offline selector and workflow safety regressions. No third-party modules."""
import importlib.util
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('components', ROOT / 'scripts/ci-components.py')
COMPONENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPONENTS)


class SelectionTests(unittest.TestCase):
    def selected(self, *paths):
        return {key for key, enabled in COMPONENTS.select(paths).items() if enabled}

    def test_representative_boundaries(self):
        cases = [
            (['backup/restore.sh'], {'backup', 'status', 'doctor'}),
            (['auth/app.py'], {'auth', 'proxy'}),
            (['README.md', 'docs/haven/ARCHITECTURE.md'], set()),
            (['status/app.py'], {'status'}),
            (['status/Dockerfile'], {'status'}),
            (['scripts/generate-agent-context.py', 'scripts/check-agent-context.sh',
              'scripts/test-check-agent-context.sh'], set()),
            (['openwebui/runpod_core.py'], {'inference', 'status', 'doctor'}),
            (['hermes/agent-hooks/secret-guard.py'], {'hermes'}),
            (['auth/app.py', 'backup/restore.sh'], {'auth', 'proxy', 'backup', 'status', 'doctor'}),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                self.assertEqual(self.selected(*paths), expected)

    def test_shared_unknown_security_and_ci_are_full(self):
        for path in ('scripts/lib/haven-env.sh', 'scripts/lib/tls.sh', 'scripts/lib/installer-env-render.sh',
                     'install.sh', 'docker-compose.yml',
                     '.github/workflows/agent-context.yml',
                     '.github/workflows/agent-context-committer.yml',
                     'scripts/sandbox-firewall.sh', '.github/workflows/validate.yml',
                     'scripts/ci-components.py', 'scripts/test-ci-components.py',
                     'deploy/haven-deploy@.service', '.env.example',
                     'status/Caddyfile', 'status/Caddyfile.tmpl',
                     'new-module/app.py', 'docs/haven/identity/inventory.py',
                     'scripts/test-new-contract.sh', 'odd\nname.py'):
            with self.subTest(path=path):
                self.assertEqual(self.selected(path), set(('full',) + COMPONENTS.COMPONENTS))

    def test_cli_git_diff_deletion_rename_and_invalid_base(self):
        script = str(ROOT / 'scripts/ci-components.py')
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args):
                return subprocess.check_output(['git', '-C', tmp, *args], stderr=subprocess.DEVNULL).decode().strip()
            git('init', '-q')
            git('config', 'user.name', 'fixture')
            git('config', 'user.email', 'fixture@example.test')
            git('config', 'commit.gpgsign', 'false')
            path = Path(tmp) / 'backup/restore.sh'
            path.parent.mkdir()
            path.write_text('fixture')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            path.rename(Path(tmp) / 'README.md')
            git('add', '-A')
            git('commit', '-qm', 'rename code to docs')
            result = subprocess.run(['python3', script, '--base', base], cwd=tmp, capture_output=True, text=True, check=True)
            self.assertIn('backup=true\n', result.stdout)
            self.assertIn('full=false\n', result.stdout)
            for bad in ('', '--output=bad', 'a' * 40):
                result = subprocess.run(['python3', script, '--base', bad], cwd=tmp, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
            result = subprocess.check_output(['python3', script], cwd=tmp, text=True)
            self.assertIn('full=true\n', result)

    def test_selected_workflow_steps(self):
        workflow = (ROOT / '.github/workflows/validate.yml').read_text()
        blocks = re.split(r'^      - name: ', workflow, flags=re.M)[1:]

        def steps(path):
            flags = COMPONENTS.select([path])
            names = set()
            for block in blocks:
                condition = re.search(r'^        if: (.+)$', block, re.M)
                components = re.findall(
                    r"steps.components.outputs.(\w+) == 'true'", condition[1]) if condition else []
                if not components or any(flags[key] for key in components):
                    names.add(block.splitlines()[0])
            return names

        backup = steps('backup/restore.sh')
        self.assertTrue({'Backup script fixture tests', 'Backup mode / timer tests',
                         'Post-deploy verifier tests', 'Deploy-remote tests',
                         'Private Backups socket tests'}.issubset(backup))
        self.assertNotIn('Pipe behavioural tests', backup)
        self.assertNotIn('Auth service tests', backup)
        auth = steps('auth/app.py')
        self.assertTrue({'Auth service tests', 'Auth render tests',
                         'Install auth env-leak tests',
                         'Validate rendered Caddyfiles with real Caddy (TLS x auth matrix)',
                         'Assert proxy allowlist is intact'}.issubset(auth))
        self.assertNotIn('Backup script fixture tests', auth)
        status = steps('status/app.py')
        self.assertTrue({'Private Backups socket tests', 'GPU pod wake-readiness tile tests',
                         'Post-deploy verifier tests', 'Compose schema check'}.issubset(status))
        self.assertTrue({'Backup script fixture tests', 'Installation root migration tests',
                         'B77 port-80 redirect-only dynamic tests', 'Auth service tests',
                         'Pipe behavioural tests'}.isdisjoint(status))
        docs = steps('README.md')
        self.assertEqual(steps('scripts/generate-agent-context.py'), docs)
        self.assertIn('Assert no secrets are tracked', docs)
        self.assertIn('Shell syntax check', docs)
        self.assertFalse(any('fixture tests' in name or 'Doctor ' in name for name in docs))
        for path in ('scripts/lib/haven-env.sh', '.github/workflows/validate.yml'):
            self.assertEqual(len(steps(path)), len(blocks))
        for label, path in (('backup', 'backup/restore.sh'), ('auth', 'auth/app.py'),
                            ('status', 'status/app.py'),
                            ('docs', 'README.md'), ('shared', 'scripts/lib/haven-env.sh')):
            print(f'{label}: {len(steps(path))}/{len(blocks)} validation steps selected')

    def test_aggregate_gate_fails_closed(self):
        workflow = (ROOT / '.github/workflows/sast-checks.yml').read_text()
        gate = workflow.split('      - name: Require every check to succeed\n', 1)[1]
        body = gate.split('        run: |\n', 1)[1]
        body = '\n'.join(line[10:] for line in body.splitlines())
        keys = re.findall(r'\$\{\{ (.*?) \}\}', body)
        defaults = {key: 'success' for key in keys}
        defaults['needs.changes.outputs.hermes_image'] = 'true'

        def run(overrides):
            values = dict(defaults, **overrides)
            script = re.sub(r'\$\{\{ (.*?) \}\}', lambda m: values[m[1]], body)
            return subprocess.run(['bash', '-euo', 'pipefail', '-c', script],
                                  capture_output=True).returncode

        self.assertEqual(run({}), 0)
        self.assertEqual(run({'needs.changes.outputs.hermes_image': 'false',
                              'needs.hermes-nonroot-smoke.result': 'skipped'}), 0)
        for state in ('failure', 'cancelled', 'skipped', ''):
            for key in keys:
                if key.endswith('.result'):
                    with self.subTest(state=state, key=key):
                        self.assertNotEqual(run({key: state}), 0)
        self.assertNotEqual(run({'needs.changes.outputs.hermes_image': ''}), 0)

    def test_workflow_contract(self):
        workflow = (ROOT / '.github/workflows/validate.yml').read_text()
        sast = (ROOT / '.github/workflows/sast-checks.yml').read_text()
        deploy = (ROOT / '.github/workflows/deploy.yml').read_text()
        self.assertIn('default: false', workflow)
        self.assertIn('changed_only: true', sast)
        self.assertNotIn('changed_only:', deploy)
        self.assertIn('python3 scripts/test-ci-components.py', workflow)
        self.assertIn('name: Security & SAST gate', sast)
        self.assertIn('if: ${{ always() }}', sast)
        self.assertNotIn('workflow_run:', sast)
        smoke = sast.split('  hermes-nonroot-smoke:\n', 1)[1]
        self.assertIn("!cancelled() && needs.changes.result == 'success'", smoke)
        # Every narrowed step includes the conservative full fallback. Each
        # component has actual executable consumers, not just detector outputs.
        for line in workflow.splitlines():
            if line.strip().startswith('if:') and 'steps.components.outputs' in line:
                self.assertIn("steps.components.outputs.full == 'true'", line)
        for component in COMPONENTS.COMPONENTS:
            self.assertIn(f"steps.components.outputs.{component} == 'true'", workflow)

    def test_deployment_selection_always_runs_full(self):
        # Execute the real workflow shell, without GitHub or a production host.
        # The same SAST caller opts into scoped PR tests. Every non-PR
        # event must stay full, independently of the input or PR base.
        workflow = (ROOT / '.github/workflows/validate.yml').read_text()
        block = workflow.split('      - name: Select component tests\n', 1)[1]
        body = block.split('        run: |\n', 1)[1].split('      - name:', 1)[0]
        body = '\n'.join(line[10:] for line in body.splitlines())
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'output'
            for event in ('push', 'workflow_dispatch', 'schedule'):
                for changed_only in ('false', 'true'):
                    with self.subTest(event=event, changed_only=changed_only):
                        output.write_text('')
                        result = subprocess.run(
                            ['bash', '-euo', 'pipefail', '-c', body], cwd=ROOT,
                            env=dict(os.environ, EVENT_NAME=event,
                                     CHANGED_ONLY=changed_only, BASE_SHA='invalid',
                                     GITHUB_OUTPUT=str(output)),
                            capture_output=True, text=True, check=True)
                        expected = {f'{key}=true' for key in ('full',) + COMPONENTS.COMPONENTS}
                        self.assertEqual(set(result.stdout.splitlines()), expected)
                        self.assertEqual(set(output.read_text().splitlines()), expected)
        deploy = (ROOT / '.github/workflows/deploy.yml').read_text()
        validate = deploy.split('  validate:\n', 1)[1].split('  deploy:\n', 1)[0]
        self.assertIn('uses: ./.github/workflows/validate.yml', validate)
        self.assertIn('needs: candidate', validate)
        self.assertNotIn('secrets:', validate)
        self.assertNotIn('security-events: write', deploy)
        self.assertIn('needs: validate', deploy)
        self.assertIn("if: needs.validate.result == 'success'", deploy)


if __name__ == '__main__':
    unittest.main()
