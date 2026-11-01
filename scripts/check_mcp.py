#!/usr/bin/env python3
"""Real stdio MCP lifecycles with varied client identities/capabilities.

These are protocol clients, not installed Codex/Claude/Cursor application tests.
Only disposable libraries are used; no accounts, credentials or models.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid
from e2e import Core, require


def operation():
    return str(uuid.uuid4())


CLIENTS = (
    {"name": "codex", "protocol": "2025-11-25", "capabilities": {}},
    {"name": "claude-code", "protocol": "2025-06-18", "capabilities": {"roots": {"listChanged": True}, "sampling": {}}},
    {"name": "cursor", "protocol": "2025-03-26", "capabilities": {"roots": {"listChanged": True}}, "string_ids": True},
    {"name": "Независимый MCP-клиент", "protocol": "2099-01-01", "capabilities": {"experimental": {"future": {}}}, "string_ids": True},
)


class Client:
    def __init__(self, core, identity, shared_material_search=False):
        self.identity = identity
        self.actor = identity["name"]
        self.sequence = 0
        self.output = queue.Queue()
        self.errors = []
        self.process = subprocess.Popen([str(core.engine), "mcp", "--root", str(core.root)] + (["--shared-material-search"] if shared_material_search else []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=core.environment)
        def read():
            try:
                for line in self.process.stdout:
                    self.output.put(json.loads(line))
            except Exception as error:
                self.output.put(error)
            finally:
                self.output.put(EOFError("MCP stdout closed"))
        threading.Thread(target=read, daemon=True).start()
        def errors():
            for line in self.process.stderr:
                self.errors.append(line.decode(errors="replace"))
        threading.Thread(target=errors, daemon=True).start()
        initialized = self.request("initialize", {"protocolVersion": identity["protocol"], "capabilities": identity["capabilities"],
            "clientInfo": {"name": self.actor, "version": "1"}})
        require(initialized["serverInfo"]["name"] == "posle", "Wrong server identity")
        require(initialized["protocolVersion"] in {"2025-03-26", "2025-06-18", "2025-11-25"}, "No compatible protocol negotiated")
        require("tools" in initialized["capabilities"], "Task tools capability not advertised")
        self.negotiated_version = initialized["protocolVersion"]
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, data):
        self.process.stdin.write((json.dumps(data, ensure_ascii=False) + "\n").encode())
        self.process.stdin.flush()

    def request(self, method, parameters):
        self.sequence += 1
        request_id = f"request-{self.sequence}" if self.identity.get("string_ids") else self.sequence
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": parameters})
        while True:
            response = self.output.get(timeout=20)
            if isinstance(response, BaseException):
                raise AssertionError(f"MCP transport: {response}; {''.join(self.errors)[-2000:]}")
            if response.get("id") == request_id:
                require("error" not in response, f"MCP protocol failure: {response}")
                return response["result"]

    def tool(self, name, *, error=False, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        require(bool(result.get("isError")) is error, f"MCP {name}: {result}")
        if error:
            return result
        structured = result.get("structuredContent")
        if structured is not None:
            return structured
        return json.loads(result["content"][0]["text"])

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


def lifecycle(engine, library, identity, other_identity):
    with tempfile.TemporaryDirectory(prefix="posle-mcp-check-", dir="/private/tmp") as temporary:
        core = Core(engine, library, Path(temporary))
        first = Client(core, identity)
        second = None
        try:
            require(first.request("tools/list", {})["tools"] == [], "Task tools exposed before opt-in")
            first.tool("posle_tasks", error=True)
            (core.root / "settings.json").write_text(json.dumps({"features": {"tasks": True}}))
            tools = first.request("tools/list", {})["tools"]
            require(len(tools) == 7 and len({tool["name"] for tool in tools}) == 7, "MCP tool catalog")
            first.tool("posle_tasks", error=True)
            settings = core.request("task-agent-settings")
            core.request("task-agent-settings", enabled=True, expectedRevision=settings["revision"], operationID=operation())
            created = core.request("task-create", title="Проверить совместимость входа", text="Сохранить старые ссылки", project="Пилот", operationID=operation())
            task_id = created["id"]
            require(first.tool("posle_tasks")["tasks"] == [], "Unshared task leaked through MCP")
            first.tool("posle_task_context", taskID=task_id, error=True)
            task = core.request("task-details-update", taskID=task_id, expectedRevision=created["revision"], operationID=operation(), patch={"agentAccess": {"enabled": True}})
            task = core.request("task-material-link", taskID=task_id, expectedRevision=task["revision"], operationID=operation(),
                material={"kind": "note", "title": "Публичный контекст", "text": "Нужен обратный сценарий", "shared": True})
            task = core.request("task-material-link", taskID=task_id, expectedRevision=task["revision"], operationID=operation(),
                material={"kind": "note", "title": "Личный контекст", "text": "PRIVATE-MATERIAL-MUST-NOT-LEAK", "shared": False})
            folder = core.root / "source-project"
            folder.mkdir()
            (folder / "private.txt").write_text("FOLDER-CONTENTS-MUST-NOT-BE-READ")
            task = core.request("task-material-link", taskID=task_id, expectedRevision=task["revision"], operationID=operation(),
                material={"kind": "folder", "title": "Проект", "path": str(folder), "shared": True})
            context = first.tool("posle_task_context", taskID=task_id)
            serial = json.dumps(context)
            require("PRIVATE-MATERIAL-MUST-NOT-LEAK" not in serial and "FOLDER-CONTENTS-MUST-NOT-BE-READ" not in serial, "Context leaked excluded material or traversed folder")
            claim_args = dict(taskID=task_id, expectedRevision=context["task"]["revision"], expectedContextVersion=context["contextVersion"], agentID=first.actor, operationID=operation())
            claimed = first.tool("posle_claim_task", **claim_args)
            retry = first.tool("posle_claim_task", **claim_args)
            require(claimed == retry and claimed["status"] == "doing", "Claim retry duplicated mutation")
            claim_id = claimed["claim"]["id"]
            scoped = Client(core, identity, shared_material_search=True)
            try:
                require(len(scoped.request("tools/list", {})["tools"]) == 8, "Opt-in search missing")
                search_context = scoped.tool("posle_task_context", taskID=task_id)
                search = scoped.tool("posle_task_material_search", taskID=task_id, query="сценарий", agentID=first.actor, claimID=claim_id, expectedContextVersion=search_context["contextVersion"])
                require(len(search["results"]) == 1 and search["results"][0]["title"] == "Публичный контекст", "Shared material search returned wrong results")
                require("PRIVATE-MATERIAL" not in json.dumps(search), "Search leaked private material")
                first.tool("posle_task_material_search", taskID=task_id, query="сценарий", agentID=first.actor, claimID=claim_id, expectedContextVersion=search_context["contextVersion"], error=True)
            finally:
                scoped.close()
            second = Client(core, other_identity)
            require({tool["name"] for tool in second.request("tools/list", {})["tools"]} == {tool["name"] for tool in tools}, "Client identity changed available tools")
            fresh = second.tool("posle_task_context", taskID=task_id)
            require(fresh["contextVersion"] == first.tool("posle_task_context", taskID=task_id)["contextVersion"], "Client identity changed the shared context")
            second.tool("posle_task_progress", taskID=task_id, expectedRevision=claimed["revision"], claimID=claim_id,
                agentID=second.actor, operationID=operation(), text="Cannot write another agent's claim", error=True)
            second.tool("posle_claim_task", taskID=task_id, expectedRevision=claimed["revision"], expectedContextVersion=fresh["contextVersion"], agentID=second.actor, operationID=operation(), error=True)
            report = first.tool("posle_task_report", taskID=task_id, expectedRevision=claimed["revision"], claimID=claim_id, agentID=first.actor, operationID=operation(),
                text="Реализация и проверки готовы", artifacts=[{"title": "Проверки", "kind": "checks", "text": "12 сценариев пройдено"}])
            require(any(event.get("artifacts") for event in report["history"]), "Report artifacts were not persisted")
            core.request("task-material-link", taskID=task_id, expectedRevision=report["revision"], operationID=operation(),
                material={"kind": "note", "title": "Новое условие", "text": "Проверить второе устройство", "shared": True})
            first.tool("posle_complete_task", taskID=task_id, expectedRevision=report["revision"], claimID=claim_id, agentID=first.actor, operationID=operation(), expectedContextVersion=fresh["contextVersion"], error=True)
            updated = first.tool("posle_task_context", taskID=task_id)
            require(updated["contextVersion"] != context["contextVersion"], "Changed user context has unchanged fingerprint")
            report_arguments = dict(taskID=task_id, expectedRevision=updated["task"]["revision"], claimID=claim_id, agentID=first.actor, operationID=operation(), text="Учтено новое условие; проверки повторены")
            reported = first.tool("posle_task_report", **report_arguments)
            latest = first.tool("posle_task_context", taskID=task_id)
            completed = first.tool("posle_complete_task", taskID=task_id, expectedRevision=reported["revision"], claimID=claim_id, agentID=first.actor, operationID=operation(), expectedContextVersion=latest["contextVersion"])
            require(completed["status"] == "done" and completed["completed"], "Agent completion did not reach shared tracker state")
            native = core.request("task-get", taskID=task_id)
            require(all(native[key] == completed[key] for key in ("id", "status", "completed", "revision")), "MCP and native domain have divergent task state")
            public_material = next(material for material in native["materials"] if material["title"] == "Публичный контекст")
            core.request("task-material-link", taskID=task_id, expectedRevision=native["revision"], operationID=operation(), material={"id": public_material["id"], "shared": False})
            replayed = first.tool("posle_task_report", **report_arguments)
            require("Публичный контекст" not in json.dumps(replayed, ensure_ascii=False) and "Нужен обратный сценарий" not in json.dumps(replayed, ensure_ascii=False), "A cached mutation replay leaked a newly revoked material")
            handoff = core.request("task-create", title="Передать проверку другому агенту", text="Сохранить ход работы", operationID=operation())
            handoff = core.request("task-details-update", taskID=handoff["id"], expectedRevision=handoff["revision"], operationID=operation(), patch={"agentAccess": {"enabled": True}})
            handoff_context = first.tool("posle_task_context", taskID=handoff["id"])
            handoff = first.tool("posle_claim_task", taskID=handoff["id"], expectedRevision=handoff["revision"], expectedContextVersion=handoff_context["contextVersion"], agentID=first.actor, operationID=operation())
            handoff = first.tool("posle_task_progress", taskID=handoff["id"], expectedRevision=handoff["revision"], claimID=handoff["claim"]["id"], agentID=first.actor, operationID=operation(), text="Первый шаг выполнен")
            handoff = first.tool("posle_release_task", taskID=handoff["id"], expectedRevision=handoff["revision"], claimID=handoff["claim"]["id"], agentID=first.actor, operationID=operation(), text="Передано для проверки")
            require(handoff["status"] == "todo" and not handoff.get("claim"), "Release did not return task to the queue")
            handoff_context = second.tool("posle_task_context", taskID=handoff["id"])
            handoff = second.tool("posle_claim_task", taskID=handoff["id"], expectedRevision=handoff["revision"], expectedContextVersion=handoff_context["contextVersion"], agentID=second.actor, operationID=operation())
            handoff = second.tool("posle_task_report", taskID=handoff["id"], expectedRevision=handoff["revision"], claimID=handoff["claim"]["id"], agentID=second.actor, operationID=operation(), text="Проверено вторым клиентом")
            handoff_context = second.tool("posle_task_context", taskID=handoff["id"])
            handoff = second.tool("posle_complete_task", taskID=handoff["id"], expectedRevision=handoff["revision"], claimID=handoff["claim"]["id"], agentID=second.actor, operationID=operation(), expectedContextVersion=handoff_context["contextVersion"])
            require(handoff["completed"] and any(event.get("actor") == second.actor for event in handoff["history"]), "Second client could not finish or persist its identity")
            revoked = core.request("task-details-update", taskID=handoff["id"], expectedRevision=handoff["revision"], operationID=operation(), patch={"agentAccess": {"enabled": False}})
            first.tool("posle_task_context", taskID=revoked["id"], error=True)
            second.tool("posle_task_context", taskID=revoked["id"], error=True)
            integration = core.request("task-agent-settings")
            core.request("task-agent-settings", enabled=False, expectedRevision=integration["revision"], operationID=operation())
            first.tool("posle_task_context", taskID=task_id, error=True)
            first.tool("posle_task_report", error=True, **report_arguments)
            first.tool("posle_tasks", root="/tmp/other", error=True)
            (core.root / "settings.json").write_text(json.dumps({"features": {}}))
            require(first.request("tools/list", {})["tools"] == [], "Task tools survived module opt-out")
            first.tool("posle_task_context", taskID=task_id, error=True)
            require(core.request("task-get", taskID=task_id)["id"] == task_id, "Module opt-out deleted a task")
            print(f"PASS: stdio {first.actor} ({first.negotiated_version}) ↔ {second.actor}: all 7 tools, permissions, claim ownership/retries/handoff, artifacts, stale completion and revocation", flush=True)
        finally:
            if second:
                second.close()
            first.close()


def run(engine, library):
    for index, identity in enumerate(CLIENTS):
        lifecycle(engine, library, identity, CLIENTS[(index + 1) % len(CLIENTS)])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    args = parser.parse_args()
    run(args.engine.resolve(), args.library.resolve())
