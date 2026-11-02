"""Native queue fixture client; no renderer grants or personal libraries."""
import json
from pathlib import Path
import selectors
import subprocess
import time
import uuid


class Queue:
    def __init__(self, engine, library, backend, env):
        self.process = subprocess.Popen([str(engine), '--posle-speech-queue', '--root', str(library), '--backend', str(backend)],
                                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        if self.read().get('event') != 'ready':
            self.close()
            raise RuntimeError('Native speech queue did not become ready')

    def read(self):
        if not self.selector.select(timeout=300):
            raise RuntimeError('Native speech queue reply deadline expired')
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('Native speech queue closed without a reply')
        return json.loads(line)

    def call(self, action, **arguments):
        identity = str(uuid.uuid4())
        self.process.stdin.write(json.dumps({'version': 1, 'id': identity, 'request': {'action': action, **arguments}}) + '\n')
        self.process.stdin.flush()
        frame = self.read()
        if frame.get('id') != identity or frame.get('version') != 1 or not frame.get('envelope', {}).get('ok'):
            raise RuntimeError('Native speech queue rejected a fixture request: ' + json.dumps(frame))
        return frame['envelope']['result']

    def wait(self, identity, expected):
        deadline = time.monotonic() + 900
        while True:
            job = self.call('get', jobId=identity)['job']
            if job['state'] == expected:
                return job
            if job['state'] not in ('running', 'queued') or time.monotonic() >= deadline:
                raise RuntimeError('Unexpected durable speech state: ' + json.dumps(job))
            time.sleep(.05)

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            code = self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise RuntimeError('Speech queue did not stop and join its native worker')
        finally:
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()
        if code:
            raise RuntimeError('Speech queue connection failed')

    def __enter__(self):
        return self

    def __exit__(self, *ignored):
        self.close()


def transcribe(engine, library, backend, env, work):
    with Queue(engine, library, backend, env) as queue:
        job = queue.call('enqueue', input=work)['job']
        serialized = json.dumps(job)
        if any(secret in serialized for secret in (work['attemptToken'], work['operationId'], 'settings', 'inputRevision')):
            raise RuntimeError('Native queue read model exposed private configuration or grants')
        if job['state'] == 'succeeded':
            return job
        claimed = queue.call('run', jobId=job['id'])['job']
        if not claimed or claimed['attempt'] != job['attempt'] + 1:
            raise RuntimeError('Speech attempt was not claimed durably')
        result = queue.wait(job['id'], 'succeeded')
        if result['progress'] != 1:
            raise RuntimeError('Completed speech did not publish complete durable progress')
        return result


def check_cancel(engine, library, env, work, scratch):
    """Real native publisher + verified Python; only a synthetic backend stalls."""
    backend = scratch / 'cancellable speech backend'
    backend.mkdir(mode=0o700)
    ready = library / 'fixture-speech-child-ready'
    pids = library / 'fixture-speech-pids.json'
    child_code = ('import os,signal,time; from pathlib import Path; '
                  'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                  f'Path({str(ready)!r}).write_text(str(os.getpid())); time.sleep(120)')
    (backend / 'engine.py').write_text(
        'import os,signal,subprocess,sys,time,json\nfrom pathlib import Path\n'
        'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
        f'child=subprocess.Popen([sys.executable,"-B","-I","-c",{child_code!r}])\n'
        f'while not Path({str(ready)!r}).exists(): time.sleep(.01)\n'
        f'Path({str(pids)!r}).write_text(json.dumps([os.getppid(),os.getpid(),child.pid]))\n'
        'print(json.dumps({"event":"progress","message":"synthetic queue cancellation","fraction":.2}),flush=True)\n'
        'time.sleep(120)\n')
    work = dict(work, operationId=str(uuid.uuid4()), attemptToken=str(uuid.uuid4()))
    # The fake backend loads no model. External selection retains the established
    # local compatibility boundary; managed-model verification is never bypassed.
    work['settings'] = dict(work['settings'], asrModelPath=str(scratch / 'external fixture model'))
    inspect = subprocess.run([str(engine), '--posle-speech-job', '--root', str(library), '--backend', str(backend)],
                             input=json.dumps({'inspect':work['meetingId']}),env=env,capture_output=True,text=True,check=True,timeout=30)
    work['inputRevision'] = json.loads(inspect.stdout.splitlines()[-1])['speechJob']['inputRevision']
    transcript = library / 'meetings' / work['meetingId'] / 'transcript.json'
    original = transcript.read_bytes()
    def identity(pid):
        try:
            fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            return fields[0], fields[19]
        except FileNotFoundError:
            return None
    for expected in ('cancelled', 'interrupted'):
        ready.unlink(missing_ok=True)
        pids.unlink(missing_ok=True)
        work = dict(work, operationId=str(uuid.uuid4()), attemptToken=str(uuid.uuid4()))
        with Queue(engine, library, backend, env) as queue:
            job = queue.call('enqueue', input=work)['job']
            queue.call('run', jobId=job['id'])
            deadline = time.monotonic() + 30
            while not pids.exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError('Synthetic speech process tree did not start')
                time.sleep(.02)
            processes = {pid:identity(pid) for pid in json.loads(pids.read_text())}
            if len(processes) != 3 or not all(processes.values()):
                raise RuntimeError('Native publisher/SDK/descendant were not all live before cancellation')
            if expected == 'cancelled':
                queue.call('cancel', jobId=job['id'], expectedAttempt=1)
                queue.wait(job['id'], 'cancelled')
            # EOF with a live worker exercises owner shutdown and join.
        for pid, before in processes.items():
            after = identity(pid)
            if after and after[1] == before[1] and after[0] != 'Z':
                raise RuntimeError('A native speech descendant survived cancellation/shutdown')
        marker = pids.read_bytes()
        with Queue(engine, library, backend, env) as queue:
            recovered = queue.call('get', jobId=job['id'])['job']
            if recovered['state'] != expected or pids.read_bytes() != marker:
                raise RuntimeError('Queue recovery changed cancellation/shutdown or resumed inference')
    if transcript.read_bytes() != original:
        raise RuntimeError('Cancelled staged speech replaced the previous transcript')
