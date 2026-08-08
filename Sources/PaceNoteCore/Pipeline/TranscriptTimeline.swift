import Foundation

public struct TranscriptTimeline: Sendable {
    public let retention: Duration
    private(set) public var segments: [TranscriptSegment]

    public init(retention: Duration = .seconds(180), segments: [TranscriptSegment] = []) {
        self.retention = retention
        self.segments = segments.sorted { $0.startedAt < $1.startedAt }
    }

    public mutating func upsert(_ segment: TranscriptSegment) {
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
        segments.sort {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.startedAt < $1.startedAt
        }
        prune(relativeTo: segment.endedAt)
    }

    public mutating func clear() {
        segments.removeAll(keepingCapacity: false)
    }

    public func recent(endingAt end: TimeInterval, seconds: TimeInterval) -> [TranscriptSegment] {
        let start = end - seconds
        return segments.filter { $0.endedAt >= start && $0.startedAt <= end }
    }

    private mutating func prune(relativeTo latest: TimeInterval) {
        let seconds =
            Double(retention.components.seconds)
            + Double(retention.components.attoseconds) / 1_000_000_000_000_000_000
        let cutoff = latest - seconds
        segments.removeAll { $0.endedAt < cutoff }
    }
}
