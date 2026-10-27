#!/usr/bin/env python3
"""Loopback-only model fixture for native voice E2E. Never contacts a provider."""
import argparse
import json
import pathlib
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True)
args = parser.parse_args()
root = pathlib.Path(args.root).resolve()
if root.parent != pathlib.Path('/private/tmp') or not root.name.startswith('posle-native-check-'):
    raise SystemExit('Disposable voice fixture root required')

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, payload, status=200):
        data = json.dumps(payload).encode()
        try:
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == '/v1/models':
            return self.reply({'data': [{'id': 'voice-fixture'}]})
        self.reply({}, 404)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length < 100_000:
            return self.reply({}, 400)
        body = json.loads(self.rfile.read(length))
        (root / 'fixture-request.json').write_text(json.dumps(body))
        fixture = json.loads((root / 'fixture-response.json').read_text())
        time.sleep(min(float(fixture.get('delay', 0)), 3))
        schema = body.get('response_format', {}).get('json_schema', {}).get('schema', {})
        properties = schema.get('properties', {})
        reranking = 'matches' in properties
        knowledge = 'paragraphs' in properties
        if knowledge:
            # The real second pass supplies opaque, validated source IDs. The
            # fixture echoes only actual evidence; never fabricate citations.
            prompt = json.loads(body['messages'][-1]['content'])
            sources = prompt.get('sources', [])
            (root / 'fixture-knowledge-started.json').write_text(json.dumps(prompt))
            time.sleep(min(float(fixture.get('knowledgeDelay', 0)), 3))
            kinds = fixture.get('knowledgeKinds', [])
            if kinds:
                sources = [source for source in sources if source.get('kind') in kinds]
            paragraphs = [{'text': source['excerpt'][:900], 'sourceIDs': [source['id']]}
                          for source in sources[:3] if source.get('excerpt')]
            if fixture.get('knowledgeMixed'):
                mixed = [next(source for source in sources if source['kind'] == kind)
                         for kind in ['calendar', 'task']]
                paragraphs = [{'text': '\n'.join(source['excerpt'][:900] for source in mixed),
                               'sourceIDs': [source['id'] for source in mixed]}]
            content = fixture.get('knowledge', {'title': 'Найдено в библиотеке', 'paragraphs': paragraphs})
        else:
            prompt = json.loads(body['messages'][-1]['content'])
            if reranking:
                (root / 'fixture-reranking-started.json').write_text(json.dumps(prompt))
                time.sleep(min(float(fixture.get('rerankingDelay', 0)), 3))
            else:
                (root / 'fixture-classification-started.json').write_text(json.dumps(prompt))
                time.sleep(min(float(fixture.get('classificationDelay', 0)), 3))
            content = fixture.get('reranking') if reranking else fixture.get('content', fixture.get('proposal'))
        if not isinstance(content, str):
            content = json.dumps(content, ensure_ascii=False)
        self.reply({'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': content}}]})

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'fixture-port').write_text(str(server.server_port))
server.serve_forever()
