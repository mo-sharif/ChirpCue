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
            "Sign in to the isolated PaceNote Codex profile with ChatGPT."
        case .credentialStoreUnavailable:
            "The dedicated PaceNote Codex profile cannot read ChatGPT credentials from the OS credential store."
        case .accountMismatch:
            "The signed-in ChatGPT account does not match this PaceNote profile."
        case .protocolUnsupported:
            "This Codex build cannot prove PaceNote's required read-only protocol."
        case .runtimeUnavailable:
            "The isolated local Codex runtime is unavailable."
        case .notPrepared:
            "PaceNote's Codex response runtime is not ready."
        case .quickRateLimited:
            "Fast suggestions are temporarily rate limited."
        case .deepRateLimited:
            "Grounded suggestions are temporarily rate limited."
        case .deepAlreadyActive:
            "A grounded suggestion is already in progress."
        case .groundingUnavailable:
            "A sealed repository snapshot is required for this grounded answer."
        case .groundingMismatch:
            "The grounded answer did not match the current sealed repository snapshot."
        case .skillPolicyMismatch:
            "The effective Codex skill set did not match PaceNote's explicit allowlist."
        case .invalidOutput:
            "Codex returned a response that did not pass PaceNote's strict output checks."
        case .cleanupFailed:
            "PaceNote could not confirm deletion of all transcript-bearing Codex work."
        }
    }
}

public protocol MeetingResponseGenerating: ResponseGenerating {
    func prepare() async throws -> MeetingResponseRuntime
    func cancelActiveWork() async
    func shutdown() async -> MeetingResponseCleanupReport
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
        routingPolicy: CodexRoutingPolicy = .codex_0_147,
        quickPerMinute: Int = 8,
        deepPerMinute: Int = 2
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
}
