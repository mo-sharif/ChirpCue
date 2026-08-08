import CoreAudio
import Darwin
import Foundation
import Synchronization

struct RealtimeAudioRingConfiguration: Sendable {
    let slotCount: Int
    let maximumBytesPerSlot: Int
    let maximumPlanes: Int

    init(
        slotCount: Int = 256,
        maximumBytesPerSlot: Int = 64 * 1_024,
        maximumPlanes: Int = 8
    ) {
        precondition(slotCount > 1)
        precondition(maximumBytesPerSlot > 0)
        precondition(maximumPlanes > 0)
        self.slotCount = slotCount
        self.maximumBytesPerSlot = maximumBytesPerSlot
        self.maximumPlanes = maximumPlanes
    }
}

/// A bounded SPSC transfer ring. `write` is safe for an audio callback: it only
/// performs bounds checks, memory copies, and atomic loads/stores.
final class RealtimeAudioRing: @unchecked Sendable {
    let lane: AudioLane
    let format: AudioFormatDescription

    private let configuration: RealtimeAudioRingConfiguration
    private let storage: UnsafeMutableRawPointer
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let frameCounts: UnsafeMutablePointer<UInt32>
    private let planeCounts: UnsafeMutablePointer<UInt32>
    private let planeByteCounts: UnsafeMutablePointer<UInt32>
    private let planeChannelCounts: UnsafeMutablePointer<UInt32>
    private let writeSequence = Atomic<UInt64>(0)
    private let readSequence = Atomic<UInt64>(0)
    private let overflowCount = Atomic<UInt64>(0)
    private let oversizedCount = Atomic<UInt64>(0)
    private let invalidTimestampCount = Atomic<UInt64>(0)
    private let latestCallbackTicks = Atomic<UInt64>(0)
    private let acceptsWrites = Atomic<Bool>(true)
    private let writerIsActive = Atomic<Bool>(false)

    init(
        lane: AudioLane,
        format: AudioFormatDescription,
        configuration: RealtimeAudioRingConfiguration = .init()
    ) {
        self.lane = lane
        self.format = format
        self.configuration = configuration

        storage = .allocate(
            byteCount: configuration.slotCount * configuration.maximumBytesPerSlot,
            alignment: 64
        )
        hostTimes = .allocate(capacity: configuration.slotCount)
        frameCounts = .allocate(capacity: configuration.slotCount)
        planeCounts = .allocate(capacity: configuration.slotCount)
        planeByteCounts = .allocate(capacity: configuration.slotCount * configuration.maximumPlanes)
        planeChannelCounts = .allocate(capacity: configuration.slotCount * configuration.maximumPlanes)

        storage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: configuration.slotCount * configuration.maximumBytesPerSlot
        )
        hostTimes.initialize(repeating: 0, count: configuration.slotCount)
        frameCounts.initialize(repeating: 0, count: configuration.slotCount)
        planeCounts.initialize(repeating: 0, count: configuration.slotCount)
        planeByteCounts.initialize(
            repeating: 0,
            count: configuration.slotCount * configuration.maximumPlanes
        )
        planeChannelCounts.initialize(
            repeating: 0,
            count: configuration.slotCount * configuration.maximumPlanes
        )
    }

    deinit {
        scrubStorage()
        storage.deallocate()
        hostTimes.deinitialize(count: configuration.slotCount)
        hostTimes.deallocate()
        frameCounts.deinitialize(count: configuration.slotCount)
        frameCounts.deallocate()
        planeCounts.deinitialize(count: configuration.slotCount)
        planeCounts.deallocate()
        planeByteCounts.deinitialize(count: configuration.slotCount * configuration.maximumPlanes)
        planeByteCounts.deallocate()
        planeChannelCounts.deinitialize(count: configuration.slotCount * configuration.maximumPlanes)
        planeChannelCounts.deallocate()
    }

    func noteInvalidTimestamp() {
        _ = invalidTimestampCount.wrappingAdd(1, ordering: .relaxed)
    }

    @discardableResult
    func write(
        _ bufferList: UnsafePointer<AudioBufferList>,
        frameCount: UInt32,
        hostTime: HostTimestamp
    ) -> Bool {
        guard acceptsWrites.load(ordering: .acquiring) else { return false }
        writerIsActive.store(true, ordering: .releasing)
        defer { writerIsActive.store(false, ordering: .releasing) }
        guard acceptsWrites.load(ordering: .acquiring) else { return false }

        latestCallbackTicks.store(hostTime.ticks, ordering: .relaxed)

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard buffers.count > 0, buffers.count <= configuration.maximumPlanes else {
            _ = oversizedCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        var totalBytes = 0
        for buffer in buffers {
            guard buffer.mData != nil else {
                _ = oversizedCount.wrappingAdd(1, ordering: .relaxed)
                return false
            }
            totalBytes += Int(buffer.mDataByteSize)
        }
        guard totalBytes > 0, totalBytes <= configuration.maximumBytesPerSlot else {
            _ = oversizedCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        guard write &- read < UInt64(configuration.slotCount) else {
            _ = overflowCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let slot = Int(write % UInt64(configuration.slotCount))
        let metadataBase = slot * configuration.maximumPlanes
        let destination = storage.advanced(by: slot * configuration.maximumBytesPerSlot)
        var offset = 0

        for (index, buffer) in buffers.enumerated() {
            let byteCount = Int(buffer.mDataByteSize)
            destination.advanced(by: offset).copyMemory(from: buffer.mData!, byteCount: byteCount)
            planeByteCounts[metadataBase + index] = UInt32(byteCount)
            planeChannelCounts[metadataBase + index] = buffer.mNumberChannels
            offset += byteCount
        }

        hostTimes[slot] = hostTime.ticks
        frameCounts[slot] = frameCount
        planeCounts[slot] = UInt32(buffers.count)
        writeSequence.store(write &+ 1, ordering: .releasing)
        return true
    }

    func read() -> CapturedAudioChunk? {
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        guard read != write else { return nil }

        let slot = Int(read % UInt64(configuration.slotCount))
        let metadataBase = slot * configuration.maximumPlanes
        let source = storage.advanced(by: slot * configuration.maximumBytesPerSlot)
        let count = Int(planeCounts[slot])
        var offset = 0
        var planes: [CapturedAudioPlane] = []
        planes.reserveCapacity(count)

        for index in 0..<count {
            let byteCount = Int(planeByteCounts[metadataBase + index])
            let data = Data(bytes: source.advanced(by: offset), count: byteCount)
            planes.append(
                CapturedAudioPlane(
                    channelCount: planeChannelCounts[metadataBase + index],
                    data: data
                )
            )
            offset += byteCount
        }

        source.initializeMemory(as: UInt8.self, repeating: 0, count: offset)
        let chunk = CapturedAudioChunk(
            lane: lane,
            hostTime: HostTimestamp(ticks: hostTimes[slot]),
            frameCount: frameCounts[slot],
            format: format,
            planes: planes
        )
        readSequence.store(read &+ 1, ordering: .releasing)
        return chunk
    }

    func takeOverflowCount() -> UInt64 {
        overflowCount.exchange(0, ordering: .acquiringAndReleasing)
    }

    func takeOversizedCount() -> UInt64 {
        oversizedCount.exchange(0, ordering: .acquiringAndReleasing)
    }

    func takeInvalidTimestampCount() -> UInt64 {
        invalidTimestampCount.exchange(0, ordering: .acquiringAndReleasing)
    }

    func lastCallbackHostTime() -> HostTimestamp? {
        let ticks = latestCallbackTicks.load(ordering: .acquiring)
        return ticks == 0 ? nil : HostTimestamp(ticks: ticks)
    }

    func clear() {
        let write = writeSequence.load(ordering: .acquiring)
        readSequence.store(write, ordering: .releasing)
        overflowCount.store(0, ordering: .releasing)
        oversizedCount.store(0, ordering: .releasing)
        invalidTimestampCount.store(0, ordering: .releasing)
        latestCallbackTicks.store(0, ordering: .releasing)
        scrubStorage()
    }

    /// Permanently closes this ring to the realtime writer, waits for the one
    /// bounded in-flight copy to leave, and then overwrites all sensitive bytes.
    func sealAndClear() {
        acceptsWrites.store(false, ordering: .releasing)
        while writerIsActive.load(ordering: .acquiring) {
            sched_yield()
        }
        clear()
    }

    private func scrubStorage() {
        storage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: configuration.slotCount * configuration.maximumBytesPerSlot
        )
    }
}
