#!/usr/bin/env python3
"""Optional RU/EN retrieval smoke against an already-running local Ollama.

Uses invented texts only. Does not download models or read the user's library.
This small corpus is a regression smoke, not a general retrieval benchmark.
"""
import argparse
import ipaddress
import json
import math
import time
import urllib.parse
import urllib.request

DOCUMENTS = [
    'circle back — return to an earlier topic and discuss it again',
    'follow up — contact someone again to check progress',
    'Подготовить договор на поставку оборудования',
    'Отпуск согласован с 12 по 20 августа',
    'The access token has expired and must be refreshed',
    'Встреча по бюджету пилота, лимит 80000 рублей',
]
QUERIES = [
    ('как по-английски вернуться к ранее обсуждавшемуся вопросу', 0),
    ('повторно связаться и уточнить результат', 1),
    ('supplier agreement for hardware delivery', 2),
    ('когда у меня отдых летом', 3),
    ('authentication credential no longer valid', 4),
    ('сколько разрешили потратить на пробный запуск', 5),
]
PREFIX = 'Instruct: Given a search query, retrieve relevant passages from personal notes, tasks, meetings and code.\nQuery: '


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', default='http://127.0.0.1:11434')
    parser.add_argument('--model', default='qwen3-embedding:0.6b')
    args = parser.parse_args()
    endpoint = urllib.parse.urlsplit(args.endpoint)
    try:
        local = ipaddress.ip_address(endpoint.hostname).is_loopback
    except ValueError:
        local = False
    if not local or endpoint.scheme != 'http' or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment or endpoint.path not in ('', '/'):
        parser.error('Use an explicit loopback IP and port, for example http://127.0.0.1:11434')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())

    def embed(texts):
        request = urllib.request.Request(args.endpoint.rstrip('/') + '/api/embed',
            data=json.dumps({'model': args.model, 'input': texts, 'truncate': False, 'keep_alive': 0}).encode(),
            headers={'Content-Type': 'application/json'})
        with opener.open(request, timeout=120) as response:
            value = json.loads(response.read(4 * 1024 * 1024 + 1))
        vectors = value['embeddings']
        if len(vectors) != len(texts) or not all(v and all(math.isfinite(x) for x in v) and sum(x*x for x in v) > 0 for v in vectors):
            raise RuntimeError('Invalid embedding response')
        return vectors

    started = time.monotonic()
    vectors = embed(DOCUMENTS + [PREFIX + query for query, _ in QUERIES])
    if len({len(v) for v in vectors}) != 1:
        raise RuntimeError('Mixed vector dimensions')

    def cosine(a, b):
        return sum(x*y for x, y in zip(a, b)) / math.sqrt(sum(x*x for x in a) * sum(x*x for x in b))

    results = []
    for vector, (_, expected) in zip(vectors[len(DOCUMENTS):], QUERIES):
        ranked = sorted(range(len(DOCUMENTS)), key=lambda i: cosine(vector, vectors[i]), reverse=True)
        results.append({'expected': expected, 'top1': ranked[0], 'top3': ranked[:3]})
    report = {'model': args.model, 'dimensions': len(vectors[0]), 'cases': len(results),
        'top1': sum(r['expected'] == r['top1'] for r in results),
        'top3': sum(r['expected'] in r['top3'] for r in results),
        'elapsedSeconds': round(time.monotonic() - started, 3), 'results': results,
        'note': 'Invented six-case smoke; not an Air M5 performance or general quality benchmark.'}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report['top3'] != len(results):
        raise SystemExit('A known source is missing from top3')


if __name__ == '__main__':
    main()
