#!/usr/bin/env python3
"""Real managed-model acceptance with synthetic text and existing pinned assets.

No network downloads, user library, API keys or external embedding server.
Run under sandbox-exec denying IP network and writes outside /private/tmp.
Pass --keep to retain the fresh fixture for other synthetic acceptance checks.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='after-managed-product-', dir='/private/tmp')).resolve()
    core = ctypes.CDLL(str(args.library.resolve(strict=True)))
    core.posle_request.argtypes = [ctypes.c_char_p]
    core.posle_request.restype = ctypes.c_void_p
    core.posle_free_string.argtypes = [ctypes.c_void_p]
    timings = {}
    def request(command, **params):
        started = time.monotonic()
        raw = core.posle_request(json.dumps(dict(root=str(root), command=command, **params)).encode())
        try:
            result = json.loads(ctypes.string_at(raw))
        finally:
            core.posle_free_string(raw)
        timings.setdefault(command, []).append(round(time.monotonic()-started, 3))
        if not result['ok']:
            raise RuntimeError(result['error'])
        return result['value']
    before = set(Path('/private/tmp').glob('after-e-*'))
    try:
        directory = root / 'runtime' / 'semantic'
        directory.mkdir(parents=True)
        for source, name in ((args.runtime, 'After Embeddings'), (args.model, 'qwen3-embedding-0.6b.gguf')):
            subprocess.run(['/bin/cp', '-c', str(source.resolve(strict=True)), str(directory/name)], check=True)
        (directory/'After Embeddings').chmod(0o700)
        (root/'settings.json').write_text(json.dumps({'features': {'semanticSearch': True, 'knowledgeBase': True, 'assistant': True}}))
        config = request('semantic-config')['config']
        assert config['provider'] == 'managed' and config['endpoint'] == ''
        assert request('semantic-pull', config=config)['ready']
        config['enabled'] = True
        checked = request('semantic-check', config=config)
        config = checked['config']
        assert config['dimensions'] == 1024 and 'cpu-v1' in config['modelRevision']
        request('semantic-config', config=config)
        for identifier, text in [('recovery', 'При аварии сервера восстанавливаем сервис из резервной копии и проверяем целостность данных.'), ('budget', 'Расходы на маркетинг и бюджет рекламной кампании согласуем в пятницу.'), ('cooking', 'Рецепт домашнего хлеба: мука, вода, дрожжи и соль.')]:
            request('note-save', note=dict(id=identifier, kind='note', title=text, text=text, createdAt=1, updatedAt=1, revision=0))
        for _ in range(10):
            if request('semantic-refresh', maxDocuments=8)['complete']:
                break
        else:
            raise AssertionError('index did not complete')
        query = 'How do we restore service after a crash?'
        result = request('semantic-search', query=query, limit=3)
        assert result['hits'][0]['source']['noteID'] == 'recovery', result
        request('semantic-runtime-activity', recording=True)
        started = time.monotonic()
        try:
            request('semantic-search', query=query)
        except RuntimeError:
            pass
        else:
            raise AssertionError('recording failed to block model load')
        assert time.monotonic()-started < 2
        request('semantic-runtime-activity', recording=False)
        assert request('semantic-search', query=query)['hits'][0]['source']['noteID'] == 'recovery'
        # Revoking enabled config while the owned child is loading must cancel
        # before returning a search result. No real/private source text is used.
        outcome = []
        def run_search():
            try:
                request('semantic-search', query=query)
                outcome.append('unexpected-success')
            except RuntimeError:
                outcome.append('cancelled')
        thread = threading.Thread(target=run_search)
        thread.start()
        deadline = time.monotonic()+5
        while not (set(Path('/private/tmp').glob('after-e-*'))-before) and thread.is_alive() and time.monotonic()<deadline:
            time.sleep(.005)
        disabled = dict(config, enabled=False)
        request('semantic-config', config=disabled)
        thread.join(timeout=10)
        assert not thread.is_alive() and outcome == ['cancelled'], outcome
        request('semantic-config', config=config)
        assert not (set(Path('/private/tmp').glob('after-e-*'))-before), 'owned runtime scratch not removed'
        print(json.dumps({'passed': True, 'root': str(root) if args.keep else '(removed)', 'model': config['modelRevision'], 'timingsSeconds': timings, 'checks': ['explicit prepare', 'real 1024D model', 'index and cross-language retrieval', 'recording pauses and resumes', 'config revocation cancels loading', 'owned runtime cleanup']}, ensure_ascii=False, indent=2))
    finally:
        if not args.keep:
            shutil.rmtree(root)

if __name__ == '__main__':
    main()
