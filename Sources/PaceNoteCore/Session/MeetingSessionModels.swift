import Foundation

public enum MeetingCaptureMode: String, Codable, CaseIterable, Sendable {
    case manualOnly
    case microphoneOnly
    case systemOutputOnly
    case microphoneAndSystemOutput

    public var capturesMicrophone: Bool {
        self == .microphoneOnly || self == .microphoneAndSystemOutput
    }

    public var capturesSystemOutput: Bool {
        self == .systemOutputOnly || self == .microphoneAndSystemOutput
    }

    public var enabledLanes: [AudioLane] {
        var lanes: [AudioLane] = []
        if capturesMicrophone { lanes.append(.microphone) }
        if capturesSystemOutput { lanes.append(.output) }
        return lanes
    }
}

public enum MeetingSystemOutputScope: String, Codable, CaseIterable, Sendable {
    case meetingApplication
    case allSystemAudio
}

public struct MeetingConsent: Equatable, Sendable {
    public let participantDisclosureConfirmed: Bool

    public init(participantDisclosureConfirmed: Bool) {
        self.participantDisclosureConfirmed = participantDisclosureConfirmed
    }
}

public struct MeetingGroundingIdentity: Equatable, Sendable {
    public let repoAlias: String
    public let fingerprint: String

    public init(repoAlias: String, fingerprint: String) {
        self.repoAlias = repoAlias
        self.fingerprint = fingerprint
    }
}

public struct MeetingSessionConfiguration: Sendable {
    public let meetingID: UUID
    public let captureMode: MeetingCaptureMode
    public let localeIdentifier: String
    public let grounding: MeetingGroundingIdentity?
    public let speakerBrief: String?
    public let transcriptRetention: Duration
    public let transcriptContextSeconds: TimeInterval
    public let deepTranscriptContextSeconds: TimeInterval
    public let turnBoundaryDelay: Duration
    public let microphoneAttributionDelay: Duration
    public let systemOutputScope: MeetingSystemOutputScope
    public let soleNearbySpeakerConfirmed: Bool

    public init(
        meetingID: UUID = UUID(),
        captureMode: MeetingCaptureMode,
        localeIdentifier: String = "en-US",
        grounding: MeetingGroundingIdentity? = nil,
        speakerBrief: String? = nil,
        transcriptRetention: Duration = .seconds(180),
        transcriptContextSeconds: TimeInterval = 45,
        deepTranscriptContextSeconds: TimeInterval = 180,
        turnBoundaryDelay: Duration = .milliseconds(450),
        microphoneAttributionDelay: Duration = .milliseconds(250),
        systemOutputScope: MeetingSystemOutputScope = .meetingApplication,
        soleNearbySpeakerConfirmed: Bool = false
    ) {
        precondition(transcriptContextSeconds > 0)
        precondition(deepTranscriptContextSeconds > 0)
        self.meetingID = meetingID
        self.captureMode = captureMode
        self.localeIdentifier = localeIdentifier
        self.grounding = grounding
        self.speakerBrief = SpeakerBriefPolicy.normalized(speakerBrief)
        self.transcriptRetention = transcriptRetention
        self.transcriptContextSeconds = transcriptContextSeconds
        self.deepTranscriptContextSeconds = deepTranscriptContextSeconds
        self.turnBoundaryDelay = turnBoundaryDelay
        self.microphoneAttributionDelay = microphoneAttributionDelay
        self.systemOutputScope = systemOutputScope
        self.soleNearbySpeakerConfirmed = soleNearbySpeakerConfirmed
    }
}

public struct MeetingAudioLaneServices: Sendable {
    public let lane: AudioLane
    public let capture: any AudioCapturing
    public let transcriber: any AudioTranscribing

    public init(
        lane: AudioLane,
        capture: any AudioCapturing,
        transcriber: any AudioTranscribing
    ) {
        self.lane = lane
        self.capture = capture
        self.transcriber = transcriber
    }
}

public struct MeetingAudioServices: Sendable {
    public let microphone: MeetingAudioLaneServices?
    public let systemOutput: MeetingAudioLaneServices?

    public init(
        microphone: MeetingAudioLaneServices? = nil,
        systemOutput: MeetingAudioLaneServices? = nil
    ) {
        self.microphone = microphone
        self.systemOutput = systemOutput
    }
}

public struct MeetingBrownout: Identifiable, Equatable, Sendable {
    public let reason: BrownoutReason
    public let lane: AudioLane?

    public init(reason: BrownoutReason, lane: AudioLane? = nil) {
        self.reason = reason
        self.lane = lane
    }

    public var id: String {
        "\(reason.rawValue):\(lane?.rawValue ?? "session")"
    }

    public var summary: String {
        switch reason {
        case .systemAudioLost:
            "Meeting audio is unavailable. Typed Coach still works."
        case .microphoneLost:
            "Microphone audio is unavailable."
        case .microphoneDisabled:
            "Microphone capture is off."
        case .outputDisabled:
            "Meeting audio capture is off. Use typed Coach for questions."
        case .transcriptUncertain:
            "The local transcript may be incomplete."
        case .transcriptionUnavailable:
            "On-device transcription stopped while audio capture remained active."
        case .transcriberAssetMissing:
            "The local transcription language is not ready."
        case .providerPreparing:
            "The selected AI provider is connecting. Capture and transcription remain active."
        case .codexOffline:
            "The selected AI provider is unavailable."
        case .authenticationExpired:
            "Sign in to the selected AI provider to continue."
        case .accountMismatch:
            "The active AI-provider account does not match this profile."
        case .protocolUnsupported:
            "The selected provider version is not compatible with ChirpCue."
        case .appServerCrashed:
            "The selected provider process stopped unexpectedly."
        case .providerLimited:
            "The selected provider's subscription capacity is temporarily unavailable."
        case .quickLimited:
            "ChirpCue's local quick response limit was reached."
        case .quickTimedOut:
            "The quick response did not finish before its deadline."
        case .quickUnavailable:
            "The quick response provider is unavailable."
        case .quickRejected:
            "The quick response did not pass local validation."
        case .deepLimited:
            "The grounded response path is temporarily limited."
        case .deepBusy:
            "Another deeper response is still finishing."
        case .deepTimedOut:
            "The deeper response did not finish before its deadline."
        case .deepUnavailable:
            "The deeper response provider is unavailable."
        case .deepRejected:
            "The deeper response did not pass local validation."
        case .repositoryChanged:
            "The approved repository changed after its snapshot was sealed."
        case .snapshotBlocked:
            "The repository snapshot was blocked by a safety check."
        case .snapshotBusy:
            "The repository snapshot is still being prepared."
        case .permissionProfileMismatch:
            "The Codex permission profile is not read-only."
        case .skillPolicyMismatch:
            "The selected skill is not approved for this session."
        case .speakerUncertain:
            "Speaker attribution is uncertain."
        }
    }
}

public struct MeetingSessionState: Equatable, Sendable {
    public let phase: MeetingPhase
    public let captureMode: MeetingCaptureMode
    public let consentConfirmed: Bool
    public let isPrepared: Bool
    public let isRunning: Bool
    public let runtime: MeetingSessionRuntimeStatus?
    public let transcript: [TranscriptSegment]
    public let suggestions: [SuggestionCard]
    public let brownouts: [MeetingBrownout]

    public init(
        phase: MeetingPhase,
        captureMode: MeetingCaptureMode,
        consentConfirmed: Bool,
        isPrepared: Bool,
        isRunning: Bool,
        runtime: MeetingSessionRuntimeStatus?,
        transcript: [TranscriptSegment],
        suggestions: [SuggestionCard],
        brownouts: [MeetingBrownout]
    ) {
        self.phase = phase
        self.captureMode = captureMode
        self.consentConfirmed = consentConfirmed
        self.isPrepared = isPrepared
        self.isRunning = isRunning
        self.runtime = runtime
        self.transcript = transcript
        self.suggestions = suggestions
        self.brownouts = brownouts
    }
}

public struct MeetingSessionRuntimeStatus: Equatable, Sendable {
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

public enum MeetingSessionFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidLifecycle
    case consentRequired
    case microphonePermissionRequired
    case microphonePermissionDenied
    case missingAudioServices(AudioLane)
    case invalidAudioServices(AudioLane)
    case transcriptionAssetUnavailable
    case responseSignInRequired
    case responseAccountMismatch
    case responseProtocolUnsupported
    case responseRateLimited
    case responseUnavailable
    case captureUnavailable(AudioLane)
    case captureTeardownFailed(AudioLane)
    case systemAudioPermissionDenied
    case noCandidateQuestion
    case emptyManualQuestion

    public var errorDescription: String? {
        switch self {
        case .invalidLifecycle:
            "That action is not available in the current meeting state."
        case .consentRequired:
            "Confirm participant disclosure before preparing the meeting coach."
        case .microphonePermissionRequired:
            "Microphone permission must be requested explicitly before setup can finish."
        case .microphonePermissionDenied:
            "Microphone permission is denied."
        case .missingAudioServices(let lane):
            "The \(lane.rawValue) audio service is not configured."
        case .invalidAudioServices(let lane):
            "The \(lane.rawValue) audio service is assigned to the wrong lane."
        case .transcriptionAssetUnavailable:
            "The local transcription language could not be prepared."
        case .responseSignInRequired:
            "Sign in to the selected AI provider before starting."
        case .responseAccountMismatch:
            "The selected provider account does not match the confirmed ChirpCue profile."
        case .responseProtocolUnsupported:
            "The installed provider version is not compatible with ChirpCue."
        case .responseRateLimited:
            "The selected provider's subscription capacity is temporarily unavailable. Wait for its allowance to reset, then choose Recheck."
        case .responseUnavailable:
            "The selected provider response runtime could not be prepared."
        case .captureUnavailable(let lane):
            "The \(lane.rawValue) audio route could not be started."
        case .captureTeardownFailed(let lane):
            "The \(lane.rawValue) audio route could not be fully stopped. Retry Stop before starting or resuming."
        case .systemAudioPermissionDenied:
            "System audio capture permission is denied. Allow ChirpCue in System Settings, then try again."
        case .noCandidateQuestion:
            "No recent question from the other party is available to coach yet."
        case .emptyManualQuestion:
            "Enter a question before using Coach."
        }
    }
}

public enum MeetingSessionEvent: Sendable {
    case stateChanged(MeetingSessionState)
    case transcriptUpserted(TranscriptSegment)
    case transcriptRemoved(UUID)
    case transcriptsCleared
    case suggestionThreadStarted(identity: TurnIdentity, question: String)
    case suggestionsCleared(TurnIdentity?)
    case suggestionUpserted(SuggestionCard)
    case suggestionStageFailed(
        identity: TurnIdentity,
        stage: SuggestionStage,
        reason: BrownoutReason
    )
    case suggestionThreadCompleted(TurnIdentity)
    case brownoutActivated(MeetingBrownout)
    case brownoutCleared(MeetingBrownout)
    case failed(MeetingSessionFailure)
}

public protocol MeetingTimeProviding: Sendable {
    func now() -> TimeInterval
}

public struct HostMeetingTimeProvider: MeetingTimeProviding {
    public init() {}

    public func now() -> TimeInterval {
        HostTimestamp.now.seconds
    }
}
