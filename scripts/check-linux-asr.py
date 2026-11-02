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
        runtime_args = ['--posle-install-python-runtime','--root',str(library),'--archive',str(args.python_archive.resolve()),'--profile','linux-cpu']
        if args.wheelhouse: runtime_args += ['--wheelhouse',str(args.wheelhouse.resolve())]
        print("Installing verified CPU runtime", file=sys.stderr, flush=True)
        run(runtime_args)
        print("Installing verified Parakeet model", file=sys.stderr, flush=True)
        model = json.loads(run(['--posle-install-asr-model','--root',str(library),'--archive',str(args.model_archive.resolve())]).stdout)
        model_dir = Path(model['directory'])
        active = model_dir.parent.parent / 'active.json'
        before = active.read_bytes()
        entries = set(active.parent.iterdir())
        bad = root / 'corrupt-model.tar.bz2'; bad.write_bytes(b'not a pinned archive')
        run(['--posle-install-asr-model','--root',str(library),'--archive',str(bad)],expected=False)
        if active.read_bytes() != before or set(active.parent.iterdir()) != entries:
            raise RuntimeError('Failed model preparation changed activation or leaked its candidate')
        settings = {'speechMode':'local','asrModelPath':str(model_dir),'asrModelFormat':'onnx','diarization':False}
        (library / 'settings.json').write_text(json.dumps(settings))
        speech = root / 'synthetic.wav'
        subprocess.run([tts,'-v','en-us','-s','145','-w',str(speech),'Hello world. This is a test of local speech recognition.'],env=env,check=True,timeout=20)
        imported = json.loads(run(['import','--root',str(library)],payload=json.dumps({'source':str(speech)})).stdout.splitlines()[-1])
        meeting = library / 'meetings' / imported['id']
        source = meeting / imported['source']; source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        command = ['transcribe','--root',str(library),'--backend',str(PROJECT/'backend'),'--meeting',str(meeting),'--no-diarization']
        print("Transcribing synthetic English speech", file=sys.stderr, flush=True)
        run(command)
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
        token_file = model_dir/'tokens.txt'
        original = token_file.read_bytes(); mode = stat.S_IMODE(token_file.stat().st_mode)
        token_file.chmod(mode | stat.S_IWUSR)
        try:
            token_file.write_bytes(bytes([original[0]^1])+original[1:])
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
        print(json.dumps({'passed':True,'realParakeetCpu':True,'syntheticSpeechOnly':True,'canonicalTranscript':True,
                          'corruptArchivePreservedActive':True,'tamperedModelRejectedBeforeExecution':True,
                          'frozenSelectionPreserved':True,'previousTranscriptAndSourcePreserved':True},indent=2))


if __name__ == '__main__': main()
