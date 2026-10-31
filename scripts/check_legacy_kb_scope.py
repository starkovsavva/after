#!/usr/bin/env python3
"""Check a published legacy MCP binary against a disposable current library.

This proves only that the disabled selection route doesn't hand data to legacy
MCP. It does not test an unavailable protected broker or revoke bytes already
given to a legacy client.
"""
import argparse
import json
from pathlib import Path
import tempfile

from e2e import Core, require
from check_mcp import Client, CLIENTS, operation


def run(engine, library):
    with tempfile.TemporaryDirectory(prefix="posle-legacy-scope-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        (root / "settings.json").write_text(json.dumps({"features": {"tasks": True, "knowledgeBase": True}}))
        core = Core(engine, library, root)
        note = core.request("note-save", note={"id": "selected-note", "kind": "note", "title": "SCOPE-TITLE", "text": "SCOPE-SECRET", "createdAt": 1, "updatedAt": 1, "revision": 0})
        core.request("task-agent-settings", enabled=True, expectedRevision=0, operationID=operation())
        task = core.request("task-create", title="Scoped fixture", operationID=operation())
        task = core.request("task-details-update", taskID=task["id"], expectedRevision=task["revision"],
                            operationID=operation(), patch={"agentAccess": {"enabled": True}})
        task = core.request("task-material-link", taskID=task["id"], expectedRevision=task["revision"],
                            operationID=operation(), material={"kind": "note", "title": "Legacy material", "text": "LEGACY-ALLOWED", "shared": True})
        core.request("task-material-share-notes", expected_ok=False, taskID=task["id"], expectedRevision=task["revision"],
                     operationID=operation(), notes=[{"id": note["id"], "revision": note["revision"]}])
        # Protected runs require legacy agent access off. The native-only
        # grant store is deliberately never represented as a task material.
        protected = core.request("task-create", title="Protected fixture", operationID=operation())
        client = Client(core, CLIENTS[0])
        try:
            tools = client.request("tools/list", {})["tools"]
            require(len(tools) == 7, "Legacy tool catalogue changed")
            result = json.dumps(client.tool("posle_task_context", taskID=task["id"]), ensure_ascii=False)
            require("SCOPE-SECRET" not in result and "SCOPE-TITLE" not in result, "Unapproved scope leaked to legacy MCP")
            require("LEGACY-ALLOWED" in result, "Explicit existing legacy material was changed")
            client.tool("posle_task_context", taskID=protected["id"], error=True)
            require(protected["id"] not in json.dumps(client.tool("posle_tasks")), "Protected task visible to legacy MCP")
            print("PASS: disabled KB selection grants no access through published legacy stdio MCP; explicit legacy material remains available")
            print("PASS: published legacy stdio MCP cannot list or read a task while its legacy agent access is off")
        finally:
            client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy-engine", type=Path, required=True)
    parser.add_argument("--current-library", type=Path, required=True)
    args = parser.parse_args()
    run(args.legacy_engine.resolve(), args.current_library.resolve())
