#!/usr/bin/env python3
"""Evaluate the actual managed FFI index on frozen synthetic note fixtures.

Uses existing pinned assets only; no downloads or user library. The 0.43 manual
suggestion threshold is frozen from earlier calibration, never fit to holdout.
Run with an OS sandbox denying IP networking and non-temporary file writes.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import time

from eval_knowledge_semantic import evaluate, CORPUS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('library', 'runtime', 'model', 'output'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    core = ctypes.CDLL(str(args.library.resolve(strict=True)))
    core.posle_request.argtypes = [ctypes.c_char_p]
    core.posle_request.restype = ctypes.c_void_p
    core.posle_free_string.argtypes = [ctypes.c_void_p]
    results = {}
    with tempfile.TemporaryDirectory(prefix='after-managed-eval-', dir='/private/tmp') as temporary:
        root = Path(temporary).resolve()
        assets = root/'runtime/semantic'
        assets.mkdir(parents=True)
        for source, name in ((args.runtime, 'After Embeddings'), (args.model, 'qwen3-embedding-0.6b.gguf')):
            subprocess.run(['/bin/cp', '-c', str(source.resolve(strict=True)), str(assets/name)], check=True)
        (assets/'After Embeddings').chmod(0o700)
        (root/'settings.json').write_text(json.dumps({'features': {'semanticSearch': True, 'knowledgeBase': True}}))
        def call(command, **parameters):
            raw = core.posle_request(json.dumps(dict(root=str(root), command=command, **parameters)).encode())
            try:
                envelope = json.loads(ctypes.string_at(raw))
            finally:
                core.posle_free_string(raw)
            if not envelope['ok']:
                raise RuntimeError(envelope['error'])
            return envelope['value']
        config = call('semantic-config')['config']
        config['enabled'] = True
        config = call('semantic-check', config=config)['config']
        call('semantic-config', config=config)
        fixtures = [('calibration', CORPUS), ('holdout', CORPUS.with_name('knowledge-semantic-holdout-v2.json'))]
        for label, path in fixtures:
            data = path.read_bytes()
            documents = json.loads(data)['documents']
            started = time.monotonic()
            for document in documents:
                call('note-save', note=dict(id=document['id'], kind='note', title='', text=document['text'], createdAt=1, updatedAt=1, revision=0))
            for _ in range(100):
                if call('semantic-refresh', maxDocuments=8)['complete']:
                    break
            else:
                raise AssertionError('incomplete index')
            vectors = {}
            connection = sqlite3.connect(str(root/'cache/semantic/index.sqlite'))
            for source, vector in connection.execute('select source,vector from vectors'):
                source = json.loads(source)
                if source.get('noteID') in {d['id'] for d in documents}:
                    assert source['noteID'] not in vectors, 'fixture unexpectedly chunked'
                    vectors[source['noteID']] = list(struct.unpack('<'+'f'*(len(vector)//4), vector))
            connection.close()
            payload = dict(model=config['model'], revision=config['modelRevision'], vectors=vectors)
            results[label] = evaluate(documents, payload, threshold=.43, corpus_sha256=hashlib.sha256(data).hexdigest())
            results[label]['indexSeconds'] = round(time.monotonic()-started,3)
        results['scope'] = 'Actual app FFI index and pinned CPU model; synthetic fixtures only, not full mixed-topic quality.'
        args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
        print(json.dumps(results, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
