#!/usr/bin/env python3
"""Source-level layer guardrails; not a complete Rust dependency parser."""
import argparse
from pathlib import Path
import re


def violations(root):
    rules = (
        (r"\bcrate\s*::\s*(?!domain\b)\w+", "domain depends on an outer module"),
        (r"\bstd\s*::\s*(?:fs|os|process|net|env|path|thread)\b", "domain depends on OS/I/O"),
        (r"\b(?:reqwest|rusqlite|tokio|tauri|libc|after_process_runtime)\s*::", "domain depends on an infrastructure library"),
        (r"\bcfg!?\s*\([^)]*\b(?:windows|unix|target_os|target_arch|target_family)\b", "domain selects an OS implementation"),
    )
    graph = {}
    for path in sorted(root.rglob("*.rs")):
        # Preserve line numbers for diagnostics. The current domain uses line
        # comments; this also handles ordinary block comments, not nested ones.
        source = re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: "\n" * m[0].count("\n"), path.read_text(), flags=re.S)
        production = re.split(r"#\[cfg\(test\)\]", source, maxsplit=1)[0]
        dependencies = set(re.findall(r"(?:crate\s*::\s*domain|super)\s*::\s*(\w+)", production))
        for group in re.findall(r"(?:crate\s*::\s*domain|super)\s*::\s*\{([^}]+)\}", production, re.S):
            dependencies.update(re.findall(r"\b(\w+)\s*::", group))
        if path.parent == root and path.stem != "mod":
            graph[path.stem] = dependencies
        for pattern, reason in rules:
            for match in re.finditer(pattern, source, re.S):
                yield f"{path}:{source[:match.start()].count(chr(10)) + 1}: {reason}"
        for match in re.finditer(r"\bstd\s*::\s*\{([^}]+)\}", source, re.S):
            if re.search(r"\b(?:fs|os|process|net|env|path|thread)\b", match[1]):
                yield f"{path}: grouped std import depends on OS/I/O"

    visited = set()
    active = []
    def visit(module):
        if module in active:
            return " -> ".join(active[active.index(module):] + [module])
        if module in visited:
            return None
        active.append(module)
        for dependency in sorted(graph.get(module, set()) & graph.keys()):
            cycle = visit(dependency)
            if cycle:
                return cycle
        active.pop()
        visited.add(module)
        return None
    for module in sorted(graph):
        cycle = visit(module)
        if cycle:
            yield f"{root}: cyclic domain dependency: {cycle}"
            break


def outer_layer_violations(src):
    for layer in ("application", "infrastructure"):
        root = src / layer
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.rs")):
            source = re.split(r"#\s*!?\s*\[\s*cfg\s*\(\s*(?:all\s*\(\s*)?test\b", path.read_text(), maxsplit=1)[0]
            source = re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: "\n" * m[0].count("\n"), source, flags=re.S)
            forbidden = r"\bcrate\s*::\s*(?:notes|folders|corrections|workspace_repository|jobs)\b"
            if layer == "application":
                forbidden = r"\bcrate\s*::\s*(?:infrastructure|notes|folders|storage|corrections|workspace_repository|platform_fs|jobs)\b|\b(?:reqwest|rusqlite|libc|tauri|after_process_runtime)\s*::|\bstd\s*::\s*(?:fs|os|process|net|env)\b"
            for match in re.finditer(forbidden, source):
                yield f"{path}:{source[:match.start()].count(chr(10)) + 1}: {layer} depends on a concrete outer implementation/facade"


def capture_boundary_violations(src):
    # Lifecycle may coordinate file adapters, but never select a driver or let
    # that driver mutate its state. The backend contract is an independent leaf.
    patterns = {
        "capture.rs": r"\bcfg!?\s*\([^)]*\b(?:windows|unix|target_os|target_arch|target_family)\b|\b(?:wasapi|windows|libpulse_binding)\s*::|\bcrate\s*::\s*(?:platform|capture_platform)\b",
        "capture_backend.rs": r"\bstd\s*::\s*(?:fs|os|process|net|env)\b|\b(?:wasapi|windows|tauri|libc|libpulse_binding)\s*::|\bcfg!?\s*\([^)]*\b(?:windows|unix|target_os)\b|\bcrate\s*::\s*capture\b",
        "capture/linux.rs": r"\bShared\b|\bRecordingStatus\b|\bcrate\s*::\s*capture\s*::",
        "capture/windows.rs": r"\bShared\b|\bRecordingStatus\b|\bcrate\s*::\s*capture\s*::",
    }
    for name, pattern in patterns.items():
        path = src / name
        if not path.exists():
            continue
        source = re.split(r"#\[cfg\(test\)\]\s*mod\s+tests\b", path.read_text(), maxsplit=1)[0]
        source = re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: "\n" * m[0].count("\n"), source, flags=re.S)
        for match in re.finditer(pattern, source):
            yield f"{path}:{source[:match.start()].count(chr(10)) + 1}: capture boundary depends on a concrete driver or recorder state"
        if name == "capture_backend.rs":
            for match in re.finditer(r"\bstd\s*::\s*\{([^}]+)\}", source, re.S):
                if re.search(r"\b(?:fs|os|process|net|env)\b", match[1]):
                    yield f"{path}: capture port has a grouped OS/I/O dependency"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain-root", type=Path, default=Path(__file__).resolve().parents[1] / "rust-core/src/domain")
    args = parser.parse_args()
    if not args.domain_root.is_dir() or not any(args.domain_root.rglob("*.rs")):
        parser.error("Domain source directory is missing or empty")
    errors = list(violations(args.domain_root)) + list(outer_layer_violations(args.domain_root.parent))
    errors += list(capture_boundary_violations(Path(__file__).resolve().parents[1] / "desktop/src-tauri/src"))
    if errors:
        raise SystemExit("\n".join(errors))
    print("PASS: domain/application/infrastructure layer boundaries")


if __name__ == "__main__":
    main()
