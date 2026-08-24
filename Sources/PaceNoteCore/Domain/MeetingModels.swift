import Foundation

public enum TranscriptSource: String, Codable, CaseIterable, Sendable {
    case you
    case them
    case microphone
    case output
    case unknown

    public var displayName: String {
        switch self {
        case .you: "YOU"
        case .them: "THEM"
        case .microphone: "MIC"
        case .output: "OUTPUT"
        case .unknown: "UNKNOWN"
        }
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let source: TranscriptSource
    public let text: String
    public let startedAt: TimeInterval
    public let endedAt: TimeInterval
    public let isFinal: Bool
    public let confidence: Double?

    public init(
        id: UUID = UUID(),
        source: TranscriptSource,
        text: String,
        startedAt: TimeInterval,
        endedAt: TimeInterval,
        isFinal: Bool,
        confidence: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

public struct TurnIdentity: Codable, Hashable, Sendable {
    public let meetingID: UUID
    public let turnID: UUID
    public let generation: UInt64

    public init(meetingID: UUID, turnID: UUID = UUID(), generation: UInt64) {
        self.meetingID = meetingID
        self.turnID = turnID
        self.generation = generation
    }
}

public struct ConversationTurn: Codable, Equatable, Sendable {
    public let identity: TurnIdentity
    public let question: String
    public let recentTranscript: [TranscriptSegment]
    public let repoAlias: String?
    public let groundingFingerprint: String?

    public init(
        identity: TurnIdentity,
        question: String,
        recentTranscript: [TranscriptSegment],
        repoAlias: String? = nil,
        groundingFingerprint: String? = nil
    ) {
        self.identity = identity
        self.question = question
        self.recentTranscript = recentTranscript
        self.repoAlias = repoAlias
        self.groundingFingerprint = groundingFingerprint
    }
}

public enum MeetingPhase: String, Codable, Sendable {
    case idle
    case permissionRequired
    case ready
    case listening
    case candidateQuestion
    case thinking
    case suggesting
    case paused
    case ended
    case brownout
}

public enum BrownoutReason: String, Codable, CaseIterable, Sendable {
    case systemAudioLost = "SYSTEM_AUDIO_LOST"
    case microphoneLost = "MIC_LOST"
    case microphoneDisabled = "MIC_DISABLED"
    case outputDisabled = "OUTPUT_DISABLED"
    case transcriptUncertain = "TRANSCRIPT_UNCERTAIN"
    case transcriptionUnavailable = "TRANSCRIPTION_UNAVAILABLE"
    case transcriberAssetMissing = "TRANSCRIBER_ASSET_MISSING"
    case providerPreparing = "PROVIDER_PREPARING"
    case codexOffline = "CODEX_OFFLINE"
    case authenticationExpired = "AUTH_EXPIRED"
    case accountMismatch = "ACCOUNT_MISMATCH"
    case protocolUnsupported = "PROTOCOL_UNSUPPORTED"
    case appServerCrashed = "APP_SERVER_CRASHED"
    case providerLimited = "PROVIDER_LIMITED"
    case quickLimited = "QUICK_LIMITED"
    case quickTimedOut = "QUICK_TIMED_OUT"
    case quickUnavailable = "QUICK_UNAVAILABLE"
    case quickRejected = "QUICK_REJECTED"
    case deepLimited = "DEEP_LIMITED"
    case deepBusy = "DEEP_BUSY"
    case deepTimedOut = "DEEP_TIMED_OUT"
    case deepUnavailable = "DEEP_UNAVAILABLE"
    case deepRejected = "DEEP_REJECTED"
    case repositoryChanged = "REPO_CHANGED"
    case snapshotBlocked = "SNAPSHOT_BLOCKED"
    case snapshotBusy = "SNAPSHOT_BUSY"
    case permissionProfileMismatch = "PERMISSION_PROFILE_MISMATCH"
    case skillPolicyMismatch = "SKILL_POLICY_MISMATCH"
    case speakerUncertain = "SPEAKER_UNCERTAIN"

    public var isQuickResponseFailure: Bool {
        switch self {
        case .providerLimited, .quickLimited, .quickTimedOut, .quickUnavailable,
            .quickRejected:
            true
        default:
            false
        }
    }

    public var isDeepResponseFailure: Bool {
        switch self {
        case .providerLimited, .deepLimited, .deepBusy, .deepTimedOut, .deepUnavailable,
            .deepRejected:
            true
        default:
            false
        }
    }
}
