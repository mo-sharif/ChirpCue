import Foundation

public struct CandidateQuestion: Equatable, Sendable {
    public let text: String
    public let sourceSegmentID: UUID
    public let stableAt: TimeInterval

    public init(text: String, sourceSegmentID: UUID, stableAt: TimeInterval) {
        self.text = text
        self.sourceSegmentID = sourceSegmentID
        self.stableAt = stableAt
    }
}

public struct TurnDetectorConfiguration: Sendable {
    public let minimumSilence: TimeInterval
    public let minimumConfidence: Double
    public let minimumWordCount: Int

    public init(
        minimumSilence: TimeInterval = 0.45,
        minimumConfidence: Double = 0.55,
        minimumWordCount: Int = 3
    ) {
        self.minimumSilence = minimumSilence
        self.minimumConfidence = minimumConfidence
        self.minimumWordCount = minimumWordCount
    }
}

public struct TurnDetector: Sendable {
    private let configuration: TurnDetectorConfiguration
    private var latestOutput: TranscriptSegment?
    private var emittedRevision: Revision?

    public init(configuration: TurnDetectorConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func observe(_ segment: TranscriptSegment) {
        guard segment.source == .them || segment.source == .output else { return }
        guard latestOutput == nil || segment.endedAt >= latestOutput!.endedAt else { return }
        latestOutput = segment
    }

    public mutating func candidate(at time: TimeInterval, force: Bool = false) -> CandidateQuestion? {
        guard let segment = latestOutput else { return nil }
        let normalized = Self.normalized(segment.text)
        let revision = Revision(segmentID: segment.id, text: normalized)

        guard emittedRevision != revision,
            normalized.split(whereSeparator: { $0.isWhitespace }).count >= configuration.minimumWordCount,
            segment.confidence.map({ $0 >= configuration.minimumConfidence }) ?? true,
            force || segment.isFinal || time - segment.endedAt >= configuration.minimumSilence,
            force || Self.looksActionable(normalized)
        else {
            return nil
        }

        emittedRevision = revision
        return CandidateQuestion(text: normalized, sourceSegmentID: segment.id, stableAt: time)
    }

    public mutating func invalidate() {
        latestOutput = nil
        emittedRevision = nil
    }

    private struct Revision: Equatable, Sendable {
        let segmentID: UUID
        let text: String
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func looksActionable(_ text: String) -> Bool {
        if text.hasSuffix("?") { return true }
        let lowercased = text.lowercased()
        let prefixes = [
            "why ", "how ", "what ", "when ", "where ", "which ", "who ",
            "can you ", "could you ", "would you ", "will you ", "do you ",
            "walk me through ", "tell me ", "explain ", "help me understand ",
        ]
        return prefixes.contains { lowercased.hasPrefix($0) }
    }
}
