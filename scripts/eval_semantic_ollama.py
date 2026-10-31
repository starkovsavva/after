#!/usr/bin/env python3
"""Evaluate an already-installed local Ollama on a fixed synthetic corpus.

This explicitly initiated smoke check does not install models or read a user
library. It accepts only a literal loopback address and disables proxies and
redirects. Results do not measure real-world topic quality or replace a
separate holdout. See eval_knowledge_semantic.py for the ranking metrics.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import statistics
import time
import urllib.parse
import urllib.request

from eval_knowledge_semantic import CORPUS, evaluate

MAX_RESPONSE = 8 * 1024 * 1024
HOLDOUT = Path(__file__).resolve().parent / "fixtures" / "knowledge-semantic-holdout-v2.json"


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def local_endpoint(value: str) -> str:
    parts = urllib.parse.urlsplit(value)
    try:
        valid_host = ipaddress.ip_address(parts.hostname or "").is_loopback
        port = parts.port
    except ValueError:
        valid_host, port = False, None
    if not (parts.scheme == "http" and valid_host and port and not parts.username and
            not parts.password and not parts.query and not parts.fragment and parts.path in ("", "/")):
        raise ValueError("Endpoint must be an explicit HTTP loopback IP and port")
    return value.rstrip("/")


def request_json(opener, url: str, data: dict | None = None):
    payload = None if data is None else json.dumps(data).encode("utf-8")
    request = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with opener.open(request, timeout=180) as response:
        raw = response.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise ValueError("Response is too large")
    return json.loads(raw)


def note_model_input(text: str) -> str:
    # Source title falls back to the first line for an empty explicit title;
    # our fixtures have no tags or attachments. The app chunker prepends the
    # title to `text + "\\n" + tags + "\\n" + attachments`.
    if "\n" in text or len(text.encode("utf-8")) > 160:
        raise ValueError("Fixture exceeds the exact note-input assumptions")
    return text + "\n" + text + "\n\n"


def run(endpoint: str, model: str, independent_holdout: bool = False) -> dict:
    endpoint = local_endpoint(endpoint)
    if model != "qwen3-embedding:0.6b":
        raise ValueError("This fixed check supports qwen3-embedding:0.6b only")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())
    tags = request_json(opener, endpoint + "/api/tags")
    entries = [entry for entry in tags.get("models", [])
               if entry.get("name") == model or entry.get("model") == model]
    if len(entries) != 1 or not isinstance(entries[0].get("digest"), str) or not entries[0]["digest"]:
        raise ValueError("The exact model and its immutable digest must already be installed")
    revision = entries[0]["digest"]
    calibration = json.loads(CORPUS.read_text(encoding="utf-8"))["documents"]
    holdout = json.loads(HOLDOUT.read_text(encoding="utf-8"))["documents"] if independent_holdout else []
    if {item["id"] for item in calibration} & {item["id"] for item in holdout} or \
       {item["text"] for item in calibration} & {item["text"] for item in holdout}:
        raise ValueError("Calibration and holdout must be independent")
    documents = calibration + holdout
    if not (1 <= len(documents) <= 100):
        raise ValueError("Unexpected fixture size")
    vectors, durations = {}, []
    for start in range(0, len(documents), 8):
        batch = documents[start:start + 8]
        inputs = [note_model_input(item["text"]) for item in batch]
        started = time.monotonic()
        response = request_json(opener, endpoint + "/api/embed", {
            "model": model, "input": inputs, "truncate": False,
            "dimensions": 1024, "keep_alive": "60s",
        })
        durations.append(time.monotonic() - started)
        values = response.get("embeddings")
        if not isinstance(values, list) or len(values) != len(batch):
            raise ValueError("Model returned an unexpected number of vectors")
        for item, vector in zip(batch, values):
            vectors[item["id"]] = vector
    latest = request_json(opener, endpoint + "/api/tags")
    if not any((entry.get("name") == model or entry.get("model") == model) and
               entry.get("digest") == revision for entry in latest.get("models", [])):
        raise ValueError("Model changed during evaluation")
    def score(items, threshold, path):
        payload = {"model": model, "revision": revision,
                   "vectors": {item["id"]: vectors[item["id"]] for item in items}}
        return evaluate(items, payload, threshold=threshold,
                        corpus_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    result = score(calibration, 0.82, CORPUS)
    if independent_holdout:
        # The threshold is chosen solely from the calibration split. Holdout
        # labels are not examined until the single threshold is frozen.
        candidates = [score(calibration, i / 100, CORPUS) for i in range(20, 83)]
        qualified = [candidate for candidate in candidates if candidate["returned"] >= 10 and
                     candidate["precision_returned"] is not None and candidate["precision_returned"] >= 0.85]
        chosen = max(qualified, key=lambda item: (item["coverage"], item["recall_at_3"], item["threshold"])) if qualified else None
        result = {"fixed_threshold_calibration": result, "calibration": chosen,
                  "holdout": score(holdout, chosen["threshold"], HOLDOUT) if chosen else None,
                  "warning": "Independent synthetic smoke only; do not tune on holdout or treat it as a production-quality benchmark."}
    ordered = sorted(durations)
    result["timing"] = {"batch_count": len(durations), "wall_seconds": round(sum(durations), 3),
                        "median_batch_seconds": round(statistics.median(durations), 3),
                        "slowest_batch_seconds": round(ordered[-1], 3)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", default="qwen3-embedding:0.6b")
    parser.add_argument("--independent-holdout", action="store_true")
    args = parser.parse_args()
    print(json.dumps(run(args.endpoint, args.model, args.independent_holdout), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
