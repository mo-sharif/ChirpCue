import Foundation

public enum TranscriptAttributionDecision: Equatable, Sendable {
    case suppressEcho
    case attribute(source: TranscriptSource, speakerUncertain: Bool)
}

public struct TranscriptAttributionResolver: Sendable {
    public let nearSynchronousThreshold: TimeInterval
    public let minimumMicrophoneEchoConfidence: Double
    public let duplicateSimilarityThreshold: Double

    public init(
        nearSynchronousThreshold: TimeInterval = 0.75,
        minimumMicrophoneEchoConfidence: Double = 0.8,
        duplicateSimilarityThreshold: Double = 0.84
    ) {
        precondition(nearSynchronousThreshold >= 0)
        precondition((0...1).contains(minimumMicrophoneEchoConfidence))
        precondition((0...1).contains(duplicateSimilarityThreshold))
        self.nearSynchronousThreshold = nearSynchronousThreshold
        self.minimumMicrophoneEchoConfidence = minimumMicrophoneEchoConfidence
        self.duplicateSimilarityThreshold = duplicateSimilarityThreshold
    }

    public func resolveMicrophone(
        _ microphone: ProgressiveTranscriptResult,
        receivedAt microphoneReceivedAt: TimeInterval,
        against output: ProgressiveTranscriptResult,
        receivedAt outputReceivedAt: TimeInterval
    ) -> TranscriptAttributionDecision {
        guard
            isNearSynchronous(
                microphone,
                receivedAt: microphoneReceivedAt,
                output,
                receivedAt: outputReceivedAt
            )
        else {
            return .attribute(source: .you, speakerUncertain: false)
        }

        let similarity = Self.similarity(microphone.text, output.text)
        if (microphone.confidence ?? 0) >= minimumMicrophoneEchoConfidence,
            similarity >= duplicateSimilarityThreshold
        {
            return .suppressEcho
        }
        return .attribute(source: .unknown, speakerUncertain: true)
    }

    private func isNearSynchronous(
        _ lhs: ProgressiveTranscriptResult,
        receivedAt lhsReceivedAt: TimeInterval,
        _ rhs: ProgressiveTranscriptResult,
        receivedAt rhsReceivedAt: TimeInterval
    ) -> Bool {
        if let lhsRange = lhs.hostTimeRange, let rhsRange = rhs.hostTimeRange {
            let separation: TimeInterval
            if lhsRange.end < rhsRange.start {
                separation = rhsRange.start.seconds - lhsRange.end.seconds
            } else if rhsRange.end < lhsRange.start {
                separation = lhsRange.start.seconds - rhsRange.end.seconds
            } else {
                separation = 0
            }
            return separation <= nearSynchronousThreshold
        }
        return abs(lhsReceivedAt - rhsReceivedAt) <= nearSynchronousThreshold
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = tokens(lhs)
        let rhsTokens = tokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        if lhsTokens == rhsTokens { return 1 }

        let lhsSet = Set(lhsTokens)
        let rhsSet = Set(rhsTokens)
        let shared = lhsSet.intersection(rhsSet).count
        return Double(shared) / Double(max(lhsSet.count, rhsSet.count))
    }

    private static func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .replacingOccurrences(
                of: #"[\p{P}\p{S}]+"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}
