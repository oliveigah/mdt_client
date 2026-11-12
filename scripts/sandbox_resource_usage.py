#!/usr/bin/env python3
"""Read-only Linux CPU/RSS sample, on the host and optionally inside a VM."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def snapshot():
    processes = {}
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit():
            continue
        try:
            raw = (directory / 'stat').read_text()
            end = raw.rindex(')')
            fields = raw[end + 2:].split()
            processes[directory.name] = {
                'name': raw[raw.index('(') + 1:end],
                'ticks': int(fields[11]) + int(fields[12]),
                'start': fields[19],
                'rss_mib': round(int(fields[21]) * os.sysconf('SC_PAGE_SIZE') / 1048576, 1),
            }
        except (OSError, ValueError, IndexError):
            pass
    cpu = list(map(int, Path('/proc/stat').read_text().splitlines()[0].split()[1:9]))
    return processes, cpu


def sample(seconds):
    before, cpu_before = snapshot()
    start = time.monotonic()
    time.sleep(seconds)
    after, cpu_after = snapshot()
    elapsed = time.monotonic() - start
    ticks = os.sysconf('SC_CLK_TCK')
    rows = []
    for pid, current in after.items():
        previous = before.get(pid)
        if previous and previous['start'] == current['start']:
            rows.append({'pid': int(pid), 'name': current['name'],
                         'cpu_percent_one_core': round(100 * (current['ticks'] - previous['ticks']) / ticks / elapsed, 1),
                         'rss_mib': current['rss_mib']})
    rows.sort(key=lambda row: row['cpu_percent_one_core'], reverse=True)
    delta = [b - a for a, b in zip(cpu_before, cpu_after)]
    total = sum(delta)
    return {'seconds': round(elapsed, 1), 'logical_cpus': os.cpu_count(),
            'total_cpu_busy_percent': round(100 * (total - delta[3] - delta[4]) / max(total, 1), 1),
            'iowait_percent': round(100 * delta[4] / max(total, 1), 1),
            'top_processes': rows[:20]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sandbox')
    parser.add_argument('--seconds', type=int, default=20, choices=range(5, 61))
    args = parser.parse_args()
    child = None
    if args.sandbox:
        if os.environ.get('MDT_SANDBOX') == '1':
            parser.error('--sandbox must be run on the host')
        child = subprocess.Popen(
            ['msb', 'exec', '--no-stdin', '--no-tty', args.sandbox, '--',
             'python3', str(Path(__file__).resolve()), '--seconds', str(args.seconds)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, 'MSB_BACKEND': 'local'})
    result = {'host' if args.sandbox else 'guest': sample(args.seconds)}
    if child:
        try:
            output, errors = child.communicate(timeout=15)
            result['guest'] = json.loads(output) if child.returncode == 0 else {'error': errors[-1000:]}
        except (subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            child.kill()
            child.communicate()
            result['guest'] = {'error': str(error)}
    report = json.dumps(result, indent=2)
    destination = Path(__file__).resolve().parent.parent / 'tmp' / 'sandbox-resource-usage.json'
    destination.parent.mkdir(exist_ok=True)
    if args.sandbox:
        destination.write_text(report + '\n')
        print('Saved report: ' + str(destination))
    print(report)
