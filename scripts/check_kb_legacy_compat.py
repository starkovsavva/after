#!/usr/bin/env python3
"""Exercise the published and current FFI against disposable shared data.

The two dylibs run in separate processes to preserve their real symbols and
SQLite connections. This does not test the installed app or a real worker.
"""
import argparse
import json
import os
import shutil
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor


WORKER = r'''
import ctypes,json,sys
lib=ctypes.CDLL(sys.argv[1]); lib.posle_request.argtypes=[ctypes.c_char_p]
lib.posle_request.restype=ctypes.c_void_p; lib.posle_free_string.argtypes=[ctypes.c_void_p]
p=lib.posle_request(sys.stdin.buffer.read())
if not p: raise SystemExit("null FFI result")
try: print(ctypes.string_at(p).decode())
finally: lib.posle_free_string(p)
'''


def call(lib, root, command, **kw):
    request = {"root": str(root), "command": command, **kw}
    fragments = ("API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE", "PROXY")
    env = {k: v for k, v in os.environ.items() if not any(s in k.upper() for s in fragments)}
    run = subprocess.run([sys.executable, "-c", WORKER, str(lib)], input=json.dumps(request, ensure_ascii=False),
                         text=True, capture_output=True, timeout=45, env=env, check=True)
    return json.loads(run.stdout)


def ok(lib, root, command, **kw):
    result = call(lib, root, command, **kw)
    assert result.get("ok") is True, (command, result)
    return result["value"]


def note(lib, root, ident, text):
    return ok(lib, root, "note-save", note={"id": ident, "kind": "note", "text": text,
                                                "createdAt": 1, "updatedAt": 1, "revision": 0})


def link_request(snapshot, a, b):
    return {"operationID": str(uuid.uuid4()), "fromID": a["id"], "toID": b["id"], "action": "add",
            "expectedWorkspaceRevision": snapshot["workspaceRevision"], "expectedKBRevision": snapshot["kbRevision"],
            "expectedFromRevision": a["revision"], "expectedToRevision": b["revision"]}


def main(old, new):
    with tempfile.TemporaryDirectory(prefix="after-legacy-compat-") as tmp:
        root = Path(tmp)
        (root / "settings.json").write_text(json.dumps({"features": {"knowledgeBase": True, "tasks": True}}))
        a = note(old, root, "a", "Проверить бюджет договора")
        b = note(old, root, "b", "Вторая заметка")
        snapshot = ok(new, root, "kb-snapshot", noteID="a")
        with sqlite3.connect(root / "core.sqlite") as db:
            assert db.execute("PRAGMA user_version").fetchone()[0] == 1
        first_link = link_request(snapshot, a, b)
        ok(new, root, "kb-link-change", **first_link)
        a["text"] = "Сохранено старой версией"
        a = ok(old, root, "note-save", note=a)
        current = ok(new, root, "kb-snapshot", noteID="a")
        assert len(current["links"]) == 1
        assert next(n for n in ok(new, root, "notes-list")["notes"] if n["id"] == "a")["text"] == a["text"]
        # An older UI can save settings without the newer feature flag. The
        # links remain durable and the feature becomes unavailable until the
        # user enables it again; the old setting must not delete decisions.
        ok(old, root, "write", path="settings.json", value={"features": {"tasks": True}})
        assert call(new, root, "kb-snapshot", noteID="a")["ok"] is False
        ok(new, root, "write", path="settings.json", value={"features": {"knowledgeBase": True, "tasks": True}})
        assert len(ok(new, root, "kb-snapshot", noteID="a")["links"]) == 1
        assert ok(old, root, "task-create", title="Старая задача", operationID=str(uuid.uuid4()))["title"] == "Старая задача"
        queued = ok(old, root, "job-enqueue", kind="transcribe", objectID="legacy")
        job = queued.get("job", queued)
        assert ok(old, root, "job-claim", jobID=job["id"])["job"]["id"] == job["id"]
        ok(old, root, "job-update", jobID=job["id"], state="succeeded")
        assert any(j["id"] == job["id"] for j in ok(new, root, "job-list")["jobs"])
        # Old worker-style file publication must invalidate an already shown
        # meeting source before a new client opens it.
        m = note(old, root, "meeting-note", "Проверить договор и бюджет")
        (root / "meetings" / "meeting").mkdir(parents=True)
        ok(old, root, "write", path="meetings/meeting/meta.json",
           value={"id": "meeting", "title": "Встреча", "source": "audio.mp3", "createdAt": 1, "status": "ready"})
        ok(old, root, "write", path="meetings/meeting/transcript.json",
           value={"segments": [{"id": 1, "start": 1, "end": 2, "text": "Проверить договор и бюджет"}]})
        args = {"noteID": m["id"], "noteRevision": m["revision"]}
        result = ok(new, root, "knowledge-meeting-suggestions", **args)
        assert result["items"], "The current published version should be offered"
        source = result["items"][0]["source"]
        original_meta = (root / "meetings/meeting/meta.json").read_bytes()
        original_transcript = (root / "meetings/meeting/transcript.json").read_bytes()
        state = ok(new, root, "kb-snapshot", noteID=m["id"])
        added = ok(new, root, "kb-meeting-link-change", action="add", operationID=str(uuid.uuid4()),
                   **args, source=source, expectedWorkspaceRevision=state["workspaceRevision"],
                   expectedKBRevision=state["kbRevision"])
        link_id = added["link"]["id"]
        assert ok(new, root, "kb-meeting-links", **args)["items"][0]["available"] is True
        ok(old, root, "write", path="meetings/meeting/transcript.json",
           value={"segments": [{"id": 1, "start": 1, "end": 2, "text": "Изменённая старая запись"}]})
        assert ok(new, root, "knowledge-meeting-validate", **args, source=source)["valid"] is False
        assert ok(new, root, "kb-meeting-links", **args)["items"][0]["available"] is False
        # A content-version reference intentionally accepts an exact restore,
        # but never different content under a reused ID. It is not a grant.
        shutil.rmtree(root / "meetings/meeting")
        (root / "meetings/meeting").mkdir()
        (root / "meetings/meeting/meta.json").write_bytes(original_meta)
        (root / "meetings/meeting/transcript.json").write_bytes(original_transcript)
        assert ok(new, root, "knowledge-meeting-validate", **args, source=source)["valid"] is True
        state = ok(new, root, "kb-meeting-links", **args)
        assert state["items"][0]["available"] is True
        ok(new, root, "kb-meeting-link-change", action="remove", operationID=str(uuid.uuid4()),
           **args, linkID=link_id, expectedWorkspaceRevision=state["workspaceRevision"],
           expectedKBRevision=state["kbRevision"])
        (root / "meetings/meeting/transcript.json").write_bytes(original_transcript)
        assert ok(new, root, "kb-meeting-links", **args)["items"] == [], "Explicitly removed link resurrected"
        # Race a v1 save against adding a KB link. A stale link may fail, but
        # it must never discard the old save or an earlier canonical link.
        for i in range(4):
            other = note(old, root, f"c{i}", f"Заметка {i}")
            current = ok(new, root, "kb-snapshot", noteID="a")
            saved = dict(a, text=f"Одновременное изменение {i}")
            with ThreadPoolExecutor(max_workers=2) as pool:
                f_save = pool.submit(call, old, root, "note-save", note=saved)
                f_link = pool.submit(call, new, root, "kb-link-change", **link_request(current, a, other))
                saved_result, linked = f_save.result(), f_link.result()
            assert saved_result["ok"] is True
            a = saved_result["value"]
            assert next(n for n in ok(new, root, "notes-list")["notes"] if n["id"] == "a")["text"] == saved["text"]
            assert len(ok(new, root, "kb-snapshot", noteID="a")["links"]) >= 1
            if not linked["ok"]:
                assert "измен" in str(linked).lower(), linked
        with sqlite3.connect(root / "core.sqlite") as db:
            revisions = [row[0] for row in db.execute("SELECT revision FROM workspace_outbox ORDER BY revision")]
            assert revisions == sorted(set(revisions))
            assert db.execute("SELECT COUNT(*) FROM workspace_outbox WHERE kind='knowledge.changed'").fetchone()[0] >= 1
            assert db.execute("SELECT COUNT(*) FROM operation_receipts WHERE namespace='knowledge' AND operation_id=?",
                              (first_link["operationID"],)).fetchone()[0] == 1
            assert db.execute("SELECT COUNT(*) FROM kb_operations WHERE operation_id=?",
                              (first_link["operationID"],)).fetchone()[0] == 1
        print("PASS: released v1 and new extension preserve notes, links, tasks and queue; concurrent stale writes fail safely")
        print("PASS: meeting links reject changed content, accept exact restores and preserve explicit deletion")

    with tempfile.TemporaryDirectory(prefix="after-legacy-delete-") as tmp:
        root = Path(tmp)
        (root / "settings.json").write_text(json.dumps({"features": {"knowledgeBase": True}}))
        a = note(old, root, "reused-id", "Старая заметка")
        b = note(old, root, "b", "Другая заметка")
        snapshot = ok(new, root, "kb-snapshot", noteID=a["id"])
        linked = ok(new, root, "kb-link-change", **link_request(snapshot, a, b))
        ok(new, root, "kb-collection-change", action="create", operationID=str(uuid.uuid4()),
           name="Сохранённая подборка", sources=[{"noteID":a["id"],"revision":a["revision"]}, {"noteID":b["id"],"revision":b["revision"]}],
           expectedWorkspaceRevision=linked["workspaceRevision"], expectedKBRevision=linked["kbRevision"])
        ok(old, root, "note-delete", id=a["id"], revision=a["revision"])
        note(old, root, "reused-id", "Новая заметка с тем же ID")
        current = ok(new, root, "kb-snapshot", noteID="reused-id")
        assert not current["links"], "Deleted link was resurrected after reuse of the ID"
        topics = ok(new, root, "kb-topics", expectedWorkspaceRevision=current["workspaceRevision"], expectedKBRevision=current["kbRevision"])
        assert len(topics["collections"]) == 1 and [x["noteID"] for x in topics["collections"][0]["sources"]] == ["b"]
        print("PASS: released client delete+recreate does not resurrect links or saved collection membership")

    with tempfile.TemporaryDirectory(prefix="after-legacy-crash-") as tmp:
        root = Path(tmp)
        (root / "settings.json").write_text(json.dumps({"features": {"knowledgeBase": True}}))
        a = note(old, root, "a", "До прерывания")
        ok(new, root, "kb-snapshot", noteID="a")
        journal_path = root / ".knowledge-migration" / "current.json"
        journal = json.loads(journal_path.read_text())
        journal["state"] = "prepared"
        journal_path.write_text(json.dumps(journal))
        with sqlite3.connect(root / "core.sqlite") as db:
            db.execute("DELETE FROM workspace_metadata WHERE key='knowledge_migration_finalized'")
        a["text"] = "Изменено после сбоя"
        ok(old, root, "note-save", note=a)
        assert next(n for n in ok(new, root, "notes-list")["notes"] if n["id"] == "a")["text"] == a["text"]
        assert json.loads(journal_path.read_text())["state"] == "committed"
        print("PASS: interrupted extension recovers a subsequent legitimate save by the released client")

    with tempfile.TemporaryDirectory(prefix="after-legacy-v2-") as tmp:
        root = Path(tmp)
        (root / "settings.json").write_text(json.dumps({"features": {"knowledgeBase": True}}))
        note(old, root, "a", "Пробная база")
        with sqlite3.connect(root / "core.sqlite") as db:
            db.execute("PRAGMA user_version=2")
        assert call(new, root, "notes-list")["ok"] is False
        assert call(new, root, "kb-snapshot", noteID="a")["ok"] is False
        with sqlite3.connect(root / "core.sqlite") as db:
            assert db.execute("PRAGMA user_version").fetchone()[0] == 2
        print("PASS: trial schema v2 is rejected without being rewritten")

    # An identity marker is not a barrier to an old binary whose root is
    # explicitly supplied. Never use this observation as proof that a new
    # root is isolated: the compatibility boundary must account for old
    # clients launched with an override, not just their default path.
    with tempfile.TemporaryDirectory(prefix="after-legacy-identity-") as tmp:
        root = Path(tmp)
        marker = root / ".after-library-id"
        marker.write_text(str(uuid.uuid4()), encoding="utf-8")
        (root / "settings.json").write_text(json.dumps({"features": {"knowledgeBase": True}}))
        saved = note(old, root, "identity-check", "Disposable synthetic note")
        assert saved["id"] == "identity-check"
        ok(old, root, "write", path="settings.json", value={"features": {"knowledgeBase": False}})
        assert json.loads((root / "settings.json").read_text())["features"]["knowledgeBase"] is False
        assert marker.exists()
        print("PASS: released core can still write a root with an unknown identity marker; marker alone is not isolation")

    # A separate UUID journal also cannot detect writers that do not consult
    # it. This is an adversarial regression, not an isolation implementation.
    with tempfile.TemporaryDirectory(prefix="after-legacy-incarnation-") as tmp:
        root = Path(tmp)
        (root / "settings.json").write_text(json.dumps({"features": {"knowledgeBase": True}}))
        meeting = root / "meetings" / "synthetic"
        meeting.mkdir(parents=True)
        meta = {"id": "synthetic", "title": "Fixture", "source": "synthetic.wav", "createdAt": 1, "status": "ready"}
        transcript = {"segments": [{"id": 1, "start": 0, "end": 1, "text": "Synthetic speech"}]}
        def publish_old():
            ok(old, root, "write", path="meetings/synthetic/meta.json", value=meta)
            ok(old, root, "write", path="meetings/synthetic/transcript.json", value=transcript)
        publish_old()
        before = [(meeting / name).read_bytes() for name in ("meta.json", "transcript.json")]
        with sqlite3.connect(root / "synthetic-incarnations.sqlite") as db:
            db.execute("CREATE TABLE meeting_incarnations(meeting_id TEXT, incarnation TEXT, active INTEGER)")
            generation = str(uuid.uuid4())
            db.execute("INSERT INTO meeting_incarnations VALUES('synthetic',?,1)", (generation,))
        shutil.rmtree(meeting)
        meeting.mkdir()
        publish_old()
        assert before == [(meeting / name).read_bytes() for name in ("meta.json", "transcript.json")]
        with sqlite3.connect(root / "synthetic-incarnations.sqlite") as db:
            assert db.execute("SELECT incarnation,active FROM meeting_incarnations WHERE meeting_id='synthetic'").fetchone() == (generation, 1)
        print("PASS: released writer bypasses an unintegrated generation journal, even for byte-identical recreation")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-library", type=Path, required=True)
    parser.add_argument("--new-library", type=Path, required=True)
    args = parser.parse_args()
    main(args.old_library.resolve(strict=True), args.new_library.resolve(strict=True))
