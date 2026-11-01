#!/usr/bin/env python3
"""Check managed runtime startup ownership using temporary native children.

All HTTP probes use an in-process URLProtocol fixture. No server, model, user
library or external provider is contacted.
"""
from pathlib import Path
import os
import subprocess
import tempfile

from standalone_swift import source


ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Darwin
import Foundation

private final class Health: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var holdAt: Int?
    private static var pending: Health?
    private var stopped = false
    static func configure(hold: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        count = 0; holdAt = hold; pending = nil
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    static func release() {
        lock.lock(); let value = pending; pending = nil; lock.unlock()
        value?.respond(200)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let number = Self.count
        if Self.holdAt == number {
            Self.pending = self; Self.lock.unlock(); return
        }
        Self.lock.unlock()
        respond(number == 1 ? 503 : 200)
    }
    private func respond(_ status: Int) {
        Self.lock.lock(); let active = !stopped; Self.lock.unlock()
        guard active else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
}

@main
private struct ServiceChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let binary = directory.appendingPathComponent("service-child")
        let marker = directory.appendingPathComponent("child.pid")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Health.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var settings = AppSettings(); settings.localProvider = "managed"
        func expect(_ value: Bool, _ text: String) throws { if !value { throw AppError.message(text) } }
        func wait(_ ready: () -> Bool) async throws {
            let clock = ContinuousClock(), start = ContinuousClock.now
            while !ready() {
                try expect(start.duration(to: clock.now) < .seconds(5), "Synthetic service checkpoint timed out")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func childPID() async throws -> pid_t {
            try await wait { (try? String(contentsOf: marker)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil }
            return Int32(try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines))!
        }
        func seed(_ name: String) throws -> URL {
            try? FileManager.default.removeItem(at: marker)
            let root = directory.appendingPathComponent(name)
            let runtime = root.appendingPathComponent("runtime/ollama/bin")
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: binary, to: runtime.appendingPathComponent("ollama"))
            return root
        }

        let normal = LocalModelService(session: session)
        defer { normal.stop() }
        Health.configure()
        let normalRoot = try seed("normal")
        try await normal.ensure(root: normalRoot, settings: settings)
        let normalPID = try await childPID()
        try await normal.ensure(root: normalRoot, settings: settings)
        try expect(try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines) == String(normalPID), "Healthy managed service was restarted")
        normal.stop()
        try await wait { Darwin.kill(normalPID, 0) != 0 }
        print("PASS: a running owned managed process is reused and stops normally")

        let cancelled = LocalModelService(session: session)
        defer { cancelled.stop() }
        Health.configure(hold: 2)
        let cancelledRoot = try seed("cancelled")
        let cancelling = Task { try await cancelled.ensure(root: cancelledRoot, settings: settings) }
        try await wait { Health.isHeld }
        let cancelledPID = try await childPID()
        cancelling.cancel()
        do { try await cancelling.value; throw AppError.message("Cancelled startup returned success") }
        catch is CancellationError {}
        try await wait { Darwin.kill(cancelledPID, 0) != 0 }
        Health.release()
        print("PASS: Task cancellation during startup tears down its owned child")

        let exited = LocalModelService(session: session)
        defer { exited.stop() }
        Health.configure(hold: 2)
        let exitedRoot = try seed("exited")
        let failed = Task { try await exited.ensure(root: exitedRoot, settings: settings) }
        try await wait { Health.isHeld }
        let exitedPID = try await childPID()
        _ = Darwin.kill(exitedPID, SIGTERM)
        try await wait { Darwin.kill(exitedPID, 0) != 0 }
        Health.release()
        var rejected = false
        do { try await failed.value } catch { rejected = true }
        try expect(rejected, "A dead owned process was accepted from a successful unrelated health response")
        print("PASS: HTTP 200 cannot publish startup success after the launched process has exited")

        let superseded = LocalModelService(session: session)
        defer { superseded.stop() }
        Health.configure(hold: 2)
        let supersededRoot = try seed("superseded")
        let stale = Task { try await superseded.ensure(root: supersededRoot, settings: settings) }
        try await wait { Health.isHeld }
        let retainedPID = try await childPID()
        try await superseded.ensure(root: supersededRoot, settings: settings)
        stale.cancel()
        do { try await stale.value; throw AppError.message("Superseded startup returned success") }
        catch is CancellationError {}
        Health.release()
        try expect(Darwin.kill(retainedPID, 0) == 0, "Stale startup cleanup terminated the newer owner's reused process")
        try await superseded.ensure(root: supersededRoot, settings: settings)
        superseded.stop()
        try await wait { Darwin.kill(retainedPID, 0) != 0 }
        print("PASS: superseded startup cancellation preserves a newer owner's reuse of the same process")

        let stopped = LocalModelService(session: session)
        defer { stopped.stop() }
        Health.configure(hold: 2)
        let stoppedRoot = try seed("stopped")
        let stopping = Task { try await stopped.ensure(root: stoppedRoot, settings: settings) }
        try await wait { Health.isHeld }
        let stoppedPID = try await childPID()
        stopped.stop(); Health.release()
        do { try await stopping.value; throw AppError.message("Stopped startup returned success") }
        catch is CancellationError {}
        try await wait { Darwin.kill(stoppedPID, 0) != 0 }
        print("PASS: explicit stop invalidates an in-flight health response")

        Health.configure()
        settings.localProvider = "lmstudio"; settings.localEndpoint = "http://localhost:1234/"
        try await stopped.ensure(root: directory.appendingPathComponent("absent"), settings: settings)
        try expect(stopped.baseURL == "http://localhost:1234" && Health.requestCount == 0,
            "External provider route inspected managed state or contacted its server")
        print("PASS: an explicit external provider remains untouched by managed lifecycle checks")
    }
}
'''


def main():
    environment = os.environ.copy()
    environment.pop("SDKROOT", None)
    with tempfile.TemporaryDirectory(prefix="after-local-service-", dir="/private/tmp") as temporary:
        directory = Path(temporary)
        marker = directory / "child.pid"
        child = directory / "service-child"
        child_source = directory / "child.c"
        child_source.write_text("""#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\nint main(void) { const char *p=getenv(\"POSLE_SERVICE_FIXTURE_PID\"); if(!p)return 2; FILE *f=fopen(p,\"w\"); if(!f)return 3; fprintf(f,\"%d\\n\",getpid()); fclose(f); sleep(30); return 0; }\n""")
        subprocess.run(["clang", str(child_source), "-o", str(child)], check=True, timeout=60)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(child)], check=True, capture_output=True)
        contracts = source(ROOT / "Sources/AfterPlatform/WorkerContracts.swift")
        text = contracts[contracts.index("enum AppError:"):contracts.index("struct InstalledLocalModel:")]
        runtime = ROOT / "Sources/AfterPlatformMacOS/Runtime"
        text += "\n" + "\n".join(source(runtime / name) for name in ("ProcessEnvironment.swift", "ManagedModelRuntime.swift", "LocalModelService.swift"))
        fixture = directory / "check.swift"
        fixture.write_text("import Foundation\n" + text + CHECKS)
        executable = directory / "check"
        subprocess.run([
            "swiftc", "-module-cache-path", str(directory / "module-cache"), "-parse-as-library",
            *map(str, sorted((ROOT / "Sources/AfterCore").glob("*.swift"))),
            str(ROOT / "scripts/fixtures/CanonicalLocalization.swift"), str(fixture), "-o", str(executable),
        ], cwd=ROOT, env=environment, check=True, timeout=180)
        subprocess.run([str(executable), str(directory)], cwd=ROOT,
                       env=environment | {"POSLE_SERVICE_FIXTURE_PID": str(marker)}, check=True, timeout=40)


if __name__ == "__main__":
    main()
