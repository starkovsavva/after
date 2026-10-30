import AVFoundation

/// Implementations deliver host-clock PCM on the supplied delivery queue. A
/// route owns its session and clock; neither is reused after a device switch.
protocol MicrophoneInputRoute: AnyObject {
    var name: String { get }
    func start() throws
    func stop()
}

/// Reconnects only microphone capture. ScreenCaptureKit and the media writer
/// remain alive, including while no input device is available.
final class MicrophoneCapture: @unchecked Sendable {
    typealias MonitorFactory = (DispatchQueue, @escaping @Sendable (DefaultMicrophoneSelection) -> Void) -> any MicrophoneRouteMonitor
    typealias InputFactory = (String, DispatchQueue, @escaping @Sendable (CMSampleBuffer) -> Void,
                             @escaping @Sendable () -> Void) throws -> any MicrophoneInputRoute
    private let queue = DispatchQueue(label: "app.posle.microphone-route", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let deliveryQueue: DispatchQueue
    private let deliver: @Sendable (CMSampleBuffer) -> Void
    private let silence: @Sendable (CMTime) -> Void
    private let status: @Sendable (RecordingMicrophoneState) -> Void
    private let makeMonitor: MonitorFactory
    private let makeInput: InputFactory
    private let now: @Sendable () -> TimeInterval
    private let hostNow: @Sendable () -> CMTime
    private let gate = MicrophoneSampleGate()
    private var monitor: (any MicrophoneRouteMonitor)?
    private var input: (any MicrophoneInputRoute)?
    private var timer: DispatchSourceTimer?
    private var selection = DefaultMicrophoneSelection.unavailable
    private var token = UUID()
    private var lifecycle = UUID()
    private var running = false
    private var attempts = 0
    private var retryAt: TimeInterval = 0
    private var inputStartedAt: TimeInterval = 0
    private var published: RecordingMicrophoneState?

    init(deliveryQueue: DispatchQueue,
         deliver: @escaping @Sendable (CMSampleBuffer) -> Void,
         silence: @escaping @Sendable (CMTime) -> Void,
         status: @escaping @Sendable (RecordingMicrophoneState) -> Void,
         makeMonitor: @escaping MonitorFactory = { DefaultMicrophoneMonitor(queue: $0, changed: $1) },
         makeInput: @escaping InputFactory = { try AVCaptureMicrophoneRoute(deviceID: $0, queue: $1, sample: $2, interrupted: $3) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         hostNow: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) {
        self.deliveryQueue = deliveryQueue; self.deliver = deliver; self.silence = silence; self.status = status
        self.makeMonitor = makeMonitor; self.makeInput = makeInput; self.now = now; self.hostNow = hostNow
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() async throws {
        try Task.checkCancellation()
        let cancellation = MicrophoneStartCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard !self.running else { continuation.resume(throwing: self.startError); return }
                    guard self.gate.begin(unless: cancellation) else { continuation.resume(throwing: CancellationError()); return }
                    self.running = true; self.published = nil; self.attempts = 0
                    self.lifecycle = UUID()
                    let lifecycle = self.lifecycle
                    let monitor = self.makeMonitor(self.queue) { [weak self] selection in
                        guard let self, self.running, self.lifecycle == lifecycle else { return }
                        self.updateSelection(selection)
                    }
                    self.monitor = monitor
                    do {
                        self.selection = try monitor.start()
                        guard case .device = self.selection else { throw self.startError }
                        try self.replaceInput()
                        if cancellation.isCancelled { throw CancellationError() }
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                        timer.setEventHandler { [weak self] in
                            guard let self, self.lifecycle == lifecycle else { return }
                            self.tick()
                        }
                        self.timer = timer; timer.resume()
                        continuation.resume()
                    } catch {
                        self.stopOnQueue()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel(); self.gate.invalidate()
        }
        if Task.isCancelled { await stop(); throw CancellationError() }
    }

    func stop() async {
        // AVFoundation start/stop may block the control queue. Stop accepting
        // PCM immediately while its session teardown waits for that queue.
        gate.invalidate()
        await withCheckedContinuation { continuation in
            queue.async {
                let missing = self.running && self.input == nil
                let time = self.hostNow()
                self.stopOnQueue()
                if missing { self.deliveryQueue.async { self.silence(time) } }
                continuation.resume()
            }
        }
        // Drain callbacks admitted before Stop before the caller finalizes the
        // writer. Late callbacks from any old route are rejected by the gate.
        await withCheckedContinuation { continuation in deliveryQueue.async { continuation.resume() } }
    }

    private func stopOnQueue() {
        running = false; lifecycle = UUID(); token = UUID(); gate.invalidate()
        timer?.cancel(); timer = nil
        monitor?.stop(); monitor = nil
        input?.stop(); input = nil
    }

    private func updateSelection(_ next: DefaultMicrophoneSelection) {
        guard running, selection != next else { return }
        selection = next; attempts = 0
        do { try replaceInput() } catch { scheduleRetry() }
    }

    private func replaceInput() throws {
        token = UUID(); gate.wait(token)
        input?.stop(); input = nil
        guard case let .device(id) = selection else { publish(.unavailable); return }
        publish(.switching)
        let current = token
        guard gate.activate(current) else { throw CancellationError() }
        do {
            let route = try makeInput(id, deliveryQueue, { [weak self] buffer in
                guard let self, let first = self.gate.receive(current, at: self.now()) else { return }
                self.deliver(buffer)
                if first {
                    self.queue.async {
                        guard self.running, self.token == current, let input = self.input else { return }
                        self.attempts = 0; self.publish(.active(name: input.name))
                    }
                }
            }, { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.running, self.token == current else { return }
                    self.token = UUID(); self.gate.wait(self.token)
                    self.input?.stop(); self.input = nil
                    self.scheduleRetry()
                }
            })
            input = route; inputStartedAt = now()
            try route.start()
        } catch {
            gate.wait(token); input?.stop(); input = nil
            throw error
        }
    }

    private func scheduleRetry() {
        publish(.unavailable)
        retryAt = now() + min(4, 0.25 * pow(2, Double(min(attempts, 4))))
        attempts += 1
    }

    private func tick() {
        guard running else { return }
        // HAL may publish its default before AVFoundation can open that UID.
        // Re-read rather than falling back to an unrelated connected input.
        if let monitor { updateSelection(monitor.current()) }
        if input != nil {
            let last = gate.lastReceived ?? inputStartedAt
            if now() - last > 3 {
                token = UUID(); gate.wait(token); input?.stop(); input = nil
                scheduleRetry()
            }
        }
        if input == nil, case .device = selection, now() >= retryAt {
            do { try replaceInput() } catch { scheduleRetry() }
        }
        if input == nil {
            let current = token, time = hostNow()
            deliveryQueue.async { [weak self] in
                guard let self, self.gate.isWaiting(current) else { return }
                self.silence(time)
            }
        }
    }

    private func publish(_ value: RecordingMicrophoneState) {
        guard published != value else { return }
        published = value; status(value)
    }

    private var startError: AppError { .message(L("Не удалось включить системный микрофон. Подключите микрофон и выберите вход в настройках macOS.")) }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    #if DEBUG
    func stopRequestedForChecks() -> Bool { gate.isClosed }
    /// Deterministic recovery checks drive the real timer path with a fake
    /// monotonic clock and invented input sessions, without opening hardware.
    func tickForChecks() async {
        await withCheckedContinuation { continuation in queue.async { self.tick(); continuation.resume() } }
    }
    func drainForChecks() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in deliveryQueue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    #endif
}

private final class MicrophoneSampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var inactive: UUID?
    private var received: TimeInterval?
    private var closed = true
    func begin(unless cancellation: MicrophoneStartCancellation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancellation.isCancelled else { return false }
        closed = false; token = nil; received = nil; inactive = nil
        return true
    }
    func activate(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        self.token = token; inactive = nil; received = nil
        return true
    }
    func invalidate() { lock.lock(); closed = true; token = nil; received = nil; inactive = nil; lock.unlock() }
    func wait(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        token = nil; received = nil; inactive = generation
    }
    var lastReceived: TimeInterval? { lock.lock(); defer { lock.unlock() }; return received }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func isWaiting(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && self.token == nil && inactive == token
    }
    func receive(_ token: UUID, at time: TimeInterval) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, self.token == token else { return nil }
        let first = received == nil; received = time; return first
    }
}

private final class AVCaptureMicrophoneRoute: NSObject, MicrophoneInputRoute, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let name: String
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sample: @Sendable (CMSampleBuffer) -> Void
    private let interrupted: @Sendable () -> Void
    private var observations: [NSObjectProtocol] = []

    init(deviceID: String, queue: DispatchQueue,
         sample: @escaping @Sendable (CMSampleBuffer) -> Void,
         interrupted: @escaping @Sendable () -> Void) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected, device.hasMediaType(.audio) else {
            throw AppError.message(L("Системный микрофон пока недоступен."))
        }
        name = device.localizedName; self.sample = sample; self.interrupted = interrupted
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw AppError.message(L("Не удалось подключить системный микрофон.")) }
        session.addInput(input)
        // Request decoded PCM; retain the native rate/channels. The shared
        // normalizer owns conversion to the writer's stable format.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM]
        guard session.canAddOutput(output) else { throw AppError.message(L("Не удалось подключить системный микрофон.")) }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        let center = NotificationCenter.default
        for event in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification,
                      AVCaptureSession.wasInterruptedNotification] {
            observations.append(center.addObserver(forName: event, object: session, queue: nil) { [weak self] _ in self?.interrupted() })
        }
        observations.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device, queue: nil) { [weak self] _ in self?.interrupted() })
    }

    func start() throws {
        session.startRunning()
        guard session.isRunning else { throw AppError.message(L("Не удалось подключить системный микрофон.")) }
    }

    func stop() {
        observations.forEach { NotificationCenter.default.removeObserver($0) }; observations.removeAll()
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { interrupted(); return }
        do { sample(try CaptureSampleClock.hostTimed(sampleBuffer, clock: clock)) }
        catch { interrupted() }
    }

    deinit { stop() }
}

private final class MicrophoneStartCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
