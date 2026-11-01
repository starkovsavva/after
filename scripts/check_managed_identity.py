#!/usr/bin/env python3
"""Verify native names and safe migration of the app-owned model runtime.

Uses only signed temporary copies of system tools; no models, network, user
process enumeration, Application Support changes, microphone, or recording.
"""
from __future__ import annotations

import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
SERVER = "После ИИ"
MODEL = "После Модель"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def seed(source, destination):
    shutil.copyfile(source, destination)
    destination.chmod(0o700)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(destination)],
                   check=True, capture_output=True)


# Compile the actual service and settings types. The custom URLProtocol makes
# every health request synthetic; no installed server or model can be reached.
SERVICE_CHECKS = r'''
private final class SyntheticHealth: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URL] = []
    static var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); if let url = request.url { Self.requests.append(url) }; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main
private enum RuntimeChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments[1] != "--service" {
            print(try ManagedModelRuntime.brandedExecutable(root: URL(fileURLWithPath: CommandLine.arguments[1])).path)
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyntheticHealth.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LocalModelService(session: session)
        defer { service.stop() }
        // Real Swift subprocess boundary: shell startup code must not run before
        // the child reaches its native/runtime integrity checks.
        let envScript = root.deletingLastPathComponent().appendingPathComponent("env-injection.sh")
        let envMarker = root.deletingLastPathComponent().appendingPathComponent("env-injection-ran")
        try Data(": > \"$POSLE_ENV_MARKER\"\n".utf8).write(to: envScript)
        let clean = ProcessEnvironment.withoutSecrets([
            "PATH": "/usr/bin:/bin", "KEEP": "yes", "POSLE_ENV_MARKER": envMarker.path,
            "BASH_ENV": envScript.path, "ENV": envScript.path, "SHELLOPTS": "xtrace",
            "BASH_FUNC_probe%%": "() { :; }", "DYLD_INSERT_LIBRARIES": "not-a-library", "LD_PRELOAD": "not-a-library"
        ])
        guard clean["PATH"] == "/usr/bin:/bin", clean["KEEP"] == "yes",
              clean["BASH_ENV"] == nil, clean["ENV"] == nil, clean["SHELLOPTS"] == nil,
              clean["BASH_FUNC_probe%%"] == nil, clean["DYLD_INSERT_LIBRARIES"] == nil, clean["LD_PRELOAD"] == nil else {
            throw AppError.message("Executable shell/loader overrides survived Swift process sanitization")
        }
        let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", "exit 0"]; shell.environment = clean
        try shell.run(); shell.waitUntilExit()
        guard shell.terminationStatus == 0, !FileManager.default.fileExists(atPath: envMarker.path) else {
            throw AppError.message("Shell startup code ran before child integrity checks")
        }
        func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
            if !condition() { throw AppError.message(detail) }
        }
        // External providers neither inspect the owned runtime nor start a process.
        // Use the real settings resolver, including its provider-specific defaults.
        var settings = AppSettings()
        for (provider, endpoint) in [("ollama", "http://127.0.0.1:11434"), ("lmstudio", "http://127.0.0.1:1234")] {
            settings.localProvider = provider; settings.localEndpoint = ""
            try await service.ensure(root: root, settings: settings)
            try expect(service.baseURL == endpoint, "External provider endpoint changed")
            settings.localEndpoint = "http://localhost:12555/"
            try await service.ensure(root: root, settings: settings)
            try expect(service.baseURL == "http://localhost:12555", "Explicit external endpoint changed")
        }
        try expect(SyntheticHealth.urls.isEmpty && !FileManager.default.fileExists(atPath: root.path), "External route touched managed runtime or health endpoint")
        // ASR can be installed while the independent text runtime is absent.
        // Managed selection must report setup, never reuse the previous external URL.
        settings.localProvider = "managed"
        for missing in [root, root.appendingPathComponent("missing-model")] {
            if missing != root { try FileManager.default.createDirectory(at: missing.appendingPathComponent("runtime"), withIntermediateDirectories: true) }
            do {
                try await service.ensure(root: missing, settings: settings)
                throw AppError.message("Missing managed runtime was accepted")
            } catch {
                try expect(error.localizedDescription.contains("Локальный ИИ «After» не подготовлен") && error.localizedDescription.contains("Подготовить ИИ"), "Missing runtime leaked a Cocoa file error")
            }
            try expect(service.baseURL == "http://127.0.0.1:11436" && SyntheticHealth.urls.isEmpty, "Managed route fell back to external provider or probed before preflight")
        }
        let binary = root.appendingPathComponent("runtime/ollama/ollama")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid synthetic executable".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        do {
            try await service.ensure(root: root, settings: settings)
            throw AppError.message("Nonexecutable runtime was accepted")
        } catch {
            try expect(error.localizedDescription.contains("Не удалось подготовить процессы локального ИИ «After»"), "Nonexecutable runtime leaked a binary error")
        }
        try expect(SyntheticHealth.urls.isEmpty, "Nonexecutable runtime reached health scan")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        do {
            try await service.ensure(root: root, settings: settings)
            throw AppError.message("Invalid executable started")
        } catch {
            try expect(error.localizedDescription.contains("Не удалось запустить локальный ИИ «After»") && !error.localizedDescription.contains("ollama"), "Process launch failure leaked a file error")
        }
        try expect(SyntheticHealth.urls.map(\.absoluteString) == ["http://127.0.0.1:11436/api/tags"], "Managed service contacted an external route")
        try expect(service.baseURL == "http://127.0.0.1:11436", "Managed process failure changed provider")
        print("PASS: real service keeps managed/Ollama/LM Studio routing explicit; missing, nonexecutable and invalid runtime errors are actionable")
    }
}
'''

def main():
    with tempfile.TemporaryDirectory(prefix="posle-managed-identity-") as temporary:
        directory = Path(temporary).resolve()
        from standalone_swift import source as standalone_source
        runtime = PROJECT / "Sources/AfterPlatformMacOS/Runtime"
        contracts = standalone_source(PROJECT / "Sources/AfterPlatform/WorkerContracts.swift")
        swift = directory / "check.swift"
        app_error = contracts[contracts.index("enum AppError:"):contracts.index("struct InstalledLocalModel:")]
        swift.write_text("import Foundation\nimport Darwin\n" + app_error
            + standalone_source(runtime / "ProcessEnvironment.swift")
            + standalone_source(runtime / "ManagedModelRuntime.swift")
            + standalone_source(runtime / "LocalModelService.swift") + SERVICE_CHECKS)
        checker = directory / "check"
        subprocess.run(["swiftc", "-module-cache-path", str(directory / "module-cache"), "-parse-as-library",
                        *sorted((PROJECT / "Sources/AfterCore").glob("*.swift")),
                        str(PROJECT / "scripts/fixtures/CanonicalLocalization.swift"), str(swift), "-o", str(checker)], check=True)
        subprocess.run([str(checker), "--service", str(directory / "service")], check=True)

        def prepare(root, succeeds=True):
            result = subprocess.run([str(checker), str(root)], capture_output=True, text=True)
            assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
            return result.stdout.strip()

        def fixture(label, bin_layout=False):
            root = directory / label
            base = root / "runtime/ollama"
            binary = base / "bin" if bin_layout else base
            binary.mkdir(parents=True)
            for name in ("ollama", "llama-server"):
                seed("/bin/sleep", binary / name)
            return root, binary

        root, binary = fixture("Папка с пробелами")
        original = {name: digest(binary / name) for name in ("ollama", "llama-server")}
        assert prepare(root) == str(binary / SERVER)
        for old, display in (("ollama", SERVER), ("llama-server", MODEL)):
            assert (binary / old).is_symlink()
            assert os.readlink(binary / old) == display
            assert digest(binary / display) == original[old]
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary / display)], check=True)
        identity = {name: (binary / name).stat() for name in (SERVER, MODEL)}
        prepare(root)
        for name, before in identity.items():
            after = (binary / name).stat()
            assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)

        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        library.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        for old, display in (("ollama", SERVER), ("llama-server", MODEL)):
            process = subprocess.Popen([str(binary / old), "5"])
            try:
                time.sleep(0.1)
                assert process.poll() is None
                buffer = ctypes.create_string_buffer(4096)
                assert library.proc_name(process.pid, buffer, len(buffer)) > 0
                assert buffer.value.decode() == display, buffer.value
                assert library.proc_pidpath(process.pid, buffer, len(buffer)) > 0
                assert Path(buffer.value.decode()) == binary / display
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait()
        print("PASS: actual kernel process names and paths are После ИИ / После Модель")

        # An interrupted rename recovers; a freshly extracted update replaces the
        # previous executable without rewriting or re-signing its verified bytes.
        (binary / "ollama").unlink()
        prepare(root)
        (binary / "llama-server").unlink()
        seed("/bin/cat", binary / "llama-server")
        updated = digest(binary / "llama-server")
        prepare(root)
        assert digest(binary / MODEL) == updated
        other, other_binary = fixture("bin layout", True)
        assert prepare(other) == str(other_binary / SERVER)
        print("PASS: repeat launch, interrupted migration, runtime update and bin layout")

        # The installer restores the original name while keeping the old branded
        # file. Brand the new signed executable even if that old file lost +x.
        for old, display in (("ollama", SERVER), ("llama-server", MODEL)):
            (binary / display).chmod(0o600)
            (binary / old).unlink()
            seed("/bin/sleep", binary / old)
            replacement = digest(binary / old)
            assert prepare(root) == str(binary / SERVER)
            assert os.access(binary / display, os.X_OK)
            assert digest(binary / display) == replacement
            assert (binary / old).is_symlink() and os.readlink(binary / old) == display
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary / display)], check=True)
        print("PASS: installed replacements atomically repair owned branded files without executable permission")

        # No foreign runtime, compatibility link, lock file, or branded target is
        # followed or overwritten, including a link that points to a real binary.
        outside = directory / "external-model"
        seed("/bin/sleep", outside)
        expected = digest(outside)
        bad, bad_binary = fixture("bad compatibility link")
        (bad_binary / "llama-server").unlink()
        (bad_binary / "llama-server").symlink_to(outside)
        prepare(bad, False)
        bad, bad_binary = fixture("bad branded target")
        (bad_binary / SERVER).symlink_to(outside)
        prepare(bad, False)
        bad, bad_binary = fixture("bad lock")
        (bad_binary / ".posle-identity.lock").symlink_to(outside)
        prepare(bad, False)
        bad = directory / "bad runtime directory"
        (bad / "runtime").mkdir(parents=True)
        (bad / "runtime/ollama").symlink_to(binary, target_is_directory=True)
        prepare(bad, False)
        assert digest(outside) == expected
        bad, bad_binary = fixture("contended lock")
        with (bad_binary / ".posle-identity.lock").open("w") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            prepare(bad, False)
            assert time.monotonic() - started < 2, "UI must not block behind another migration"
        print("PASS: symlink escapes, unsafe targets and lock contention rejected; external binary unchanged")


if __name__ == "__main__":
    main()
