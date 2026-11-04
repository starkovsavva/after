#!/usr/bin/env python3
"""Real local CPU Parakeet → canonical transcript, using synthetic speech only."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid
from linux_speech_queue_fixture import transcribe as queued_transcribe, check_cancel, preflight
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python-archive', type=Path, required=True)
    parser.add_argument('--model-archive', type=Path, required=True)
    parser.add_argument('--wheelhouse', type=Path)
    parser.add_argument('--engine', type=Path, default=PROJECT / '.build/rust/debug/posle-engine')
    args = parser.parse_args()
    tts = shutil.which('espeak-ng') or shutil.which('espeak')
    if not tts: parser.error('espeak-ng or espeak is required for synthetic speech')
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='after-real-asr-') as folder:
        root = Path(folder)
        library = root / 'Library с пробелами'
        library.mkdir(mode=0o700)
        env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'TMPDIR': folder}
        def run(arguments, *, payload=None, expected=True, extra_env=None):
            result = subprocess.run([str(engine), *arguments], input=payload, env=env | (extra_env or {}), capture_output=True, text=True, timeout=900)
            if (result.returncode == 0) != expected:
                raise RuntimeError('ASR fixture command failed: ' + result.stdout[-3000:] + result.stderr[-1000:])
            return result
        setup_args = ['--posle-install-local-speech','--root',str(library),'--python-archive',str(args.python_archive.resolve()),'--model-archive',str(args.model_archive.resolve())]
        if args.wheelhouse: setup_args += ['--wheelhouse',str(args.wheelhouse.resolve())]
        settings_before = json.dumps({'speechMode':'cloud','apiKey':'private-deployment-fixture','future':{'keep':True}}).encode()
        (library/'settings.json').write_bytes(settings_before)
        print("Installing verified local CPU runtime and Parakeet model", file=sys.stderr, flush=True)
        installed = run(setup_args)
        setup = json.loads(installed.stdout)
        phases = [event['stage'] for line in installed.stderr.splitlines() if line.startswith('{')
                  for event in [json.loads(line)] if event.get('event') == 'local_speech_install']
        if phases != ['runtime', 'model', 'verify', 'complete']:
            raise RuntimeError('Deployment progress did not finish verification in order')
        if setup['settingsChanged'] is not False or setup['inferenceChecked'] is not False:
            raise RuntimeError('Deployment incorrectly selected a model or claimed inference readiness')
        if (library/'settings.json').read_bytes() != settings_before or 'private-deployment-fixture' in installed.stdout+installed.stderr:
            raise RuntimeError('Deployment changed or exposed existing settings')
        model = setup['model']
        model_dir = Path(model['directory'])
        active = model_dir.parent.parent / 'active.json'
        before = active.read_bytes()
        entries = set(active.parent.iterdir())
        bad = root / 'corrupt-model.tar.bz2'; bad.write_bytes(b'not a pinned archive')
        run(['--posle-install-asr-model','--root',str(library),'--archive',str(bad)],expected=False)
        if active.read_bytes() != before or set(active.parent.iterdir()) != entries:
            raise RuntimeError('Failed model preparation changed activation or leaked its candidate')
        selection_args = ['--posle-local-speech-selection','--root',str(library)]
        status = json.loads(run(selection_args).stdout)
        metadata_args = ['desktop-bridge','--root',str(library)]
        configured = json.loads(run(metadata_args,payload=json.dumps({'command':'get_speech_model_configuration','arguments':{}})).stdout)
        if configured.get('ok') is not True or configured['result']['selection'] != status:
            raise RuntimeError('Standalone metadata bridge returned another selection')
        candidate = configured['result']['candidate']
        if set(candidate) != {'generation','modelId'} or candidate['generation'] != model['generation']:
            raise RuntimeError('Model candidate exposed private deployment data or another generation')
        selected = run(metadata_args,payload=json.dumps({'command':'select_managed_speech_model','arguments':{'generation':model['generation'],'expectedRevision':status['revision']}}))
        selection_reply = json.loads(selected.stdout)
        if selection_reply.get('ok') is not True:
            raise RuntimeError('Standalone metadata bridge rejected verified model selection')
        selection = selection_reply['result']
        settings = json.loads((library/'settings.json').read_text())
        if selection['local'] is not True or selection['revision'] == status['revision']:
            raise RuntimeError('Explicit model selection was not acknowledged')
        if settings['apiKey'] != 'private-deployment-fixture' or settings['future'] != {'keep':True} or settings['asrModelPath'] != str(model_dir):
            raise RuntimeError('Selection lost unrelated settings or selected another model')
        if set(selection) != {'revision','local'} or 'private-deployment-fixture' in selected.stdout:
            raise RuntimeError('Selection exposed private settings')
        selected_bytes = (library/'settings.json').read_bytes()
        run([*selection_args,'--select-generation',model['generation'],'--expected-revision',status['revision']],expected=False)
        run([*selection_args,'--select-generation',str(uuid.uuid4()),'--expected-revision',selection['revision']],expected=False)
        if (library/'settings.json').read_bytes() != selected_bytes:
            raise RuntimeError('Stale or missing-model selection changed settings')
        # Private queue work contains only the speech selection, never the full
        # persisted settings whose unrelated fields were preserved above.
        settings = {key: settings[key] for key in ('speechMode','speechLocalModel','asrModelPath','asrModelFormat','diarization')}
        print("Checking actual offline speech readiness", file=sys.stderr, flush=True)
        checked = run(['check-speech','--root',str(library),'--backend',str(PROJECT / 'backend')])
        events = [json.loads(line) for line in checked.stdout.splitlines() if line.startswith('{')]
        if not any(event.get('localInferenceVerified') is True and event.get('mediaVerified') is True
                   and event.get('diarizationVerified') is False for event in events):
            raise RuntimeError('Speech preflight did not verify actual local inference and media')
        if (library / 'meetings').exists() and any((library / 'meetings').glob('*/transcript.json')):
            raise RuntimeError('Speech preflight wrote a meeting transcript')
        print('Checking admitted native preflight',file=sys.stderr,flush=True)
        preflight(engine,library,PROJECT/'backend',env)
        speech = root / 'synthetic.wav'
        subprocess.run([tts,'-v','en-us','-s','145','-w',str(speech),'Hello world. This is a test of local speech recognition.'],env=env,check=True,timeout=20)
        imported = json.loads(run(['import','--root',str(library)],payload=json.dumps({'source':str(speech)})).stdout.splitlines()[-1])
        meeting = library / 'meetings' / imported['id']
        source = meeting / imported['source']; source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        # Change live selection inside the real child, after native verification.
        # The backend must still use exactly the local snapshot selected by host.
        backend = root / 'settings-race backend'
        backend.mkdir(mode=0o700)
        (backend / 'engine.py').write_text(
            'import json,runpy,sys\nfrom pathlib import Path\n'
            + 'root=Path(sys.argv[sys.argv.index("--root")+1])\n'
            + '(root/"settings.json").write_text(json.dumps({"speechMode":"cloud"}))\n'
            + f'sys.path.insert(0,{str(PROJECT / "backend")!r})\n'
            + f'runpy.run_path({str(PROJECT / "backend/engine.py")!r},run_name="__main__")\n')
        command = ['transcribe','--root',str(library),'--backend',str(backend),'--meeting',str(meeting),'--no-diarization']
        print("Transcribing synthetic English speech", file=sys.stderr, flush=True)
        job_command = ['--posle-speech-job','--root',str(library),'--backend',str(backend)]
        inspected = json.loads(run(job_command,payload=json.dumps({'inspect':imported['id']})).stdout.splitlines()[-1])
        work = {'version':1,'operationId':str(uuid.uuid4()),'attemptToken':str(uuid.uuid4()),'meetingId':imported['id'],
                'inputRevision':inspected['speechJob']['inputRevision'],'settings':settings}
        queued_transcribe(engine,library,backend,env,work,start_by_meeting=True)
        receipt = json.loads((meeting/'transcript.json').read_text())['_posleSpeechReceipt']
        if receipt['operationId'] != work['operationId'] or receipt['attemptToken'] != work['attemptToken']:
            raise RuntimeError('Native speech publication returned the wrong receipt')
        transcript = meeting / 'transcript.json'; preserved = transcript.read_bytes()
        value = json.loads(preserved)
        words = re.findall(r'[a-z]+',' '.join(segment['text'] for segment in value['segments']).lower())
        if not {'hello','world','local','speech','recognition'} <= set(words):
            raise RuntimeError('Real Parakeet did not recognize the synthetic test phrase')
        if value['modelFormat'] != 'onnx' or value['modelPath'] != str(model_dir):
            raise RuntimeError('Unexpected model/runtime path')
        for segment in value['segments']:
            if not 0 <= segment['start'] <= segment['end'] <= value['duration']+.01:
                raise RuntimeError('Invalid transcript timing')
        if json.loads((library/'settings.json').read_text()) != {'speechMode':'cloud'}:
            raise RuntimeError('Selection race fixture did not execute')
        (library/'settings.json').write_text(json.dumps(settings))
        token_file = model_dir/'tokens.txt'
        original = token_file.read_bytes(); mode = stat.S_IMODE(token_file.stat().st_mode)
        token_file.chmod(mode | stat.S_IWUSR)
        try:
            token_file.write_bytes(bytes([original[0]^1])+original[1:])
            queued_transcribe(engine,library,backend,env,work)
            repeated = json.loads(run(job_command,payload=json.dumps(work)).stdout.splitlines()[-1])
            if repeated['speechJob']['receipt'] != receipt:
                raise RuntimeError('Committed speech was not reconciled without rerunning the damaged model')
            blocked = run(command,expected=False)
            if 'ASR model integrity verification failed' not in blocked.stdout+blocked.stderr:
                raise RuntimeError('Corrupted managed model was not rejected by the native guard')
            # A frozen local job must not fall back to different live settings.
            (library/'settings.json').write_text(json.dumps({'speechMode':'cloud'}))
            blocked = run(command,expected=False,extra_env={'POSLE_JOB_SETTINGS':json.dumps(settings)})
            if 'ASR model integrity verification failed' not in blocked.stdout+blocked.stderr:
                raise RuntimeError('Managed model guard lost frozen job selection')
        finally:
            token_file.write_bytes(original);token_file.chmod(mode)
        if transcript.read_bytes()!=preserved or hashlib.sha256(source.read_bytes()).hexdigest()!=source_hash:
            raise RuntimeError('Integrity failure altered previous transcription or source')
        print("Cancelling a real native/SDK/descendant scope", file=sys.stderr, flush=True)
        check_cancel(engine,library,env,work,root)
        print("Cancelling native preflight/SDK/descendant scopes", file=sys.stderr, flush=True)
        check_cancel(engine,library,env,work,root,preflight=True)
        if hashlib.sha256(source.read_bytes()).hexdigest()!=source_hash:
            raise RuntimeError('Speech cancellation/shutdown altered the original media')
        print(json.dumps({'passed':True,'durablePreflight':True,'preflightCancellationAndEof':True,'durableSpeechQueue':True,'nativeSdkDescendantCancellation':True,'eofInterruptedWithoutResume':True,'realParakeetCpu':True,'syntheticSpeechOnly':True,'canonicalTranscript':True,'nativeStagedPublication':True,'receiptPreventedRepeatInference':True,'liveSettingsSwitchDidNotRedirect':True,
                          'corruptArchivePreservedActive':True,'tamperedModelRejectedBeforeExecution':True,
                          'frozenSelectionPreserved':True,'previousTranscriptAndSourcePreserved':True},indent=2))


if __name__ == '__main__': main()
