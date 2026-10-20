#!/usr/bin/env python3
"""One-off CPU/RSS sampling of an already running app; never part of XCTest/CI.

Run twice against the desired baseline/candidate processes under the same
song, window, scene and warmup conditions. This script only reads ps output.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def cpu_seconds(value):
    days, _, clock = value.rpartition('-')
    total = 0.0
    for component in clock.split(':'):
        total = total * 60 + float(component)
    return total + (int(days) * 86400 if days else 0)


def read_process(pid):
    result = subprocess.check_output(
        ['ps', '-p', str(pid), '-o', 'time=', '-o', 'rss=', '-o', 'comm='], text=True
    ).strip().split(None, 2)
    cpu, rss, executable = result
    return {'monotonicSeconds': time.monotonic(), 'cpuSeconds': cpu_seconds(cpu),
            'residentBytes': int(rss) * 1024, 'executable': executable}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--label', default='', help='Build SHA and scenario notes')
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--warmup', type=float, default=2)
    args = parser.parse_args()
    if args.pid <= 0 or args.seconds <= 0 or args.warmup < 0:
        parser.error('pid and seconds must be positive; warmup must be nonnegative')
    time.sleep(args.warmup)
    samples = [read_process(args.pid)]
    started = samples[0]['monotonicSeconds']
    for index in range(1, args.seconds + 1):
        time.sleep(max(0, started + index - time.monotonic()))
        samples.append(read_process(args.pid))
    elapsed = samples[-1]['monotonicSeconds'] - started
    report = {
        'schema': 'lyricsq-process-resources-v1', 'pid': args.pid, 'label': args.label,
        'method': 'ps cumulative process CPU time and RSS; one CPU core = 100%',
        'warmupSeconds': args.warmup, 'measurementSeconds': elapsed,
        'averageCPUPercent': 100 * (samples[-1]['cpuSeconds'] - samples[0]['cpuSeconds']) / elapsed,
        'startResidentBytes': samples[0]['residentBytes'],
        'endResidentBytes': samples[-1]['residentBytes'],
        'peakResidentBytes': max(s['residentBytes'] for s in samples), 'samples': samples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as output:
        json.dump(report, output, indent=2)
    print(f"CPU {report['averageCPUPercent']:.3f}%; "
          f"RSS {report['startResidentBytes'] / 1048576:.2f} → "
          f"{report['endResidentBytes'] / 1048576:.2f} MiB; {args.output}")


if __name__ == '__main__':
    main()
