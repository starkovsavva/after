#!/usr/bin/env python3
"""Exercise immutable snapshot sharing through real stdio MCP on disposable data.

No model or network, no personal data, and no configured MCP client is changed.
Optional --old-library checks actual released writer compatibility in separate
FFI processes. Approval calls here simulate the native UI on synthetic fixtures.
"""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid

from check_kb_legacy_compat import call, ok, note


class Client:
    def __init__(self, engine, root, label):
        env = {k: v for k, v in os.environ.items() if not any(s in k.upper() for s in
               ("TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "API_KEY", "PROXY"))}
        self.process = subprocess.Popen([str(engine), "mcp-share", "--root", str(root)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=env)
        self.sequence = 0
        self.buffer = b""
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                   "clientInfo": {"name": label, "version": "fixture"}})
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        payload = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        self.process.stdin.write(json.dumps(payload).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "MCP response timed out"
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            assert ready, "MCP response timed out"
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, "MCP closed unexpectedly"
            self.buffer += data
            assert len(self.buffer) < 3 * 1024 * 1024, "Unbounded response"
        line, self.buffer = self.buffer.split(b"\n", 1)
        result = json.loads(line)
        assert result["id"] == self.sequence and "error" not in result, result
        return result["result"]

    def tool(self, name, arguments=None, denied=False):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        assert bool(result.get("isError")) == denied, result
        if denied:
            assert "PRIVATE_UNSELECTED" not in json.dumps(result)
            return result
        return result.get("structuredContent") or json.loads(result["content"][0]["text"])

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.process.stdout.close()


def run(engine, library, old_library=None):
    with tempfile.TemporaryDirectory(prefix="after-snapshot-mcp-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        (root / "settings.json").write_text(json.dumps({"features": {"tasks": True, "knowledgeBase": True}}))
        selected = note(library, root, "public", "ANCHOR Approved exact source version one.")
        note(library, root, "private", "PRIVATE_UNSELECTED must never enter the agent snapshot.")
        large = note(library, root, "stalled", "STALL " + "x" * 60_000)
        task = ok(library, root, "task-create", title="Synthetic snapshot task", operationID=str(uuid.uuid4()))
        task_id = task["id"]
        first = Client(engine, root, "Synthetic first client")
        second = Client(engine, root, "Synthetic second client")
        stalled = Client(engine, root, "Synthetic stalled client")
        try:
            definitions = first.request("tools/list", {})["tools"]
            assert {t["name"] for t in definitions} == {
                "after_share_status", "after_share_sources", "after_share_request_snapshot",
                "after_share_search", "after_share_read", "after_share_report"}
            assert not any(key in json.dumps(definitions) for key in ("sessionID", "capability", "draftID"))
            first.tool("after_share_search", {"query": "ANCHOR"}, denied=True)
            first_status = first.tool("after_share_status")
            second_status = second.tool("after_share_status")
            assert not first_status["approved"] and first_status["connectionCode"] != second_status["connectionCode"]
            settings = ok(library, root, "agent-share-settings")
            ok(library, root, "agent-share-settings", enabled=True, expectedRevision=settings["revision"])
            draft = ok(library, root, "agent-share-preview", taskID=task_id,
                       sources=[{"noteID": selected["id"], "revision": selected["revision"]}])
            stalled_draft = ok(library, root, "agent-share-preview", taskID=task_id,
                               sources=[{"noteID": large["id"], "revision": large["revision"]}])
            assert "PRIVATE_UNSELECTED" not in json.dumps(draft)
            assert any("version one" in s["text"] for s in draft["sources"])
            # The user approves exactly the draft they inspected, even if the
            # old app edited the originals in the meantime. No implicit refresh.
            writer = old_library or library
            selected["text"] = "CHANGED_UNAPPROVED version two."
            selected = ok(writer, root, "note-save", note=selected)
            ok(writer, root, "write", path="settings.json", value={"features": {"tasks": False, "knowledgeBase": False}})
            pending = ok(library, root, "agent-share-connections")["connections"]
            session = next(c["id"] for c in pending if c["code"] == first_status["connectionCode"])
            share = ok(library, root, "agent-share-approve", draftID=draft["id"], digest=draft["digest"], sessionID=session)
            assert first.tool("after_share_status")["approved"]
            assert not second.tool("after_share_status")["approved"]
            first.tool("after_share_search", {"query": "ANCHOR", "sessionID": session}, denied=True)
            found = first.tool("after_share_search", {"query": "ANCHOR"})
            assert found["snapshotID"] == share["id"]
            assert len(found["sources"]) == 1
            source = found["sources"][0]
            inventory = first.tool("after_share_sources")
            assert inventory["snapshotID"] == share["id"] and len(inventory["sources"]) == 2
            assert {s["kind"] for s in inventory["sources"]} == {"task", "note"}
            assert all("text" not in s for s in inventory["sources"]), "Inventory should contain bounded metadata only"
            assert "version one" in source["text"]
            assert not first.tool("after_share_search", {"query": "PRIVATE_UNSELECTED"})["sources"]
            assert not first.tool("after_share_search", {"query": "CHANGED_UNAPPROVED"})["sources"]
            second.tool("after_share_read", {"sourceID": source["id"], "fingerprint": source["fingerprint"]}, denied=True)
            first.tool("after_share_read", {"sourceID": source["id"], "fingerprint": "0" * 64}, denied=True)
            evidence = [{"sourceID": source["id"], "fingerprint": source["fingerprint"]}]
            first.tool("after_share_report", {"snapshotID": share["id"], "operationID": "unread", "text": "Unsupported citation", "evidence": evidence}, denied=True)
            read = first.tool("after_share_read", evidence[0])
            assert read["text"] == "ANCHOR Approved exact source version one."
            first.tool("after_share_report", {"snapshotID": share["id"], "operationID": "file-link", "text": "Unsafe artifact URL",
                        "artifacts": [{"title": "No local execution", "url": "file:///tmp/fixture"}]}, denied=True)
            report = {"snapshotID": share["id"], "operationID": str(uuid.uuid4()), "text": "Synthetic report grounded in the approved version.",
                      "evidence": evidence, "artifacts": [{"title": "Synthetic checklist", "text": "Review approved source."}],
                      "completed": True}
            result = first.tool("after_share_report", report)
            assert result["completed"] and not result["taskStatusChanged"]
            assert first.tool("after_share_report", report) == result
            first.tool("after_share_report", dict(report, text="Changed retry"), denied=True)
            history = ok(library, root, "agent-share-history", taskID=task_id)
            row = next(s for s in history["shares"] if s["id"] == share["id"])
            reports = [r for r in history["reports"] if r["shareID"] == row["id"]]
            assert len(reports) == 1
            assert [{k: item[k] for k in ("sourceID", "fingerprint")} for item in reports[0]["evidence"]] == evidence
            assert reports[0]["evidence"][0]["title"] == source["title"]
            assert reports[0]["artifacts"][0]["title"] == "Synthetic checklist"
            retained = ok(library, root, "agent-share-snapshot", shareID=share["id"])
            assert any("version one" in s["text"] for s in retained["sources"])
            assert "CHANGED_UNAPPROVED" not in json.dumps(retained)
            assert "PRIVATE_UNSELECTED" not in json.dumps(history)
            ok(library, root, "agent-share-revoke", shareID=share["id"])
            assert not first.tool("after_share_status")["approved"]
            first.tool("after_share_search", {"query": "ANCHOR"}, denied=True)
            first.tool("after_share_read", evidence[0], denied=True)
            first.tool("after_share_report", report, denied=True)
            settings = ok(library, root, "agent-share-settings")
            settings = ok(library, root, "agent-share-settings", enabled=False, expectedRevision=settings["revision"])
            ok(library, root, "agent-share-settings", enabled=True, expectedRevision=settings["revision"])
            assert not first.tool("after_share_status")["approved"], "Master re-enable resurrected revoked access"
            assert len(ok(library, root, "agent-share-history", taskID=task_id)["reports"]) == 1
            # Reuse the same live MCP process for another explicitly approved
            # snapshot. An old delayed report must never land in the new share.
            renewed = first.tool("after_share_request_snapshot")
            assert not renewed["approved"] and renewed["connectionCode"] != first_status["connectionCode"]
            first.tool("after_share_sources", denied=True)
            ok(library, root, "write", path="settings.json", value={"features": {"tasks": True, "knowledgeBase": True}})
            renewed_draft = ok(library, root, "agent-share-preview", taskID=task_id,
                               sources=[{"noteID": selected["id"], "revision": selected["revision"]}])
            pending = ok(library, root, "agent-share-connections")["connections"]
            renewed_session = next(c["id"] for c in pending if c["code"] == renewed["connectionCode"])
            renewed_share = ok(library, root, "agent-share-approve", draftID=renewed_draft["id"], digest=renewed_draft["digest"], sessionID=renewed_session)
            first.tool("after_share_report", report, denied=True)
            first.tool("after_share_read", evidence[0], denied=True)
            new_sources = first.tool("after_share_sources")
            assert new_sources["snapshotID"] == renewed_share["id"]
            renewed_source = next(s for s in new_sources["sources"] if s["kind"] == "note")
            new_evidence = {"sourceID": renewed_source["id"], "fingerprint": renewed_source["fingerprint"]}
            assert first.tool("after_share_read", new_evidence)["text"] == "CHANGED_UNAPPROVED version two."
            new_report = dict(report, snapshotID=renewed_share["id"], evidence=[new_evidence], text="Explicitly reapproved version two.")
            first.tool("after_share_report", new_report)
            history = ok(library, root, "agent-share-history", taskID=task_id)
            assert len(history["reports"]) == 2
            assert ok(library, root, "task-get", taskID=task_id)["revision"] == task["revision"], "Agent changed the original task"
            # Real pipe backpressure: this read response is larger than macOS's
            # pipe capacity. The client stops draining after its search. Revoke
            # must return in bounded time; the unfinished frame must be dropped.
            stalled_code = stalled.tool("after_share_status")["connectionCode"]
            pending = ok(library, root, "agent-share-connections")["connections"]
            stalled_session = next(c["id"] for c in pending if c["code"] == stalled_code)
            stalled_share = ok(library, root, "agent-share-approve", draftID=stalled_draft["id"],
                               digest=stalled_draft["digest"], sessionID=stalled_session)
            stalled_source = stalled.tool("after_share_search", {"query": "STALL"})["sources"][0]
            stalled.sequence += 1
            frame = {"jsonrpc": "2.0", "id": stalled.sequence, "method": "tools/call", "params": {
                "name": "after_share_read", "arguments": {k: stalled_source[k] for k in ("fingerprint",)}}}
            frame["params"]["arguments"]["sourceID"] = stalled_source["id"]
            stalled.process.stdin.write(json.dumps(frame).encode() + b"\n")
            stalled.process.stdin.flush()
            assert select.select([stalled.process.stdout], [], [], 5)[0], "No protected response started"
            before = time.monotonic()
            ok(library, root, "agent-share-revoke", shareID=stalled_share["id"])
            assert time.monotonic() - before < 5, "Slow MCP client blocked revocation"
            stalled.process.wait(timeout=3)
            partial = stalled.process.stdout.read()
            assert partial and b"\n" not in partial, "Stalled publication unexpectedly completed"
            print("PASS: real MCP preview/approve/search/read/report/history/revoke with independent sessions")
            print("PASS: original edits and legacy settings cannot alter approved copies; unselected data stays absent")
            print("PASS: real pipe backpressure aborts incomplete publication and cannot hang revocation")
            print("PASS: source enumeration and connection renewal; old reports cannot enter the newly approved snapshot")
        finally:
            first.close()
            second.close()
            stalled.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--old-library", type=Path)
    args = parser.parse_args()
    run(args.engine.resolve(), args.library.resolve(), args.old_library.resolve() if args.old_library else None)
