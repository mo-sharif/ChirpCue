import Foundation

public struct BoundedAudioBufferLimits: Equatable, Sendable {
    public let maximumDuration: TimeInterval
    public let maximumBytes: Int

    public init(
        maximumDuration: TimeInterval = 5,
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) {
        precondition(maximumDuration > 0)
        precondition(maximumBytes > 0)
        self.maximumDuration = maximumDuration
        self.maximumBytes = maximumBytes
    }
}

public enum BoundedAudioAppendResult: Equatable, Sendable {
    case stored
    case rejectedTooLarge
}

public actor BoundedAudioBuffer {
    public let limits: BoundedAudioBufferLimits

    private var chunks: [CapturedAudioChunk] = []
    private var storedByteCount = 0
    private let discardedChunkObserver: (@Sendable (CapturedAudioChunk) -> Void)?

    public init(limits: BoundedAudioBufferLimits = .init()) {
        self.limits = limits
        self.discardedChunkObserver = nil
    }

    init(
        limits: BoundedAudioBufferLimits = .init(),
        discardedChunkObserver: @escaping @Sendable (CapturedAudioChunk) -> Void
    ) {
        self.limits = limits
        self.discardedChunkObserver = discardedChunkObserver
    }

    @discardableResult
    public func append(_ chunk: CapturedAudioChunk) -> BoundedAudioAppendResult {
        guard chunk.byteCount <= limits.maximumBytes else {
            return .rejectedTooLarge
        }

        chunks.append(chunk.ownedCopy())
        storedByteCount += chunk.byteCount
        evictBefore(latestEnd: chunk.hostTimeRange.end)
        return .stored
    }

    public func snapshot() -> [CapturedAudioChunk] {
        chunks
    }

    public func snapshot(since timestamp: HostTimestamp) -> [CapturedAudioChunk] {
        chunks.filter { $0.hostTimeRange.end >= timestamp }
    }

    public func byteCount() -> Int {
        storedByteCount
    }

    public func duration() -> TimeInterval {
        guard let first = chunks.first, let last = chunks.last else { return 0 }
        return max(0, last.hostTimeRange.end.seconds - first.hostTime.seconds)
    }

    public func clear() {
        for index in chunks.indices {
            chunks[index].scrubAudioData()
            discardedChunkObserver?(chunks[index])
        }
        chunks.removeAll(keepingCapacity: false)
        storedByteCount = 0
    }

    private func evictBefore(latestEnd: HostTimestamp) {
        while !chunks.isEmpty {
            let firstEnd = chunks[0].hostTimeRange.end.seconds
            let shouldEvict =
                storedByteCount > limits.maximumBytes
                || latestEnd.seconds - firstEnd > limits.maximumDuration
            guard shouldEvict else { return }

            storedByteCount -= chunks[0].byteCount
            chunks[0].scrubAudioData()
            discardedChunkObserver?(chunks[0])
            chunks.removeFirst()
        }
    }
}
