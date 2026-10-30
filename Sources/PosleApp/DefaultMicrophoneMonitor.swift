import CoreAudio
import Foundation

enum DefaultMicrophoneSelection: Equatable, Sendable {
    case unavailable
    case device(id: String)
}

protocol MicrophoneRouteMonitor: AnyObject {
    func start() throws -> DefaultMicrophoneSelection
    func current() -> DefaultMicrophoneSelection
    func stop()
}

/// Call start/current/stop on the supplied serial queue. Change callbacks run
/// on that queue too. This observes HAL metadata without opening an input or
/// requesting permission, and never substitutes a different input device.
final class DefaultMicrophoneMonitor: MicrophoneRouteMonitor, @unchecked Sendable {
    typealias ListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

    struct Driver {
        var defaultDevice: () throws -> AudioObjectID
        var selection: (AudioObjectID) throws -> DefaultMicrophoneSelection
        var add: (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping ListenerBlock) -> OSStatus
        var remove: (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping ListenerBlock) -> OSStatus

        static var live: Driver {
            Driver(defaultDevice: {
                try DefaultMicrophoneMonitor.integerProperty(AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyDefaultInputDevice)
            }, selection: DefaultMicrophoneMonitor.selection, add: { object, address, queue, block in
                var address = address
                return AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
            }, remove: { object, address, queue, block in
                var address = address
                return AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            })
        }
    }

    private struct Registration {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: ListenerBlock
    }

    private let queue: DispatchQueue
    private let changed: @Sendable (DefaultMicrophoneSelection) -> Void
    private let driver: Driver
    private var generation: UUID?
    private var systemRegistrations: [Registration] = []
    private var deviceRegistrations: [Registration] = []
    private var observedDevice: AudioObjectID?
    private var lastSelection = DefaultMicrophoneSelection.unavailable

    convenience init(queue: DispatchQueue, changed: @escaping @Sendable (DefaultMicrophoneSelection) -> Void) {
        self.init(queue: queue, driver: .live, changed: changed)
    }

    init(queue: DispatchQueue, driver: Driver, changed: @escaping @Sendable (DefaultMicrophoneSelection) -> Void) {
        self.queue = queue
        self.driver = driver
        self.changed = changed
    }

    deinit {
        // HAL retains the registered blocks and queue, but each block holds
        // self weakly. Final release can happen off queue; no method can still
        // own self here. Remove the exact registrations without queue.sync.
        remove(deviceRegistrations)
        remove(systemRegistrations)
    }

    func start() throws -> DefaultMicrophoneSelection {
        dispatchPrecondition(condition: .onQueue(queue))
        if generation != nil { return current() }
        let token = UUID()
        generation = token
        do {
            for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
                systemRegistrations.append(try add(object: AudioObjectID(kAudioObjectSystemObject),
                    selector: selector, generation: token))
            }
            lastSelection = try readCurrent()
            return lastSelection
        } catch {
            stop()
            throw error
        }
    }

    func current() -> DefaultMicrophoneSelection {
        dispatchPrecondition(condition: .onQueue(queue))
        lastSelection = (try? readCurrent()) ?? .unavailable
        return lastSelection
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation = nil
        remove(deviceRegistrations)
        remove(systemRegistrations)
        deviceRegistrations.removeAll()
        systemRegistrations.removeAll()
        observedDevice = nil
        lastSelection = .unavailable
    }

    private func add(object: AudioObjectID, selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     generation token: UUID) throws -> Registration {
        let address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        let block: ListenerBlock = { [weak self] _, _ in
            guard let self, self.generation == token else { return }
            let previous = self.lastSelection
            let selection = self.current()
            if previous != selection { self.changed(selection) }
        }
        let status = driver.add(object, address, queue, block)
        guard status == noErr else { throw Self.error(status) }
        return Registration(object: object, address: address, block: block)
    }

    private func remove(_ registrations: [Registration]) {
        for registration in registrations.reversed() {
            _ = driver.remove(registration.object, registration.address, queue, registration.block)
        }
    }

    private func readCurrent() throws -> DefaultMicrophoneSelection {
        let device = try driver.defaultDevice()
        if generation != nil, observedDevice != device {
            remove(deviceRegistrations)
            deviceRegistrations.removeAll()
            observedDevice = nil
            if device != kAudioObjectUnknown, let token = generation {
                do {
                    deviceRegistrations.append(try add(object: device,
                        selector: kAudioDevicePropertyDeviceIsAlive, generation: token))
                    deviceRegistrations.append(try add(object: device,
                        selector: kAudioDevicePropertyDeviceUID, generation: token))
                    deviceRegistrations.append(try add(object: device,
                        selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput,
                        generation: token))
                    deviceRegistrations.append(try add(object: device,
                        selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                        generation: token))
                } catch {
                    remove(deviceRegistrations)
                    deviceRegistrations.removeAll()
                    throw error
                }
            }
            observedDevice = device
        }
        guard device != kAudioObjectUnknown else { return .unavailable }
        return try driver.selection(device)
    }

    private static func integerProperty(_ object: AudioObjectID,
                                        selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw error(status) }
        guard size == MemoryLayout<UInt32>.size else { throw error(kAudioHardwareBadPropertySizeError) }
        return value
    }

    private static func selection(_ device: AudioObjectID) throws -> DefaultMicrophoneSelection {
        guard try integerProperty(device, selector: kAudioDevicePropertyDeviceIsAlive) != 0,
              try hasInputChannels(device) else { return .unavailable }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        // HAL returns an owned CFString for DeviceUID. Balance that ownership
        // even if a driver returns a malformed property result.
        let value = uid?.takeRetainedValue()
        guard status == noErr else { throw error(status) }
        guard size == MemoryLayout<Unmanaged<CFString>?>.size,
              let value, !(value as String).isEmpty else { return .unavailable }
        return .device(id: value as String)
    }

    private static func hasInputChannels(_ device: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else { throw error(status) }
        guard size >= MemoryLayout<UInt32>.size, size <= 1_048_576 else {
            throw error(kAudioHardwareBadPropertySizeError)
        }
        let capacity = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage)
        guard status == noErr else { throw error(status) }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let header = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
        let buffers = Int(list.pointee.mNumberBuffers)
        guard Int(size) <= capacity, size >= MemoryLayout<UInt32>.size,
              buffers <= max(0, (Int(size) - header) / MemoryLayout<AudioBuffer>.stride) else {
            throw error(kAudioHardwareBadPropertySizeError)
        }
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
