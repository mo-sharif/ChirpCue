import Foundation

public enum CodexRPCID: Codable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct CodexServerNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

public enum CodexTransportEvent: Equatable, Sendable {
    case notification(CodexServerNotification)
    case rejectedServerRequest(method: String)
    case disconnected
}

public protocol CodexRPCTransporting: Sendable {
    func start() async throws
    func stop() async
    func request(method: String, params: JSONValue?) async throws -> JSONValue
    func sendNotification(method: String, params: JSONValue?) async throws
    func events() async -> AsyncStream<CodexTransportEvent>
}

public enum CodexClientError: Error, Equatable, LocalizedError, Sendable {
    case binaryUnavailable
    case incompatibleBinaryVersion
    case transportUnavailable
    case transportClosed
    case requestTimedOut(method: String)
    case requestFailed(method: String, code: Int)
    case malformedMessage
    case invalidResponse(method: String)
    case notInitialized
    case alreadyInitialized
    case unsupportedPlatform
    case missingCapability(String)
    case permissionProfileUnavailable(String)
    case permissionProfileMismatch
    case threadInvariantFailed
    case turnAlreadyStarting
    case serverRequestRejected(method: String)

    public var errorDescription: String? {
        switch self {
        case .binaryUnavailable:
            "The compatible Codex binary is unavailable."
        case .incompatibleBinaryVersion:
            "The installed Codex version is outside the tested compatibility range."
        case .transportUnavailable:
            "The local Codex transport could not start."
        case .transportClosed:
            "The local Codex transport closed."
        case .requestTimedOut(let method):
            "Codex request \(CodexSafeLabel.method(method)) timed out."
        case .requestFailed(let method, let code):
            "Codex request \(CodexSafeLabel.method(method)) failed (\(code))."
        case .malformedMessage:
            "Codex returned a malformed protocol message."
        case .invalidResponse(let method):
            "Codex returned an invalid response for \(CodexSafeLabel.method(method))."
        case .notInitialized:
            "The Codex client is not initialized."
        case .alreadyInitialized:
            "The Codex client is already initialized."
        case .unsupportedPlatform:
            "This Codex app-server target is not macOS."
        case .missingCapability(let capability):
            "The installed Codex binary is missing \(CodexSafeLabel.capability(capability))."
        case .permissionProfileUnavailable(let profile):
            "The required Codex permission profile \(CodexSafeLabel.capability(profile)) is unavailable."
        case .permissionProfileMismatch:
            "Codex did not activate the required permission profile."
        case .threadInvariantFailed:
            "Codex returned a thread that failed local safety checks."
        case .turnAlreadyStarting:
            "A Codex turn is already starting for this thread."
        case .serverRequestRejected(let method):
            "PaceNote rejected an unexpected Codex server request: \(CodexSafeLabel.method(method))."
        }
    }
}

enum CodexSafeLabel {
    static func method(_ value: String) -> String {
        sanitize(value, fallback: "unknown-method")
    }

    static func capability(_ value: String) -> String {
        sanitize(value, fallback: "unknown-capability")
    }

    private static func sanitize(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:/.-")
        let scalars = value.unicodeScalars.filter { allowed.contains($0) }.prefix(80)
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? fallback : result
    }
}

struct CodexRPCErrorPayload: Codable, Equatable, Sendable {
    let code: Int
    let message: String?
    let data: JSONValue?
}

struct CodexWireMessage: Codable, Equatable, Sendable {
    let id: CodexRPCID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: CodexRPCErrorPayload?
}

enum CodexInboundMessage: Equatable, Sendable {
    case response(id: CodexRPCID, result: JSONValue?, error: CodexRPCErrorPayload?)
    case notification(CodexServerNotification)
    case serverRequest(id: CodexRPCID, method: String, params: JSONValue?)
}

enum CodexWireCodec {
    static func decodeLine(_ data: Data) throws -> CodexInboundMessage {
        let message: CodexWireMessage
        do {
            message = try JSONDecoder().decode(CodexWireMessage.self, from: data)
        } catch {
            throw CodexClientError.malformedMessage
        }

        switch (message.id, message.method) {
        case (.some(let id), .some(let method)):
            return .serverRequest(id: id, method: method, params: message.params)
        case (.none, .some(let method)):
            return .notification(.init(method: method, params: message.params))
        case (.some(let id), .none):
            guard message.result != nil || message.error != nil else {
                throw CodexClientError.malformedMessage
            }
            return .response(id: id, result: message.result, error: message.error)
        case (.none, .none):
            throw CodexClientError.malformedMessage
        }
    }

    static func request(
        method: String,
        id: CodexRPCID,
        params: JSONValue?
    ) throws -> Data {
        try encode(OutboundRequest(method: method, id: id, params: params))
    }

    static func notification(method: String, params: JSONValue?) throws -> Data {
        try encode(OutboundNotification(method: method, params: params))
    }

    static func rejectedServerRequest(id: CodexRPCID) throws -> Data {
        try encode(
            OutboundErrorResponse(
                id: id,
                error: .init(
                    code: -32_000,
                    message: "Client rejects server-initiated requests.",
                    data: nil
                )
            )
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

private struct OutboundRequest: Encodable {
    let method: String
    let id: CodexRPCID
    let params: JSONValue?

    enum CodingKeys: String, CodingKey { case method, id, params }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

private struct OutboundNotification: Encodable {
    let method: String
    let params: JSONValue?

    enum CodingKeys: String, CodingKey { case method, params }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

private struct OutboundErrorResponse: Encodable {
    let id: CodexRPCID
    let error: CodexRPCErrorPayload
}

public struct CodexInitializeResult: Codable, Equatable, Sendable {
    public let userAgent: String
    public let codexHome: String
    public let platformFamily: String
    public let platformOs: String
}

public struct CodexAccountReadResult: Codable, Equatable, Sendable {
    public let account: CodexAccount?
    public let requiresOpenaiAuth: Bool
}

public struct CodexAccount: Codable, Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?
}

public struct CodexChatGPTLogin: Codable, Equatable, Sendable {
    public let type: String
    public let loginId: String
    public let authUrl: String
}

public struct CodexReasoningEffortOption: Codable, Equatable, Sendable {
    public let reasoningEffort: String
    public let description: String
}

public struct CodexModel: Codable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let displayName: String?
    public let hidden: Bool?
    public let supportedReasoningEfforts: [CodexReasoningEffortOption]
    public let defaultReasoningEffort: String?
    public let inputModalities: [String]?
    public let supportsPersonality: Bool?
    public let serviceTiers: [CodexModelServiceTier]?
    public let defaultServiceTier: String?
    public let isDefault: Bool?
}

public struct CodexModelServiceTier: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
}

struct CodexModelListPage: Codable, Sendable {
    let data: [CodexModel]
    let nextCursor: String?
}

public struct CodexListedThread: Codable, Equatable, Sendable {
    public let id: String
}

struct CodexThreadListPage: Codable, Sendable {
    let data: [CodexListedThread]
    let nextCursor: String?
}

public struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Double?
    public let resetsAt: Double?
}

public struct CodexCreditsSnapshot: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
    public let credits: CodexCreditsSnapshot?
    public let spendControlReached: Bool?
    public let planType: String?
    public let rateLimitReachedType: String?
}

public struct CodexRateLimitsResult: Codable, Equatable, Sendable {
    public let rateLimits: CodexRateLimitSnapshot
    public let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
    public let rateLimitResetCredits: JSONValue?
}

public struct CodexPermissionProfile: Codable, Equatable, Sendable {
    public let id: String
    public let description: String?
    public let allowed: Bool
}

struct CodexPermissionProfilePage: Codable, Sendable {
    let data: [CodexPermissionProfile]
    let nextCursor: String?
}

public struct CodexSkill: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let path: String
    public let scope: String
    public let enabled: Bool
    public let interface: JSONValue?
    public let dependencies: JSONValue?
}

public struct CodexSkillError: Codable, Equatable, Sendable {
    public let path: String
    public let message: String
}

public struct CodexSkillsListEntry: Codable, Equatable, Sendable {
    public let cwd: String
    public let skills: [CodexSkill]
    public let errors: [CodexSkillError]
}

public struct CodexSkillsResult: Codable, Equatable, Sendable {
    public let data: [CodexSkillsListEntry]
}

public struct CodexActivePermissionProfile: Codable, Equatable, Sendable {
    public let id: String
    public let extends: String?
}

public struct CodexThread: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let forkedFromId: String?
    public let ephemeral: Bool
}

struct CodexThreadConfigurationResult: Codable, Sendable {
    let thread: CodexThread
    let model: String
    let modelProvider: String
    let serviceTier: String?
    let cwd: String
    let runtimeWorkspaceRoots: [String]
    let instructionSources: [String]
    let approvalPolicy: JSONValue
    let activePermissionProfile: CodexActivePermissionProfile?
    let reasoningEffort: String?
}

public struct CodexBaseThread: Equatable, Sendable {
    public let id: String
    public let model: String
    public let permissionProfileID: String
    public let cwd: String
    public let runtimeWorkspaceRoots: [String]
    public let instructionSources: [String]
}

public struct CodexEphemeralThread: Equatable, Sendable {
    public let id: String
    public let baseThreadID: String
    public let model: String
    public let permissionProfileID: String
    public let cwd: String
    public let runtimeWorkspaceRoots: [String]
    public let instructionSources: [String]
}

public struct CodexSkillsConfigWriteResult: Codable, Equatable, Sendable {
    public let effectiveEnabled: Bool
}

struct CodexTurnStartResult: Codable, Sendable {
    let turn: CodexTurn
}

public struct CodexTurn: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let items: [JSONValue]?
    public let error: JSONValue?
}

public struct CodexSkillInvocation: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum CodexTurnEvent: Equatable, Sendable {
    case agentMessageDelta(itemID: String, delta: String)
    case itemCompleted(JSONValue)
    case completed(status: String)
    case notification(method: String, params: JSONValue?)
}

public struct CodexTurnSession: Sendable {
    public let threadID: String
    public let turnID: String
    public let events: AsyncThrowingStream<CodexTurnEvent, any Error>

    public init(
        threadID: String,
        turnID: String,
        events: AsyncThrowingStream<CodexTurnEvent, any Error>
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.events = events
    }
}

public struct CodexCapabilitySnapshot: Equatable, Sendable {
    public let models: [CodexModel]
    public let permissionProfiles: [CodexPermissionProfile]
    public let skills: [CodexSkillsListEntry]
}

public struct CodexRuntimeCapabilities: Equatable, Sendable {
    public let realtimeTextV3: Bool

    public init(realtimeTextV3: Bool) {
        self.realtimeTextV3 = realtimeTextV3
    }

    public static let none = CodexRuntimeCapabilities(realtimeTextV3: false)
}

public enum CodexRealtimeTextRole: String, Sendable {
    case user
    case developer
    case assistant
}

public enum CodexRealtimeEvent: Equatable, Sendable {
    case started(sessionID: String?, version: String)
    case transcriptDelta(role: String, delta: String)
    case transcriptDone(role: String, text: String)
    case itemAdded(JSONValue)
    case closed
}

public struct CodexRealtimeSession: Sendable {
    public let threadID: String
    public let events: AsyncThrowingStream<CodexRealtimeEvent, any Error>

    public init(
        threadID: String,
        events: AsyncThrowingStream<CodexRealtimeEvent, any Error>
    ) {
        self.threadID = threadID
        self.events = events
    }
}

public enum CodexQuickSession: Sendable {
    case realtime(CodexRealtimeSession)
    case turn(CodexTurnSession)
}
