#!/usr/bin/env python3
"""Opt-in research smoke for the unexposed helper and existing local model.

Run only on macOS with an already built helper, runtime and model. It creates a
private temporary home, denies IP networking and all other filesystem writes,
and uses synthetic text. This does not validate app-to-helper IPC privacy.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    args = parser.parse_args()
    paths = [str(path.resolve(strict=True)) for path in (args.helper, args.runtime, args.model)]
    with tempfile.TemporaryDirectory(prefix="ah-", dir="/private/tmp") as directory:
        temporary = os.path.realpath(directory)
        profile = (f'(version 1) (allow default) (deny file-write*) '
                   f'(allow file-write* (subpath "{temporary}") (literal "/dev/null")) '
                   '(deny network-inbound (local ip "*:*")) '
                   '(deny network-outbound (remote ip "*:*"))')
        command = ["/usr/bin/sandbox-exec", "-p", profile, *paths, temporary]
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": temporary}
        result = subprocess.run(command, input=b'{"input":["synthetic test"]}',
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=120, env=environment)
        if result.returncode:
            raise RuntimeError("helper failed: " + result.stderr.decode(errors="replace"))
        output = json.loads(result.stdout)
        vector = output["value"]["data"][0]["embedding"]
        if output["ok"] is not True or len(vector) != 1024 or not all(math.isfinite(n) for n in vector):
            raise AssertionError("invalid real model response")
        print("PASS: isolated helper and local model returned 1024 finite dimensions")
        bad_model = Path(temporary) / "bad-model"
        bad_model.write_bytes(b"not a model")
        command[-2] = str(bad_model)
        result = subprocess.run(command, input=b'{"input":["synthetic"]}',
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=15, env=environment)
        if result.returncode == 0 or b"unexpected experimental runtime or model digest" not in result.stderr:
            raise AssertionError("altered model was not rejected")
        print("PASS: altered model rejected before runtime launch")
        if any(Path(temporary).glob("h-*")):
            raise AssertionError("helper did not remove its temporary directory")
        print("PASS: temporary helper directories cleaned")


if __name__ == "__main__":
    main()
