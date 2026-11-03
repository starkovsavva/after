#!/usr/bin/env python3
"""Preserve check exit status and expose a bounded failure excerpt in Actions."""
from collections import deque
import re
import subprocess
import sys


def escape_command(value):
    return value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main():
    command = sys.argv[1:]
    if command[:1] == ['--']:
        command = command[1:]
    if not command:
        raise SystemExit('Usage: run-ci-check.py -- command [arguments...]')
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    tail = deque(maxlen=40)
    errors = deque(maxlen=20)
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding='utf-8', errors='replace') as process:
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            bounded = line.rstrip()[:2000]
            tail.append(bounded)
            if re.search(r'error:|error\[|FAILED|panicked at|AssertionError|Traceback', bounded):
                errors.append(bounded)
        code = process.wait()
    if code:
        excerpt = ('Error markers:\n' + '\n'.join(errors) + '\nOutput tail:\n' + '\n'.join(tail))[-14000:]
        print('::error title=Check failure details::' + escape_command(excerpt), flush=True)
    raise SystemExit(code if code >= 0 else 128-code)


if __name__ == '__main__':
    main()
