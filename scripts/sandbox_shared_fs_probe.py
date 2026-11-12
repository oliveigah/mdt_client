#!/usr/bin/env python3
"""Disposable shared-filesystem probes. No dependencies beyond Python 3 and git.

python3 sandbox_shared_fs_probe.py local
python3 sandbox_shared_fs_probe.py check --sandbox NAME  # on the host
python3 sandbox_shared_fs_probe.py guest  # manual two-terminal alternative

All test writes stay in a unique directory under tmp/sandbox-sharing-probes. The host peer
communicates through JSON files; neither side executes commands from the other.
"""
import argparse
import concurrent.futures
import ctypes
import errno
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time


def atomic(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + f'.{os.getpid()}.partial')
    with temporary.open('wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)


def put(path, value):
    atomic(path, json.dumps(value).encode())


def get(path, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return json.loads(Path(path).read_bytes())
        except FileNotFoundError:
            if time.monotonic() > deadline:
                raise TimeoutError(str(path))
            time.sleep(.005)


def git(directory, *args):
    p = subprocess.run(['git', '--no-optional-locks', '-C', str(directory), *args],
                       capture_output=True, check=True)
    return p.stdout


def payload(i):
    return f'{i:08d}\n'.encode() + bytes([i % 251]) * 65536


class Watch:
    def __init__(self, path):
        self.lib = ctypes.CDLL(None, use_errno=True)
        self.fd = self.lib.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), 'inotify_init1')
        self.wd = self.lib.inotify_add_watch(self.fd, os.fsencode(path), 0xFFF)
        if self.wd < 0:
            os.close(self.fd)
            raise OSError(ctypes.get_errno(), 'inotify_add_watch')

    def drain(self, timeout=0):
        events = []
        if not select.select([self.fd], [], [], timeout)[0]:
            return events
        while True:
            try:
                data = os.read(self.fd, 65536)
            except BlockingIOError:
                break
            pos = 0
            while pos < len(data):
                wd, mask, cookie, length = struct.unpack_from('iIII', data, pos)
                name = data[pos + 16:pos + 16 + length].rstrip(b'\0').decode()
                pos += 16 + length
                events.append({'name': name, 'mask': mask})
        return events

    def close(self):
        os.close(self.fd)


def index_writer(repo, trees, loops, ready, stop):
    ready.wait()
    try:
        for i in range(loops):
            git(repo, 'read-tree', trees[i % len(trees)])
    finally:
        stop.set()


def make_repo(repo):
    repo.mkdir()
    git(repo, 'init', '-q')
    for i in range(32):
        (repo / f'file-{i:02d}').write_bytes(payload(i))
    git(repo, 'add', '.')
    first = git(repo, 'write-tree').decode().strip()
    for i in range(32, 64):
        (repo / f'file-{i:02d}').write_bytes(payload(i))
    git(repo, 'add', '.')
    second = git(repo, 'write-tree').decode().strip()
    return [first, second]


def atomic_writer(path, count, ready, stop):
    ready.wait()
    try:
        for i in range(count):
            atomic(path, payload(i))
    finally:
        stop.set()


def exclusive_worker(path, rounds):
    acquired = 0
    for _ in range(rounds):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        try:
            guard = path + '.guard'
            guard_fd = os.open(guard, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(guard_fd)
            os.unlink(guard)
            acquired += 1
        finally:
            os.close(fd)
            os.unlink(path)
    return acquired


def local(root):
    report = {'root': str(root), 'scope': 'VM processes on shared mount'}
    cold = root / 'cold'
    cold.mkdir()
    for i in range(500):
        folder = cold / str(i)
        folder.mkdir()
        target = folder / 'value'
        target.write_bytes(payload(i))
        assert target.read_bytes() == payload(i)
        assert target.stat().st_size == len(payload(i))
        target.unlink()
        assert not target.exists()
        folder.rmdir()
    report['create_stat_read_unlink'] = {'rounds': 500, 'passed': True}

    target = root / 'atomic-value'
    atomic(target, payload(0))
    ready, stop = mp.Event(), mp.Event()
    writer = mp.Process(target=atomic_writer, args=(target, 1000, ready, stop))
    writer.start()
    reads, errors = 0, []
    ready.set()
    while not stop.is_set():
        try:
            data = target.read_bytes()
            version = int(data[:8])
            if data != payload(version):
                errors.append('partial/torn content')
        except Exception as e:
            errors.append(repr(e))
        reads += 1
    writer.join()
    assert writer.exitcode == 0 and not errors, errors[:5]
    report['atomic_replace'] = {'writes': 1000, 'reads': reads, 'passed': True}

    with concurrent.futures.ProcessPoolExecutor(max_workers=4) as pool:
        counts = list(pool.map(exclusive_worker, [str(root / 'index.lock')] * 4, [1000] * 4))
    report['exclusive_create'] = {'attempts': 4000, 'acquired': sum(counts), 'passed': True}

    repo = root / 'repo'
    trees = make_repo(repo)
    ready, stop = mp.Event(), mp.Event()
    writer = mp.Process(target=index_writer, args=(repo, trees, 500, ready, stop))
    writer.start()
    reads, errors = 0, []
    expected = [{f'file-{i:02d}' for i in range(n)} for n in (32, 64)]
    ready.set()
    while not stop.is_set():
        try:
            actual = set(git(repo, 'ls-files').decode().splitlines())
            if actual not in expected:
                errors.append(f'index listed {len(actual)} entries')
        except Exception as e:
            errors.append(repr(e))
        reads += 1
    writer.join()
    assert writer.exitcode == 0 and not errors, errors[:5]
    report['git_index_replacement'] = {'writes': 500, 'reads': reads, 'passed': True}

    watch = Watch(root)
    atomic(root / 'notification', b'notification')
    (root / 'notification').unlink()
    events = watch.drain(.5)
    watch.close()
    target_events = [e for e in events if e['name'] == 'notification']
    assert any(e['mask'] & 0x80 for e in target_events), events
    assert any(e['mask'] & 0x200 for e in target_events), events
    report['guest_inotify'] = {'events': target_events, 'passed': True}
    put(root / 'local-results.json', report)
    print(json.dumps(report, indent=2), flush=True)


def guest(root):
    # Mailboxes are separate from watched directories, so protocol traffic cannot
    # masquerade as target-file notifications.
    (root / 'targets').mkdir()
    (root / 'mail').mkdir()
    watch = Watch(root / 'targets')
    repo = root / 'host-repo'
    report = {'root': str(root), 'scope': 'host and guest', 'checks': []}
    sequence = 0

    def request(op, **args):
        nonlocal sequence
        sequence += 1
        put(root / 'mail' / f'request-{sequence}.json', {'op': op, **args})
        return get(root / 'mail' / f'response-{sequence}.json')

    print('Run this in a HOST terminal (not the Zed remote terminal):', flush=True)
    print(f'python3 {Path(__file__).resolve()} host {root}', flush=True)
    print('Waiting up to 15 minutes for the host peer...', flush=True)
    get(root / 'mail' / 'host-ready.json', 900)
    for op in ('create', 'overwrite', 'replace', 'delete', 'recreate'):
        watch.drain()
        response = request(op)
        start = time.monotonic()
        first_observed = None
        while True:
            try:
                data = (root / 'targets' / 'host-value').read_bytes()
                observed = hashlib.sha256(data).hexdigest()
                passed = op != 'delete' and observed == response['sha256']
            except FileNotFoundError:
                observed = 'absent' if op == 'delete' else 'missing'
                passed = op == 'delete'
            if first_observed is None:
                first_observed = observed
            # Normal metadata caching is intentional. Check bounded visibility,
            # while retaining the strict immediate Git-index checks below.
            if passed or time.monotonic() - start >= 10:
                break
            time.sleep(.05)
        visibility_ms = round((time.monotonic() - start)*1000, 2)
        events = [e for e in watch.drain(.25) if e['name'] == 'host-value']
        report['checks'].append({'op': f'host_{op}', 'content_passed': passed,
                                  'first_observed': first_observed,
                                  'observed': observed, 'events': events,
                                  'visibility_ms': visibility_ms})

    response = request('git_init')
    actual = git(repo, 'ls-files').decode().splitlines()
    report['checks'].append({'op': 'cold_host_git_index', 'passed': len(actual) == 64,
                              'tracked_count': len(actual)})
    for i in range(100):
        response = request('git_replace', version=i)
        actual = git(repo, 'ls-files').decode().splitlines()
        if len(actual) != response['count']:
            report['checks'].append({'op': 'host_git_index_replace', 'round': i,
                                      'passed': False, 'expected': response['count'],
                                      'actual': len(actual)})
    report['checks'].append({'op': 'host_git_index_replacements_completed', 'rounds': 100})

    atomic(root / 'targets' / 'guest-value', payload(123))
    response = request('read_guest')
    report['checks'].append({'op': 'host_reads_guest_write',
                              'passed': response['sha256'] == hashlib.sha256(payload(123)).hexdigest()})
    lock = root / 'targets' / 'exclusive.lock'
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        response = request('try_guest_lock')
        report['checks'].append({'op': 'host_respects_guest_exclusive_create',
                                  'passed': response['blocked']})
    finally:
        os.close(fd)
        lock.unlink()
    request('hold_host_lock')
    blocked = False
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    except FileExistsError:
        blocked = True
    report['checks'].append({'op': 'guest_respects_host_exclusive_create', 'passed': blocked})
    request('release_host_lock')
    request('done')
    watch.close()
    report['passed'] = all(
        check.get('passed', True) and check.get('content_passed', True)
        for check in report['checks']
    )
    put(root / 'cross-results.json', report)
    print(json.dumps(report, indent=2), flush=True)
    return 0 if report['passed'] else 1


def require_host():
    mounts = Path('/proc/mounts')
    if mounts.exists() and any(
        line.split()[1:3] == ['/mnt/mdt', 'virtiofs']
        for line in mounts.read_text().splitlines()
    ):
        raise RuntimeError('This is the sandbox terminal. Run the host command in a terminal on your actual machine.')


def host(root):
    # No project paths are touched; the peer is confined by construction to root.
    require_host()
    if not (root / 'mail').is_dir() or not root.name.startswith('cross-'):
        raise ValueError('Not a prepared probe directory')
    put(root / 'mail' / 'host-ready.json', {'pid': os.getpid()})
    sequence, trees = 0, None
    lock = root / 'targets' / 'exclusive.lock'
    held_fd = None
    try:
        while True:
            sequence += 1
            req = get(root / 'mail' / f'request-{sequence}.json', 120)
            op = req['op']
            target = root / 'targets' / 'host-value'
            response = {}
            if op in ('create', 'overwrite', 'replace', 'recreate'):
                # Exercise size changes too, so cached EOF metadata is tested.
                data = payload(sequence) + b'extra' * sequence
                if op == 'replace':
                    atomic(target, data)
                else:
                    with target.open('wb') as f:
                        f.write(data)
                        f.flush()
                        os.fsync(f.fileno())
                response['sha256'] = hashlib.sha256(data).hexdigest()
            elif op == 'delete':
                target.unlink()
            elif op == 'git_init':
                trees = make_repo(root / 'host-repo')
            elif op == 'git_replace':
                version = req['version'] % 2
                git(root / 'host-repo', 'read-tree', trees[version])
                response['count'] = (32, 64)[version]
            elif op == 'read_guest':
                response['sha256'] = hashlib.sha256((root / 'targets' / 'guest-value').read_bytes()).hexdigest()
            elif op == 'try_guest_lock':
                try:
                    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                    os.close(fd)
                    response['blocked'] = False
                except FileExistsError:
                    response['blocked'] = True
            elif op == 'hold_host_lock':
                held_fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            elif op == 'release_host_lock':
                os.close(held_fd)
                held_fd = None
                lock.unlink()
            elif op != 'done':
                raise ValueError(op)
            put(root / 'mail' / f'response-{sequence}.json', response)
            if op == 'done':
                break
    finally:
        if held_fd is not None:
            os.close(held_fd)
            lock.unlink(missing_ok=True)
    print('Host peer finished. Results: ' + str(root / 'cross-results.json'))


def paired(root, sandbox, msb):
    require_host()
    command = [msb, 'exec', '--no-stdin', '--no-tty', '--timeout', '5m', sandbox,
               '--', 'python3', str(Path(__file__).resolve()), 'guest', str(root)]
    with (root / 'guest.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   env={**os.environ, 'MSB_BACKEND': 'local'})
        try:
            deadline = time.monotonic() + 30
            while not (root / 'mail').is_dir():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Guest did not start; see ' + str(root / 'guest.log'))
                time.sleep(.05)
            host(root)
            status = process.wait(timeout=60)
            report = get(root / 'cross-results.json')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    failed = [c['op'] for c in report['checks']
              if not c.get('passed', True) or not c.get('content_passed', True)]
    print('Sharing checks: ' + ('PASS' if report['passed'] and status == 0 else 'FAIL'))
    print('Failed checks:', len(failed))
    if failed:
        print('Failures:', ', '.join(sorted(set(failed))))
    print('Raw inotify events are diagnostic; host mutation events are not expected.')
    print('Zed polling must be validated separately after reconnecting.')
    return 0 if report['passed'] and status == 0 else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('local', 'guest', 'host', 'check'))
    parser.add_argument('root', nargs='?', type=Path)
    parser.add_argument('--sandbox', help='Sandbox name for the paired host-side check')
    parser.add_argument('--msb', default='msb', help='Host msb executable for the paired check')
    args = parser.parse_args()
    if args.mode == 'host':
        if args.root is None:
            parser.error('host mode requires the root printed by guest mode')
        host(args.root.resolve())
    else:
        if args.mode == 'check' and not args.sandbox:
            parser.error('check requires --sandbox NAME')
        probes = Path(__file__).resolve().parent.parent / 'tmp' / 'sandbox-sharing-probes'
        probes.mkdir(parents=True, exist_ok=True)
        prefix = 'local-' if args.mode == 'local' else 'cross-'
        root = args.root.resolve() if args.root else Path(tempfile.mkdtemp(prefix=prefix, dir=probes))
        print('Probe directory: ' + str(root), flush=True)
        if args.mode == 'check':
            sys.exit(paired(root, args.sandbox, args.msb))
        sys.exit((local if args.mode == 'local' else guest)(root) or 0)
