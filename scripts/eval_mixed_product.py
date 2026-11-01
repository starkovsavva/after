#!/usr/bin/env python3
"""Opt-in product evaluation using an existing local model and isolated library.

Runs the actual Rust commands, persisted semantic index, and mixed topic endpoint.
Never downloads a model or reads a personal library. Corpus splits are frozen
before inference; threshold changes may use calibration, never holdout results.
"""
import argparse, ctypes, hashlib, itertools, json, math, os, shutil, sqlite3, struct, subprocess, tempfile
from pathlib import Path


def metrics(docs, groups):
    expected={tuple(sorted((a['id'],b['id']))) for a,b in itertools.combinations(docs,2) if a['label']==b['label'] and (a['type']=='meeting' or b['type']=='meeting')}
    found=set()
    for group in groups:
        sources=group['sources']
        for a,b in itertools.combinations(sources,2):
            if a['kind']=='meeting' or b['kind']=='meeting': found.add(tuple(sorted((a.get('noteID') or a['meetingID'],b.get('noteID') or b['meetingID']))))
    correct=found&expected
    relevant_ids={i for pair in expected for i in pair}; covered={i for pair in correct for i in pair}
    return dict(returned=len(found),correct=len(correct),expected=len(expected),false_pairs=sorted(found-expected),missed_pairs=sorted(expected-found),
        precision=len(correct)/len(found) if found else None,recall=len(correct)/len(expected) if expected else None,
        positive_source_coverage=len(covered)/len(relevant_ids) if relevant_ids else None,groups=len(groups))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--runtime',type=Path,required=True);p.add_argument('--model',type=Path,required=True)
    p.add_argument('--corpus',type=Path,default=Path(__file__).parent/'fixtures/knowledge-mixed-product-v1.json')
    p.add_argument('--split',choices=['calibration','holdout'],required=True);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args(); docs=json.loads(args.corpus.read_text())['splits'][args.split]
    core=ctypes.CDLL(str(args.library.resolve()));core.posle_request.argtypes=[ctypes.c_char_p];core.posle_request.restype=ctypes.c_void_p
    core.posle_free_string.argtypes=[ctypes.c_void_p]
    with tempfile.TemporaryDirectory(prefix='after-mixed-eval-',dir='/private/tmp') as tmp:
        root=Path(tmp)
        def call(command,**data):
            raw=core.posle_request(json.dumps(dict(root=tmp,command=command,**data)).encode())
            try: result=json.loads(ctypes.string_at(raw))
            finally: core.posle_free_string(raw)
            if not result['ok']: raise RuntimeError(command+': '+result['error'])
            return result['value']
        (root/'settings.json').write_text(json.dumps({'features':{'knowledgeBase':True,'semanticSearch':True}}))
        for d in docs:
            if d['type']=='note':call('note-save',note=dict(id=d['id'],kind='note',text=d['text'],createdAt=0,updatedAt=0,revision=0))
            else:
                path=root/'meetings'/d['id'];path.mkdir(parents=True)
                (path/'meta.json').write_text(json.dumps(dict(id=d['id'],title='Discussion',source='audio.mp3',createdAt=1,status='ready')))
                (path/'transcript.json').write_text(json.dumps(dict(segments=[dict(id=1,start=0,end=1,text=d['text'])])))
        lexical=call('kb-mixed-topics')
        runtime=root/'runtime/semantic';runtime.mkdir(parents=True)
        for src,name in [(args.runtime,'After Embeddings'),(args.model,'qwen3-embedding-0.6b.gguf')]:
            subprocess.run(['/bin/cp','-c',str(src.resolve()),str(runtime/name)],check=True);os.chmod(runtime/name,0o700 if name=='After Embeddings' else 0o600)
        config=call('semantic-config')['config'];config.update(enabled=True,provider='managed',endpoint='',model='qwen3-embedding:0.6b',modelRevision='qwen3-embedding-0.6b-06507c7b-llama-v0.40.3-cpu-v1',dimensions=1024,documentPrefix='')
        call('semantic-config',config=config)
        for _ in range(100):
            status=call('semantic-refresh',maxDocuments=8)
            print('indexed',status['indexed'],'/',status['total'],flush=True)
            if status['complete']:break
        else:raise AssertionError('index failed to complete')
        semantic=call('kb-mixed-topics')
        if semantic['semanticIndexed']!=len(docs):raise AssertionError('not all fixture sources use real vectors')
        result=dict(corpus_sha256=hashlib.sha256(args.corpus.read_bytes()).hexdigest(),split=args.split,model=config['model'],revision=config['modelRevision'],
            documents=len(docs),threshold=semantic.get('semanticThreshold'),lexical=metrics(docs,lexical['topics']),semantic=metrics(docs,semantic['topics']),semanticIndexed=semantic['semanticIndexed'],
            limitation='Small frozen synthetic corpus; this is product regression evidence, not a guarantee for a real personal library.')
        # Calibration export uses the same per-source normalized centroids as Rust.
        with sqlite3.connect(root/'cache/semantic/index.sqlite') as db:
            sums={}; counts={}
            for raw,blob in db.execute("SELECT source,vector FROM vectors WHERE generation=(SELECT value FROM state WHERE key='active') ORDER BY id"):
                source=json.loads(raw);kind=source['kind']
                if kind not in ('note','transcript','summary'):continue
                key=source.get('noteID') or source['meetingID'];limit=4 if kind=='note' else 16
                if counts.get(key,0)>=limit:continue
                vec=struct.unpack('<'+'f'*(len(blob)//4),blob);counts[key]=counts.get(key,0)+1
                sums[key]=[a+b for a,b in zip(sums.get(key,[0]*len(vec)),vec)]
            vectors={key:[x/math.sqrt(sum(v*v for v in vals)) for x in vals] for key,vals in sums.items()}
        result['cosines']=[dict(a=a['id'],b=b['id'],relevant=a['label']==b['label'],score=sum(x*y for x,y in zip(vectors[a['id']],vectors[b['id']]))) for a,b in itertools.combinations(docs,2) if a['type']=='meeting' or b['type']=='meeting']
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k!='cosines'},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
