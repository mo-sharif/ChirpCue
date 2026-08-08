import Foundation

public protocol CodexMeetingClient: Sendable {
    var runtimeCapabilities: CodexRuntimeCapabilities { get }

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
    func forkEphemeral(from base: CodexBaseThread, model: String?) async throws
        -> CodexEphemeralThread
    func deleteThread(id: String) async throws
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
        outputSchema: JSONValue?,
        skills: [CodexSkillInvocation]
    ) async throws -> CodexTurnSession
    func interruptTurn(threadID: String, turnID: String) async throws
    func stopRealtimeText(threadID: String) async throws
    func shutdown() async
}

extension CodexAppServerClient: CodexMeetingClient {}

public typealias CodexMeetingClientFactory =
    @Sendable (
        CodexAppServerConfiguration
    ) async throws -> any CodexMeetingClient
