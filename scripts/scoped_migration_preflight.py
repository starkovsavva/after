"""Read-only, negative-only migration inspection prototype.

This is not connected to After, MCP, a migration, or a live-process detector.
It may identify reasons to stop, but cannot authorize a snapshot or root
switch. It intentionally returns blocked even if every observation is benign.
Call only on disposable fixtures until a comprehensive collector is designed.
"""

import os
import stat

# Top-level labels only; directories are not traversed and are not considered
# inventoried. The list is deliberately narrow, not an allowlist for migration.
_KNOWN = {
    "settings.json": "settings", "semantic-settings.json": "settings",
    "sidebar-state.json": "settings", "language-state.json": "settings",
    "overview-drafts.json": "settings", "voice-draft.json": "settings",
    "capture-drafts.json": "settings", "core.sqlite": "workspace",
    "core.sqlite-wal": "workspace", "core.sqlite-shm": "workspace",
    "jobs.sqlite": "jobs", "jobs.sqlite-wal": "jobs", "jobs.sqlite-shm": "jobs",
    "notes": "notes", "meetings": "meetings", "trash": "trash",
    "runtime": "runtime", "cache": "cache", "voice-inputs": "voice",
}
_DIRECTORY_LABELS = {"notes", "meetings", "trash", "runtime", "cache", "voice"}
_WRITERS = frozenset({"native-app", "engine-workers", "python-workers", "legacy-app-workers-mcp", "external-unknown"})
_MAX_ENTRIES = 10_000


def _open_directory(path):
    # A missing O_NOFOLLOW cannot be silently interpreted as a safe root.
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise OSError("directory nofollow unavailable")
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def inspect_disposable_fixture(root, *, observed_writers=None):
    """Inspect only immediate names; return no filenames, content, or success.

    `observed_writers` is test input, not a trusted process inspection API.
    Missing or malformed categories become unknown. Even all-stopped inputs
    cannot establish a filesystem-wide write barrier or consistent snapshot.
    """
    reasons = {"no-quiescence-barrier", "no-consistent-snapshot", "recursive-inventory-not-implemented"}
    counts = {}
    writer_states = {}
    supplied = observed_writers if isinstance(observed_writers, dict) else {}
    for writer in sorted(_WRITERS):
        state = supplied.get(writer, "unknown")
        if state not in ("stopped", "live", "unknown"):
            state = "unknown"
        writer_states[writer] = state
        if state != "stopped":
            reasons.add("writer-live-or-unknown")
    if any(writer not in _WRITERS for writer in supplied):
        reasons.add("unknown-writer-class")
    try:
        fd = _open_directory(root)
    except OSError:
        return {"status": "blocked", "reasons": sorted(reasons | {"root-unreadable"}),
                "writerStates": writer_states, "counts": counts}
    try:
        with os.scandir(fd) as entries:
            for index, entry in enumerate(entries):
                if index >= _MAX_ENTRIES:
                    reasons.add("inventory-incomplete")
                    break
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError:
                    reasons.add("entry-unreadable")
                    continue
                label = _KNOWN.get(entry.name)
                if stat.S_ISLNK(info.st_mode):
                    reasons.add("symlink-present")
                elif label is None:
                    reasons.add("unknown-format")
                elif label in _DIRECTORY_LABELS:
                    if not stat.S_ISDIR(info.st_mode):
                        reasons.add("unexpected-entry-type")
                    else:
                        counts[label] = counts.get(label, 0) + 1
                elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    reasons.add("unexpected-entry-type")
                else:
                    counts[label] = counts.get(label, 0) + 1
    except OSError:
        reasons.add("inventory-incomplete")
    finally:
        os.close(fd)
    return {"status": "blocked", "reasons": sorted(reasons), "writerStates": writer_states, "counts": counts}
