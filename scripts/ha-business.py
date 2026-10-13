#!/usr/bin/env python3
"""Task-scoped application stop/start without touching database data or volumes."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid

INSTALLER = Path(__file__).resolve().parent.parent / 'jmsctl.sh'
ROOT = Path('/data/ha-toolkit')
DATABASES = {'postgresql', 'mysql', 'mariadb', 'redis', 'es', 'minio', 'loki'}


def run(args, timeout=60):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, timeout=timeout)
    if result.returncode:
        raise ValueError('business command failed: ' + Path(args[0]).name)
    return result.stdout.strip()


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=str(path.parent), prefix='.business-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, str(path))
        descriptor = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise ValueError('unsafe business task state')
    return json.loads(path.read_text())


def services():
    names = run(['bash', str(INSTALLER), 'show_services']).split()
    names = [name for name in names if name not in DATABASES]
    if not names or any(not re.fullmatch(r'[a-zA-Z0-9_-]+', name) for name in names):
        raise ValueError('unsupported business service inventory')
    return names


def inspect(names):
    rows = json.loads(run(['docker', 'inspect'] + ['jms_' + name for name in names]))
    if len(rows) != len(names):
        raise ValueError('business container inventory mismatch')
    return rows


def operation(action, task):
    if action == 'capabilities':
        return {'schema_version': 1, 'no_database_rebuild': True}
    if action == 'check':
        names = services()
        allowed = {'jms_' + name for name in names + list(DATABASES)}
        active = run(['docker', 'ps', '--filter', 'name=^jms_', '--format', '{{.Names}}']).splitlines()
        if any(name not in allowed for name in active):
            raise ValueError('unknown business writer; inspect before detaching')
        rows = inspect(names)
        if any(not row['State']['Running'] or row['State'].get('Health', {}).get('Status', 'healthy') != 'healthy' for row in rows):
            raise ValueError('business must be healthy before detaching')
        return {'healthy': True}
    if str(uuid.UUID(task)) != task:
        raise ValueError('invalid task ID')
    guard = ROOT / 'detaching'
    if guard.is_symlink() or guard.read_text().splitlines()[0] != task:
        raise ValueError('business operation does not own the HA detach guard')
    path = ROOT / 'detach' / task / 'business.json'
    if any(parent.is_symlink() for parent in (ROOT, ROOT / 'detach', path.parent)):
        raise ValueError('unsafe business task directory')
    if path.exists():
        state = read(path)
        if state.get('task_id') != task:
            raise ValueError('business task mismatch')
        names = state['services']
        if not names or any(name in DATABASES or not re.fullmatch(r'[a-zA-Z0-9_-]+', name) for name in names):
            raise ValueError('unsafe business service inventory')
    elif action == 'stop':
        names = services()
        rows = inspect(names)
        state = {'task_id': task, 'services': names, 'containers': {}}
        for row in rows:
            state['containers'][row['Name'].lstrip('/')] = {
                'running': bool(row['State']['Running']),
                'restart': row['HostConfig']['RestartPolicy'],
            }
        atomic(path, state)
    elif action == 'status':
        return {'stopped': False, 'prepared': False}
    else:
        raise ValueError('business stop snapshot is missing')
    if action == 'stop':
        for name in names:
            run(['docker', 'update', '--restart=no', 'jms_' + name])
        run(['bash', str(INSTALLER), 'raw', 'stop', '-t', '30'] + names, timeout=600)
        if any(row['State']['Running'] for row in inspect(names)):
            raise ValueError('business writers did not stop')
        state['stopped'] = True
        atomic(path, state)
    elif action in ('start', 'recreate', 'restore_policies'):
        enabled = [name for name in names if state['containers']['jms_' + name]['running']]
        if enabled and action != 'restore_policies':
            args = ['bash', str(INSTALLER), 'raw', 'up', '-d', '--no-deps']
            if action == 'recreate':
                args.append('--force-recreate')
            run(args + enabled, timeout=600)
        for name in names:
            policy = state['containers']['jms_' + name]['restart']
            value = policy['Name'] or 'no'
            if value == 'on-failure' and policy.get('MaximumRetryCount'):
                value += ':' + str(policy['MaximumRetryCount'])
            run(['docker', 'update', '--restart=' + value, 'jms_' + name])
        state['stopped'] = False
        atomic(path, state)
    elif action != 'status':
        raise ValueError('unsupported business operation')
    rows = inspect(names)
    return {'schema_version': 1, 'prepared': True,
            'stopped': all(not row['State']['Running'] for row in rows)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('capabilities', 'check', 'stop', 'status', 'start', 'recreate', 'restore_policies'))
    parser.add_argument('--task-id')
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError('root required')
        os.umask(0o077)
        print(json.dumps(operation(args.action, args.task_id)))
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        print(json.dumps({'error': 'business operation failed; inspect protected HA task state'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
