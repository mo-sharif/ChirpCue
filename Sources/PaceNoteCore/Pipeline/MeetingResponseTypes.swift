import Foundation

public struct MeetingResponseRuntime: Equatable, Sendable {
    public let planType: String?
    public let quickRoute: CodexModelRoute
    public let deepRoute: CodexModelRoute
    public let usesRealtimeQuick: Bool

    public init(
        planType: String?,
        quickRoute: CodexModelRoute,
        deepRoute: CodexModelRoute,
        usesRealtimeQuick: Bool
    ) {
        self.planType = planType
        self.quickRoute = quickRoute
        self.deepRoute = deepRoute
        self.usesRealtimeQuick = usesRealtimeQuick
    }
}

public enum MeetingSubscriptionStatus: Equatable, Sendable {
    case signedOut
    case signedIn(planType: String?, redactedLabel: String, identityHash: String)
    case unsupportedAccount
}

public enum MeetingResponseCleanupFailure: String, Equatable, Sendable {
    case interruptTurn
    case stopRealtime
    case deleteThread
    case updateJournal
    case shutdownRuntime
}

public struct MeetingResponseCleanupReport: Equatable, Sendable {
    public let deletedThreadCount: Int
    public let failures: [MeetingResponseCleanupFailure]

    public init(
        deletedThreadCount: Int = 0,
        failures: [MeetingResponseCleanupFailure] = []
    ) {
        self.deletedThreadCount = deletedThreadCount
        self.failures = failures
    }
}

public enum MeetingResponseError: Error, Equatable, LocalizedError, Sendable {
    case signInRequired(CodexChatGPTLogin)
    case credentialStoreUnavailable
    case accountMismatch
    case protocolUnsupported
    case runtimeUnavailable
    case notPrepared
    case providerCapacityUnavailable
    case quickRateLimited
    case deepRateLimited
    case deepAlreadyActive
    case groundingUnavailable
    case groundingMismatch
    case skillPolicyMismatch
    case invalidOutput
    case cleanupFailed

    public var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to the selected subscription provider before starting."
        case .credentialStoreUnavailable:
            "The selected provider cannot read its subscription credentials from the OS credential store."
        case .accountMismatch:
            "The signed-in provider account does not match the account confirmed for ChirpCue."
        case .protocolUnsupported:
            "The installed provider client cannot prove ChirpCue's required read-only protocol."
        case .runtimeUnavailable:
            "The selected provider's isolated local runtime is unavailable."
        case .notPrepared:
            "ChirpCue's response runtime is not ready."
        case .providerCapacityUnavailable:
            "The selected provider's subscription capacity is temporarily unavailable."
        case .quickRateLimited:
            "ChirpCue's local Quick start limit was reached."
        case .deepRateLimited:
            "ChirpCue's local Deep start limit was reached."
        case .deepAlreadyActive:
            "A grounded suggestion is already in progress."
        case .groundingUnavailable:
            "A sealed repository snapshot is required for this grounded answer."
        case .groundingMismatch:
            "The grounded answer did not match the current sealed repository snapshot."
        case .skillPolicyMismatch:
            "The effective Codex skill set did not match ChirpCue's explicit allowlist."
        case .invalidOutput:
            "The selected provider returned a response that did not pass ChirpCue's strict output checks."
        case .cleanupFailed:
            "ChirpCue could not confirm deletion of all transcript-bearing inference work."
        }
    }
}

public protocol MeetingResponseGenerating: ResponseGenerating {
    func prepare() async throws -> MeetingResponseRuntime
    func recoverAfterCleanupFailure() async throws -> MeetingResponseRuntime
    func cancelActiveWork() async
    func shutdown() async -> MeetingResponseCleanupReport
}

public extension MeetingResponseGenerating {
    func recoverAfterCleanupFailure() async throws -> MeetingResponseRuntime {
        await cancelActiveWork()
        return try await prepare()
    }
}

public protocol MeetingSubscriptionManaging: Sendable {
    func subscriptionStatus() async throws -> MeetingSubscriptionStatus
    func startChatGPTSignIn() async throws -> CodexChatGPTLogin
    func logoutChatGPT() async throws
}

public struct MeetingResponseConfiguration: Sendable {
    public let meetingID: UUID
    public let meetingPrivateRoot: URL
    public let codexProfileRoot: URL
    public let executableURL: URL
    public let clientVersion: String
    public let subscriptionPlanType: String?
    public let expectedAccountIdentityHash: String?
    public let speakingStyle: String
    public let groundingSnapshot: GroundingSnapshot?
    public let selectedDomainSkillName: String?
    public let deepComplexity: CodexResponseComplexity
    public let routingPolicy: CodexRoutingPolicy
    public let subscriptionQuickEnabled: Bool
    public let realtimeQuickEnabled: Bool
    public let quickPerMinute: Int
    public let deepPerMinute: Int

    public init(
        meetingID: UUID,
        meetingPrivateRoot: URL,
        codexProfileRoot: URL,
        executableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        ),
        clientVersion: String,
        subscriptionPlanType: String? = nil,
        expectedAccountIdentityHash: String? = nil,
        speakingStyle: String = "calm, direct, and conversational",
        groundingSnapshot: GroundingSnapshot?,
        selectedDomainSkillName: String? = nil,
        deepComplexity: CodexResponseComplexity = .narrowTechnical,
        routingPolicy: CodexRoutingPolicy = .liveCoaching,
        subscriptionQuickEnabled: Bool = true,
        realtimeQuickEnabled: Bool = true,
        quickPerMinute: Int = 8,
        deepPerMinute: Int = 6
    ) {
        self.meetingID = meetingID
        self.meetingPrivateRoot = meetingPrivateRoot.standardizedFileURL
        self.codexProfileRoot = codexProfileRoot.standardizedFileURL
        self.executableURL = executableURL.standardizedFileURL
        self.clientVersion = clientVersion
        self.subscriptionPlanType = subscriptionPlanType
        self.expectedAccountIdentityHash = expectedAccountIdentityHash
        self.speakingStyle = speakingStyle
        self.groundingSnapshot = groundingSnapshot
        self.selectedDomainSkillName = selectedDomainSkillName
        self.deepComplexity = deepComplexity
        self.routingPolicy = routingPolicy
        self.subscriptionQuickEnabled = subscriptionQuickEnabled
        self.realtimeQuickEnabled = realtimeQuickEnabled
        self.quickPerMinute = max(0, quickPerMinute)
        self.deepPerMinute = max(0, deepPerMinute)
    }
}

public protocol MeetingEvidenceVerifying: Sendable {
    func isFresh(_ snapshot: GroundingSnapshot) async -> Bool
    func verifyAnswer(
        candidateSayNext: String,
        _ references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot
    ) async throws
    func verifiedExtractiveFallback(
        references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot,
        maximumWords: Int
    ) async throws -> EvidenceReference?
}

public extension MeetingEvidenceVerifying {
    func verifiedExtractiveFallback(
        references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot,
        maximumWords: Int
    ) async throws -> EvidenceReference? {
        nil
    }
}

public struct DefaultMeetingEvidenceVerifier: MeetingEvidenceVerifying {
    private let verifier: EvidenceVerifier

    public init(verifier: EvidenceVerifier = .init()) {
        self.verifier = verifier
    }

    public func isFresh(_ snapshot: GroundingSnapshot) async -> Bool {
        await verifier.isFresh(snapshot)
    }

    public func verifyAnswer(
        candidateSayNext: String,
        _ references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot
    ) async throws {
        _ = try await verifier.verifyAnswer(
            candidateSayNext: candidateSayNext,
            references: references,
            groundingFingerprint: groundingFingerprint,
            against: snapshot
        )
    }

    public func verifiedExtractiveFallback(
        references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot,
        maximumWords: Int
    ) async throws -> EvidenceReference? {
        try await verifier.verifiedExtractiveFallback(
            references: references,
            groundingFingerprint: groundingFingerprint,
            against: snapshot,
            maximumWords: maximumWords
        )
    }
}
