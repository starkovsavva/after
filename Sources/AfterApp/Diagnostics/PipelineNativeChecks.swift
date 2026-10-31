import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AppKit
import Foundation

/// Real subprocess stdin and cancellation checks. Inputs are generated here;
/// no microphone, account, Keychain or external service is involved.
@MainActor
enum PipelineNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview") else {
            throw AppError.message("Pipeline checks require --preview")
        }
        let watchdog = PipelineWatchdog()
        watchdog.start()
        defer { watchdog.finish() }
        let payload = Data(repeating: 65, count: 256 * 1024)
        let runner = ProcessRunner()
        for _ in 0..<3 {
            runner.resetCancellation()
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], input: payload) { _ in }
        }
        print("PASS: child exits before reading 256 KB stdin; no SIGPIPE, deadlock or retained writer")
        fflush(stdout)

        do {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], input: payload) { _ in }
            throw AppError.message("Failed child was reported as successful")
        } catch {
            guard error.localizedDescription != "Failed child was reported as successful" else { throw error }
        }
        let message = String(repeating: "synthetic-input-", count: 20_000)
        let json = try JSONSerialization.data(withJSONObject: ["event": "done", "message": message])
        let result = try await runner.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], input: json) { _ in }
        guard result?.event == "done", result?.message == message else {
            throw AppError.message("Stdin payload was truncated or retry did not recover")
        }
        print("PASS: failed stdin child releases resources; next run preserves an entire large JSON command")
        fflush(stdout)

        runner.resetCancellation()
        var cancellationIssued = false
        let cancellation = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            cancellationIssued = true
            runner.cancel()
        }
        defer { cancellation.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        var failed = false
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-I", "-c", "import time; time.sleep(30)"], input: payload) { _ in }
        } catch { failed = true }
        guard failed, cancellationIssued, started.duration(to: clock.now) < .seconds(5) else {
            throw AppError.message("Cancelling a child blocked on stdin did not release the writer")
        }
        runner.resetCancellation()
        _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], input: payload) { _ in }
        print("PASS: cancellation unblocks stdin writer and a subsequent job can start")
        print("3 native pipeline groups passed")
        fflush(stdout)
    }
}

/// A broken pipe-drain implementation must fail this isolated test process
/// instead of leaving CI waiting forever for a continuation that never resumes.
private final class PipelineWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func start() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [self] in
            lock.lock(); let done = finished; lock.unlock()
            if !done {
                fputs("Pipeline check timed out while draining synthetic stdin\n", stderr)
                fflush(stderr)
                exit(2)
            }
        }
    }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
#endif
