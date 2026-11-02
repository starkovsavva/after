"""Real CPython/supervisor plumbing fixture; synthetic speech, no models or audio."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def check_worker(engine, library, installed, root, runtime_env):
    backend = root / 'synthetic backend с пробелами'
    backend.mkdir(mode=0o700)
    (backend / 'fixture_helper.py').write_text('VALUE = "resource-module-loaded"\n')
    (backend / 'engine.py').write_text('''import json,os,signal,subprocess,sys,time
from pathlib import Path
from fixture_helper import VALUE
root = Path(sys.argv[sys.argv.index("--root")+1])
assert sys.flags.ignore_environment and sys.flags.no_user_site and sys.dont_write_bytecode
assert sys.prefix == os.environ["AFTER_EXPECTED_VENV"]
for key in ("POSLE_API_KEY","POSLE_SPEECH_API_KEY","OPENAI_API_KEY","LD_PRELOAD","PYTHONPATH"):
    assert key not in os.environ, key
assert VALUE == "resource-module-loaded"
(root / "fixture-worker.json").write_text(json.dumps({"prefix":sys.prefix,"version":sys.version.split()[0],"resourceModule":VALUE,"command":sys.argv[1]}))
print(json.dumps({"event":"progress","message":"verified-python-fixture","fraction":0.5}),flush=True)
if os.environ.get("AFTER_FIXTURE_HOLD") == "1":
    child = subprocess.Popen([sys.executable,"-B","-I","-c","import signal,time,sys; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(sys.argv[1]).write_text(str(1)); time.sleep(120)",str(root / "fixture-child-ready")])
    while not (root / "fixture-child-ready").exists():
        time.sleep(.01)
    (root / "fixture-pids.json").write_text(json.dumps([os.getpid(),child.pid]))
    time.sleep(120)
''')
    # Synthetic values exercise the real credential scrubber; never use secrets.
    env = runtime_env | {'AFTER_EXPECTED_VENV': str(Path(installed['interpreter']).parent.parent),
                         'POSLE_API_KEY': 'fixture-text-secret', 'POSLE_SPEECH_API_KEY': 'fixture-speech-secret',
                         'OPENAI_API_KEY': 'fixture-provider-secret', 'PYTHONPATH': str(root / 'untrusted-import-path')}
    command = [str(engine), 'prepare', '--root', str(library), '--backend', str(backend)]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Verified worker failed: ' + result.stdout[-2000:] + result.stderr[-1000:])
    events = [json.loads(line) for line in result.stdout.splitlines()]
    if not any(event.get('event') == 'progress' and event.get('message') == 'verified-python-fixture' for event in events):
        raise RuntimeError('Worker progress did not traverse the native supervisor')
    report = json.loads((library / 'fixture-worker.json').read_text())
    if report['version'] != installed['version'] or report['command'] != 'prepare':
        raise RuntimeError('Worker ran an unexpected runtime or command')

    def identity(pid):
        try:
            data = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            return data[0], data[19]
        except FileNotFoundError:
            return None

    worker = None
    pids = {}
    try:
        worker = subprocess.Popen(command, env=env | {'AFTER_FIXTURE_HOLD': '1'}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and worker.poll() is None:
            try:
                values = json.loads((library / 'fixture-pids.json').read_text())
                pids = {pid: identity(pid) for pid in values}
                if len(pids) == 2 and all(pids.values()):
                    break
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.02)
        if len(pids) != 2 or not all(pids.values()):
            raise RuntimeError('Cancellation fixture did not start its worker and descendant')
        worker.send_signal(signal.SIGTERM)
        output, errors = worker.communicate(timeout=8)
        if worker.returncode == 0:
            raise RuntimeError('Cancelled worker incorrectly reported success')
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            live = [pid for pid, original in pids.items() if (current := identity(pid)) and current[1] == original[1] and current[0] != 'Z']
            if not live:
                break
            time.sleep(.02)
        if live:
            raise RuntimeError('Owned worker descendant survived cancellation')
        for secret in ('fixture-text-secret', 'fixture-speech-secret', 'fixture-provider-secret'):
            if secret in output + errors:
                raise RuntimeError('Synthetic credential escaped through worker output')
    finally:
        if worker is not None and worker.poll() is None:
            worker.kill()
            worker.communicate(timeout=5)
        for pid, original in pids.items():
            current = identity(pid)
            if current and original and current[1] == original[1] and current[0] != 'Z':
                os.kill(pid, signal.SIGKILL)
