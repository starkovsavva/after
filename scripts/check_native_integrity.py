#!/usr/bin/env python3
"""Exercise the shipping pre-dlopen gate with ad-hoc signed constructor fixtures.

Only synthetic code and disposable /private/tmp bundles are used. No account,
model, certificate, Keychain, application install, or capture API is accessed.
"""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

import signing

PROJECT = Path(__file__).resolve().parents[1]


def command(*arguments: str | Path) -> None:
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Fixture command failed: {arguments[0]}: {result.stderr}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="posle-native-integrity-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        marker = root / "constructor.marker"
        source = root / "fixture.c"
        libraries = []
        for value in ("A", "B"):
            source.write_text('#include <stdlib.h>\n#include <fcntl.h>\n#include <unistd.h>\n'
                              '__attribute__((constructor)) static void start(void) {'
                              'const char *p=getenv("POSLE_INTEGRITY_MARKER");if(p){int fd=open(p,O_WRONLY|O_CREAT|O_APPEND,0600);'
                              f'if(fd>=0){{write(fd,"{value}",1);close(fd);}}}}}}\nint fixture_value(void){{return {ord(value)};}}\n')
            library = root / f"fixture-{value}.dylib"
            command("clang", "-dynamiclib", source, "-o", library)
            command("install_name_tool", "-id", "@rpath/libposle_core.dylib", library)
            signing.sign_core_library(library, signing.Identity("-"))
            libraries.append(library)
        original, replacement = libraries
        app = root / "Fixture.app"
        macos = app / "Contents/MacOS"
        frameworks = app / "Contents/Frameworks"
        macos.mkdir(parents=True); frameworks.mkdir()
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "Fixture", "CFBundleIdentifier": "app.posle.integrity-fixture", "CFBundlePackageType": "APPL"}, stream)
        bundled = frameworks / "libposle_core.dylib"
        shutil.copy2(original, bundled)
        digest = signing.core_digest(original)
        swift_main = root / "Main.swift"
        swift_main.write_text('import Darwin\n@main enum Run {static func main(){do {'
                              'let h=try NativeLibraryIntegrity.openCoreLibrary();'
                              'guard let p=dlsym(h,"fixture_value") else {exit(3)};'
                              'let f=unsafeBitCast(p,to:(@convention(c)()->Int32).self);print(f());'
                              '}catch{print(error.localizedDescription);exit(2)}}}')
        binary = macos / "Fixture"

        def build(section: bytes | None) -> None:
            binary.unlink(missing_ok=True)
            arguments = ["swiftc", "-parse-as-library", "-module-cache-path", str(root / "module-cache"),
                         str(PROJECT / "Sources/PosleApp/NativeLibraryIntegrity.swift"),
                         str(PROJECT / "scripts/fixtures/CanonicalLocalization.swift"), str(swift_main), "-o", str(binary)]
            if section is not None:
                digest_file = root / "core.sha256"; digest_file.write_bytes(section)
                arguments += ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__posle_core", "-Xlinker", str(digest_file)]
            command(*arguments)
            command("/usr/bin/codesign", "--force", "--sign", "-", binary)

        env = os.environ.copy()
        for key in list(env):
            if any(word in key.upper() for word in ("API_KEY", "ACCESS_TOKEN", "SECRET", "PASSWORD", "CREDENTIAL")) or key.startswith("DYLD_"):
                env.pop(key, None)
        env["POSLE_INTEGRITY_MARKER"] = str(marker)

        def run(name: str, *, accepted: bool, constructor: bytes = b"", extra: dict[str, str] | None = None) -> None:
            marker.unlink(missing_ok=True)
            result = subprocess.run([str(binary)], env=env | (extra or {}), capture_output=True, text=True, timeout=15)
            actual = marker.read_bytes() if marker.exists() else b""
            if (result.returncode == 0) != accepted or actual != constructor:
                raise RuntimeError(f"{name}: exit={result.returncode}, constructor={actual!r}, stdout={result.stdout!r}, stderr={result.stderr!r}")
            print("PASS:", name, flush=True)

        build(digest.encode())
        # Exercise the real inside-out app signer: the library's final signed
        # bytes must stay identical after the executable embeds their digest.
        engine_source = root / "engine.c"; engine_source.write_text("int main(void){return 0;}")
        command("clang", engine_source, "-o", macos / "posle-engine")
        for name in ("После Распознавание.app", "После Обработка.app"):
            contents = app / "Contents/Helpers" / name / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            command("clang", engine_source, "-o", contents / "MacOS/Helper")
            with (contents / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": "Helper", "CFBundleIdentifier": "app.posle.integrity-helper", "CFBundlePackageType": "APPL"}, stream)
        entitlements = root / "entitlements.plist"
        with entitlements.open("wb") as stream: plistlib.dump({}, stream)
        signing.sign_application(app, entitlements, signing.Identity("-"), presigned_core_sha256=digest)
        if signing.core_digest(bundled) != digest:
            raise RuntimeError("Final application signing changed the pinned library")
        command("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        run("valid signed library loads after real final app signing without changing its digest", accepted=True, constructor=b"A")
        run("release ignores a foreign POSLE_RUST_LIBRARY override", accepted=True, constructor=b"A", extra={"POSLE_RUST_LIBRARY": str(replacement)})
        # A replaceable sidecar/Info field cannot authorize different bytes.
        (frameworks / "core.sha256").write_text(signing.core_digest(replacement))
        with (app / "Contents/Info.plist").open("rb") as stream: info = plistlib.load(stream)
        info["PosleCoreSHA256"] = signing.core_digest(replacement)
        with (app / "Contents/Info.plist").open("wb") as stream: plistlib.dump(info, stream)
        shutil.copy2(replacement, bundled)
        run("validly re-signed replacement and matching sidecar/Info fail before constructor", accepted=False)
        (frameworks / "core.sha256").unlink()
        shutil.copy2(original, bundled)
        with bundled.open("ab") as stream: stream.write(b"tampered")
        run("tampered bytes fail before constructor", accepted=False)
        bundled.unlink()
        run("missing library fails before constructor", accepted=False)
        bundled.symlink_to(original)
        run("foreign symlink target fails before constructor even with matching digest", accepted=False)
        bundled.unlink(); bundled.mkdir()
        run("directory masquerading as library fails before constructor", accepted=False)
        bundled.rmdir(); os.mkfifo(bundled)
        run("FIFO masquerading as library fails promptly before constructor", accepted=False)
        bundled.unlink(); shutil.copy2(original, bundled); bundled.chmod(0o666)
        run("group/world-writable library fails before constructor", accepted=False)
        bundled.chmod(0o755)
        saved_frameworks = root / "saved-frameworks"
        frameworks.rename(saved_frameworks); frameworks.symlink_to(saved_frameworks)
        run("symlinked Frameworks fails before constructor", accepted=False)
        frameworks.unlink(); saved_frameworks.rename(frameworks)
        for name, section in [("missing", None), ("malformed", b"g" * 64), ("oversized", digest.encode() + b"\n"), ("wrong", b"0" * 64)]:
            build(section)
            run(name + " executable digest fails before constructor", accepted=False)
        build(digest.encode())

        # Interpose only this disposable process's dlopen call. Swap its original
        # pathname after the production gate has hashed/rechecked it, exactly at
        # the call boundary. The held descriptor must select A, never B.
        interpose = root / "swap.c"
        interpose.write_text('''#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <errno.h>
static off_t checked_seek(int descriptor, off_t offset, int whence) {
 char path[PATH_MAX]; const char *original=getenv("POSLE_FIXTURE_ORIGINAL");
 if(getenv("POSLE_FIXTURE_SEEK_FAIL") && original && fcntl(descriptor,F_GETPATH,path)==0 && strcmp(path,original)==0) {
  errno=ESPIPE; return -1;
 }
 return lseek(descriptor,offset,whence);
}
static void *swap_open(const char *path, int mode) {
 if (path && strncmp(path,"/dev/fd/",8)==0) {
  const char *a=getenv("POSLE_FIXTURE_ORIGINAL"), *b=getenv("POSLE_FIXTURE_REPLACEMENT"), *old=getenv("POSLE_FIXTURE_RENAMED");
  if(a&&b&&old) { if(rename(a,old)||rename(b,a)) abort(); }
 }
 return dlopen(path,mode);
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; } records[]
__attribute__((section("__DATA,__interpose"))) = {
 {(const void *)&swap_open,(const void *)&dlopen}, {(const void *)&checked_seek,(const void *)&lseek}
};
''')
        shim = root / "swap.dylib"; command("clang", "-dynamiclib", interpose, "-o", shim)
        run("failed verified-FD rewind fails before constructor", accepted=False, extra={
            "DYLD_INSERT_LIBRARIES": str(shim), "POSLE_FIXTURE_ORIGINAL": str(bundled), "POSLE_FIXTURE_SEEK_FAIL": "1",
        })
        swapped = root / "replacement.dylib"; shutil.copy2(replacement, swapped)
        run("pathname replacement after hash cannot run replacement constructor", accepted=True, constructor=b"A", extra={
            "DYLD_INSERT_LIBRARIES": str(shim), "POSLE_FIXTURE_ORIGINAL": str(bundled),
            "POSLE_FIXTURE_REPLACEMENT": str(swapped), "POSLE_FIXTURE_RENAMED": str(root / "renamed-original.dylib"),
        })
        if not (root / "renamed-original.dylib").is_file() or swapped.exists() or bundled.read_bytes() != replacement.read_bytes():
            raise RuntimeError("Pathname replacement interposition did not actually run")
        print("PASS: native integrity constructor checks (ad-hoc fixtures only)")


if __name__ == "__main__":
    main()
