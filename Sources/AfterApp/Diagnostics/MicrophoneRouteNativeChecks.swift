import AfterPlatform
#if DEBUG
@testable import AfterPlatformMacOS
#else
import AfterPlatformMacOS
#endif
#if DEBUG
import AVFoundation
import CoreAudio
import Foundation

/// The actual route controller runs against invented devices and a monotonic
/// clock. Retained callbacks deliberately survive fake input stop(). No audio
/// device, permission, screen capture, account, or real library is accessed.
@MainActor
enum MicrophoneRouteNativeChecks {
    static func run(root: URL) async throws {
        let owned = root.resolvingSymlinksInPath()
        try expect(["/private/tmp", "/tmp"].contains(owned.deletingLastPathComponent().path)
            && owned.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable microphone-route root required")
        try monitorContracts()
        try await switchesAndLateCallbacks()
        try await unavailableAndRecovery()
        try await retriesUseMonotonicBackoff()
        try await stalledInputRestarts()
        try await stopCancelsPendingRetry()
        try await initialFailureCleansUp()
        try await restartRejectsOldMonitor()
        try await cancellationDuringMonitorStart()
        try await stopDuringHandoff()
        try await routerWritesOneM4A(root: root)
        print("11 synthetic microphone route checks passed")
    }

    private static func monitorContracts() throws {
        let queue = DispatchQueue(label: "microphone.monitor.fixture")
        let hal = MonitorHALFixture()
        var monitor: DefaultMicrophoneMonitor? = DefaultMicrophoneMonitor(queue: queue, driver: hal.driver,
            changed: { [hal] value in hal.changes.append(value) })
        weak var released = monitor
        try queue.sync { try expect(try monitor!.start() == .device(id: "A") && hal.entries.count == 6,
            "Default microphone monitor did not register its exact system and device properties") }
        let stale = hal.entries[0].block
        try queue.sync {
            hal.available = false; hal.fire(stale)
            try expect(hal.changes == [.unavailable], "An alive/input change did not revoke the default UID")
            hal.device = 20; hal.available = true; hal.fire(stale)
            try expect(hal.changes.last == .device(id: "B") && hal.removed == 4,
                "Changing default input retained old device listeners or chose the wrong UID")
            hal.available = false
            try expect(monitor!.current() == .unavailable && hal.changes.count == 2,
                "current() must reread availability without publishing a callback")
            monitor!.stop(); hal.fire(stale)
            try expect(hal.entries.isEmpty && hal.changes.count == 2, "Stop retained listeners or admitted a queued callback")
            hal.available = true
            _ = try monitor!.start()
            hal.device = 10; hal.fire(stale)
            try expect(hal.changes.count == 2, "An old listener generation changed a restarted monitor")
        }
        let afterRelease = hal.entries[0].block
        monitor = nil
        try expect(released == nil && hal.entries.isEmpty, "HAL listener blocks retained the monitor or survived deinit")
        queue.sync { hal.fire(afterRelease) }
        let failed = MonitorHALFixture()
        failed.failAt = 4
        let retry = DefaultMicrophoneMonitor(queue: queue, driver: failed.driver, changed: { _ in })
        try queue.sync {
            do { _ = try retry.start(); throw AppError.message("A failed HAL listener registration did not throw") }
            catch let error as NSError where error.domain == NSOSStatusErrorDomain { }
            try expect(failed.entries.isEmpty && failed.removed == 3, "Partial HAL listener setup did not roll back exactly")
            failed.failAt = nil; failed.device = 0
            try expect(try retry.start() == .unavailable && failed.entries.count == 2,
                "No-input startup must watch system changes without choosing another device")
            retry.stop(); retry.stop()
        }
        print("PASS: fake HAL exact listener removal, rollback, no-input state, silent poll and stale/deinit callbacks")
    }

    private static func switchesAndLateCallbacks() async throws {
        let fixture = RouteFixture()
        let capture = fixture.capture()
        try await capture.start()
        let a = try fixture.route("A")
        await a.packet(11)
        await capture.drainForChecks()
        try expect(fixture.states.last == .active(name: "A"), "The first PCM must activate its own route")
        await fixture.monitor.publish(.device(id: "B"))
        await capture.drainForChecks()
        let b = try fixture.route("B")
        await b.packet(22)
        await capture.drainForChecks()
        await fixture.monitor.publish(.device(id: "C"))
        await capture.drainForChecks()
        let c = try fixture.route("C")
        await a.packet(91); await a.interrupt()
        await b.packet(92); await b.interrupt()
        await capture.drainForChecks()
        try expect(fixture.delivered == [11, 22] && fixture.routeCount == 3,
            "Late PCM or runtime callbacks from A/B changed the replacement C route")
        await c.packet(33)
        await capture.drainForChecks()
        try expect(fixture.delivered == [11, 22, 33] && fixture.states.last == .active(name: "C"),
            "Only C may deliver PCM and publish active after the second handoff")
        await capture.stop()
        let states = fixture.states
        let silence = fixture.silenceTimes.count
        await c.packet(93); await c.interrupt()
        await fixture.monitor.publish(.device(id: "A"))
        fixture.time = 1000
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.delivered == [11, 22, 33] && fixture.states == states
            && fixture.silenceTimes.count == silence && fixture.routeCount == 3,
            "Stop admitted a retained packet/runtime/monitor callback or timer retry")
        try expect(fixture.inputs.allSatisfy { $0.stops > 0 } && fixture.monitor.stops == 1,
            "Stop did not close every selected input and its monitor")
        print("PASS: microphone A→B→C, active state and late callback/Stop generation gates")
    }

    private static func unavailableAndRecovery() async throws {
        let fixture = RouteFixture()
        let capture = fixture.capture()
        try await capture.start()
        let a = try fixture.route("A")
        await a.packet(1); await capture.drainForChecks()
        await fixture.monitor.publish(.unavailable)
        await capture.drainForChecks()
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.states.last == .unavailable && a.stops == 1 && !fixture.silenceTimes.isEmpty,
            "An absent input must stop only its route, report unavailable, and advance microphone silence")
        // Polling must recover even if HAL's notification preceded AVFoundation
        // readiness or the notification was coalesced; no unrelated UID is used.
        fixture.selection = .device(id: "B")
        fixture.time += 1
        await capture.tickForChecks(); await capture.drainForChecks()
        await (try fixture.route("B")).packet(2)
        await capture.drainForChecks()
        try expect(fixture.delivered == [1, 2] && fixture.states.last == .active(name: "B"),
            "Polling failed to reopen the exact newly available default UID")
        await capture.stop()
        print("PASS: no-device interval produces silence and polling recovers the exact default input")
    }

    private static func retriesUseMonotonicBackoff() async throws {
        let fixture = RouteFixture()
        fixture.failures["B"] = 2
        let capture = fixture.capture()
        try await capture.start()
        await fixture.monitor.publish(.device(id: "B")); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 1 && fixture.states.last == .unavailable,
            "The first B open failure must remain recoverable")
        fixture.time = 100.249
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 1, "A failed input retried before its first monotonic deadline")
        fixture.time = 100.251
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 2, "The first bounded retry did not run")
        fixture.time = 100.750
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 2, "The second failure did not increase retry backoff")
        fixture.time = 100.752
        await capture.tickForChecks(); await capture.drainForChecks()
        let recovered = try fixture.route("B")
        await recovered.packet(3); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 3 && fixture.states.last == .active(name: "B")
            && fixture.delivered == [3], "B did not recover after its monotonic backoff")
        try expect(fixture.inputs.filter { $0.name == "B" }.dropLast().allSatisfy { $0.stops == 1 },
            "Failed B sessions were retained during retry")
        await capture.stop()
        print("PASS: failed input opens use increasing monotonic backoff and recover without a new recording")
    }

    private static func stalledInputRestarts() async throws {
        let fixture = RouteFixture()
        let capture = fixture.capture()
        try await capture.start()
        let old = try fixture.route("A")
        await old.packet(1); await capture.drainForChecks()
        fixture.time = 102.999
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.attempts("A") == 1, "A healthy input was restarted before the stall threshold")
        fixture.time = 103.001
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(old.stops == 1 && fixture.states.last == .unavailable,
            "A stopped PCM stream remained falsely active after three seconds")
        fixture.time = 103.252
        await capture.tickForChecks(); await capture.drainForChecks()
        let replacement = try fixture.route("A")
        await old.packet(90); await old.interrupt()
        await replacement.packet(2); await capture.drainForChecks()
        try expect(fixture.attempts("A") == 2 && fixture.delivered == [1, 2]
            && fixture.states.last == .active(name: "A"), "A stalled route did not recover with a fresh callback generation")
        await capture.stop()
        print("PASS: stalled PCM restarts its input after the threshold and rejects the old session")
    }

    private static func stopCancelsPendingRetry() async throws {
        let fixture = RouteFixture()
        fixture.failures["B"] = 5
        let capture = fixture.capture()
        try await capture.start()
        await fixture.monitor.publish(.device(id: "B")); await capture.drainForChecks()
        let failed = try fixture.route("B")
        await capture.stop()
        let silence = fixture.silenceTimes.count
        fixture.time = 1000
        await failed.packet(99); await failed.interrupt()
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 1 && fixture.delivered.isEmpty
            && fixture.silenceTimes.count == silence, "Stop allowed a pending retry or stale input callback to restart capture")
        print("PASS: Stop cancels delayed microphone retries and silence callbacks")
    }

    private static func initialFailureCleansUp() async throws {
        for monitorFailure in [true, false] {
            let fixture = RouteFixture()
            fixture.monitorStartFails = monitorFailure
            if !monitorFailure { fixture.failures["A"] = 1 }
            let capture = fixture.capture()
            do { try await capture.start(); throw AppError.message("A synthetic initial failure unexpectedly succeeded") }
            catch let error as RouteFixture.Failure { _ = error }
            try expect(fixture.monitor.stops == 1 && fixture.inputs.allSatisfy { $0.stops == 1 },
                "Initial monitor/input failure left a live listener or input session")
            await fixture.monitor.publish(.device(id: "B"))
            for input in fixture.inputs { await input.packet(9); await input.interrupt() }
            fixture.time = 1000
            await capture.tickForChecks(); await capture.drainForChecks()
            try expect(fixture.delivered.isEmpty && fixture.attempts("B") == 0,
                "Initial failure admitted a retained input callback or later monitor event")
            await capture.stop()
        }
        print("PASS: initial monitor and input-start failures clean up callbacks and sessions")
    }

    private static func restartRejectsOldMonitor() async throws {
        let fixture = RouteFixture()
        let capture = fixture.capture()
        try await capture.start()
        let old = fixture.monitor
        await capture.stop()
        try await capture.start()
        await old.publish(.device(id: "B"), updateSelection: false)
        await capture.drainForChecks()
        try expect(fixture.attempts("A") == 2 && fixture.attempts("B") == 0,
            "A retained monitor callback from the previous recording changed the new lifecycle")
        await capture.stop()
        print("PASS: restarting capture rejects monitor callbacks retained by the previous lifecycle")
    }

    private static func cancellationDuringMonitorStart() async throws {
        let fixture = RouteFixture()
        let blocked = RouteBlockingGate()
        fixture.monitorStartGate = blocked
        fixture.emitOnStartIDs = ["A"]
        let capture = fixture.capture()
        let start = Task { try await capture.start() }
        do { try await wait { blocked.entered } }
        catch { start.cancel(); blocked.release(); _ = await start.result; throw error }
        start.cancel()
        blocked.release()
        do { try await start.value; throw AppError.message("Canceled microphone startup unexpectedly succeeded") }
        catch is CancellationError { }
        await capture.drainForChecks()
        try expect(fixture.delivered.isEmpty && fixture.monitor.stops == 1
            && fixture.inputs.allSatisfy { $0.stops == 1 },
            "A canceled blocked monitor startup reopened its PCM gate or leaked an input")
        await capture.stop()
        print("PASS: cancellation while monitor.start blocks cannot reopen the PCM gate")
    }

    private static func stopDuringHandoff() async throws {
        let fixture = RouteFixture()
        let blocked = RouteBlockingGate()
        fixture.stopGates["A"] = blocked
        fixture.emitOnStartIDs = ["B"]
        let capture = fixture.capture()
        try await capture.start()
        let change = Task { await fixture.monitor.publish(.device(id: "B")) }
        do { try await wait { blocked.entered } }
        catch { blocked.release(); await change.value; await capture.stop(); throw error }
        let stop = Task { await capture.stop() }
        do { try await wait { capture.stopRequestedForChecks() } }
        catch { blocked.release(); await change.value; await stop.value; throw error }
        blocked.release()
        await change.value; await stop.value
        await capture.drainForChecks()
        try expect(fixture.delivered.isEmpty && fixture.attempts("B") == 0,
            "Completing a blocked A.stop after Stop reopened B or delivered its startup PCM")
        fixture.time = 1000
        await capture.tickForChecks(); await capture.drainForChecks()
        try expect(fixture.attempts("B") == 0, "A delayed handoff retry escaped the sticky Stop gate")
        print("PASS: Stop during a blocked handoff prevents the replacement input from opening")
    }

    private static func wait(_ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("Synthetic microphone handoff timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func routerWritesOneM4A(root: URL) async throws {
        let directory = root.appendingPathComponent("microphone-routes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("handoff.m4a")
        let fixture = RouteFixture()
        fixture.time = 1000
        let sink = try CaptureSink(url: source, systemAudio: false)
        sink.failed = { [fixture] message in fixture.failure(message) }
        let capture = fixture.capture(sink: sink)
        do {
            try await capture.start()
            let a = try fixture.route("A")
            for index in 0..<20 {
                fixture.time = 1000 + Double(index) / 100
                await a.packet(fixture.time, frames: 480, frequency: 700)
                try await Task.sleep(for: .milliseconds(2))
            }
            await fixture.monitor.publish(.unavailable)
            await capture.drainForChecks()
            for index in 4...8 {
                fixture.time = 1000 + Double(index) / 20
                await capture.tickForChecks(); await capture.drainForChecks()
            }
            await fixture.monitor.publish(.device(id: "B"))
            await capture.drainForChecks()
            let b = try fixture.route("B")
            await a.packet(1000.45, frames: 480, frequency: 700)
            await a.interrupt()
            for index in 40..<60 {
                fixture.time = 1000 + Double(index) / 100
                await b.packet(fixture.time, frames: 480, frequency: 1500)
                try await Task.sleep(for: .milliseconds(2))
            }
            fixture.time = 1000.6
            await capture.stop()
            try await sink.finish()
        } catch {
            await capture.stop(); await sink.cancel(); throw error
        }
        try expect(fixture.failuresReceived.isEmpty && fixture.delivered.count == 40,
            "The real M4A writer received a stale route packet or reported a capture failure")
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try expect(tracks.count == 1, "Microphone handoff created a second track or recording")
        let range = try await tracks[0].load(.timeRange)
        try expect(abs(range.start.seconds) < 0.003 && abs(range.end.seconds - 0.6) < 0.003,
            "Microphone handoff shortened or shifted the single M4A timeline")
        let values = try decode(asset: asset, track: tracks[0], frames: 28_800)
        try expect(tone(values, frequency: 700, start: 0.05) > 0.08,
            "The M4A lost microphone A before disconnection")
        try expect(tone(values, frequency: 1500, start: 0.45) > 0.08
            && tone(values, frequency: 700, start: 0.45) < 0.005,
            "Microphone B was lost or mixed with a retained A callback after handoff")
        let gap = values[12_000..<16_800]
        let rms = sqrt(gap.reduce(0.0) { $0 + Double($1 * $1) } / Double(gap.count))
        try expect(rms < 0.002, "The no-device interval was compressed or filled with stale microphone audio")
        print("PASS: real router→single M4A keeps A, disconnected silence and B in sync; late A is absent")
    }

    private static func decode(asset: AVAsset, track: AVAssetTrack, frames: Int) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw AppError.message("Cannot inspect generated microphone M4A") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError.message("Cannot decode generated microphone M4A") }
        var values = [Float](repeating: 0, count: frames)
        var covered = [Bool](repeating: false, count: frames)
        while let sample = output.copyNextSampleBuffer() {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { throw AppError.message("Decoded microphone PCM has no format") }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let count = CMSampleBufferGetNumSamples(sample)
            guard format.commonFormat == .pcmFormatFloat32, format.sampleRate == 48000, format.channelCount == 2,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = pcm.floatChannelData else { throw AppError.message("Unexpected decoded microphone format") }
            pcm.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                into: pcm.mutableAudioBufferList) == noErr else { throw AppError.message("Cannot read generated microphone PCM") }
            let first = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48000).rounded())
            for index in 0..<count where values.indices.contains(first + index) {
                values[first + index] = format.isInterleaved ? data[0][index * 2] : data[0][index]
                covered[first + index] = true
            }
        }
        try expect(reader.status == .completed && covered.filter { $0 }.count >= frames - 1,
            "The generated M4A silently lost PCM frames")
        return values
    }

    private static func tone(_ values: [Float], frequency: Double, start: Double) -> Double {
        let first = Int((start * 48000).rounded()), count = 4800
        var real = 0.0, imaginary = 0.0
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / 48000
            real += Double(values[first + index]) * cos(phase)
            imaginary += Double(values[first + index]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(count)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }
}

private final class MonitorHALFixture: @unchecked Sendable {
    struct Entry {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var queue: DispatchQueue
        var block: DefaultMicrophoneMonitor.ListenerBlock
    }
    var device: AudioObjectID = 10
    var available = true
    var entries: [Entry] = []
    var changes: [DefaultMicrophoneSelection] = []
    var removed = 0
    var attempts = 0
    var failAt: Int?
    var driver: DefaultMicrophoneMonitor.Driver {
        DefaultMicrophoneMonitor.Driver(defaultDevice: { [self] in device }, selection: { [self] device in
            available ? .device(id: device == 10 ? "A" : "B") : .unavailable
        }, add: { [self] object, address, queue, block in
            attempts += 1
            if attempts == failAt { return kAudioHardwareUnspecifiedError }
            entries.append(Entry(object: object, address: address, queue: queue, block: block)); return noErr
        }, remove: { [self] object, address, queue, block in
            guard let index = entries.firstIndex(where: {
                $0.object == object && $0.address.mSelector == address.mSelector && $0.address.mScope == address.mScope
                    && $0.address.mElement == address.mElement && $0.queue === queue
                    && unsafeBitCast($0.block, to: UInt.self) == unsafeBitCast(block, to: UInt.self)
            }) else { preconditionFailure("HAL removal must use its exact registered object/address/queue/native block") }
            entries.remove(at: index); removed += 1; return noErr
        })
    }
    func fire(_ block: DefaultMicrophoneMonitor.ListenerBlock) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        withUnsafePointer(to: &address) { block(1, $0) }
    }
}

private final class RouteFixture: @unchecked Sendable {
    enum Failure: Error { case synthetic }
    private let lock = NSLock()
    private var clock: TimeInterval = 100
    private var selected = DefaultMicrophoneSelection.device(id: "A")
    private var routeValues: [FakeMicrophoneInput] = []
    private var monitorValue: FakeMicrophoneMonitor?
    private var packetValues: [Double] = []
    private var silenceValues: [Double] = []
    private var stateValues: [RecordingMicrophoneState] = []
    private var failureValues: [String] = []
    var failures: [String: Int] = [:]
    var monitorStartFails = false
    var monitorStartGate: RouteBlockingGate?
    var stopGates: [String: RouteBlockingGate] = [:]
    var emitOnStartIDs: Set<String> = []

    var time: TimeInterval { get { locked { clock } } set { locked { clock = newValue } } }
    var selection: DefaultMicrophoneSelection { get { locked { selected } } set { locked { selected = newValue } } }
    var monitor: FakeMicrophoneMonitor { locked { monitorValue! } }
    var inputs: [FakeMicrophoneInput] { locked { routeValues } }
    var routeCount: Int { inputs.count }
    var delivered: [Double] { locked { packetValues } }
    var silenceTimes: [Double] { locked { silenceValues } }
    var states: [RecordingMicrophoneState] { locked { stateValues } }
    var failuresReceived: [String] { locked { failureValues } }
    func failure(_ message: String) { locked { failureValues.append(message) } }

    func capture(sink: CaptureSink? = nil) -> MicrophoneCapture {
        MicrophoneCapture(deliveryQueue: sink?.queue ?? DispatchQueue(label: "microphone.route.fixture.delivery"),
            deliver: { [self] buffer in
                locked { packetValues.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))) }
                sink?.consume(buffer, type: .microphone)
            }, silence: { [self] time in
                locked { silenceValues.append(CMTimeGetSeconds(time)) }
                sink?.advanceMicrophone(to: time)
            },
            status: { [self] state in locked { stateValues.append(state) } },
            makeMonitor: { [self] queue, changed in
                let value = FakeMicrophoneMonitor(queue: queue, fixture: self, changed: changed)
                locked { monitorValue = value }; return value
            }, makeInput: { [self] id, queue, sample, interrupted in
                let value = FakeMicrophoneInput(name: id, queue: queue, fixture: self, sample: sample, interrupted: interrupted)
                locked { routeValues.append(value) }; return value
            }, now: { [self] in time }, hostNow: { [self] in CMTime(seconds: time, preferredTimescale: 48000) })
    }

    func route(_ name: String) throws -> FakeMicrophoneInput {
        guard let value = inputs.last(where: { $0.name == name }) else { throw AppError.message("Synthetic route \(name) was not created") }
        return value
    }
    func attempts(_ name: String) -> Int { inputs.filter { $0.name == name }.count }
    func shouldFail(_ name: String) -> Bool {
        locked {
            guard (failures[name] ?? 0) > 0 else { return false }
            failures[name, default: 0] -= 1; return true
        }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private final class FakeMicrophoneMonitor: MicrophoneRouteMonitor, @unchecked Sendable {
    private let queue: DispatchQueue
    private unowned let fixture: RouteFixture
    private let changed: @Sendable (DefaultMicrophoneSelection) -> Void
    private let lock = NSLock()
    private var stopCount = 0
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    init(queue: DispatchQueue, fixture: RouteFixture, changed: @escaping @Sendable (DefaultMicrophoneSelection) -> Void) {
        self.queue = queue; self.fixture = fixture; self.changed = changed
    }
    func start() throws -> DefaultMicrophoneSelection {
        dispatchPrecondition(condition: .onQueue(queue))
        fixture.monitorStartGate?.wait()
        if fixture.monitorStartFails { throw RouteFixture.Failure.synthetic }
        return fixture.selection
    }
    func current() -> DefaultMicrophoneSelection { dispatchPrecondition(condition: .onQueue(queue)); return fixture.selection }
    func stop() { dispatchPrecondition(condition: .onQueue(queue)); lock.lock(); stopCount += 1; lock.unlock() }
    func publish(_ value: DefaultMicrophoneSelection, updateSelection: Bool = true) async {
        if updateSelection { fixture.selection = value }
        await withCheckedContinuation { continuation in
            queue.async { self.changed(value); continuation.resume() }
        }
    }
}

private final class FakeMicrophoneInput: MicrophoneInputRoute, @unchecked Sendable {
    let name: String
    private let queue: DispatchQueue
    private unowned let fixture: RouteFixture
    private let sample: @Sendable (CMSampleBuffer) -> Void
    private let interrupted: @Sendable () -> Void
    private let lock = NSLock()
    private var stopCount = 0
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    init(name: String, queue: DispatchQueue, fixture: RouteFixture,
         sample: @escaping @Sendable (CMSampleBuffer) -> Void, interrupted: @escaping @Sendable () -> Void) {
        self.name = name; self.queue = queue; self.fixture = fixture; self.sample = sample; self.interrupted = interrupted
    }
    func start() throws {
        if fixture.shouldFail(name) { throw RouteFixture.Failure.synthetic }
        if fixture.emitOnStartIDs.contains(name) {
            queue.sync { sample(Self.pcm(77, frames: 48, frequency: nil)) }
        }
    }
    func stop() {
        fixture.stopGates[name]?.wait()
        lock.lock(); stopCount += 1; lock.unlock()
    }
    func packet(_ tag: Double, frames: Int = 48, frequency: Double? = nil) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.sample(Self.pcm(tag, frames: frames, frequency: frequency))
                continuation.resume()
            }
        }
    }
    func interrupt() async {
        await withCheckedContinuation { continuation in queue.async { self.interrupted(); continuation.resume() } }
    }
    private static func pcm(_ tag: Double, frames: Int, frequency: Double?) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            pcm.floatChannelData![0][index] = frequency.map {
                Float(0.2 * sin(2 * Double.pi * $0 * (tag + Double(index) / 48000)))
            } ?? 0.1
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: tag, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        let sample = result!
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(sample) == noErr)
        return sample
    }
}

private final class RouteBlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reached = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func wait() {
        lock.lock()
        if reached { lock.unlock(); return }
        reached = true; lock.unlock()
        semaphore.wait()
    }
    func release() { semaphore.signal() }
}
#endif
