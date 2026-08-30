import CryptoKit
import Foundation

public enum SuggestionRelationship: String, Codable, Sendable {
    case continueAnswer = "continue"
    case correctAnswer = "correct"
    case clarify
    case abstain
}

public enum DeepDraftKind: String, Codable, Sendable {
    case answer
    case generalAnswer = "general_answer"
    case clarification
    case abstention
}

public struct QuickModelOutput: Codable, Equatable, Sendable {
    public let turnID: UUID
    public let generation: UInt64
    public let sayNow: String
    public let needsDeep: Bool
    public let confidence: Double
    public let reason: String

    public init(
        turnID: UUID,
        generation: UInt64,
        sayNow: String,
        needsDeep: Bool,
        confidence: Double,
        reason: String
    ) {
        self.turnID = turnID
        self.generation = generation
        self.sayNow = sayNow
        self.needsDeep = needsDeep
        self.confidence = confidence
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case turnID, generation, sayNow, needsDeep, confidence, reason
    }

    public init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(UUID.self, forKey: .turnID)
        generation = try container.decode(UInt64.self, forKey: .generation)
        sayNow = try container.decode(String.self, forKey: .sayNow)
        needsDeep = try container.decode(Bool.self, forKey: .needsDeep)
        confidence = try container.decode(Double.self, forKey: .confidence)
        reason = try container.decode(String.self, forKey: .reason)
    }
}

public struct CueEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let turnID: UUID
    public let generation: UInt64
    public let text: String
    public let textHash: String
    public let reason: String
    public let isDeterministicBridge: Bool

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        generation: UInt64,
        text: String,
        reason: String,
        isDeterministicBridge: Bool
    ) {
        self.id = id
        self.turnID = turnID
        self.generation = generation
        self.text = text
        self.textHash = Self.hash(text)
        self.reason = reason
        self.isDeterministicBridge = isDeterministicBridge
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct EvidenceReference: Codable, Hashable, Sendable {
    public let repoAlias: String
    public let relativePath: String
    public let startLine: Int
    public let endLine: Int
    public let fileHash: String
    public let claim: String

    public init(
        repoAlias: String,
        relativePath: String,
        startLine: Int,
        endLine: Int,
        fileHash: String,
        claim: String
    ) {
        self.repoAlias = repoAlias
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.fileHash = fileHash
        self.claim = claim
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case repoAlias, relativePath, startLine, endLine, fileHash, claim
    }

    public init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoAlias = try container.decode(String.self, forKey: .repoAlias)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        startLine = try container.decode(Int.self, forKey: .startLine)
        endLine = try container.decode(Int.self, forKey: .endLine)
        fileHash = try container.decode(String.self, forKey: .fileHash)
        claim = try container.decode(String.self, forKey: .claim)
    }
}

public struct DeepDraft: Codable, Equatable, Sendable {
    public let turnID: UUID
    public let generation: UInt64
    public let groundingFingerprint: String?
    public let kind: DeepDraftKind
    public let candidateSayNext: String
    public let confidence: Double
    public let basis: [EvidenceReference]
    public let missingEvidence: [String]

    public init(
        turnID: UUID,
        generation: UInt64,
        groundingFingerprint: String?,
        kind: DeepDraftKind,
        candidateSayNext: String,
        confidence: Double,
        basis: [EvidenceReference],
        missingEvidence: [String] = []
    ) {
        self.turnID = turnID
        self.generation = generation
        self.groundingFingerprint = groundingFingerprint
        self.kind = kind
        self.candidateSayNext = candidateSayNext
        self.confidence = confidence
        self.basis = basis
        self.missingEvidence = missingEvidence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case turnID, generation, groundingFingerprint, kind, candidateSayNext, confidence, basis,
            missingEvidence
    }

    public init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(UUID.self, forKey: .turnID)
        generation = try container.decode(UInt64.self, forKey: .generation)
        groundingFingerprint = try container.decodeIfPresent(String.self, forKey: .groundingFingerprint)
        kind = try container.decode(DeepDraftKind.self, forKey: .kind)
        candidateSayNext = try container.decode(String.self, forKey: .candidateSayNext)
        confidence = try container.decode(Double.self, forKey: .confidence)
        basis = try container.decode([EvidenceReference].self, forKey: .basis)
        missingEvidence = try container.decode([String].self, forKey: .missingEvidence)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(generation, forKey: .generation)
        if let groundingFingerprint {
            try container.encode(groundingFingerprint, forKey: .groundingFingerprint)
        } else {
            try container.encodeNil(forKey: .groundingFingerprint)
        }
        try container.encode(kind, forKey: .kind)
        try container.encode(candidateSayNext, forKey: .candidateSayNext)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(basis, forKey: .basis)
        try container.encode(missingEvidence, forKey: .missingEvidence)
    }
}

public struct Reconciliation: Codable, Equatable, Sendable {
    public let relationship: SuggestionRelationship
    public let transition: String

    public init(relationship: SuggestionRelationship, transition: String) {
        self.relationship = relationship
        self.transition = transition
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case relationship, transition
    }

    public init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relationship = try container.decode(SuggestionRelationship.self, forKey: .relationship)
        transition = try container.decode(String.self, forKey: .transition)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
    }
}

private func requireExactKeys<Key: CodingKey & CaseIterable>(
    _ decoder: any Decoder,
    _ keyType: Key.Type
) throws where Key.AllCases: Sequence {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    let expected = Set(keyType.allCases.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "The structured output contained missing or additional keys."
            )
        )
    }
}

public struct BoundDeep: Codable, Equatable, Sendable {
    public let turnID: UUID
    public let generation: UInt64
    public let cueID: UUID
    public let cueHash: String
    public let deepDraftHash: String
    public let groundingFingerprint: String?
    public let kind: DeepDraftKind
    public let relationship: SuggestionRelationship
    public let transition: String
    public let sayNext: String
    public let basis: [EvidenceReference]

    public init(
        turnID: UUID,
        generation: UInt64,
        cueID: UUID,
        cueHash: String,
        deepDraftHash: String,
        groundingFingerprint: String?,
        kind: DeepDraftKind,
        relationship: SuggestionRelationship,
        transition: String,
        sayNext: String,
        basis: [EvidenceReference]
    ) {
        self.turnID = turnID
        self.generation = generation
        self.cueID = cueID
        self.cueHash = cueHash
        self.deepDraftHash = deepDraftHash
        self.groundingFingerprint = groundingFingerprint
        self.kind = kind
        self.relationship = relationship
        self.transition = transition
        self.sayNext = sayNext
        self.basis = basis
    }

    public var composedText: String {
        [transition, sayNext]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func draftHash(_ draft: DeepDraft) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(draft)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SuggestionStage: String, Codable, Sendable {
    case quick
    case bridge
    case deep
}

public struct SuggestionCard: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let identity: TurnIdentity
    public let stage: SuggestionStage
    public let text: String
    public let confidence: Double?
    public let evidence: [EvidenceReference]
    public let deepKind: DeepDraftKind?

    public init(
        id: UUID = UUID(),
        identity: TurnIdentity,
        stage: SuggestionStage,
        text: String,
        confidence: Double? = nil,
        evidence: [EvidenceReference] = [],
        deepKind: DeepDraftKind? = nil
    ) {
        self.id = id
        self.identity = identity
        self.stage = stage
        self.text = text
        self.confidence = confidence
        self.evidence = evidence
        self.deepKind = deepKind
    }
}
