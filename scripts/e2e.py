#!/usr/bin/env python3
"""Exercise the built Rust CLI + C ABI, real files and localhost HTTP contracts.

No models, Keychain, microphone, existing library, paid APIs or external servers
are used. WAV input is generated; ASR output is a synthetic injected transcript;
LLM output is deliberately deterministic/malformed from a loopback fixture.
Actual ASR/model quality and native SwiftUI interactions need separate checks.

Run after scripts/build.sh:
    python3 scripts/e2e.py
Use --engine /absolute/posle-engine --library /absolute/libposle_core.dylib
for an explicitly selected build. --keep retains only this synthetic fixture.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
from contextlib import contextmanager
import copy
import csv
import ctypes
from datetime import datetime
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import uuid
import wave

PROJECT = Path(__file__).resolve().parent.parent
MODEL = "e2e-fixture:local"
TEST_KEY = "e2e-only-key-not-a-secret"
FACTS = {
    101: ("detail", "Бюджет пилота — 42 000 рублей без НДС.", "", ""),
    205: ("action", "Анна подготовит демо к пятнице.", "Анна", "к пятнице"),
    309: ("decision", "Для пилота выбрали PostgreSQL.", "", ""),
    413: ("detail", "Экспорт CSV должен содержать даты в UTC.", "", ""),
    517: ("question", "Какой срок хранения архива нужен?", "", ""),
}
QUOTE = "We will follow up after the demo."


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def semantic_cards(cards):
    return [{key: card[key] for key in ("front", "back", "context", "kind")} for card in cards]


class Core:
    def __init__(self, engine, library, root):
        self.engine, self.root = engine, root
        self.calls = 0
        self.ffi_calls = 0
        # Keep ambient real provider/proxy credentials out of every child.
        fragments = ("API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE", "PROXY")
        self.environment = {key: value for key, value in os.environ.items()
                            if not any(part in key.upper() for part in fragments)}
        self.library = ctypes.CDLL(str(library))
        self.library.posle_request.argtypes = [ctypes.c_char_p]
        self.library.posle_request.restype = ctypes.c_void_p
        self.library.posle_free_string.argtypes = [ctypes.c_void_p]
        self.library.posle_free_string.restype = None

    def request(self, command, expected_ok=True, **arguments):
        self.ffi_calls += 1
        payload = {"root": str(self.root), "command": command, **arguments}
        pointer = self.library.posle_request(json.dumps(payload, ensure_ascii=False).encode())
        require(pointer, "FFI returned no envelope")
        try:
            envelope = json.loads(ctypes.string_at(pointer))
        finally:
            self.library.posle_free_string(pointer)
        require(envelope.get("ok") is expected_ok, f"FFI {command}: {envelope}")
        return envelope.get("value") if expected_ok else envelope

    def write(self, path, value):
        return self.request("write", path=path, value=value)

    def cli(self, command, *arguments, stdin=None, expected_ok=True, environment=None):
        self.calls += 1
        result = subprocess.run([str(self.engine), command, "--root", str(self.root), *map(str, arguments)],
                                input=None if stdin is None else json.dumps(stdin, ensure_ascii=False),
                                text=True, capture_output=True, timeout=90,
                                env={**self.environment, **(environment or {})}, cwd=PROJECT)
        require((result.returncode == 0) is expected_ok,
                f"CLI {command} returned {result.returncode}: {result.stdout[-3000:]} {result.stderr[-1000:]}")
        events = []
        for line in result.stdout.splitlines():
            if line.strip():
                events.append(json.loads(line))
        require(events, f"CLI {command} returned no JSON events")
        require(events[-1].get("event") == ("done" if expected_ok else "error"),
                f"CLI {command} returned no final event: {events[-1]}")
        return events[-1], events, result.stdout + result.stderr


class ModelFixture:
    def __init__(self):
        self.requests = []
        self.errors = []
        self.lock = threading.Lock()
        self.fail_source = None
        self.source_count = 0
        self.mode = "ok"

    def phase(self, mode="ok", fail_source=None):
        with self.lock:
            self.mode, self.fail_source, self.source_count = mode, fail_source, 0
            return len(self.requests)

    def since(self, start):
        with self.lock:
            return copy.deepcopy(self.requests[start:])

    def dispatch(self, method, route, headers, body):
        with self.lock:
            self.requests.append({"method": method, "route": route, "headers": dict(headers), "body": body})
            require(headers.get("host", "").startswith("127.0.0.1:"), "Request left the selected localhost host")
            if route == "/api/tags":
                require(method == "GET", "Ollama discovery must be GET")
                return 200, {"models": [{"name": MODEL}]}, {}
            if route == "/api/show":
                require(body == {"model": MODEL}, "Wrong selected model in capability probe")
                return 200, {"details": {"family": "fixture"}}, {}
            if route == "/api/chat":
                require(headers.get("authorization") is None, "Local LLM received cloud credentials")
                require(body["model"] == MODEL and body["stream"] is False, "Wrong local model/stream contract")
                require(body["think"] is False and body["keep_alive"] == 0, "Local model lifecycle parameters missing")
                require(body["options"]["num_ctx"] >= 16000, "Local context budget regressed")
                require([message["role"] for message in body["messages"]] == ["system", "user"], "Lost system/source role separation")
                schema = body["format"]
                require(schema["type"] == "object" and schema["additionalProperties"] is False, "Missing strict schema")
                prompt = json.loads(body["messages"][1]["content"])
                if "source_segments" in prompt:
                    self.source_count += 1
                    if self.source_count == self.fail_source:
                        return 503, {"error": "synthetic middle-chunk outage"}, {}
                    segments = prompt["source_segments"]
                    ids = [segment["id"] for segment in segments]
                    enum = schema["properties"]["facts"]["items"]["properties"]["segmentIDs"]["items"]["enum"]
                    require(enum == ids, "Evidence schema does not enumerate this request's original IDs")
                    facts = [{"kind": FACTS[s["id"]][0], "text": FACTS[s["id"]][1],
                              "owner": FACTS[s["id"]][2], "due": FACTS[s["id"]][3], "segmentIDs": [s["id"]]} for s in segments]
                    cards = []
                    if 205 in ids:
                        require(QUOTE in next(s["text"] for s in segments if s["id"] == 205), "Fixture quote absent from actual source request")
                        cards.append({"kind": "phrase", "front": "follow up", "back": "Уточнить результат; вернуться к вопросу", "context": QUOTE, "segmentIDs": [205]})
                    # Deliberately violate provider grounding; real Rust must filter both.
                    facts.append({"kind": "detail", "text": "UNSUPPORTED FACT", "owner": "", "due": "", "segmentIDs": [999999]})
                    cards.append({"kind": "phrase", "front": "invented phrase", "back": "UNSUPPORTED CARD", "context": "not a source quotation", "segmentIDs": [ids[0]]})
                    answer = {"facts": facts, "overview": "Unlinked draft text must not become the final overview.", "studyCards": cards}
                elif "factual_notes" in prompt:
                    require("claims" in schema["properties"], "Unexpected overview protocol")
                    index = prompt["factual_notes"][0]["itemIndex"]
                    answer = {"claims": [{"text": prompt["factual_notes"][0]["text"], "itemIndices": [index]}]}
                elif "card" in prompt:
                    require(prompt["card"]["front"] == "follow up", "Example requested for wrong card")
                    answer = {"example": "I will follow up with the team tomorrow.", "translation": "Завтра я уточню результат у команды.", "explanation": "Пример для тренировки, не цитата встречи."}
                else:
                    raise AssertionError("Unexpected local generation request")
                return 200, {"message": {"content": json.dumps(answer, ensure_ascii=False)}, "done": True, "done_reason": "stop"}, {}
            if route in ("/gateway/v1/responses", "/gateway/v1/chat/completions"):
                require(method == "POST" and headers.get("authorization") == "Bearer " + TEST_KEY, "Wrong custom-cloud authentication")
                require(body["model"] == "fixture/cloud-model", "Wrong custom-cloud model")
                require(TEST_KEY not in json.dumps(body), "Credential entered JSON payload")
                if self.mode == "redirect":
                    return 302, {}, {"Location": "http://" + headers["host"] + "/capture-redirect"}
                if self.mode == "auth-failure":
                    return 401, {"error": {"message": TEST_KEY, "code": "fixture_auth"}}, {}
                require("source_segments" not in json.dumps(body), "Connection check uploaded meeting data")
                if route.endswith("responses"):
                    require(body["store"] is False and body["max_output_tokens"] == 256, "Responses storage/token contract regressed")
                    return 200, {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": '{"ok":true}'}]}]}, {}
                require(body["max_tokens"] == 256 and body["stream"] is False, "Chat token/stream contract regressed")
                return 200, {"choices": [{"finish_reason": "stop", "message": {"content": '{"ok":true}'}}]}, {}
            raise AssertionError("Unexpected endpoint: " + route)


@contextmanager
def localhost_fixture():
    fixture = ModelFixture()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def handle_request(self):
            try:
                size = int(self.headers.get("Content-Length", 0))
                require(0 <= size <= 1_000_000, "Fixture request too large")
                raw = self.rfile.read(size)
                body = json.loads(raw) if raw else None
                status, value, headers = fixture.dispatch(self.command, self.path,
                    {key.lower(): value for key, value in self.headers.items()}, body)
            except BaseException as error:
                fixture.errors.append(str(error))
                status, value, headers = 500, {"error": "fixture request contract failed"}, {}
            payload = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            for key, value in headers.items(): self.send_header(key, value)
            self.end_headers(); self.wfile.write(payload)
        do_GET = handle_request
        do_POST = handle_request
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield fixture, "http://127.0.0.1:" + str(server.server_port)
        require(not fixture.errors, "Localhost contract failures: " + repr(fixture.errors))
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=3)


def generated_wav(path):
    rate = 16000
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        audio.writeframes(b"".join(struct.pack("<h", int(2000 * math.sin(2 * math.pi * 220 * sample / rate))) for sample in range(rate * 20)))


def source_requests(requests):
    return [r for r in requests if r["route"] == "/api/chat" and "source_segments" in json.loads(r["body"]["messages"][1]["content"])]


def source_ids(requests):
    return [s["id"] for request in source_requests(requests) for s in json.loads(request["body"]["messages"][1]["content"])["source_segments"]]


def assert_summary(summary, segments):
    ids = {segment["id"] for segment in segments}
    require({ref for item in summary["items"] for ref in item["segmentIDs"]} == ids, "Summary lost original source evidence")
    require(len(summary["items"]) == len(FACTS), "Summary lost facts or retained ungrounded facts")
    require(all(item["text"] != "UNSUPPORTED FACT" for item in summary["items"]), "Invalid evidence was published")
    require(len(summary["cards"]) == 1 and summary["cards"][0]["context"] == QUOTE, "Grounded card quote was lost or fabricated card survived")
    require(summary["cards"][0]["segmentIDs"] == [205], "Card source IDs changed")
    for claim in summary["overviewClaims"]:
        require(claim["itemIndices"] and all(0 <= index < len(summary["items"]) for index in claim["itemIndices"]), "Overview points to missing facts")
    require("Unlinked draft" not in summary["overview"], "Chunk overview bypassed factual citations")
    require(any("неподтверждённых" in warning for warning in summary["warnings"]), "Invalid provider citations were not explained")


def run(engine, library, temporary):
    root = temporary / "Библиотека с пробелами"
    root.mkdir(mode=0o700)
    core = Core(engine, library, root)
    source = temporary / "Встреча с пробелами.wav"
    generated_wav(source)
    original_hash = digest(source)
    meeting, _, _ = core.cli("import", stdin={"source": str(source), "focus": "Договор и сроки"})
    meeting_id = meeting["id"]
    directory = root / "meetings" / meeting_id
    require(digest(directory / meeting["source"]) == original_hash == digest(source), "Import changed or lost WAV data")
    require(directory.stat().st_mode & 0o777 == 0o700 and (directory / meeting["source"]).stat().st_mode & 0o777 == 0o600, "Import created public data")
    require(core.cli("list")[0]["meetings"][0]["id"] == meeting_id, "CLI library listing lost imported meeting")
    print("PASS: real CLI imports generated WAV through Unicode paths, preserves bytes and private permissions")

    segments = []
    for index, (segment_id, fact) in enumerate(FACTS.items()):
        text = fact[1] + (" " + QUOTE if segment_id == 205 else "")
        # More than one source chunk exercises actual restart/checkpoint behavior.
        text += " Дополнительный синтетический контекст для проверки полной обработки записи." * 60
        segments.append({"id": segment_id, "start": index * 4, "end": (index + 1) * 4,
                         "speaker": "speaker_1" if index % 2 == 0 else "speaker_2", "text": text, "overlap": False})
    transcript = {"duration": 20, "segments": segments, "warnings": [], "model": "synthetic transcript fixture"}
    core.write(f"meetings/{meeting_id}/transcript.json", transcript)
    core.cli("update", stdin={"id": meeting_id, "patch": {"status": "transcribed", "duration": 20, "speakerNames": {"speaker_1": "Анна", "speaker_2": "Борис"}}})
    transcript_hash = digest(directory / "transcript.json")
    with localhost_fixture() as (server, endpoint):
        settings = {"mode": "local", "localProvider": "ollama", "localEndpoint": endpoint, "localModel": MODEL, "language": "ru", "focus": ""}
        core.write("settings.json", settings)
        start = server.phase()
        core.cli("summarize", "--meeting", directory)
        initial_requests = server.since(start)
        chunks = source_requests(initial_requests)
        require(len(chunks) >= 2, "Fixture did not exercise multiple summary chunks")
        require(source_ids(initial_requests) == list(FACTS), "CLI did not process each original segment exactly once")
        require(len([r for r in initial_requests if r["route"] == "/api/chat"]) == len(chunks) + 1, "Unexpected source/overview generation count")
        summary = core.request("read", path=f"meetings/{meeting_id}/summary.json")
        assert_summary(summary, segments)
        card = summary["cards"][0]
        require(digest(directory / "transcript.json") == transcript_hash, "Summary mutated original transcript")
        print(f"PASS: CLI summary uses {len(chunks)} source chunks + 1 linked overview; Rust removes invalid evidence")

        tasks = core.cli("notes-tasks")[0]["tasks"]
        task = next(task for task in tasks if task["text"] == FACTS[205][1])
        require(task["owner"] == "Анна" and task["due"] == "к пятнице" and task["segmentIDs"] == [205], "Task metadata/evidence lost")
        core.request("notes-task-complete", meetingID=meeting_id, itemIndex=task["itemIndex"], text=task["text"], completed=True)
        require(next(t for t in core.cli("notes-tasks")[0]["tasks"] if t["id"] == task["id"])["completed"], "Task completion did not persist across processes")
        search = core.cli("search", "--query", "PostgreSQL")[0]
        require(any(h["kind"] == "transcript" and h["segmentIDs"] == [309] for h in search["hits"]), "Search lost transcript navigation evidence")
        require(any(h["kind"] == "item" and h["segmentIDs"] == [309] for h in search["hits"]), "Search lost summary evidence")
        hit = next(h for h in search["hits"] if h["meetingID"] == meeting_id)
        require(core.request("search-validate", meetingID=meeting_id, sourceFingerprint=hit["sourceFingerprint"])["valid"], "Fresh search hit cannot be opened")
        print("PASS: real task completion and SQLite search retain actionable original source links")

        before_summary = digest(directory / "summary.json")
        core.cli("example", "--meeting", directory, "--card", card["id"])
        example = core.request("read", path=f"meetings/{meeting_id}/examples.json")[card["id"]]
        require("follow up" in example["example"] and digest(directory / "summary.json") == before_summary, "Practice example replaced the source card or quote")
        first = core.cli("review", "--meeting", directory, "--card", card["id"], "--rating", "3")[0]
        require(first["count"] == 1 and first["card"]["stability"] > 0, "FSRS first review missing real memory state")
        review_hash = digest(directory / "review-state.json")
        core.cli("review", "--meeting", directory, "--card", card["id"], "--rating", "0", expected_ok=False)
        require(digest(directory / "review-state.json") == review_hash, "Rejected rating changed review history")
        second = core.cli("review", "--meeting", directory, "--card", card["id"], "--rating", "1")[0]
        require(second["count"] == 2 and second["lastRating"] == 1 and second["card"]["card_id"] == first["card"]["card_id"], "FSRS identity/history reset")
        require(datetime.fromisoformat(second["due"].replace("Z", "+00:00")) > datetime.fromisoformat(second["card"]["last_review"].replace("Z", "+00:00")), "Review scheduled no future repetition")
        logs = [json.loads(line) for line in (directory / "review-log.jsonl").read_text().splitlines()]
        require(len(logs) == 2 and len({entry["reviewID"] for entry in logs}) == 2, "Review log duplicated/lost an accepted rating")
        print("PASS: generated practice stays separate; real FSRS persists two ratings and rejects invalid input without mutation")

        # Change the focus so a fresh run cannot reuse a previous success cache.
        settings["focus"] = "Повтор после искусственного сбоя"
        core.write("settings.json", settings)
        stable = {path: digest(directory / path) for path in (meeting["source"], "transcript.json", "summary.json", "review-state.json", "review-log.jsonl")}
        start = server.phase(fail_source=2)
        core.cli("summarize", "--meeting", directory, expected_ok=False)
        failed_requests = server.since(start)
        require(len(source_requests(failed_requests)) == 2, "Failure did not interrupt a real middle source request")
        require(all(digest(directory / path) == value for path, value in stable.items()), "Failed generation damaged saved meeting/review data")
        require((directory / "summary-progress.json").exists(), "Successful first chunk was not checkpointed")
        start = server.phase()
        core.cli("summarize", "--meeting", directory)
        retry_requests = server.since(start)
        committed_ids = source_ids([source_requests(failed_requests)[0]])
        require(committed_ids + source_ids(retry_requests) == list(FACTS), "Retry skipped/doubled source coverage or regenerated a committed chunk")
        require(not (directory / "summary-progress.json").exists(), "Successful retry left an unfinished checkpoint")
        assert_summary(core.request("read", path=f"meetings/{meeting_id}/summary.json"), segments)
        require(digest(directory / "review-state.json") == stable["review-state.json"] and digest(directory / "transcript.json") == transcript_hash, "Retry reset learning history or transcript")
        print("PASS: middle-chunk HTTP failure preserves old results; real CLI retry resumes committed source coverage")

        # All six OpenAI-compatible contracts are exercised on this same loopback fixture.
        for api in ("responses", "chat"):
            for output in ("schema", "json", "prompt"):
                config = {"mode": "cloud", "cloudProvider": "custom", "cloudEndpoint": endpoint + "/gateway/v1/", "cloudModel": "fixture/cloud-model", "cloudAPI": api, "cloudOutput": output}
                core.write("settings.json", config)
                start = server.phase()
                core.cli("check-cloud", environment={"POSLE_API_KEY": TEST_KEY})
                requests = server.since(start)
                require(len(requests) == 1, "Connection check made unexpected extra requests")
                body = requests[0]["body"]
                fmt = body.get("text", {}).get("format") if api == "responses" else body.get("response_format")
                require((fmt or {}).get("type") == {"schema": "json_schema", "json": "json_object"}.get(output), "Selected JSON mode was not sent")
                if output != "schema":
                    require("JSON Schema" in (body.get("instructions") or body["messages"][0]["content"]), "Fallback output mode omitted schema instructions")
        for mode in ("auth-failure", "redirect"):
            start = server.phase(mode=mode)
            _, _, console = core.cli("check-cloud", environment={"POSLE_API_KEY": TEST_KEY}, expected_ok=False)
            require(TEST_KEY not in console, "Provider failure exposed API credential")
            require(len(server.since(start)) == 1, "Redirect replayed credentials to another endpoint")
        core.write("settings.json", settings)
        print("PASS: six cloud protocol/JSON combinations preserve gateway paths; auth errors redact keys and redirects are refused")

    # Notes use the same C ABI as Swift. Concurrent stale revisions must not win.
    now = time.time()
    note = {"id": str(uuid.uuid4()), "text": "Schedule contract review", "kind": "task", "meetingID": meeting_id, "timestamp": 0,
            "createdAt": now, "updatedAt": now, "revision": 0, "sourceURL": "", "owner": "Анна", "due": "пятница", "completed": False,
            "title": "Договор", "contentRTF": base64.b64encode(b'{\\rtf1\\ansi Schedule contract review}').decode(),
            "folder": "Проект", "tags": ["пилот"], "pinned": True, "attachments": []}
    saved = core.request("note-save", note=note)
    newer = copy.deepcopy(saved); newer["title"] = "Актуальный договор"
    newer = core.request("note-save", note=newer)
    stale = copy.deepcopy(saved); stale["text"] = "Stale overwrite must fail"
    core.request("note-save", expected_ok=False, note=stale)
    current = next(n for n in core.cli("notes-list")[0]["notes"] if n["id"] == note["id"])
    require(current["title"] == newer["title"] and current["contentRTF"] == saved["contentRTF"], "Stale note edit damaged rich content")
    trashed = core.request("note-trash", id=note["id"], revision=current["revision"])
    require(not any(t.get("noteID") == note["id"] for t in core.cli("notes-tasks")[0]["tasks"]), "Trashed task remained active")
    restored = core.request("note-restore", id=note["id"], revision=trashed["revision"])
    require(restored["contentRTF"] == saved["contentRTF"] and restored["folder"] == "Проект", "Trash/restore lost note content")
    print("PASS: real C ABI notes persist formatting/organization, reject stale revisions and restore task content")

    csv_path = temporary / "Карточки с пробелами.csv"
    with csv_path.open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["Front", "Back", "Context", "Tags"])
        writer.writerow([card["front"], card["back"], card["context"], "phrase"])
        writer.writerow(['Why, "UTC"?', "Одинаковая зона\nдля обмена датами", "Синтетический контекст", "concept"])
    preview = core.cli("cards-import-preview", "--path", csv_path)[0]
    require(preview["total"] == 2, "Quoted multiline CSV preview lost a card")
    old_fingerprint = preview["sourceFingerprint"]
    csv_path.write_text(csv_path.read_text() + "\n")
    before_count = len(core.cli("list")[0]["meetings"])
    core.request("cards-import", expected_ok=False, path=str(csv_path), expectedFingerprint=old_fingerprint)
    require(len(core.cli("list")[0]["meetings"]) == before_count, "Rejected stale card preview published a deck")
    fresh = core.cli("cards-import-preview", "--path", csv_path)[0]
    imported = core.request("cards-import", path=str(csv_path), title="Колода из CSV", expectedFingerprint=fresh["sourceFingerprint"])
    deck = imported["meeting"]
    require(deck["libraryKind"] == "cards" and imported["count"] == 2, "Card import did not produce a standalone deck")
    deck_dir = root / "meetings" / deck["id"]
    roundtrip = core.cli("cards-import-preview", "--path", deck_dir / "cards.tsv")[0]
    require(semantic_cards(roundtrip["cards"]) == semantic_cards(fresh["cards"]), "Rust CSV -> TSV export -> preview changed text/kind/context")
    require(all(card["segmentIDs"] == [] for card in roundtrip["cards"]), "Imported card invented meeting references")
    core.cli("review", "--meeting", deck_dir, "--card", roundtrip["cards"][0]["id"], "--rating", "4")
    core.cli("update", stdin={"id": deck["id"], "patch": {"title": "Колода после обновления"}})
    require(core.request("read", path=f'meetings/{deck["id"]}/meta.json')["libraryKind"] == "cards", "Metadata edit lost standalone deck identity")
    require(digest(source) == original_hash and digest(directory / meeting["source"]) == original_hash, "End-to-end flow changed the original recording")
    print("PASS: CSV preview CAS, real Rust-generated TSV roundtrip, standalone deck identity and imported-card FSRS")
    return {"cliCommands": core.calls, "ffiRequests": core.ffi_calls, "httpRequests": len(server.requests),
            "httpRoutes": dict(Counter(r["route"] for r in server.requests)),
            "mocked": ["ASR transcript (injected synthetic fixture)", "LLM responses (localhost HTTP)"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=PROJECT / "dist/После.app/Contents/MacOS/posle-engine")
    parser.add_argument("--library", type=Path, default=PROJECT / "dist/После.app/Contents/Frameworks/libposle_core.dylib")
    parser.add_argument("--keep", action="store_true", help="Retain this newly generated synthetic fixture")
    args = parser.parse_args()
    engine, library = args.engine.resolve(), args.library.resolve()
    require(engine.is_file() and os.access(engine, os.X_OK), "Build posle-engine first or pass --engine")
    require(library.is_file(), "Build the C ABI library first or pass --library")
    temporary = Path(tempfile.mkdtemp(prefix="posle-e2e-", dir="/private/tmp"))
    try:
        result = run(engine, library, temporary)
        print(json.dumps({"result": "PASS", **result}, ensure_ascii=False))
    finally:
        if args.keep:
            print("Synthetic fixture retained:", temporary)
        else:
            shutil.rmtree(temporary)


if __name__ == "__main__":
    main()
