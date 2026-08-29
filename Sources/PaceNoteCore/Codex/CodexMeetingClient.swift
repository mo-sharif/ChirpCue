import Foundation

public enum CodexCreatedThreadFailureCause: Equatable, Sendable {
    case cancellation
    case client(CodexClientError)
}

public struct CodexCreatedThreadFailure: Error, Equatable, Sendable {
    public let threadID: String
    public let cause: CodexCreatedThreadFailureCause

    public init(threadID: String, cause: CodexCreatedThreadFailureCause) {
        self.threadID = threadID
        self.cause = cause
    }
}

public protocol CodexMeetingClient: Sendable {
    var runtimeCapabilities: CodexRuntimeCapabilities { get }
    var usesDirectEphemeralResponses: Bool { get }

    func account(refreshToken: Bool) async throws -> CodexAccountReadResult
    func startChatGPTLogin(useHostedLoginSuccessPage: Bool) async throws -> CodexChatGPTLogin
    func logout() async throws
    func verifyCapabilities(cwd: String) async throws -> CodexCapabilitySnapshot
    func rateLimits() async throws -> CodexRateLimitsResult
    func listSkills(cwds: [String], forceReload: Bool) async throws -> CodexSkillsResult
    func setSkillExtraRoots(_ roots: [String]) async throws
    func setSkillEnabled(name: String, path: String, enabled: Bool) async throws
        -> CodexSkillsConfigWriteResult
    func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?
    ) async throws -> CodexBaseThread
    func prepareResponseTemplate(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        expectedInstructionSources: [String],
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread
    func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread
    func forkEphemeral(from base: CodexBaseThread, model: String?) async throws
        -> CodexEphemeralThread
    func forkEphemeral(
        from base: CodexBaseThread,
        model: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexEphemeralThread
    func createEphemeralResponseThread(
        from base: CodexBaseThread,
        model: String?,
        baseInstructions: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexEphemeralThread
    func listThreadIDs(cwd: String) async throws -> [String]
    func deleteThread(id: String) async throws
    func startQuick(
        threadID: String,
        text: String,
        realtimePrompt: String,
        model: String?,
        serviceTier: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexQuickSession
    func startQuick(
        threadID: String,
        text: String,
        realtimePrompt: String,
        model: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexQuickSession
    func startTurn(
        threadID: String,
        text: String,
        model: String?,
        effort: String?,
        serviceTier: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexTurnSession
    func startTurn(
        threadID: String,
        text: String,
        model: String?,
        effort: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexTurnSession
    func interruptTurn(threadID: String, turnID: String) async throws
    func disableRealtimeQuick() async
    func stopRealtimeText(threadID: String) async throws
    func shutdown() async
}

public extension CodexMeetingClient {
    var usesDirectEphemeralResponses: Bool { false }

    func listThreadIDs(cwd: String) async throws -> [String] {
        throw CodexClientError.missingCapability("thread/list")
    }

    func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread {
        let base = try await createPersistentBase(
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            model: model,
            baseInstructions: baseInstructions
        )
        try await onCreated(base.id)
        return base
    }

    func prepareResponseTemplate(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        expectedInstructionSources: [String],
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread {
        _ = expectedInstructionSources
        return try await createPersistentBase(
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            model: model,
            baseInstructions: baseInstructions,
            onCreated: onCreated
        )
    }

    func forkEphemeral(
        from base: CodexBaseThread,
        model: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexEphemeralThread {
        let fork = try await forkEphemeral(from: base, model: model)
        try await onCreated(fork.id)
        return fork
    }

    func createEphemeralResponseThread(
        from base: CodexBaseThread,
        model: String?,
        baseInstructions: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexEphemeralThread {
        _ = baseInstructions
        return try await forkEphemeral(
            from: base,
            model: model,
            onCreated: onCreated
        )
    }

    func disableRealtimeQuick() async {}

    func startQuick(
        threadID: String,
        text: String,
        realtimePrompt: String,
        model: String?,
        serviceTier: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexQuickSession {
        try await startQuick(
            threadID: threadID,
            text: text,
            realtimePrompt: realtimePrompt,
            model: model,
            outputSchema: outputSchema,
            skills: skills
        )
    }

    func startTurn(
        threadID: String,
        text: String,
        model: String?,
        effort: String?,
        serviceTier: String?,
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexTurnSession {
        try await startTurn(
            threadID: threadID,
            text: text,
            model: model,
            effort: effort,
            outputSchema: outputSchema,
            skills: skills
        )
    }
}

extension CodexAppServerClient: CodexMeetingClient {}

public typealias CodexMeetingClientFactory =
    @Sendable (
        CodexAppServerConfiguration
    ) async throws -> any CodexMeetingClient
