#!/usr/bin/env python3
"""Exercise the native Rust search C ABI using synthetic meeting data only.

No ASR/LLM runtime, network, real meeting, or Keychain access is used. The index
and generated corpus live in a private TemporaryDirectory and are removed.
Timings describe this process on this machine, not a MacBook Air benchmark.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import tempfile
import time


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    path.chmod(0o600)


def source_hashes(root):
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.glob("meetings/*/*.json")
        if not path.is_symlink() and not path.parent.is_symlink()
    }


class NativeCore:
    def __init__(self, library):
        self.library = ctypes.CDLL(str(library.resolve()))
        self.library.posle_request.argtypes = [ctypes.c_char_p]
        self.library.posle_request.restype = ctypes.c_void_p
        self.library.posle_free_string.argtypes = [ctypes.c_void_p]
        self.library.posle_free_string.restype = None

    def request(self, root, command, **fields):
        payload = json.dumps({"root": str(root), "command": command, **fields}, ensure_ascii=False).encode("utf-8")
        pointer = self.library.posle_request(payload)
        assert pointer, "C ABI returned a null response pointer"
        try:
            response = json.loads(ctypes.string_at(pointer).decode("utf-8"))
        finally:
            self.library.posle_free_string(pointer)
        assert response.get("ok") is True, response.get("error", response)
        return response["value"]

    def search(self, root, query, scope="all", limit=60):
        result = self.request(root, "search", query=query, scope=scope, limit=limit)
        assert isinstance(result["hits"], list)
        assert isinstance(result["total"], int)
        assert isinstance(result["truncated"], bool)
        assert isinstance(result["warnings"], list)
        assert result["total"] >= len(result["hits"])
        for hit in result["hits"]:
            for field in ("id", "meetingID", "meetingTitle", "kind", "text", "snippet", "sourceFingerprint"):
                assert isinstance(hit[field], str), (field, hit)
            assert isinstance(hit["createdAt"], (int, float))
            assert isinstance(hit["segmentIDs"], list)
            assert len(hit["sourceFingerprint"]) == 64
            assert len(hit["snippet"]) <= 240
        return result


def generate(root, count, segment_count):
    for number in range(count):
        identifier = f"meeting-{number:04d}"
        directory = root / "meetings" / identifier
        segments = [
            {"id": 7, "start": 0.0, "end": 4.0, "speaker": "speaker_1", "overlap": False,
             "text": "Отчёты согласовали, бюджеты проверены. We are running migrations in version 2026."},
            {"id": 9, "start": 4.0, "end": 8.0, "speaker": "speaker_2", "overlap": False,
             "text": "Участники согласовали контрольную точку по безопасности."},
        ]
        for segment_number in range(2, segment_count):
            segments.append({"id": segment_number + 20, "start": float(segment_number * 4),
                             "end": float(segment_number * 4 + 4), "speaker": "speaker_1", "overlap": False,
                             "text": f"Обсуждение проекта команды {number}, фрагмент {segment_number}. Проверяем реализацию задачи."})
        write_json(directory / "meta.json", {"id": identifier, "title": f"План бюджета — команда {number}",
                   "createdAt": 1792933200.0 + number, "source": "source.mp3", "status": "ready", "duration": segment_count * 4.0,
                   "speakerNames": {}, "completedTasks": [], "focus": "", "recordingTracks": False, "hasVideo": False})
        write_json(directory / "transcript.json", {"duration": segment_count * 4.0, "segments": segments,
                   "warnings": [], "model": "synthetic-test-fixture"})
        write_json(directory / "summary.json", {"overview": f"Бюджеты утверждены командой {number}.",
                   "items": [{"kind": "detail", "text": "Отчёты проверены на 2026 год.", "owner": "Мария", "due": "в пятницу", "segmentIDs": [7]},
                             {"kind": "decision", "text": f"Проверить специальныйфакт{number}.", "owner": "", "due": "", "segmentIDs": [9]}],
                   "cards": [{"id": f"card-{number}", "kind": "phrase", "front": "running migrations", "back": "запуск миграций",
                              "context": "We are running migrations in version 2026.", "segmentIDs": [7]}],
                   "provider": "test-fixture", "model": "no-model-was-called", "generatedAt": 1792933300.0, "warnings": []})


def validate_navigation(root, hit):
    directory = root / "meetings" / hit["meetingID"]
    meta = json.loads((directory / "meta.json").read_text())
    transcript = json.loads((directory / "transcript.json").read_text())
    summary = json.loads((directory / "summary.json").read_text())
    ids = {segment["id"] for segment in transcript["segments"]}
    assert all(identifier in ids for identifier in hit["segmentIDs"])
    assert hit["meetingTitle"] == meta["title"]
    if hit["kind"] == "title":
        assert hit["text"] == meta["title"] and not hit["segmentIDs"]
    elif hit["kind"] == "overview":
        assert hit["text"] == summary["overview"]
    elif hit["kind"] == "item":
        item = summary["items"][hit["itemIndex"]]
        assert hit["text"] == item["text"] and hit["segmentIDs"] == item["segmentIDs"]
    elif hit["kind"] == "transcript":
        segment = next(segment for segment in transcript["segments"] if segment["id"] == hit["segmentIDs"][0])
        assert hit["text"] == segment["text"] and hit["start"] == segment["start"]
    elif hit["kind"] == "card":
        card = next(card for card in summary["cards"] if card["id"] == hit["cardID"])
        assert hit["text"] == "\n".join(card[field] for field in ("front", "back", "context"))
        assert hit["segmentIDs"] == card["segmentIDs"]
    else:
        raise AssertionError(f"Unknown hit kind: {hit['kind']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    project = Path(__file__).resolve().parents[1]
    parser.add_argument("--library", type=Path, default=project / "dist" / "After.app" / "Contents" / "Frameworks" / "libposle_core.dylib")
    parser.add_argument("--meetings", type=int, default=150)
    parser.add_argument("--segments", type=int, default=80)
    arguments = parser.parse_args()
    assert 4 <= arguments.meetings <= 500 and 10 <= arguments.segments <= 200
    core = NativeCore(arguments.library)
    checks = []
    with tempfile.TemporaryDirectory(prefix="posle-search-ffi-") as temporary:
        root = Path(temporary) / "library"
        root.mkdir(mode=0o700)
        write_json(root / "settings.json", {"features": {"cards": True, "tasks": True}})
        generate(root, arguments.meetings, arguments.segments)
        original = source_hashes(root)
        start = time.perf_counter()
        first = core.search(root, "отчет", scope="notes", limit=100)
        initial_ms = round((time.perf_counter() - start) * 1000, 2)
        assert first["total"] == arguments.meetings
        assert len(first["hits"]) == min(100, arguments.meetings)
        assert first["truncated"] == (arguments.meetings > 100)
        checks.append("C ABI JSON envelope, bounded results, exact total")

        warmed = []
        for query in ("отчет", "ОТЧЁТАМИ", "бюджет", "running", "migrating", "2026"):
            start = time.perf_counter()
            result = core.search(root, query, scope="all", limit=5)
            warmed.append(round((time.perf_counter() - start) * 1000, 2))
            assert result["total"] >= arguments.meetings, query
            for hit in result["hits"]:
                validate_navigation(root, hit)
        checks.append("Russian inflections and ё/е, English stems, numeric search")

        scopes = (("meetings", "бюджет", {"title"}), ("notes", "мария пятниц", {"item"}),
                  ("transcript", "running", {"transcript"}), ("cards", "migrating", {"card"}))
        for scope, query, kinds in scopes:
            result = core.search(root, query, scope=scope, limit=3)
            assert result["total"] == arguments.meetings
            assert {hit["kind"] for hit in result["hits"]} == kinds
            for hit in result["hits"]:
                validate_navigation(root, hit)
        # No FTS operator or SQL injection is accepted as query syntax.
        assert core.search(root, 'budget" OR "missingtoken') ["total"] == 0
        assert core.search(root, "'; DROP TABLE documents; --")["total"] == 0
        assert core.search(root, "  * !! ")["total"] == 0
        assert source_hashes(root) == original
        checks.append("Scopes, exact source text, valid citation references, read-only source hashes")

        folder = root / "cache" / "search"
        assert stat.S_IMODE(folder.stat().st_mode) == 0o700
        assert stat.S_IMODE((folder / "index.sqlite").stat().st_mode) == 0o600
        for sidecar in folder.glob("index.sqlite-*"):
            assert stat.S_IMODE(sidecar.stat().st_mode) == 0o600
        checks.append("Private index directory, database and sidecar permissions")

        latest = f"meeting-{arguments.meetings - 1:04d}"
        directory = root / "meetings" / latest
        item_hit = core.search(root, "мария пятниц", scope="notes", limit=1)["hits"][0]
        assert item_hit["meetingID"] == latest
        assert core.request(root, "search-validate", meetingID=latest, sourceFingerprint=item_hit["sourceFingerprint"])["valid"] is True
        overview = json.loads((directory / "summary.json").read_text())
        overview["overview"] = "Новейший прогнозбезопасности согласован."
        write_json(directory / "summary.json", overview)
        assert core.request(root, "search-validate", meetingID=latest, sourceFingerprint=item_hit["sourceFingerprint"])["valid"] is False
        fresh = core.search(root, "прогнозбезопасности", scope="notes", limit=2)
        assert fresh["total"] == 1 and fresh["hits"][0]["kind"] == "overview"
        assert core.request(root, "search-validate", meetingID=latest, sourceFingerprint=fresh["hits"][0]["sourceFingerprint"])["valid"] is True
        checks.append("Edited overview is indexed and stale fingerprint is rejected")

        write_json(directory / "transcript.json", {"duration": 8.0, "segments": [{"id": 501, "start": 3.0, "end": 8.0,
                   "speaker": "speaker_1", "text": "Новейшаяэпоха после перетранскрибации.", "overlap": False}], "warnings": [], "model": "synthetic"})
        changed = core.search(root, "новейшаяэпоха", scope="transcript", limit=2)
        assert changed["total"] == 1 and changed["hits"][0]["segmentIDs"] == [501]
        assert core.search(root, f"специальныйфакт{arguments.meetings - 1}", scope="notes")["total"] == 0
        assert core.request(root, "search-validate", meetingID=latest, sourceFingerprint=fresh["hits"][0]["sourceFingerprint"])["valid"] is False
        checks.append("Retranscription removes old text and orphaned note/card references")

        trash = root / "trash"
        trash.mkdir(mode=0o700)
        directory.rename(trash / latest)
        assert core.search(root, "новейшаяэпоха")["total"] == 0
        assert core.search(root, "прогнозбезопасности")["total"] == 0
        assert core.request(root, "search-validate", meetingID=latest, sourceFingerprint=changed["hits"][0]["sourceFingerprint"])["valid"] is False
        damaged = root / "meetings" / f"meeting-{arguments.meetings - 2:04d}"
        (damaged / "summary.json").write_text("{ damaged JSON", encoding="utf-8")
        assert core.search(root, f"специальныйфакт{arguments.meetings - 2}", scope="notes")["total"] == 0
        remaining = core.search(root, "running", scope="transcript", limit=100)
        assert remaining["total"] == arguments.meetings - 1
        assert any(hit["meetingID"] == damaged.name for hit in remaining["hits"])
        checks.append("Trash and corrupted summaries remove ghosts while healthy transcript search remains")

        external = Path(temporary) / "outside"
        external.mkdir(mode=0o700)
        write_json(external / "meta.json", {"id": "linked", "title": "секретныйкорпус", "createdAt": 1.0, "source": "source.mp3"})
        (root / "meetings" / "linked").symlink_to(external, target_is_directory=True)
        write_json(root / "models" / "corpus.json", {"overview": "секретныйкорпус"})
        write_json(root / "settings.json", {"ignoredCanary": "секретныйкорпус", "features": {"cards": True, "tasks": True}})
        (damaged / "summary.json").unlink()
        (damaged / "summary.json").symlink_to(external / "meta.json")
        assert core.search(root, "секретныйкорпус")["total"] == 0
        checks.append("Symlinked meeting/file, models corpus and settings are excluded")
        report = {"result": "PASS", "interface": "posle_request / posle_free_string", "library": str(arguments.library),
                  "fixture": {"meetings": arguments.meetings, "segmentsPerMeeting": arguments.segments,
                              "totalSegments": arguments.meetings * arguments.segments, "data": "synthetic only"},
                  "timings": {"initialIndexAndQueryMs": initial_ms, "warmedQueryMs": warmed},
                  "machine": {"architecture": platform.machine(), "system": platform.system()},
                  "timingNote": "Measured on this machine; this is not an Air M5 benchmark.", "checks": checks}
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
