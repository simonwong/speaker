@preconcurrency import CoreAudio
import Foundation

public final class CoreAudioMicrophoneDevices: MicrophoneDeviceSource, @unchecked Sendable {
    private struct Listener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private enum ReadFailure: Error { case unavailable }

    private let lock = NSRecursiveLock()
    private let refreshLock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "speaker.microphone-devices")
    private var listeners: [Listener] = []
    private var observedDeviceIDs: Set<AudioObjectID> = []
    private var current = MicrophoneDeviceSnapshot(
        devices: [], systemDefaultDeviceID: nil, isAvailable: false
    )
    private var observers: [UUID: AsyncStream<MicrophoneDeviceSnapshot>.Continuation] = [:]
    private var isShutDown = false
    private var listenersAvailable = true

    public init() { refresh() }

    deinit { shutdown() }

    public func snapshot() -> MicrophoneDeviceSnapshot {
        lock.withLock { current }
    }

    public func observeChanges() -> AsyncStream<MicrophoneDeviceSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MicrophoneDeviceSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            self?.removeObserver(id)
        }
        lock.withLock {
            guard !isShutDown else {
                continuation.finish()
                return
            }
            observers[id] = continuation
            continuation.yield(current)
        }
        return stream
    }

    public func refresh() {
        refreshLock.withLock {
            guard lock.withLock({ !isShutDown }) else { return }
            let previous = snapshot()
            let next: MicrophoneDeviceSnapshot
            listenersAvailable = true
            register(
                AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
            register(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice)
            do {
                let ids = try Self.readIDs(
                    AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyDevices
                )
                synchronizeDeviceListeners(Set(ids))
                var devices: [MicrophoneDevice] = []
                for id in ids {
                    guard try Self.readUInt32(id, selector: kAudioDevicePropertyDeviceIsAlive) != 0,
                        try Self.inputChannelCount(id) > 0
                    else { continue }
                    let uid = try Self.readString(id, selector: kAudioDevicePropertyDeviceUID)
                    let name = try Self.readString(id, selector: kAudioObjectPropertyName)
                    guard !uid.isEmpty else { throw ReadFailure.unavailable }
                    devices.append(MicrophoneDevice(uid: uid, name: name, deviceID: id))
                }
                let defaultID = try Self.readUInt32(
                    AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyDefaultInputDevice
                )
                next = MicrophoneDeviceSnapshot(
                    devices: devices.sorted {
                        if $0.name == $1.name { return $0.uid < $1.uid }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    },
                    systemDefaultDeviceID: defaultID == kAudioObjectUnknown ? nil : defaultID,
                    isAvailable: listenersAvailable
                )
            } catch {
                next = MicrophoneDeviceSnapshot(
                    devices: previous.devices,
                    systemDefaultDeviceID: previous.systemDefaultDeviceID,
                    isAvailable: false
                )
            }
            lock.withLock {
                guard !isShutDown, next != current else { return }
                current = next
                for continuation in observers.values { continuation.yield(next) }
            }
        }
    }

    public func shutdown() {
        let removed: [Listener] = refreshLock.withLock {
            lock.withLock {
                guard !isShutDown else { return [] }
                isShutDown = true
                let removed = listeners
                listeners.removeAll()
                let continuations = Array(observers.values)
                observers.removeAll()
                for continuation in continuations { continuation.finish() }
                return removed
            }
        }
        for var listener in removed {
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID, &listener.address, queue, listener.block
            )
        }
    }

    private func synchronizeDeviceListeners(_ ids: Set<AudioObjectID>) {
        let removed = observedDeviceIDs.subtracting(ids)
        for index in listeners.indices.reversed()
        where removed.contains(listeners[index].objectID) {
            var listener = listeners.remove(at: index)
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID, &listener.address, queue, listener.block
            )
        }
        for id in ids {
            register(id, selector: kAudioDevicePropertyDeviceIsAlive)
            register(id, selector: kAudioObjectPropertyName)
            register(
                id, selector: kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeInput
            )
        }
        observedDeviceIDs = ids
    }

    private func register(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        guard
            !listeners.contains(where: {
                $0.objectID == objectID && $0.address.mSelector == selector
                    && $0.address.mScope == scope
            })
        else { return }
        var address = Self.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr else {
            listenersAvailable = false
            return
        }
        listeners.append(Listener(objectID: objectID, address: address, block: block))
    }

    private func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readUInt32(
        _ id: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
            size == MemoryLayout<UInt32>.size
        else { throw ReadFailure.unavailable }
        return value
    }

    private static func readString(
        _ id: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
            let value
        else { throw ReadFailure.unavailable }
        return value.takeRetainedValue() as String
    }

    private static func readIDs(
        _ id: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> [AudioObjectID] {
        var address = address(selector)
        for _ in 0..<2 {
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
                size <= 65_536, size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.size))
            else { throw ReadFailure.unavailable }
            guard size > 0 else { return [] }
            var ids = [AudioObjectID](
                repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
            )
            let status = ids.withUnsafeMutableBufferPointer { buffer in
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
            }
            if status == noErr {
                guard Int(size) <= ids.count * MemoryLayout<AudioObjectID>.size,
                    size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.size))
                else { throw ReadFailure.unavailable }
                return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
            }
        }
        throw ReadFailure.unavailable
    }

    private static func inputChannelCount(_ id: AudioObjectID) throws -> UInt32 {
        var address = address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
            size >= MemoryLayout<UInt32>.size, size <= 65_536
        else { throw ReadFailure.unavailable }
        let capacity = Int(size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: max(capacity, MemoryLayout<AudioBufferList>.size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr,
            size >= MemoryLayout<UInt32>.size,
            size <= capacity
        else { throw ReadFailure.unavailable }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
        guard
            Int(list.pointee.mNumberBuffers) <= max(0, (Int(size) - offset))
                / MemoryLayout<AudioBuffer>.stride
        else { throw ReadFailure.unavailable }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
}
