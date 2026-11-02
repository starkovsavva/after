# Pinned Linux CPython before runtime installation

## Artifact and trust root

Linux x86_64 GNU uses Python build standalone CPython 3.12.16, release 20261026:
[official release](https://github.com/astral-sh/python-build-standalone/releases/tag/20261026),
[release metadata](https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/20261026).
The selected `x86_64-unknown-linux-gnu-install_only_stripped.tar.gz` asset has size
34,505,639 and SHA-256 `ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20`.
These values came from the official release asset metadata and were checked
against the actual downloaded archive before inventory generation or execution.

`backend/python-runtime-linux-x86_64.json` is the complete reviewed file inventory,
compiled into `platform/linux/python_runtime.rs`. The adapter explicitly selects
ELF library `lib/libpython3.12.so.1.0` and required bootstrap files. Other Linux
architectures/libc targets fail without a pinned policy. The existing macOS policy,
layout, ABI and entry points remain unchanged.

The shared Unix verifier handles hashes, ownership/mode, unexpected files and
aliases. Linux exposes the same `--posle-verify-python-runtime <absolute-tree>`
CLI mode as macOS. No local manifest can authorize different contents.

## Inventory generation

`pin_python_runtime.py --policy <committed-policy> --archive <archive>` validates
archive size/hash before parsing. Target selection permits only the reviewed
Darwin and Linux layouts and requires the directory target to match. Linux
terminfo contains case-distinct filenames; exact duplicates still fail, while
Darwin continues to reject case-folding collisions. Traversal, external/cyclic
aliases and special files remain rejected. `--check` does not write.

## Evidence and limits

`check-linux-python-runtime.py --download` downloads only the pinned HTTPS asset,
checks the complete generated inventory, extracts into private temporary storage,
and invokes the native verifier before any downloaded code runs. It then checks
CPython's exact version/base prefix, SSL import and an isolated venv without pip,
re-verifies the base, and rejects extra files and same-size stdlib tampering.
Its child environment omits loader/Python overrides and credentials.

This passed on Arch with the actual artifact. The same fixture is configured for
Ubuntu CI; no remote CI result is claimed. No speech dependencies/models or
personal data are used. This is not an installer, venv-package integrity proof,
embedded ABI test or ASR capability. A transactional installer with rollback,
verified execution adapter and queued speech integration are still required.
