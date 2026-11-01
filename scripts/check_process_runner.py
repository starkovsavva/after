#!/usr/bin/env python3
"""Exercise the actual native runner with disposable, account-free subprocesses."""
from pathlib import Path
import os
import subprocess
import tempfile

from standalone_swift import source


ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Foundation

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    func set() { lock.lock(); ready = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func wait() async throws {
        let clock = ContinuousClock(), start = ContinuousClock.now
        while !value {
            guard start.duration(to: clock.now) < .seconds(5) else {
                throw AppError.message("Fixture did not become ready")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@main
private struct RunnerChecks {
    static let python = URL(fileURLWithPath: "/usr/bin/python3")
    static func arguments(_ code: String) -> [String] { ["-I", "-u", "-c", code] }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
    static func successfulRetry(_ runner: ProcessRunner) async throws {
        let result = try await runner.run(python, arguments: arguments("print('{\"event\":\"done\",\"message\":\"retry\"}')")) { _ in }
        try expect(result?.message == "retry", "Runner did not admit a successful retry")
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let runner = ProcessRunner(), ready = Signal()
        let first = Task {
            try await runner.run(python, arguments: arguments("import time; print('{\"event\":\"progress\",\"message\":\"ready\"}'); time.sleep(30)")) { _ in ready.set() }
        }
        try await ready.wait()
        let marker = directory.appendingPathComponent("unadmitted").path
        var overlapRejected = false
        do {
            _ = try await runner.run(python, arguments: arguments("open(" + String(reflecting: marker) + ", 'w').close()")) { _ in }
        } catch is AppError { overlapRejected = true }
        try expect(overlapRejected, "Overlapping run was admitted")
        try expect(!FileManager.default.fileExists(atPath: marker), "Rejected overlap spawned a second process")
        first.cancel()
        do { _ = try await first.value; throw AppError.message("Task cancellation returned success") }
        catch is CancellationError {}
        // Keep the next child alive past the old execution's escalation timer.
        // A stale handler must not terminate a later owner of this runner.
        let later = try await runner.run(python, arguments: arguments("import time; time.sleep(2.3); print('{\"event\":\"done\",\"message\":\"later owner\"}')")) { _ in }
        try expect(later?.message == "later owner", "Old cancellation reached a later execution")
        print("PASS: overlapping run never starts; Task cancellation owns only its child; retry succeeds")

        let closed = Signal()
        let ignored = Task {
            try await runner.run(python, arguments: arguments("import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('{\"event\":\"progress\",\"message\":\"ready\"}'); os.close(1); os.close(2); time.sleep(30)")) { _ in closed.set() }
        }
        try await closed.wait()
        let clock = ContinuousClock(), start = ContinuousClock.now
        ignored.cancel()
        do { _ = try await ignored.value; throw AppError.message("Ignored cancellation returned success") }
        catch is CancellationError {}
        try expect(start.duration(to: clock.now) < .seconds(5), "Cancellation hung after stdout/stderr closed")
        try await successfulRetry(runner)
        print("PASS: a child ignoring SIGTERM is stopped after closed pipes; no stale cancellation reaches retry")

        let callback = ProcessRunner()
        do {
            _ = try await callback.run(python, arguments: arguments("import time; print('{\"event\":\"progress\",\"message\":\"cancel\"}'); time.sleep(30)")) { _ in callback.cancel() }
            throw AppError.message("Reentrant cancellation returned success")
        } catch is CancellationError {}
        callback.resetCancellation()
        try await successfulRetry(callback)
        print("PASS: event callback cancellation is reentrant and reset does not retain an old process")

        for newline in [false, true] {
            do {
                _ = try await runner.run(python, arguments: arguments("import sys,time; sys.stdout.write('x' * (16*1024*1024+1)" + (newline ? " + '\\n'" : "") + "); sys.stdout.flush(); time.sleep(30)")) { _ in }
                throw AppError.message("Oversized worker frame returned success")
            } catch let failure as WorkerFailure {
                try expect(failure.message.contains("размер"), "Oversize failure lost its explicit diagnosis")
            }
            try await successfulRetry(runner)
        }
        print("PASS: oversized frames with/without newline fail explicitly, drain and release admission")

        let stream = try await runner.run(python, arguments: arguments("import sys; line='x'*8192+'\\n'; [sys.stdout.write(line) for _ in range(2050)]; print('{\"event\":\"done\",\"message\":\"streamed\"}')")) { _ in }
        try expect(stream?.message == "streamed", "Frame limit incorrectly became a total-output limit")
        print("PASS: a progress stream larger than the frame limit remains valid and delivers its final result")

        let payload = Data(repeating: 65, count: 256 * 1024)
        for _ in 0..<3 {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], input: payload) { _ in }
        }
        do {
            _ = try await runner.run(directory.appendingPathComponent("missing"), arguments: [], input: payload) { _ in }
            throw AppError.message("Missing executable returned success")
        } catch is CocoaError {}
        let message = String(repeating: "synthetic-input-", count: 20_000)
        let data = try JSONSerialization.data(withJSONObject: ["event":"done", "message":message])
        let full = try await runner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], input: data) { _ in }
        try expect(full?.message == message, "A large legitimate command was truncated")
        let metadata: [String: Any] = ["http_status":200, "content_type":"text/event-stream", "wire":"sse",
            "terminal_status":"failed", "terminal_output":"array", "response_bytes":40, "events":1,
            "output_text_delta":0, "output_text_done":0, "content_part_done":0, "output_item_done":0,
            "completed":0, "other_events":1, "terminal_output_items":0, "terminal_text_parts":0,
            "terminal_refusal_parts":0, "terminal_other_parts":0, "accumulated_text_bytes":0]
        let failureData = try JSONSerialization.data(withJSONObject: ["event":"error", "message":"typed failure", "chatGPTDiagnostics":metadata])
        let failureJSON = String(decoding: failureData, as: UTF8.self)
        let plainDiagnostic = Signal()
        do {
            _ = try await runner.run(python, arguments: arguments("import sys; print('plain diagnostic'); print(" + String(reflecting: failureJSON) + "); sys.exit(1)")) {
                if $0.message == "plain diagnostic" { plainDiagnostic.set() }
            }
            throw AppError.message("Error exit returned success")
        } catch let failure as WorkerFailure {
            try expect(failure.message == "typed failure", "Typed worker failure changed")
            try expect(failure.chatGPTDiagnostics?.httpStatus == 200 && failure.chatGPTDiagnostics?.wire == "sse",
                "Typed provider diagnostics were lost")
        }
        try expect(plainDiagnostic.value, "Non-JSON diagnostic semantics changed")
        try await successfulRetry(runner)
        print("PASS: setup failure, early stdin close, large JSON and typed diagnostics preserve existing behavior")
    }
}
'''


def main():
    environment = os.environ.copy()
    environment.pop("SDKROOT", None)
    with tempfile.TemporaryDirectory(prefix="after-process-check-", dir="/private/tmp") as temporary:
        directory = Path(temporary)
        contracts = ("WorkerContracts.swift", "ChatGPTDiagnostics.swift", "DictationContracts.swift", "VoiceContracts.swift")
        text = "\n".join(source(ROOT / "Sources/AfterPlatform" / name) for name in contracts)
        native = ROOT / "Sources/AfterPlatformMacOS/Runtime"
        text += "\n" + source(native / "ProcessEnvironment.swift") + "\n" + source(native / "ProcessRunner.swift")
        fixture = directory / "check.swift"
        fixture.write_text(text + CHECKS)
        binary = directory / "check"
        subprocess.run([
            "swiftc", "-module-cache-path", str(directory / "module-cache"), "-parse-as-library",
            *map(str, sorted((ROOT / "Sources/AfterCore").glob("*.swift"))),
            str(ROOT / "scripts/fixtures/CanonicalLocalization.swift"), str(fixture), "-o", str(binary),
        ], cwd=ROOT, env=environment, check=True, timeout=180)
        subprocess.run([str(binary), str(directory)], cwd=ROOT, env=environment, check=True, timeout=35)


if __name__ == "__main__":
    main()
