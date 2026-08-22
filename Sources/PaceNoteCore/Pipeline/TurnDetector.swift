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
    private struct EmittedRevision: Equatable, Sendable {
        let segmentID: UUID
        let semanticText: String
    }

    private let configuration: TurnDetectorConfiguration
    private var latestOutput: TranscriptSegment?
    private var emittedRevision: EmittedRevision?

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
        let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count
        let revision = EmittedRevision(
            segmentID: segment.id,
            semanticText: Self.semanticText(normalized)
        )
        let isFirstEmissionForSegment = emittedRevision?.segmentID != segment.id
        let isMeaningfullyRevisedFinal = segment.isFinal && emittedRevision != revision

        guard isFirstEmissionForSegment || isMeaningfullyRevisedFinal,
            wordCount >= configuration.minimumWordCount || Self.looksLikeShortPrompt(normalized),
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

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func semanticText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(
                of: #"[\p{P}\p{S}]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksActionable(_ text: String) -> Bool {
        if text.hasSuffix("?") { return true }
        let lowercased = text.lowercased()
        let prefixes = [
            "why ", "how ", "what ", "when ", "where ", "which ", "who ",
            "why's ", "how's ", "what's ", "when's ", "where's ", "who's ",
            "are you ", "are we ", "is there ", "is this ", "is that ",
            "have you ", "have we ", "has this ", "has the ",
            "can you ", "can we ", "could you ", "could we ",
            "would you ", "would we ", "will you ", "will we ",
            "do you ", "do we ", "did you ", "did we ", "does this ", "does the ",
            "should you ", "should we ", "should i ", "should the ",
            "walk me through ", "talk me through ", "take me through ",
            "tell me ", "tell us ", "show me ", "show us ",
            "describe ", "explain ", "outline ", "compare ", "contrast ", "define ",
            "summarize ", "elaborate ", "expand on ", "share ",
            "help me understand ", "help us understand ", "give me ", "give us ",
            "i'd like you to ", "we'd like you to ", "i want you to ", "we want you to ",
        ]
        return Self.looksLikeShortPrompt(lowercased)
            || prefixes.contains { lowercased.hasPrefix($0) }
    }

    private static func looksLikeShortPrompt(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let wordCount = lowercased.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount >= 2, lowercased.hasSuffix("?") { return true }

        return [
            "thoughts", "thoughts?", "questions", "questions?", "concerns", "concerns?",
            "any thoughts", "any thoughts?", "any questions", "any questions?",
            "any concerns", "any concerns?", "make sense", "make sense?",
        ].contains(lowercased)
    }
}
