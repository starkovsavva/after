#!/usr/bin/env python3
"""Evaluate retrieval against explicit, exhaustively judged source pairs.

Input is an offline synthetic or separately consented, de-identified fixture.
This evaluates ranking, not topic clustering or end-to-end agent behavior. Supply
vectors produced by the exact application model/input format and a threshold
chosen on a different calibration set. No data is sent anywhere by this tool.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

SOURCE_TYPES = {"note", "meeting"}


def evaluate(corpus: dict, payload: dict, *, threshold: float, k: int = 3) -> dict:
    if isinstance(threshold, bool) or not isinstance(threshold, (float, int)) or not math.isfinite(threshold) or not -1 <= threshold <= 1:
        raise ValueError("threshold must be a finite cosine similarity")
    if isinstance(k, bool) or not isinstance(k, int) or not 1 <= k <= 100:
        raise ValueError("k must be an integer between 1 and 100")
    if not isinstance(corpus, dict) or not isinstance(corpus.get("documents"), list) or not isinstance(corpus.get("queries"), list):
        raise ValueError("documents and queries must be lists")
    docs = corpus["documents"]
    if len(docs) < 2 or any(not isinstance(d, dict) or not isinstance(d.get("id"), str) or not d["id"] or d.get("type") not in SOURCE_TYPES for d in docs):
        raise ValueError("documents must have an ID and a supported type")
    ids = {d["id"] for d in docs}
    if len(ids) != len(docs):
        raise ValueError("duplicate document ID")
    types = {d["id"]: d["type"] for d in docs}
    if not isinstance(payload, dict) or not all(isinstance(payload.get(key), str) and payload[key].strip() for key in ("model", "revision")):
        raise ValueError("model and immutable revision are required")
    vectors = payload.get("vectors")
    if not isinstance(vectors, dict) or set(vectors) != ids:
        raise ValueError("vectors must contain exactly the document IDs")
    unit = {}
    dimension = None
    for doc_id, vector in vectors.items():
        if not isinstance(vector, list) or not 2 <= len(vector) <= 4096 or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in vector):
            raise ValueError("invalid vector")
        if dimension is None:
            dimension = len(vector)
        if len(vector) != dimension:
            raise ValueError("vector dimensions differ")
        length = math.sqrt(sum(v * v for v in vector))
        if not math.isfinite(length) or length < 1e-12:
            raise ValueError("zero or invalid vector")
        unit[doc_id] = [v / length for v in vector]
    if not corpus["queries"]:
        raise ValueError("at least one query is required")
    seen = set()
    total_returned = total_relevant = positive_queries = positive_found = negative_queries = negative_false_positive = 0
    recalls, pair_counts = [], {}
    for query in corpus["queries"]:
        if not isinstance(query, dict) or not isinstance(query.get("id"), str) or query["id"] not in ids or query["id"] in seen:
            raise ValueError("unknown or duplicate query")
        query_id = query["id"]
        seen.add(query_id)
        rel, irr = query.get("relevant"), query.get("irrelevant")
        if not isinstance(rel, list) or not isinstance(irr, list) or any(not isinstance(x, str) for x in rel + irr):
            raise ValueError("relevant and irrelevant must be ID lists")
        rel_set, irr_set = set(rel), set(irr)
        if len(rel_set) != len(rel) or len(irr_set) != len(irr) or rel_set & irr_set or rel_set | irr_set != ids - {query_id}:
            raise ValueError("every other document must be judged exactly once")
        ranked = []
        for candidate in ids - {query_id}:
            score = sum(a * b for a, b in zip(unit[query_id], unit[candidate]))
            if score >= threshold:
                ranked.append((score, candidate))
        hits = sorted(ranked, key=lambda hit: (-hit[0], hit[1]))[:k]
        found = sum(candidate in rel_set for _, candidate in hits)
        total_returned += len(hits)
        total_relevant += found
        if rel_set:
            positive_queries += 1
            positive_found += found > 0
            recalls.append(found / len(rel_set))
        else:
            negative_queries += 1
            negative_false_positive += bool(hits)
        for _, candidate in hits:
            key = f'{types[query_id]}→{types[candidate]}'
            bucket = pair_counts.setdefault(key, {"returned": 0, "relevant": 0})
            bucket["returned"] += 1
            bucket["relevant"] += candidate in rel_set
    def ratio(a, b):
        return round(a / b, 6) if b else None
    for bucket in pair_counts.values():
        bucket["precision"] = ratio(bucket["relevant"], bucket["returned"])
    return {"model": payload["model"], "revision": payload["revision"], "dimensions": dimension,
            "threshold": threshold, "k": k, "queries": len(seen), "returned": total_returned,
            "relevant_returned": total_relevant, "precision_returned": ratio(total_relevant, total_returned),
            "positive_query_coverage": ratio(positive_found, positive_queries),
            "macro_recall_at_k": ratio(sum(recalls), len(recalls)),
            "negative_queries": negative_queries, "negative_query_false_positive_rate": ratio(negative_false_positive, negative_queries),
            "pair_types": pair_counts,
            "warning": "Retrieval metrics only; corpus representativeness, clustering quality and agent behavior require separate evaluation."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--vectors", required=True, type=Path)
    parser.add_argument("--threshold", required=True, type=float, help="Threshold fixed using an independent calibration set")
    parser.add_argument("--k", type=int, default=3)
    args = parser.parse_args()
    corpus_bytes = args.corpus.read_bytes()
    vector_bytes = args.vectors.read_bytes()
    result = evaluate(json.loads(corpus_bytes), json.loads(vector_bytes), threshold=args.threshold, k=args.k)
    result["corpus_sha256"] = hashlib.sha256(corpus_bytes).hexdigest()
    result["vectors_sha256"] = hashlib.sha256(vector_bytes).hexdigest()
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
