#!/usr/bin/env python3
"""Exercise real ops scripts against a stateful, synthetic Docker command.

No Docker daemon, QQ account or production directory is accessed.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['FAKE_DOCKER_STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
s['events'].append({'args': a, 'running': list(s['running'])})
if a[0] == 'compose':
    a = a[1:]
    while a and a[0] == '-f': a = a[2:]
    cmd, *rest = a
    if cmd == 'ps':
        print('\n'.join(s['running'] if '--services' in rest else ['id-'+n for n in s['running']]))
    elif cmd == 'stop':
        s['running'] = [n for n in s['running'] if rest and n not in rest]
    elif cmd == 'start':
        for n in rest or ['backend', 'napcat']:
            if n not in s['running']: s['running'].append(n)
    elif cmd == 'up': s['running'].append('backend')
    elif cmd == 'config': print(json.dumps({'name': 'synthetic'}))
elif a[0] == 'run':
    mounts = {}
    for i, v in enumerate(a):
        if v == '-v':
            src, dest, *_ = a[i+1].split(':')
            mounts[dest] = pathlib.Path(src)
    if 'czf' in a:
        out = a[a.index('czf')+1]
        dest = mounts['/target'] / pathlib.Path(out).name
        dest.write_bytes(b'synthetic archive')
elif a[0] == 'inspect': print('running')
elif a[:2] == ['image', 'inspect']: print('linux/amd64')
p.write_text(json.dumps(s))
'''


class OpsRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dafeiyu-ops-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        shutil.copytree(ROOT / 'deploy/cloud/ops', self.directory / 'ops')
        for d in ('data', 'config', 'backups', 'bin'):
            (self.directory / d).mkdir()
        self.compose('new')
        (self.directory / 'qq-container-entrypoint.sh').write_text('')
        (self.directory / 'VERSION.txt').write_text('synthetic\n')
        self.state = self.directory / 'state.json'
        self.state.write_text(json.dumps({'running': ['napcat'], 'events': []}))
        executable = self.directory / 'bin/docker'
        executable.write_text(FAKE_DOCKER)
        executable.chmod(0o755)
        for name, body in [('date', 'echo 20260101T000000Z'), ('sleep', 'exit 0')]:
            f = self.directory / 'bin' / name
            f.write_text('#!/bin/sh\n' + body + '\n')
            f.chmod(0o755)
        self.env = {**os.environ, 'DOCKER': str(executable),
                    'FAKE_DOCKER_STATE': str(self.state),
                    'PATH': str(self.directory / 'bin') + os.pathsep + os.environ['PATH']}

    def compose(self, tag, folder=None):
        (folder or self.directory).joinpath('docker-compose.yml').write_text(
            f'name: synthetic\nservices:\n  backend:\n    image: dafeiyu-backend:{tag}\n')

    def execute(self, script, *args):
        return subprocess.run(['bash', f'ops/{script}.sh', *args], cwd=self.directory,
                              env=self.env, capture_output=True, text=True, errors='replace', timeout=20)

    def test_stop_backup_does_not_start_previously_stopped_backend(self):
        result = self.execute('backup', '--stop', '--data-only')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(state['running'], ['napcat'])

    def test_backups_in_the_same_second_do_not_overwrite(self):
        for _ in range(2):
            result = self.execute('backup', '--data-only')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backups = list((self.directory / 'backups').glob('manual-*'))
        self.assertEqual(len(backups), 2)
        self.assertTrue(all((p / 'data.tar.gz').is_file() for p in backups))

    def test_rollback_stops_backend_before_reading_data(self):
        self.state.write_text(json.dumps({'running': ['backend', 'napcat'], 'events': []}))
        previous = self.directory / 'backups/pre-upgrade-synthetic'
        previous.mkdir()
        self.compose('old', previous)
        (previous / 'info.txt').write_text('backend_tag=old\n')
        result = self.execute('rollback')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reads = [e for e in json.loads(self.state.read_text())['events']
                 if 'czf' in e['args']]
        self.assertTrue(reads)
        self.assertTrue(all('backend' not in e['running'] for e in reads))

    def test_rehearsal_child_does_not_inherit_production_project_name(self):
        spec = importlib.util.spec_from_file_location('deploy_verify', ROOT / 'scripts/verify-deploy-package.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = os.environ.get('COMPOSE_PROJECT_NAME')
        try:
            os.environ['COMPOSE_PROJECT_NAME'] = 'production-synthetic'
            result = module.run([sys.executable, '-c',
                                 'import os; print(os.environ.get("COMPOSE_PROJECT_NAME", "absent"))'])
            self.assertEqual(result.stdout.strip(), 'absent')
        finally:
            if original is None:
                os.environ.pop('COMPOSE_PROJECT_NAME', None)
            else:
                os.environ['COMPOSE_PROJECT_NAME'] = original


if __name__ == '__main__':
    unittest.main()
