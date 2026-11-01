#!/usr/bin/env python3
"""Offline semantic-neighbour smoke evaluation; never calls or downloads a model.

Prepare a JSON file with the embeddings of every fixture document using the
same model and document prefix as the application. For these single-line
synthetic notes with an empty explicit title, no tags and no attachments,
the app uses the first line as title and embeds `text + "\\n" + text + "\\n\\n"`.
All fixture texts are shorter than both the title and chunk limits:
  {"model": "...", "revision": "...", "vectors": {"rel-01": [0.1, ...], ...}}

    python3 scripts/eval_knowledge_semantic.py --emit-input
    python3 scripts/eval_knowledge_semantic.py --vectors /absolute/path/vectors.json

The small synthetic corpus is a reproducible smoke check, not the documented
real-world holdout or a validation of the complete mixed topic algorithm.
No user files, model endpoints, network access or credentials are consulted.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

CORPUS = Path(__file__).resolve().parent / "fixtures" / "knowledge-semantic-eval.json"
THRESHOLD = 0.82
K = 3


def evaluate(documents, payload, *, threshold=THRESHOLD, corpus_sha256=None):
    if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not math.isfinite(threshold) or not (-1.0 <= threshold <= 1.0):
        raise ValueError("invalid cosine threshold")
    if not isinstance(payload, dict) or not all(isinstance(payload.get(k), str) and payload[k].strip() for k in ("model", "revision")):
        raise ValueError("model and immutable revision are required")
    vectors = payload.get("vectors")
    if not isinstance(vectors, dict) or set(vectors) != {d["id"] for d in documents}:
        raise ValueError("vectors must contain exactly the fixture IDs")
    dim = None
    unit = {}
    for item in documents:
        data = vectors[item["id"]]
        if not isinstance(data, list) or not (2 <= len(data) <= 4096) or any(isinstance(x, bool) or not isinstance(x, (float, int)) or not math.isfinite(x) for x in data):
            raise ValueError("every vector must contain 2–4096 finite numbers")
        dim = len(data) if dim is None else dim
        if len(data) != dim:
            raise ValueError("vector dimensions differ")
        length = math.sqrt(sum(x*x for x in data))
        if not math.isfinite(length) or length < 1e-12:
            raise ValueError("zero or invalid vector")
        unit[item["id"]] = [x/length for x in data]
    correct = returned = possible = covered = correct_cross = returned_cross = 0
    pair_tp = pair_fp = pair_fn = 0
    for i, left in enumerate(documents):
        ranked = []
        for j, right in enumerate(documents):
            if i == j:
                continue
            score = sum(a*b for a,b in zip(unit[left["id"]], unit[right["id"]]))
            relevant = left["label"] == right["label"]
            if j > i:
                pair_tp += bool(relevant and score >= threshold)
                pair_fp += bool(not relevant and score >= threshold)
                pair_fn += bool(relevant and score < threshold)
            ranked.append((score, right["id"], relevant, left["language"] != right["language"]))
            possible += relevant
        hits = sorted((r for r in ranked if r[0] >= threshold), key=lambda r:(-r[0],r[1]))[:K]
        covered += bool(hits)
        returned += len(hits)
        correct += sum(r[2] for r in hits)
        returned_cross += sum(r[3] for r in hits)
        correct_cross += sum(r[2] and r[3] for r in hits)
    ratio = lambda a,b: round(a/b, 6) if b else None
    return {"model":payload["model"], "revision":payload["revision"], "dimensions":dim,
        "corpus_sha256":corpus_sha256 or hashlib.sha256(CORPUS.read_bytes()).hexdigest(), "documents":len(documents),
        "threshold":threshold, "k":K, "queries_with_results":covered, "returned":returned,
        "coverage":ratio(covered,len(documents)), "precision_at_3_zero_filled":ratio(correct,len(documents)*K),
        "precision_returned":ratio(correct,returned), "recall_at_3":ratio(correct,possible),
        "cross_language_returned":returned_cross, "cross_language_precision":ratio(correct_cross,returned_cross),
        "pair_precision":ratio(pair_tp,pair_tp+pair_fp), "pair_recall":ratio(pair_tp,pair_tp+pair_fn),
        "warning":"Synthetic smoke corpus only; this does not measure full topic quality or the required real-world holdout."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--emit-input", action="store_true")
    group.add_argument("--vectors", type=Path)
    args = parser.parse_args()
    documents = json.loads(CORPUS.read_text(encoding="utf-8"))["documents"]
    if args.emit_input:
        print(json.dumps([{"id":d["id"],"text":d["text"]} for d in documents], ensure_ascii=False, indent=2))
    else:
        print(json.dumps(evaluate(documents, json.loads(args.vectors.read_text(encoding="utf-8"))), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
