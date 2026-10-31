#!/usr/bin/env python3
"""Exercise the macOS-only, non-production socket identity probe on loopback.

Uses a disposable server process and sends no user data. This measures only
whether the kernel exposes the accepted TCP tuple, not whether a complete
production authorization scheme is safe.
"""
import os
import argparse
import platform
from pathlib import Path
import socket
import subprocess
import tempfile
import time


SERVER = r'''
import select, socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
print(s.getsockname()[1], flush=True)
while True:
    ready, _, _ = select.select([s, sys.stdin] if s else [sys.stdin], [], [])
    if sys.stdin in ready:
        if sys.stdin.readline().strip() != "release": sys.exit(4)
        if s: s.close(); s = None
        print("released", flush=True)
    if s and s in ready:
        conn, _ = s.accept()
        conn.settimeout(3)
        try:
            data = conn.recv(1)
            if data: sys.exit(3)
        finally:
            conn.close()
'''


def check_ollama(binary: Path, probe: Path, temp_dir: str):
    """Optional local runtime smoke; outbound traffic is restricted to loopback."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    temp_dir = os.path.realpath(temp_dir)
    profile = (f'(version 1) (allow default) (deny file-write*) '
               f'(allow file-write* (subpath "{temp_dir}")) (deny network*) '
               '(allow network-inbound (local ip "localhost:*")) '
               '(allow network-outbound (remote ip "localhost:*"))')
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": temp_dir,
                   "OLLAMA_HOST": f"127.0.0.1:{port}",
                   "OLLAMA_MODELS": str(Path(temp_dir) / "models"),
                   "OLLAMA_TMPDIR": temp_dir, "OLLAMA_NO_CLOUD": "1", "OLLAMA_NOPRUNE": "1"}
    server = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, str(binary), "serve"],
                              cwd=temp_dir, env=environment, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # Ollama may bind before its initialization finishes and before it can
        # accept connections. All retries transmit zero payload bytes.
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if server.poll() is not None:
                raise AssertionError("Ollama exited before accepting connections")
            result = subprocess.run([str(probe), str(server.pid), str(port), "--http"],
                                    capture_output=True, timeout=15)
            if result.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise AssertionError("Ollama did not become ready")
        result = subprocess.run([str(probe), str(os.getpid()), str(port)],
                                capture_output=True, timeout=6)
        if result.returncode != 1:
            raise AssertionError("unrelated PID was not rejected for Ollama")
        print("PASS: actual Ollama served a harmless HTTP request on the verified socket; unrelated process rejected")
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ollama", type=Path, help="optional path to an existing Ollama executable")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This probe requires macOS libproc")
    source = Path(__file__).with_name("probe_managed_socket.c")
    with tempfile.TemporaryDirectory(prefix="after-socket-probe-") as tmp:
        binary = Path(tmp) / "probe"
        subprocess.run(["/usr/bin/clang", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True)
        server = subprocess.Popen(["/usr/bin/python3", "-u", "-c", SERVER, "0"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        replacement = None
        try:
            port = int(server.stdout.readline().strip())
            for label, pid, expected in (("matching server", server.pid, 0),
                                         ("wrong process", os.getpid(), 1)):
                result = subprocess.run([str(binary), str(pid), str(port)], text=True,
                                        capture_output=True, timeout=6)
                if result.returncode != expected:
                    raise AssertionError(f"{label}: unexpected exit {result.returncode}: {result.stderr}")
                print(f"PASS: {label} {'accepted' if expected == 0 else 'rejected'}")
            if server.poll() is not None:
                raise AssertionError("server stopped or received unexpected data")
            server.stdin.write("release\n")
            server.stdin.flush()
            if server.stdout.readline().strip() != "released":
                raise AssertionError("original server did not release its listener")
            replacement = subprocess.Popen(["/usr/bin/python3", "-u", "-c", SERVER, str(port)],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
            if int(replacement.stdout.readline().strip()) != port:
                raise AssertionError("replacement did not bind to original port")
            for label, pid, expected in (("old owner after port reuse", server.pid, 1),
                                         ("replacement owner", replacement.pid, 0)):
                result = subprocess.run([str(binary), str(pid), str(port)], text=True,
                                        capture_output=True, timeout=6)
                if result.returncode != expected:
                    raise AssertionError(f"{label}: unexpected exit {result.returncode}: {result.stderr}")
                print(f"PASS: {label} {'accepted' if expected == 0 else 'rejected'}")
            if server.poll() is not None or replacement.poll() is not None:
                raise AssertionError("a server stopped or received unexpected data")
        finally:
            for process in (server, replacement):
                if process is not None:
                    process.terminate()
                    process.wait(timeout=5)
        if args.ollama:
            check_ollama(args.ollama.resolve(strict=True), binary, tmp)


if __name__ == "__main__":
    main()
