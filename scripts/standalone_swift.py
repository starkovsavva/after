"""Use unchanged service bodies in SDK-only compiler fixtures.

The fixtures have canonical text helpers and compile domain models directly.
Only same-package visibility and the corresponding module imports are removed;
native imports, trust checks, conditional branches and implementation stay intact.
"""
from pathlib import Path
import re


def source(path: Path) -> str:
    text = path.read_text()
    text = re.sub(r"^import (AfterPlatform|AfterLocalization|AfterCore)\n", "", text, flags=re.M)
    return re.sub(r"^(\s*)package ", r"\1", text, flags=re.M)
